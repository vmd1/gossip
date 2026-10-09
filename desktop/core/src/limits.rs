//! Per-connection resource limits: the inbound flood guard and the bounded queue of frames that arrive before the
//! user has confirmed a new pairing.

/// More than this many frames inside one second means a peer is flooding the mesh (the flood-forwarding relay
/// would amplify it), so the connection is dropped. Real traffic is orders of magnitude below it.
pub const DEFAULT_FRAMES_PER_SECOND: u32 = 400;

#[derive(Debug, Clone)]
pub struct InboundRateLimiter {
    limit: u32,
    window_start_ms: i64,
    count: u32,
}

impl Default for InboundRateLimiter {
    fn default() -> Self {
        Self::new(DEFAULT_FRAMES_PER_SECOND)
    }
}

impl InboundRateLimiter {
    pub fn new(limit_per_second: u32) -> Self {
        Self {
            limit: limit_per_second,
            window_start_ms: i64::MIN / 2,
            count: 0,
        }
    }

    /// Counts one frame at `now_ms`; `false` once the current one-second window is over budget.
    pub fn allow(&mut self, now_ms: i64) -> bool {
        if now_ms - self.window_start_ms >= 1000 || now_ms < self.window_start_ms {
            self.window_start_ms = now_ms;
            self.count = 0;
        }
        self.count += 1;
        self.count <= self.limit
    }
}

/// Transport frames received after the handshake but before the peer is confirmed. Noise nonces are implicit
/// counters, so dropping them undecrypted would desynchronise the session for good; they are held and decrypted in
/// order at promotion. Bounded by count and by total bytes (a single frame may be megabytes), so an unconfirmed
/// peer cannot make this device buffer without limit.
pub const PENDING_FRAME_LIMIT: usize = 256;
pub const PENDING_BYTE_LIMIT: usize = 4 * 1024 * 1024;

#[derive(Debug, Clone, Default)]
pub struct PendingFrameQueue {
    frames: Vec<Vec<u8>>,
    bytes: usize,
}

impl PendingFrameQueue {
    /// `false` (frame not stored) once either cap is hit; the connection should then be closed.
    pub fn enqueue(&mut self, frame: Vec<u8>) -> bool {
        if self.frames.len() >= PENDING_FRAME_LIMIT || self.bytes + frame.len() > PENDING_BYTE_LIMIT
        {
            return false;
        }
        self.bytes += frame.len();
        self.frames.push(frame);
        true
    }

    pub fn drain(&mut self) -> Vec<Vec<u8>> {
        self.bytes = 0;
        std::mem::take(&mut self.frames)
    }

    pub fn len(&self) -> usize {
        self.frames.len()
    }

    pub fn is_empty(&self) -> bool {
        self.frames.is_empty()
    }
}

/// A bounded, insertion-ordered "already handled" cache keyed by something that uniquely identifies an *attempt*
/// (a fresh UUID minted per send), not the message id, which is reused. This is the repo's idempotency pattern for
/// handlers whose side effect must not repeat (`media.command` `commandId`, `notification.reply` `attemptId`,
/// `device.ring` `ringId`).
#[derive(Debug, Clone)]
pub struct RecentIds {
    ids: std::collections::VecDeque<String>,
    capacity: usize,
}

impl RecentIds {
    pub fn new(capacity: usize) -> Self {
        Self {
            ids: std::collections::VecDeque::new(),
            capacity: capacity.max(1),
        }
    }

    /// Records `id`; `true` if it was new (act on it), `false` if it was already handled.
    pub fn first_time(&mut self, id: &str) -> bool {
        if self.ids.iter().any(|x| x == id) {
            return false;
        }
        self.ids.push_back(id.to_owned());
        if self.ids.len() > self.capacity {
            self.ids.pop_front();
        }
        true
    }

    pub fn contains(&self, id: &str) -> bool {
        self.ids.iter().any(|x| x == id)
    }
}
