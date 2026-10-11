//! Origin authentication: an Ed25519 signature by `senderId` over the envelope's canonical form.
//!
//! The signed bytes are the domain tag `"gossip-envelope-v1\n"` followed by canonical JSON of
//! `v, id, type, senderId, recipientId, broadcast, hasRawFollowup, ts, payload` (`ttl` is excluded because every
//! relay decrements it). Canonical JSON: object keys sorted by UTF-8 bytes, no whitespace, integer-only numbers,
//! strings escaping only `"`, `\` and control characters. Checked against `schema/envelope-signing-vectors.json`.

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use serde_json::Value;
use thiserror::Error;

use crate::wire::envelope::Envelope;

pub const DOMAIN: &[u8] = b"gossip-envelope-v1\n";

/// Largest integer a JSON double represents exactly; both apps reject anything outside it.
const MAX_SAFE_INTEGER: f64 = 9_007_199_254_740_992.0;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum CanonicalError {
    #[error("payload contains a number that is not an integer within +/-2^53")]
    UnsupportedNumber,
}

/// The exact bytes that get signed.
pub fn signing_bytes(e: &Envelope) -> Result<Vec<u8>, CanonicalError> {
    let mut out = DOMAIN.to_vec();
    canonical_envelope(e, &mut out)?;
    Ok(out)
}

fn canonical_envelope(e: &Envelope, out: &mut Vec<u8>) -> Result<(), CanonicalError> {
    // Keys in sorted order, written by hand so the envelope fields never round-trip through a map.
    out.push(b'{');
    out.extend_from_slice(br#""broadcast":"#);
    out.extend_from_slice(if e.broadcast { b"true" } else { b"false" });
    out.extend_from_slice(br#","hasRawFollowup":"#);
    out.extend_from_slice(if e.has_raw_followup {
        b"true"
    } else {
        b"false"
    });
    out.extend_from_slice(br#","id":"#);
    write_string(&e.id, out);
    out.extend_from_slice(br#","payload":"#);
    canonical_value(&Value::Object(e.payload.clone()), out)?;
    out.extend_from_slice(br#","recipientId":"#);
    match &e.recipient_id {
        Some(r) => write_string(r, out),
        None => out.extend_from_slice(b"null"),
    }
    out.extend_from_slice(br#","senderId":"#);
    write_string(&e.sender_id, out);
    out.extend_from_slice(br#","ts":"#);
    out.extend_from_slice(e.ts.to_string().as_bytes());
    out.extend_from_slice(br#","type":"#);
    write_string(&e.kind, out);
    out.extend_from_slice(br#","v":"#);
    out.extend_from_slice(e.v.to_string().as_bytes());
    out.push(b'}');
    Ok(())
}

/// Canonical JSON for an arbitrary value.
pub fn canonical_value(value: &Value, out: &mut Vec<u8>) -> Result<(), CanonicalError> {
    match value {
        Value::Null => out.extend_from_slice(b"null"),
        Value::Bool(b) => out.extend_from_slice(if *b { b"true" } else { b"false" }),
        Value::Number(n) => out.extend_from_slice(integer(n)?.to_string().as_bytes()),
        Value::String(s) => write_string(s, out),
        Value::Array(items) => {
            out.push(b'[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(b',');
                }
                canonical_value(item, out)?;
            }
            out.push(b']');
        }
        Value::Object(map) => {
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort_by(|a, b| a.as_bytes().cmp(b.as_bytes()));
            out.push(b'{');
            for (i, key) in keys.into_iter().enumerate() {
                if i > 0 {
                    out.push(b',');
                }
                write_string(key, out);
                out.push(b':');
                canonical_value(&map[key], out)?;
            }
            out.push(b'}');
        }
    }
    Ok(())
}

/// Integers only. A whole-valued float such as `3.0` is accepted (the Swift app decodes every number as a
/// `Double`), anything fractional or beyond +/-2^53 is rejected.
fn integer(n: &serde_json::Number) -> Result<i64, CanonicalError> {
    if let Some(i) = n.as_i64() {
        return if (i as f64).abs() < MAX_SAFE_INTEGER {
            Ok(i)
        } else {
            Err(CanonicalError::UnsupportedNumber)
        };
    }
    match n.as_f64() {
        Some(f) if f == f.round() && f.abs() < MAX_SAFE_INTEGER => Ok(f as i64),
        _ => Err(CanonicalError::UnsupportedNumber),
    }
}

fn write_string(s: &str, out: &mut Vec<u8>) {
    out.push(b'"');
    for &byte in s.as_bytes() {
        match byte {
            b'"' => out.extend_from_slice(b"\\\""),
            b'\\' => out.extend_from_slice(b"\\\\"),
            0x08 => out.extend_from_slice(b"\\b"),
            0x09 => out.extend_from_slice(b"\\t"),
            0x0a => out.extend_from_slice(b"\\n"),
            0x0c => out.extend_from_slice(b"\\f"),
            0x0d => out.extend_from_slice(b"\\r"),
            0..=0x1f => out.extend_from_slice(format!("\\u{byte:04x}").as_bytes()),
            _ => out.push(byte),
        }
    }
    out.push(b'"');
}

/// Signs `e`, returning it with `sig` set (base64).
pub fn sign(mut e: Envelope, key: &SigningKey) -> Result<Envelope, CanonicalError> {
    let signature = key.sign(&signing_bytes(&e)?);
    e.sig = Some(B64.encode(signature.to_bytes()));
    Ok(e)
}

/// Whether `e.sig` is a valid signature by `key`. Any malformed input is simply `false`.
pub fn verify(e: &Envelope, key: &VerifyingKey) -> bool {
    let Some(sig) = e.sig.as_deref() else {
        return false;
    };
    let Ok(raw) = B64.decode(sig) else {
        return false;
    };
    let Ok(signature) = Signature::from_slice(&raw) else {
        return false;
    };
    let Ok(bytes) = signing_bytes(e) else {
        return false;
    };
    key.verify(&bytes, &signature).is_ok()
}
