//! The core never reads a clock or an RNG itself: everything environmental comes through [`Env`].
//! That keeps it sans-IO and makes every behaviour reproducible in tests.

use sha2::{Digest, Sha256};

pub trait Env {
    /// Milliseconds since the Unix epoch (wall clock; used for envelope `ts` and skew checks).
    fn now_ms(&self) -> i64;
    /// Fills `buf` with cryptographically secure random bytes.
    fn random_bytes(&mut self, buf: &mut [u8]);

    fn random_array<const N: usize>(&mut self) -> [u8; N] {
        let mut out = [0u8; N];
        self.random_bytes(&mut out);
        out
    }

    /// A random version-4 UUID in canonical lowercase form.
    fn new_uuid(&mut self) -> String {
        let mut b = self.random_array::<16>();
        b[6] = (b[6] & 0x0f) | 0x40;
        b[8] = (b[8] & 0x3f) | 0x80;
        crate::wire::uuid::format(&b)
    }
}

/// Wall clock and OS randomness.
#[cfg(feature = "system-env")]
#[derive(Debug, Default, Clone, Copy)]
pub struct SystemEnv;

#[cfg(feature = "system-env")]
impl Env for SystemEnv {
    fn now_ms(&self) -> i64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0)
    }

    fn random_bytes(&mut self, buf: &mut [u8]) {
        getrandom::fill(buf).expect("operating system randomness unavailable");
    }
}

/// A deterministic environment: a settable clock and a SHA-256 counter-mode byte stream seeded from `seed`.
/// Not secure; for tests and vector generation only.
#[derive(Debug, Clone)]
pub struct TestEnv {
    pub now: i64,
    seed: [u8; 32],
    counter: u64,
}

impl TestEnv {
    pub fn new(seed: u8, now: i64) -> Self {
        Self {
            now,
            seed: [seed; 32],
            counter: 0,
        }
    }
}

impl Env for TestEnv {
    fn now_ms(&self) -> i64 {
        self.now
    }

    fn random_bytes(&mut self, buf: &mut [u8]) {
        for chunk in buf.chunks_mut(32) {
            self.counter += 1;
            let mut h = Sha256::new();
            h.update(self.seed);
            h.update(self.counter.to_be_bytes());
            let block = h.finalize();
            chunk.copy_from_slice(&block[..chunk.len()]);
        }
    }
}
