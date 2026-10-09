//! Length-prefixed framing: `[4-byte big-endian length][payload]`.
//!
//! The decoder is a stream parser: feed it whatever bytes arrive (a TCP read, a WebSocket message) and pull whole
//! frames out. Message boundaries of the underlying transport are irrelevant. The declared length is checked
//! against a limit before anything is buffered for it, so a hostile length cannot make the decoder allocate.

use thiserror::Error;

pub const HEADER_LEN: usize = 4;
/// Frames before the Noise session is established (the two handshake messages).
pub const MAX_HANDSHAKE_FRAME: usize = 16 * 1024;
/// Frames once the session is established.
pub const MAX_TRANSPORT_FRAME: usize = 16 * 1024 * 1024;

#[derive(Debug, Error, PartialEq, Eq, Clone, Copy)]
pub enum FrameError {
    #[error("declared frame length {declared} exceeds the limit {limit}")]
    TooLarge { declared: usize, limit: usize },
}

/// Prepends the length header. Panics only if `payload` exceeds `u32::MAX`, which no limit permits.
pub fn encode(payload: &[u8]) -> Vec<u8> {
    let len = u32::try_from(payload.len()).expect("frame payload larger than 4 GiB");
    let mut out = Vec::with_capacity(HEADER_LEN + payload.len());
    out.extend_from_slice(&len.to_be_bytes());
    out.extend_from_slice(payload);
    out
}

#[derive(Debug, Clone)]
pub struct FrameDecoder {
    buf: Vec<u8>,
    limit: usize,
}

impl FrameDecoder {
    pub fn new(limit: usize) -> Self {
        Self {
            buf: Vec::new(),
            limit,
        }
    }

    pub fn set_limit(&mut self, limit: usize) {
        self.limit = limit;
    }

    pub fn limit(&self) -> usize {
        self.limit
    }

    /// Bytes buffered but not yet returned as a frame.
    pub fn buffered(&self) -> usize {
        self.buf.len()
    }

    pub fn push(&mut self, bytes: &[u8]) {
        self.buf.extend_from_slice(bytes);
    }

    /// The next complete frame, `Ok(None)` if more bytes are needed, or an error if the declared length is over
    /// the limit (the connection should then be closed).
    pub fn next_frame(&mut self) -> Result<Option<Vec<u8>>, FrameError> {
        if self.buf.len() < HEADER_LEN {
            return Ok(None);
        }
        let declared =
            u32::from_be_bytes(self.buf[..HEADER_LEN].try_into().expect("length checked")) as usize;
        if declared > self.limit {
            return Err(FrameError::TooLarge {
                declared,
                limit: self.limit,
            });
        }
        let total = HEADER_LEN + declared;
        if self.buf.len() < total {
            return Ok(None);
        }
        let frame = self.buf[HEADER_LEN..total].to_vec();
        self.buf.drain(..total);
        Ok(Some(frame))
    }
}
