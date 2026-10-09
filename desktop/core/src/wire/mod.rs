//! The byte-level wire format: length-prefixed frames, JSON envelopes and the handshake identity.

pub mod envelope;
pub mod frame;
pub mod handshake;
pub mod uuid;
