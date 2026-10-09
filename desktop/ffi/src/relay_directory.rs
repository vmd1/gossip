//! The relay directory: validation, the keep-the-cache decision rule and the polling schedule. The shells do the HTTP
//! and the file; see `gossip_core::relay_directory`.

use std::sync::{Arc, Mutex, MutexGuard};

use gossip_core::env::SystemEnv;
use gossip_core::relay_directory as core;

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// The only domain a directory may name: the host must equal it or end with `.` plus it.
#[uniffi::export]
pub fn relay_directory_allowed_domain_suffix() -> String {
    core::ALLOWED_RELAY_DOMAIN_SUFFIX.to_owned()
}

/// Largest directory blob the shells should read (they cap the body at 64 KiB; the core accepts 16 KiB).
#[uniffi::export]
pub fn relay_directory_max_bytes() -> u32 {
    core::MAX_DIRECTORY_BYTES as u32
}

/// Validates a directory blob and returns the normalized `relayServer` origin, or `None` when it is not acceptable.
#[uniffi::export]
pub fn relay_directory_parse(json: String, allow_insecure_local: bool) -> Option<String> {
    core::parse_directory(&json, allow_insecure_local)
        .ok()
        .map(|d| d.relay_server)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DirectoryAction {
    /// The fetch was valid: use `relay_server` and persist the raw blob that was fetched.
    Adopt,
    /// The fetch failed or was invalid: keep the cached copy (do not touch the file).
    KeepCached,
    /// Nothing valid anywhere: use the built-in default.
    NoDirectory,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct DirectoryDecision {
    pub action: DirectoryAction,
    /// The relay origin to use, when there is one.
    pub relay_server: Option<String>,
    /// For `Adopt`: whether it differs from the cached copy (reconfigure the relay).
    pub changed: bool,
    /// For `KeepCached`/`NoDirectory` after a fetch that arrived but was rejected: a short reason, safe to log.
    pub rejection: Option<String>,
}

/// Decides what to do after a fetch. `cached_json` is the raw blob on disk (re-validated here, so a corrupt or tampered
/// file is ignored); `fetched_json` is the raw body, or `None` when the request failed. A failed or invalid fetch never
/// replaces or clears a valid cached copy.
#[uniffi::export]
pub fn relay_directory_decide(
    cached_json: Option<String>,
    fetched_json: Option<String>,
    allow_insecure_local: bool,
) -> DirectoryDecision {
    let cached = cached_json.and_then(|j| core::parse_directory(&j, allow_insecure_local).ok());
    let (fetched, rejection) = match fetched_json {
        None => (Err(core::DirectoryError::NotJson), None),
        Some(j) => match core::parse_directory(&j, allow_insecure_local) {
            Ok(d) => (Ok(d), None),
            Err(e) => {
                let why = e.to_string();
                (Err(e), Some(why))
            }
        },
    };
    match core::merge(cached, fetched) {
        core::Decision::Adopt { directory, changed } => DirectoryDecision {
            action: DirectoryAction::Adopt,
            relay_server: Some(directory.relay_server),
            changed,
            rejection: None,
        },
        core::Decision::KeepCached(d) => DirectoryDecision {
            action: DirectoryAction::KeepCached,
            relay_server: Some(d.relay_server),
            changed: false,
            rejection,
        },
        core::Decision::NoDirectory => DirectoryDecision {
            action: DirectoryAction::NoDirectory,
            relay_server: None,
            changed: false,
            rejection,
        },
    }
}

/// The polling schedule: poll on launch, then every six hours (+-10% jitter); retry a failure with exponential backoff
/// (1 min, doubling, 30 min cap); an extra poll after a relay connect failure at most every ten minutes. Times are
/// milliseconds since the Unix epoch, supplied by the shell.
#[derive(uniffi::Object)]
pub struct RelayDirectoryScheduler(Mutex<core::DirectoryCache>);

#[uniffi::export]
impl RelayDirectoryScheduler {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        let mut env = SystemEnv;
        Arc::new(Self(Mutex::new(core::DirectoryCache::new(&mut env))))
    }

    /// Fixed jitter (thousandths, clamped to +-100), for tests.
    #[uniffi::constructor]
    pub fn with_jitter_permille(jitter_permille: i64) -> Arc<Self> {
        Arc::new(Self(Mutex::new(
            core::DirectoryCache::with_jitter_permille(jitter_permille),
        )))
    }

    pub fn should_poll(
        &self,
        now_ms: i64,
        last_success_ms: Option<i64>,
        last_attempt_ms: Option<i64>,
        failures: u32,
    ) -> bool {
        lock(&self.0).should_poll(now_ms, last_success_ms, last_attempt_ms, failures)
    }

    pub fn should_poll_after_connect_failure(
        &self,
        now_ms: i64,
        last_attempt_ms: Option<i64>,
    ) -> bool {
        lock(&self.0).should_poll_after_connect_failure(now_ms, last_attempt_ms)
    }

    /// Draws a fresh jitter; call after each attempt.
    pub fn reroll(&self) {
        let mut env = SystemEnv;
        lock(&self.0).reroll(&mut env);
    }

    pub fn backoff_ms(&self, failures: u32) -> i64 {
        core::DirectoryCache::backoff_ms(failures)
    }
}
