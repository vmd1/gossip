//! The directional counter-nonce AEAD shared by the screen-mirroring and Universal Control data channels.
//!
//! Both are the same construction under different labels: HKDF-SHA256 (ikm = the per-session secret, salt = the
//! UTF-8 session id, info = `"<label> <direction>"`) derives one ChaCha20-Poly1305 key per direction; each message
//! is `[u64 BE counter][ciphertext][16-byte tag]` with nonce = four zero bytes plus the counter; AAD is
//! `label || direction byte || session id`. A receiver accepts only counters strictly greater than the last one it
//! authenticated, which makes replays and duplicates harmless. Checked against `schema/screen-cipher-vectors.json`
//! and `schema/control-test-vectors.json`.

use chacha20poly1305::{aead::Aead, aead::Payload, ChaCha20Poly1305, Key, KeyInit, Nonce};
use hkdf::Hkdf;
use sha2::Sha256;
use thiserror::Error;
use zeroize::{Zeroize, ZeroizeOnDrop};

const TAG_LEN: usize = 16;
const COUNTER_LEN: usize = 8;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum StreamError {
    #[error("message too short")]
    BadLength,
    #[error("counter not greater than the last accepted one")]
    Replayed,
    #[error("authentication failed")]
    Authentication,
    #[error("send counter exhausted")]
    Exhausted,
}

/// Names the two data channels that use this construction.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Profile {
    pub label: &'static str,
    /// Name of direction 1 and direction 2 in the HKDF info string.
    pub directions: [&'static str; 2],
}

impl Profile {
    /// Universal Control: direction 1 is Mac to device, 2 is device to Mac.
    pub const CONTROL: Profile = Profile {
        label: "gossip-control-v1",
        directions: ["m2d", "d2m"],
    };
    /// Screen mirroring: direction 1 is viewer to device, 2 is device to viewer.
    pub const SCREEN: Profile = Profile {
        label: "gossip-screen-v1",
        directions: ["v2d", "d2v"],
    };
}

/// Which end of the channel this is. `First` sends direction 1 (Mac / viewer), `Second` sends direction 2.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum End {
    First,
    Second,
}

#[derive(ZeroizeOnDrop)]
pub struct StreamCipher {
    send_key: [u8; 32],
    recv_key: [u8; 32],
    #[zeroize(skip)]
    send_dir: u8,
    #[zeroize(skip)]
    recv_dir: u8,
    #[zeroize(skip)]
    label: &'static str,
    #[zeroize(skip)]
    session_id: Vec<u8>,
    #[zeroize(skip)]
    send_counter: u64,
    #[zeroize(skip)]
    last_received: u64,
}

impl std::fmt::Debug for StreamCipher {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("StreamCipher")
            .field("label", &self.label)
            .finish_non_exhaustive()
    }
}

fn derive(secret: &[u8], session_id: &[u8], label: &str, name: &str) -> [u8; 32] {
    let hk = Hkdf::<Sha256>::new(Some(session_id), secret);
    let mut key = [0u8; 32];
    hk.expand(format!("{label} {name}").as_bytes(), &mut key)
        .expect("32 bytes is a valid HKDF output length");
    key
}

fn nonce(counter: u64) -> [u8; 12] {
    let mut n = [0u8; 12];
    n[4..].copy_from_slice(&counter.to_be_bytes());
    n
}

impl StreamCipher {
    pub fn new(profile: Profile, secret: &[u8], session_id: &str, end: End) -> Self {
        let sid = session_id.as_bytes();
        let (send_dir, recv_dir) = if end == End::First {
            (1u8, 2u8)
        } else {
            (2u8, 1u8)
        };
        let mut send_key = derive(
            secret,
            sid,
            profile.label,
            profile.directions[send_dir as usize - 1],
        );
        let mut recv_key = derive(
            secret,
            sid,
            profile.label,
            profile.directions[recv_dir as usize - 1],
        );
        let out = Self {
            send_key,
            recv_key,
            send_dir,
            recv_dir,
            label: profile.label,
            session_id: sid.to_vec(),
            send_counter: 0,
            last_received: 0,
        };
        send_key.zeroize();
        recv_key.zeroize();
        out
    }

    fn aad(&self, dir: u8) -> Vec<u8> {
        let mut a = self.label.as_bytes().to_vec();
        a.push(dir);
        a.extend_from_slice(&self.session_id);
        a
    }

    /// Seals `plaintext` with the next send counter (starting at 1).
    pub fn seal(&mut self, plaintext: &[u8]) -> Result<Vec<u8>, StreamError> {
        self.send_counter = self
            .send_counter
            .checked_add(1)
            .ok_or(StreamError::Exhausted)?;
        Ok(self.seal_with_counter(plaintext, self.send_counter))
    }

    /// Seals with an explicit counter. Used by the shared test vectors; never call it with a reused counter.
    pub fn seal_with_counter(&self, plaintext: &[u8], counter: u64) -> Vec<u8> {
        let cipher = ChaCha20Poly1305::new(Key::from_slice(&self.send_key));
        let ct = cipher
            .encrypt(
                Nonce::from_slice(&nonce(counter)),
                Payload {
                    msg: plaintext,
                    aad: &self.aad(self.send_dir),
                },
            )
            .expect("ChaCha20-Poly1305 encryption of an in-memory buffer cannot fail");
        let mut out = Vec::with_capacity(COUNTER_LEN + ct.len());
        out.extend_from_slice(&counter.to_be_bytes());
        out.extend_from_slice(&ct);
        out
    }

    /// Opens a message from the other end. The replay counter only advances after authentication succeeds, so
    /// garbage cannot burn counters.
    pub fn open(&mut self, message: &[u8]) -> Result<Vec<u8>, StreamError> {
        if message.len() < COUNTER_LEN + TAG_LEN {
            return Err(StreamError::BadLength);
        }
        let counter =
            u64::from_be_bytes(message[..COUNTER_LEN].try_into().expect("length checked"));
        if counter <= self.last_received {
            return Err(StreamError::Replayed);
        }
        let cipher = ChaCha20Poly1305::new(Key::from_slice(&self.recv_key));
        let pt = cipher
            .decrypt(
                Nonce::from_slice(&nonce(counter)),
                Payload {
                    msg: &message[COUNTER_LEN..],
                    aad: &self.aad(self.recv_dir),
                },
            )
            .map_err(|_| StreamError::Authentication)?;
        self.last_received = counter;
        Ok(pt)
    }
}
