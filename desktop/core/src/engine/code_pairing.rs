//! Pairing by a short code: the engine side of `crypto::code_pake`.
//!
//! The device being added (the *shower*) calls [`Core::start_code_pairing`] and displays the code. The user types it
//! into a device that is already paired (the *enterer*), which finds the shower on the network and calls
//! [`Core::dial_code`] on a fresh connection to it. Four plaintext envelopes then cross that connection:
//!
//! 1. `pair.code.a` (enterer to shower): the enterer's SPAKE2 message;
//! 2. `pair.code.b` (shower to enterer): the shower's SPAKE2 message;
//! 3. `pair.code.proof` (enterer to shower): the enterer's identity, sealed under a key only the right code yields;
//! 4. `pair.code.done` (shower to enterer): the shower's identity, sealed the same way.
//!
//! A shower that opens the proof knows the other side typed the right code, trusts it, and answers; the enterer
//! that opens the answer trusts the shower. Either side then closes the connection and the two connect the normal
//! way (the Noise handshake, now that each trusts the other's keys). A wrong code never opens anything, so the
//! shower counts it as a failed attempt and invalidates the code after [`CODE_ATTEMPTS`].

use super::*;
use crate::crypto::code_pake::{
    self, PairIdentity, PakeError, Side, KIND_A, KIND_B, KIND_DONE, KIND_PROOF,
};

/// Wrong codes the shower tolerates before the code stops working.
pub const CODE_ATTEMPTS: u32 = 5;
/// How long a code can be used.
pub const CODE_LIFETIME_MS: i64 = 300_000;
/// After a successful pairing the same device may retry (a lost reply) for this long; nobody else may.
const RETRY_WINDOW_MS: i64 = 60_000;
/// Simultaneous in-progress exchanges the shower accepts.
const MAX_CODE_CONNECTIONS: usize = 3;

pub(super) struct CodeShow {
    code: String,
    expires_ms: i64,
    failures: u32,
    /// A device that completed the exchange, and until when it may repeat it.
    done: Option<(String, i64)>,
}

/// What happened in a pairing by code. The shell shows it; trust changes arrive separately as `TrustChanged`.
#[derive(Debug, Clone, PartialEq)]
pub enum CodePairingEvent {
    /// The pairing completed: `peer` is now trusted.
    Succeeded { peer: PeerInfo },
    /// Shower: someone typed a wrong code.
    WrongCode { attempts_left: u32 },
    /// Shower: too many wrong codes, the code no longer works; start again for a new one.
    TooManyAttempts,
    /// Shower: the code was not used in time.
    Expired,
    /// Enterer: the device did not accept the code (wrong code, or it went away).
    Rejected { device_id: Option<String> },
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum CodePairingError {
    #[error("that is not a valid pairing code")]
    BadCode,
    #[error("that is not a valid device id")]
    BadTarget,
    #[error("connection id already in use")]
    DuplicateConnection,
    #[error("pairing by code only works over a direct connection")]
    NotDirect,
}

impl<E: Env> Core<E> {
    /// Starts showing a pairing code (replacing any earlier one). Returns it for display, as `ABCD-EFGH`. Valid for
    /// five minutes or [`CODE_ATTEMPTS`] wrong tries.
    pub fn start_code_pairing(&mut self) -> String {
        let code = code_pake::generate_code(self.env.random_array());
        self.code_show = Some(CodeShow {
            code: code.clone(),
            expires_ms: self.env.now_ms() + CODE_LIFETIME_MS,
            failures: 0,
            done: None,
        });
        code_pake::display_code(&code)
    }

    pub fn stop_code_pairing(&mut self) {
        self.code_show = None;
    }

    /// Whether a code is currently being shown (the shell advertises "pairing mode" while it is).
    pub fn code_pairing_active(&self) -> bool {
        self.code_show
            .as_ref()
            .is_some_and(|s| self.env.now_ms() < s.expires_ms && s.failures < CODE_ATTEMPTS)
    }

    /// The code was typed on this device: begin the exchange on `conn`, a fresh connection the shell opened to
    /// `target` (a device found showing a code). The first message is returned as a `Send`.
    pub fn dial_code(
        &mut self,
        conn: ConnId,
        target: &str,
        code: &str,
    ) -> Result<Out, CodePairingError> {
        if is_virtual(conn) {
            return Err(CodePairingError::NotDirect);
        }
        if self.conns.contains_key(&conn) {
            return Err(CodePairingError::DuplicateConnection);
        }
        let code = code_pake::normalize_code(code).ok_or(CodePairingError::BadCode)?;
        if !crate::wire::uuid::is_valid(target) {
            return Err(CodePairingError::BadTarget);
        }
        let now = self.env.now_ms();
        let seed = self.env.random_array::<32>();
        let (session, message) =
            PakeSession::start(Side::Enterer, &code, &self.identity.device_id, target, seed);
        let mut c = Conn::new(Role::Initiator, Stage::CodeEntererAwaitB, now);
        c.pake = Some(session);
        c.code_peer = Some(target.to_owned());
        self.conns.insert(conn, c);
        let frame = self.pake_frame(KIND_A, target, "pake", &message);
        let mut out = Vec::new();
        self.emit_send(conn, frame, &mut out);
        Ok(out)
    }

    pub(super) fn is_code_pairing_start(&self, payload: &[u8]) -> bool {
        Envelope::decode(payload).is_ok_and(|e| e.kind == KIND_A)
    }

    /// Tick: forget an unused code, and a finished exchange's retry window.
    pub(super) fn code_pairing_tick(&mut self, now: i64, out: &mut Out) {
        if let Some(show) = &mut self.code_show {
            if show.done.as_ref().is_some_and(|(_, until)| now >= *until) {
                show.done = None;
            }
            if now >= show.expires_ms {
                self.code_show = None;
                out.push(Action::Event(Event::CodePairing(CodePairingEvent::Expired)));
            }
        }
    }

    // ---- Shower ------------------------------------------------------------------------------------------------

    /// Shower: `pair.code.a`, the first frame of an exchange.
    pub(super) fn code_shower_handle_a(&mut self, conn: ConnId, payload: &[u8], out: &mut Out) {
        let now = self.env.now_ms();
        let accepted = (|| -> Option<()> {
            let env = Envelope::decode(payload).ok()?;
            let show = self.code_show.as_ref()?;
            if now >= show.expires_ms || show.failures >= CODE_ATTEMPTS {
                return None;
            }
            if !crate::wire::uuid::is_valid(&env.sender_id)
                || env.sender_id == self.identity.device_id
            {
                return None;
            }
            // After a pairing completed only that device may repeat it.
            if let Some((id, until)) = &show.done {
                if now < *until && *id != env.sender_id {
                    return None;
                }
            }
            let in_progress = self
                .conns
                .values()
                .filter(|c| c.stage == Stage::CodeShowerAwaitProof)
                .count();
            if in_progress >= MAX_CODE_CONNECTIONS {
                return None;
            }
            let message = payload_b64(&env, "pake")?;
            let code = show.code.clone();
            let seed = self.env.random_array::<32>();
            let (mut session, reply) = PakeSession::start(
                Side::Shower,
                &code,
                &env.sender_id,
                &self.identity.device_id,
                seed,
            );
            session.finish(&message).ok()?;
            let c = self.conns.get_mut(&conn)?;
            c.handshake = None;
            c.pake = Some(session);
            c.code_peer = Some(env.sender_id.clone());
            c.stage = Stage::CodeShowerAwaitProof;
            c.stage_since_ms = now;
            let frame = self.pake_frame(KIND_B, &env.sender_id, "pake", &reply);
            self.emit_send(conn, frame, out);
            Some(())
        })();
        if accepted.is_none() {
            self.drop_conn(conn, true, out);
        }
    }

    /// Shower: `pair.code.proof`. Opening it proves the other side typed the right code.
    pub(super) fn code_shower_handle_proof(&mut self, conn: ConnId, payload: &[u8], out: &mut Out) {
        let now = self.env.now_ms();
        let opened = (|| -> Result<PairIdentity, PakeError> {
            let env = Envelope::decode(payload).map_err(|_| PakeError::Malformed)?;
            let c = self.conns.get(&conn).ok_or(PakeError::Malformed)?;
            if env.kind != KIND_PROOF || Some(&env.sender_id) != c.code_peer.as_ref() {
                return Err(PakeError::Malformed);
            }
            let sealed = payload_b64(&env, "box").ok_or(PakeError::Malformed)?;
            let plain = c.pake.as_ref().ok_or(PakeError::Malformed)?.open(&sealed)?;
            let ident = PairIdentity::decode(&plain)?;
            if Some(&ident.device_id) != c.code_peer.as_ref() {
                return Err(PakeError::Malformed);
            }
            Ok(ident)
        })();
        let ident = match opened {
            Ok(i) => i,
            Err(_) => {
                self.code_shower_failed(out);
                self.drop_conn(conn, true, out);
                return;
            }
        };
        let first_time = self
            .code_show
            .as_ref()
            .is_some_and(|s| s.done.as_ref().map(|(id, _)| id) != Some(&ident.device_id));
        let sealed_reply = {
            let own = self.own_pair_identity().encode();
            let Some(c) = self.conns.get(&conn) else {
                return;
            };
            match c.pake.as_ref().map(|p| p.seal(&own)) {
                Some(Ok(sealed)) => sealed,
                _ => {
                    self.drop_conn(conn, true, out);
                    return;
                }
            }
        };
        let peer = self.trust_pair_identity(&ident, out);
        if let Some(show) = &mut self.code_show {
            show.done = Some((ident.device_id.clone(), now + RETRY_WINDOW_MS));
        }
        if let Some(c) = self.conns.get_mut(&conn) {
            c.stage = Stage::CodeShowerDone;
            c.stage_since_ms = now;
        }
        let frame = self.pake_frame(KIND_DONE, &ident.device_id, "box", &sealed_reply);
        self.emit_send(conn, frame, out);
        if first_time {
            out.push(Action::Event(Event::CodePairing(
                CodePairingEvent::Succeeded { peer },
            )));
        }
    }

    /// Shower: a wrong or malformed proof counts against the code.
    fn code_shower_failed(&mut self, out: &mut Out) {
        let Some(show) = &mut self.code_show else {
            return;
        };
        show.failures += 1;
        if show.failures >= CODE_ATTEMPTS {
            self.code_show = None;
            out.push(Action::Event(Event::CodePairing(
                CodePairingEvent::TooManyAttempts,
            )));
        } else {
            out.push(Action::Event(Event::CodePairing(
                CodePairingEvent::WrongCode {
                    attempts_left: CODE_ATTEMPTS - show.failures,
                },
            )));
        }
    }

    // ---- Enterer -----------------------------------------------------------------------------------------------

    /// Enterer: `pair.code.b`. Send the proof.
    pub(super) fn code_enterer_handle_b(&mut self, conn: ConnId, payload: &[u8], out: &mut Out) {
        let now = self.env.now_ms();
        let own = self.own_pair_identity().encode();
        let result = (|| -> Option<(String, Vec<u8>)> {
            let env = Envelope::decode(payload).ok()?;
            let c = self.conns.get_mut(&conn)?;
            if env.kind != KIND_B || Some(&env.sender_id) != c.code_peer.as_ref() {
                return None;
            }
            let message = payload_b64(&env, "pake")?;
            let session = c.pake.as_mut()?;
            session.finish(&message).ok()?;
            let sealed = session.seal(&own).ok()?;
            c.stage = Stage::CodeEntererAwaitDone;
            c.stage_since_ms = now;
            Some((env.sender_id, sealed))
        })();
        match result {
            Some((target, sealed)) => {
                let frame = self.pake_frame(KIND_PROOF, &target, "box", &sealed);
                self.emit_send(conn, frame, out);
            }
            None => self.drop_conn(conn, true, out),
        }
    }

    /// Enterer: `pair.code.done`. Opening it proves the shower used the same code; trust it.
    pub(super) fn code_enterer_handle_done(&mut self, conn: ConnId, payload: &[u8], out: &mut Out) {
        let opened = (|| -> Option<PairIdentity> {
            let env = Envelope::decode(payload).ok()?;
            let c = self.conns.get(&conn)?;
            if env.kind != KIND_DONE || Some(&env.sender_id) != c.code_peer.as_ref() {
                return None;
            }
            let sealed = payload_b64(&env, "box")?;
            let plain = c.pake.as_ref()?.open(&sealed).ok()?;
            let ident = PairIdentity::decode(&plain).ok()?;
            (Some(&ident.device_id) == c.code_peer.as_ref()).then_some(ident)
        })();
        let Some(ident) = opened else {
            self.drop_conn(conn, true, out);
            return;
        };
        let peer = self.trust_pair_identity(&ident, out);
        out.push(Action::Event(Event::CodePairing(
            CodePairingEvent::Succeeded { peer },
        )));
        // Done: close without the "rejected" event a failed exchange reports.
        self.remove_conn_entry(conn);
        Self::emit_close(conn, out);
    }

    // ---- Shared ------------------------------------------------------------------------------------------------

    /// Trusts the device that proved it knew the code. A direct pairing replaces any earlier row and lifts a
    /// revocation tombstone; an identical row is left alone, so repeating the exchange changes nothing.
    fn trust_pair_identity(&mut self, ident: &PairIdentity, out: &mut Out) -> PeerInfo {
        let noise = ident.noise_key();
        let signing = ident.signing_key();
        let device_type = DeviceType::parse(&ident.device_type);
        let name: String = ident
            .device_name
            .chars()
            .take(crate::wire::handshake::MAX_DEVICE_NAME_CHARS)
            .collect();
        let unchanged = self.trust.device(&ident.device_id).is_some_and(|d| {
            keys_match(&d.public_key, &noise)
                && d.signing_public_key.as_deref() == Some(&*B64.encode(signing))
        }) && !self.trust.is_provisional(&ident.device_id);
        if !unchanged {
            let added_at = self.env.now_ms();
            self.trust.add_device(TrustedDevice {
                device_id: ident.device_id.clone(),
                public_key: B64.encode(noise),
                device_name: name.clone(),
                device_type: device_type.as_str().to_owned(),
                added_at,
                signing_public_key: Some(B64.encode(signing)),
                beacon_key: None,
            });
            out.push(Action::Event(Event::TrustChanged(self.trust.snapshot())));
        }
        PeerInfo {
            device_id: ident.device_id.clone(),
            device_name: name,
            device_type,
            signing_public_key: signing,
            noise_public_key: noise,
        }
    }

    fn own_pair_identity(&self) -> PairIdentity {
        let own = self.identity.handshake_identity(None);
        PairIdentity {
            device_id: own.device_id,
            device_name: own.device_name,
            device_type: own.device_type,
            noise_public_key: B64.encode(self.identity.noise.public_bytes()),
            signing_public_key: own.signing_public_key,
        }
    }

    /// A length-framed plaintext envelope of `kind` carrying `bytes` (base64) under `field`.
    fn pake_frame(&mut self, kind: &str, recipient: &str, field: &str, bytes: &[u8]) -> Vec<u8> {
        let mut payload = Map::new();
        payload.insert(field.to_owned(), Value::String(B64.encode(bytes)));
        let envelope = self.new_envelope(kind).to(recipient).with_payload(payload);
        frame::encode(&envelope.encode())
    }
}

fn payload_b64(envelope: &Envelope, field: &str) -> Option<Vec<u8>> {
    match envelope.payload.get(field) {
        Some(Value::String(s)) => B64.decode(s).ok(),
        _ => None,
    }
}
