//! Pairing by a short code, without either device knowing the other's key beforehand.
//!
//! The new device shows an 8-character code; the user types it into a device that is already paired. The two run
//! SPAKE2 (a password-authenticated key exchange) with the code as the password, so:
//! - the code never crosses the network and cannot be brute-forced offline from a recording (each guess needs a live
//!   run against the device that shows the code, which allows only a few);
//! - both sides end up with the same key only if they used the same code, and prove it by decrypting each other's
//!   identity (device id, name, type, Noise key, signing key) under keys derived from it.
//!
//! This module is the pure part (code alphabet, key schedule, sealed identity). The connection stages that carry the
//! four messages live in the engine (`engine/code_pairing.rs`).

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Nonce};
use hkdf::Hkdf;
use rand_core::{CryptoRng, RngCore};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use spake2::{Ed25519Group, Identity, Password, Spake2};
use thiserror::Error;

use crate::wire::uuid;

pub const CODE_LEN: usize = 8;
/// 32 symbols (5 bits each, 40 bits per code): no 0, O, 1, I, so a code read off a screen is unambiguous.
pub const ALPHABET: &[u8; 32] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

/// Envelope kinds of the four plaintext frames of a code pairing.
pub const KIND_A: &str = "pair.code.a";
pub const KIND_B: &str = "pair.code.b";
pub const KIND_PROOF: &str = "pair.code.proof";
pub const KIND_DONE: &str = "pair.code.done";

#[derive(Debug, Error, PartialEq, Eq)]
pub enum PakeError {
    #[error("the pairing message is malformed")]
    Malformed,
    #[error("the code did not match")]
    Mismatch,
}

/// A fresh random code (`CODE_LEN` characters of [`ALPHABET`]).
pub fn generate_code(random: [u8; CODE_LEN]) -> String {
    random
        .iter()
        .map(|b| ALPHABET[(*b & 31) as usize] as char)
        .collect()
}

/// What the user typed as a canonical code: upper-cased, spaces and dashes dropped. `None` unless it is exactly
/// `CODE_LEN` characters of [`ALPHABET`].
pub fn normalize_code(input: &str) -> Option<String> {
    let code: String = input
        .chars()
        .filter(|c| !c.is_whitespace() && *c != '-')
        .flat_map(char::to_uppercase)
        .collect();
    (code.len() == CODE_LEN && code.bytes().all(|b| ALPHABET.contains(&b))).then_some(code)
}

/// The code as shown to the user: `ABCD-EFGH`.
pub fn display_code(code: &str) -> String {
    if code.len() == CODE_LEN {
        format!("{}-{}", &code[..4], &code[4..])
    } else {
        code.to_owned()
    }
}

/// A deterministic stream from a seed the engine draws from its `Env`, so SPAKE2's randomness comes from the same
/// place as everything else (and tests are reproducible).
struct SeedRng {
    seed: [u8; 32],
    counter: u64,
}

impl RngCore for SeedRng {
    fn next_u32(&mut self) -> u32 {
        let mut b = [0u8; 4];
        self.fill_bytes(&mut b);
        u32::from_le_bytes(b)
    }
    fn next_u64(&mut self) -> u64 {
        let mut b = [0u8; 8];
        self.fill_bytes(&mut b);
        u64::from_le_bytes(b)
    }
    fn fill_bytes(&mut self, dest: &mut [u8]) {
        for chunk in dest.chunks_mut(32) {
            let mut h = Sha256::new();
            h.update(b"gossip-code-pake-rng");
            h.update(self.seed);
            h.update(self.counter.to_le_bytes());
            self.counter += 1;
            let block = h.finalize();
            chunk.copy_from_slice(&block[..chunk.len()]);
        }
    }
    fn try_fill_bytes(&mut self, dest: &mut [u8]) -> Result<(), rand_core::Error> {
        self.fill_bytes(dest);
        Ok(())
    }
}

// The seed is drawn from the engine's secure `Env`, so this is as strong as that.
impl CryptoRng for SeedRng {}

/// Which side of the exchange this is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Side {
    /// The device where the code is typed (SPAKE2 side A).
    Enterer,
    /// The device that shows the code (SPAKE2 side B).
    Shower,
}

struct Keys {
    send: [u8; 32],
    recv: [u8; 32],
    transcript: [u8; 32],
}

/// One run of the exchange.
pub struct PakeSession {
    side: Side,
    spake: Option<Spake2<Ed25519Group>>,
    own_message: Vec<u8>,
    keys: Option<Keys>,
}

impl PakeSession {
    /// Starts a run. Returns the session and the first message to send. `enterer_id` and `shower_id` are the two
    /// device ids, bound into the exchange; `seed` is 32 fresh random bytes.
    pub fn start(
        side: Side,
        code: &str,
        enterer_id: &str,
        shower_id: &str,
        seed: [u8; 32],
    ) -> (Self, Vec<u8>) {
        let password = Password::new(code.as_bytes());
        let id_a = Identity::new(enterer_id.as_bytes());
        let id_b = Identity::new(shower_id.as_bytes());
        let rng = SeedRng { seed, counter: 0 };
        let (spake, message) = match side {
            Side::Enterer => Spake2::<Ed25519Group>::start_a_with_rng(&password, &id_a, &id_b, rng),
            Side::Shower => Spake2::<Ed25519Group>::start_b_with_rng(&password, &id_a, &id_b, rng),
        };
        (
            Self {
                side,
                spake: Some(spake),
                own_message: message.clone(),
                keys: None,
            },
            message,
        )
    }

    /// Completes the exchange with the other side's message and derives the session keys. Succeeds whatever the
    /// codes were (SPAKE2 cannot tell); a wrong code shows up when [`Self::open`] fails.
    pub fn finish(&mut self, peer_message: &[u8]) -> Result<(), PakeError> {
        let spake = self.spake.take().ok_or(PakeError::Malformed)?;
        let shared = spake
            .finish(peer_message)
            .map_err(|_| PakeError::Malformed)?;
        let (a, b) = match self.side {
            Side::Enterer => (self.own_message.as_slice(), peer_message),
            Side::Shower => (peer_message, self.own_message.as_slice()),
        };
        let mut t = Sha256::new();
        t.update(b"gossip-code-pake-transcript-v1");
        t.update((a.len() as u32).to_be_bytes());
        t.update(a);
        t.update((b.len() as u32).to_be_bytes());
        t.update(b);
        let transcript: [u8; 32] = t.finalize().into();

        let hk = Hkdf::<Sha256>::new(Some(b"gossip-code-pake-v1"), &shared);
        let mut e2n = [0u8; 32];
        let mut n2e = [0u8; 32];
        hk.expand(b"enterer-to-shower", &mut e2n)
            .map_err(|_| PakeError::Malformed)?;
        hk.expand(b"shower-to-enterer", &mut n2e)
            .map_err(|_| PakeError::Malformed)?;
        let (send, recv) = match self.side {
            Side::Enterer => (e2n, n2e),
            Side::Shower => (n2e, e2n),
        };
        self.keys = Some(Keys {
            send,
            recv,
            transcript,
        });
        Ok(())
    }

    /// Encrypts one message to the other side (each direction carries exactly one, so the nonce is fixed).
    pub fn seal(&self, plaintext: &[u8]) -> Result<Vec<u8>, PakeError> {
        let keys = self.keys.as_ref().ok_or(PakeError::Malformed)?;
        ChaCha20Poly1305::new((&keys.send).into())
            .encrypt(
                Nonce::from_slice(&[0u8; 12]),
                Payload {
                    msg: plaintext,
                    aad: &keys.transcript,
                },
            )
            .map_err(|_| PakeError::Malformed)
    }

    /// Decrypts the other side's message. Fails when the two sides used different codes.
    pub fn open(&self, sealed: &[u8]) -> Result<Vec<u8>, PakeError> {
        let keys = self.keys.as_ref().ok_or(PakeError::Malformed)?;
        ChaCha20Poly1305::new((&keys.recv).into())
            .decrypt(
                Nonce::from_slice(&[0u8; 12]),
                Payload {
                    msg: sealed,
                    aad: &keys.transcript,
                },
            )
            .map_err(|_| PakeError::Mismatch)
    }
}

/// Who a device is, exchanged (sealed) once the codes agree.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PairIdentity {
    #[serde(rename = "deviceId")]
    pub device_id: String,
    #[serde(rename = "deviceName")]
    pub device_name: String,
    #[serde(rename = "deviceType")]
    pub device_type: String,
    /// Base64 raw X25519 (Noise static) public key.
    #[serde(rename = "noisePublicKey")]
    pub noise_public_key: String,
    /// Base64 raw Ed25519 public key.
    #[serde(rename = "signingPublicKey")]
    pub signing_public_key: String,
}

impl PairIdentity {
    pub fn encode(&self) -> Vec<u8> {
        serde_json::to_vec(self).expect("an identity always serialises")
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, PakeError> {
        let id: Self = serde_json::from_slice(bytes).map_err(|_| PakeError::Malformed)?;
        let key_ok = |k: &str| B64.decode(k).map(|b| b.len() == 32).unwrap_or(false);
        if !uuid::is_valid(&id.device_id)
            || !key_ok(&id.noise_public_key)
            || !key_ok(&id.signing_public_key)
        {
            return Err(PakeError::Malformed);
        }
        Ok(id)
    }

    pub fn noise_key(&self) -> [u8; 32] {
        B64.decode(&self.noise_public_key)
            .ok()
            .and_then(|k| k.try_into().ok())
            .unwrap_or([0; 32])
    }

    pub fn signing_key(&self) -> [u8; 32] {
        B64.decode(&self.signing_public_key)
            .ok()
            .and_then(|k| k.try_into().ok())
            .unwrap_or([0; 32])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const A: &str = "11111111-1111-4111-8111-111111111111";
    const B: &str = "22222222-2222-4222-8222-222222222222";

    fn run(code_a: &str, code_b: &str) -> (PakeSession, PakeSession) {
        let (mut e, ma) = PakeSession::start(Side::Enterer, code_a, A, B, [1; 32]);
        let (mut s, mb) = PakeSession::start(Side::Shower, code_b, A, B, [2; 32]);
        e.finish(&mb).unwrap();
        s.finish(&ma).unwrap();
        (e, s)
    }

    #[test]
    fn codes_use_the_unambiguous_alphabet() {
        let code = generate_code([0, 1, 2, 3, 255, 128, 64, 31]);
        assert_eq!(code.len(), CODE_LEN);
        assert!(code.bytes().all(|b| ALPHABET.contains(&b)));
        assert!(!ALPHABET.contains(&b'0') && !ALPHABET.contains(&b'O'));
        assert!(!ALPHABET.contains(&b'1') && !ALPHABET.contains(&b'I'));
        assert_eq!(display_code("ABCDEFGH"), "ABCD-EFGH");
    }

    #[test]
    fn typed_codes_are_normalised_or_refused() {
        assert_eq!(normalize_code("abcd-efgh").as_deref(), Some("ABCDEFGH"));
        assert_eq!(
            normalize_code(" ab cd\tEF-GH ").as_deref(),
            Some("ABCDEFGH")
        );
        assert_eq!(normalize_code("ABCDEFG"), None, "too short");
        assert_eq!(normalize_code("ABCDEFGHJ"), None, "too long");
        assert_eq!(normalize_code("ABCDEF0H"), None, "0 is not in the alphabet");
        assert_eq!(normalize_code("ABCDEFIH"), None, "I is not in the alphabet");
        assert_eq!(normalize_code(""), None);
    }

    #[test]
    fn the_same_code_gives_each_side_the_other_sides_identity() {
        let (e, s) = run("ABCDEFGH", "ABCDEFGH");
        let sealed = e.seal(b"from the enterer").unwrap();
        assert_eq!(s.open(&sealed).unwrap(), b"from the enterer");
        let back = s.seal(b"from the shower").unwrap();
        assert_eq!(e.open(&back).unwrap(), b"from the shower");
    }

    #[test]
    fn a_wrong_code_cannot_open_anything() {
        let (e, s) = run("ABCDEFGH", "ABCDEFGJ");
        assert_eq!(s.open(&e.seal(b"x").unwrap()), Err(PakeError::Mismatch));
        assert_eq!(e.open(&s.seal(b"y").unwrap()), Err(PakeError::Mismatch));
    }

    #[test]
    fn a_message_for_one_run_does_not_open_in_another() {
        let (e1, _s1) = run("ABCDEFGH", "ABCDEFGH");
        let (mut e2, ma) = PakeSession::start(Side::Enterer, "ABCDEFGH", A, B, [9; 32]);
        let (mut s2, mb) = PakeSession::start(Side::Shower, "ABCDEFGH", A, B, [8; 32]);
        e2.finish(&mb).unwrap();
        s2.finish(&ma).unwrap();
        assert_eq!(
            s2.open(&e1.seal(b"replay").unwrap()),
            Err(PakeError::Mismatch)
        );
    }

    #[test]
    fn different_device_ids_break_the_exchange() {
        let (mut e, ma) = PakeSession::start(Side::Enterer, "ABCDEFGH", A, B, [1; 32]);
        let (mut s, mb) = PakeSession::start(Side::Shower, "ABCDEFGH", A, A, [2; 32]);
        e.finish(&mb).unwrap();
        s.finish(&ma).unwrap();
        assert_eq!(s.open(&e.seal(b"x").unwrap()), Err(PakeError::Mismatch));
    }

    #[test]
    fn malformed_messages_are_refused() {
        let (mut e, _) = PakeSession::start(Side::Enterer, "ABCDEFGH", A, B, [1; 32]);
        assert_eq!(e.finish(&[1, 2, 3]), Err(PakeError::Malformed));
    }

    #[test]
    fn identities_are_validated() {
        let good = PairIdentity {
            device_id: A.into(),
            device_name: "Mac".into(),
            device_type: "mac".into(),
            noise_public_key: B64.encode([7u8; 32]),
            signing_public_key: B64.encode([8u8; 32]),
        };
        assert_eq!(PairIdentity::decode(&good.encode()).unwrap(), good);
        let mut bad = good.clone();
        bad.device_id = "nope".into();
        assert!(PairIdentity::decode(&bad.encode()).is_err());
        let mut bad = good.clone();
        bad.noise_public_key = "AAAA".into();
        assert!(PairIdentity::decode(&bad.encode()).is_err());
    }
}
