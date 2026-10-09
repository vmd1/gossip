//! The relay directory: a small JSON blob, served over HTTPS by the operator, whose `relayServer` key names the
//! relay the apps should currently use. Sans-IO: this module only validates a blob and decides what to do with it; the
//! shell fetches it (HTTPS only, no redirects to other hosts, short timeout, small body cap, nothing identifying sent)
//! and stores the raw blob it accepted.
//!
//! # Trust
//!
//! The directory is trusted to name the relay: whatever `wss://`/`ws://` host it gives is used. A relay cannot read
//! or forge traffic (Noise end to end, keys pinned at pairing); a rogue one would see metadata only. The user's
//! explicit custom relay URL is a separate setting that the shells honour first.
//!
//! The origin returned in [`RelayDirectory::relay_server`] is the exact string handed to `relay_configure`, and the
//! engine signs it into every join. It must therefore equal the `RELAY_ORIGIN` the relay itself is configured with
//! (`wss://host[:port]`, no trailing slash).
//!
//! Unknown fields in the blob are ignored, so the operator can add keys without breaking old clients.

use serde_json::Value;

use crate::env::Env;

/// Largest blob accepted by [`parse_directory`].
pub const MAX_DIRECTORY_BYTES: usize = 16 * 1024;

/// Normal refresh period.
pub const POLL_INTERVAL_MS: i64 = 6 * 60 * 60 * 1000;
/// The refresh period is jittered by up to this many thousandths either way (10%).
pub const POLL_JITTER_PERMILLE: i64 = 100;
/// First retry delay after a failed poll; doubles per consecutive failure.
pub const BACKOFF_MIN_MS: i64 = 60 * 1000;
/// Retry delay cap.
pub const BACKOFF_MAX_MS: i64 = 30 * 60 * 1000;
/// Minimum gap between polls triggered by a relay connect failure.
pub const CONNECT_FAILURE_POLL_GAP_MS: i64 = 10 * 60 * 1000;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelayDirectory {
    /// `wss://host[:port]` (or `ws://`): ready for `relay_configure`.
    pub relay_server: String,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum DirectoryError {
    #[error("the directory is larger than {MAX_DIRECTORY_BYTES} bytes")]
    TooLarge,
    #[error("the directory is not valid JSON")]
    NotJson,
    #[error("the directory is not a JSON object")]
    NotObject,
    #[error("the directory has no relayServer")]
    MissingRelayServer,
    #[error("relayServer is not a string")]
    WrongType,
    #[error("relayServer is not a ws:// or wss:// URL with a host")]
    Invalid,
}

/// Parses a directory blob into the relay origin (`wss://host[:port]`, trailing `/` stripped).
pub fn parse_directory(json: &str) -> Result<RelayDirectory, DirectoryError> {
    if json.len() > MAX_DIRECTORY_BYTES {
        return Err(DirectoryError::TooLarge);
    }
    let value: Value = serde_json::from_str(json).map_err(|_| DirectoryError::NotJson)?;
    let Value::Object(map) = value else {
        return Err(DirectoryError::NotObject);
    };
    let server = map
        .get("relayServer")
        .ok_or(DirectoryError::MissingRelayServer)?;
    let Value::String(server) = server else {
        return Err(DirectoryError::WrongType);
    };
    normalize_relay_server(server).map(|relay_server| RelayDirectory { relay_server })
}

fn normalize_relay_server(text: &str) -> Result<String, DirectoryError> {
    let text = text.trim();
    let rest = text
        .strip_prefix("wss://")
        .or_else(|| text.strip_prefix("ws://"))
        .ok_or(DirectoryError::Invalid)?;
    let origin = text.strip_suffix('/').unwrap_or(text);
    let authority = rest.strip_suffix('/').unwrap_or(rest);
    if authority.is_empty() || authority.starts_with([':', '/']) {
        return Err(DirectoryError::Invalid);
    }
    Ok(origin.to_owned())
}

/// What the shell should do after a fetch attempt.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decision {
    /// The fetch produced a valid directory: use it and persist the raw blob it came from (even when unchanged, to
    /// refresh the last-success time). `changed` says whether the relay differs from the previous cached copy.
    Adopt {
        directory: RelayDirectory,
        changed: bool,
    },
    /// The fetch failed or was invalid; keep using (and keep on disk) the cached copy.
    KeepCached(RelayDirectory),
    /// Nothing cached and nothing valid fetched: the built-in default applies.
    NoDirectory,
}

/// A failed or invalid fetch never replaces or clears a valid cached copy; a valid fetch replaces it.
pub fn merge(
    cached: Option<RelayDirectory>,
    fetched: Result<RelayDirectory, DirectoryError>,
) -> Decision {
    match (cached, fetched) {
        (cached, Ok(directory)) => {
            let changed = cached.as_ref() != Some(&directory);
            Decision::Adopt { directory, changed }
        }
        (Some(cached), Err(_)) => Decision::KeepCached(cached),
        (None, Err(_)) => Decision::NoDirectory,
    }
}

/// Polling schedule. Holds only the jitter for the current period; everything else comes in as arguments.
#[derive(Debug, Clone)]
pub struct DirectoryCache {
    jitter_permille: i64,
}

impl DirectoryCache {
    pub fn new(env: &mut impl Env) -> Self {
        let mut cache = Self { jitter_permille: 0 };
        cache.reroll(env);
        cache
    }

    /// A fixed jitter, for tests (clamped to +-10%).
    pub fn with_jitter_permille(jitter_permille: i64) -> Self {
        Self {
            jitter_permille: jitter_permille.clamp(-POLL_JITTER_PERMILLE, POLL_JITTER_PERMILLE),
        }
    }

    /// Draws a new jitter in `[-10%, +10%]`; call after each attempt.
    pub fn reroll(&mut self, env: &mut impl Env) {
        let raw = u16::from_be_bytes(env.random_array::<2>()) as i64;
        let span = 2 * POLL_JITTER_PERMILLE + 1;
        self.jitter_permille = raw % span - POLL_JITTER_PERMILLE;
    }

    pub fn jitter_permille(&self) -> i64 {
        self.jitter_permille
    }

    /// Delay before retrying after `failures` consecutive failures (1 min, doubling, capped at 30 min).
    pub fn backoff_ms(failures: u32) -> i64 {
        let exp = failures.saturating_sub(1).min(16);
        (BACKOFF_MIN_MS << exp).min(BACKOFF_MAX_MS)
    }

    /// Whether to fetch now. Always on the first call of a run (`last_attempt` is `None`: a launch). After a failure
    /// (`failures > 0`) it retries with exponential backoff; otherwise every six hours, jittered. A clock that moved
    /// backwards counts as due, so a wrong clock cannot silence polling.
    pub fn should_poll(
        &self,
        now_ms: i64,
        last_success_ms: Option<i64>,
        last_attempt_ms: Option<i64>,
        failures: u32,
    ) -> bool {
        let Some(attempt) = last_attempt_ms else {
            return true;
        };
        if now_ms < attempt {
            return true;
        }
        if failures > 0 {
            return now_ms - attempt >= Self::backoff_ms(failures);
        }
        let base = last_success_ms.unwrap_or(attempt);
        if now_ms < base {
            return true;
        }
        let period = POLL_INTERVAL_MS + POLL_INTERVAL_MS * self.jitter_permille / 1000;
        now_ms - base >= period
    }

    /// Whether a relay connect failure may trigger an extra poll now: at most one poll per ten minutes.
    pub fn should_poll_after_connect_failure(
        &self,
        now_ms: i64,
        last_attempt_ms: Option<i64>,
    ) -> bool {
        match last_attempt_ms {
            None => true,
            Some(attempt) => now_ms < attempt || now_ms - attempt >= CONNECT_FAILURE_POLL_GAP_MS,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::env::TestEnv;

    fn blob(server: &str) -> String {
        serde_json::json!({ "relayServer": server }).to_string()
    }

    fn ok(server: &str) -> String {
        parse_directory(&blob(server)).unwrap().relay_server
    }

    #[test]
    fn uses_whatever_host_is_named_and_strips_trailing_slash() {
        assert_eq!(ok("wss://gossip.vmd1.dev"), "wss://gossip.vmd1.dev");
        assert_eq!(ok("wss://relay.example.org/"), "wss://relay.example.org");
        assert_eq!(
            ok("wss://relay.example.org:8443"),
            "wss://relay.example.org:8443"
        );
        assert_eq!(ok("ws://127.0.0.1:8099"), "ws://127.0.0.1:8099");
    }

    #[test]
    fn rejects_non_websocket_urls_and_missing_hosts() {
        for server in [
            "https://x.example",
            "x.example",
            "wss://",
            "wss:///",
            "wss://:443",
            "",
        ] {
            assert_eq!(
                parse_directory(&blob(server)),
                Err(DirectoryError::Invalid),
                "{server:?}"
            );
        }
    }

    #[test]
    fn ignores_unknown_fields() {
        let json = r#"{"relayServer":"wss://gossip.vmd1.dev","future":{"a":[1,2]},"note":"x"}"#;
        assert_eq!(
            parse_directory(json).unwrap().relay_server,
            "wss://gossip.vmd1.dev"
        );
    }

    #[test]
    fn rejects_bad_documents() {
        assert_eq!(parse_directory(""), Err(DirectoryError::NotJson));
        assert_eq!(parse_directory("not json"), Err(DirectoryError::NotJson));
        assert_eq!(parse_directory("[]"), Err(DirectoryError::NotObject));
        assert_eq!(parse_directory("\"x\""), Err(DirectoryError::NotObject));
        assert_eq!(parse_directory("null"), Err(DirectoryError::NotObject));
        assert_eq!(
            parse_directory("{}"),
            Err(DirectoryError::MissingRelayServer)
        );
        assert_eq!(
            parse_directory(r#"{"relayserver":"wss://gossip.vmd1.dev"}"#),
            Err(DirectoryError::MissingRelayServer)
        );
        for wrong in [
            "1",
            "null",
            "true",
            "[]",
            "{}",
            r#"["wss://gossip.vmd1.dev"]"#,
        ] {
            assert_eq!(
                parse_directory(&format!(r#"{{"relayServer":{wrong}}}"#)),
                Err(DirectoryError::WrongType),
                "{wrong}"
            );
        }
    }

    #[test]
    fn rejects_oversize_documents() {
        let filler = "a".repeat(MAX_DIRECTORY_BYTES);
        let json = format!(r#"{{"relayServer":"wss://gossip.vmd1.dev","pad":"{filler}"}}"#);
        assert!(json.len() > MAX_DIRECTORY_BYTES);
        assert_eq!(parse_directory(&json), Err(DirectoryError::TooLarge));
        // Right at the limit is fine.
        let head = r#"{"relayServer":"wss://gossip.vmd1.dev","pad":""#;
        let tail = r#""}"#;
        let pad = "a".repeat(MAX_DIRECTORY_BYTES - head.len() - tail.len());
        let json = format!("{head}{pad}{tail}");
        assert_eq!(json.len(), MAX_DIRECTORY_BYTES);
        assert!(parse_directory(&json).is_ok());
    }

    fn dir(server: &str) -> RelayDirectory {
        RelayDirectory {
            relay_server: server.into(),
        }
    }

    #[test]
    fn merge_never_loses_a_valid_cache() {
        let cached = dir("wss://a.vmd1.dev");
        for err in [
            DirectoryError::TooLarge,
            DirectoryError::NotJson,
            DirectoryError::Invalid,
        ] {
            assert_eq!(
                merge(Some(cached.clone()), Err(err)),
                Decision::KeepCached(cached.clone())
            );
        }
        assert_eq!(
            merge(None, Err(DirectoryError::NotJson)),
            Decision::NoDirectory
        );
    }

    #[test]
    fn merge_adopts_valid_fetches_and_reports_change() {
        let a = dir("wss://a.vmd1.dev");
        let b = dir("wss://b.vmd1.dev");
        assert_eq!(
            merge(None, Ok(a.clone())),
            Decision::Adopt {
                directory: a.clone(),
                changed: true
            }
        );
        assert_eq!(
            merge(Some(a.clone()), Ok(a.clone())),
            Decision::Adopt {
                directory: a.clone(),
                changed: false
            }
        );
        assert_eq!(
            merge(Some(a), Ok(b.clone())),
            Decision::Adopt {
                directory: b,
                changed: true
            }
        );
    }

    #[test]
    fn schedule_polls_on_launch_then_every_six_hours() {
        let c = DirectoryCache::with_jitter_permille(0);
        let t0 = 1_000_000_000_000;
        assert!(
            c.should_poll(t0, Some(t0 - 1), None, 0),
            "launch always polls"
        );
        assert!(c.should_poll(t0, None, None, 0));
        assert!(!c.should_poll(t0 + 1, Some(t0), Some(t0), 0));
        assert!(!c.should_poll(t0 + POLL_INTERVAL_MS - 1, Some(t0), Some(t0), 0));
        assert!(c.should_poll(t0 + POLL_INTERVAL_MS, Some(t0), Some(t0), 0));
    }

    #[test]
    fn schedule_jitter_is_within_ten_percent() {
        let t0 = 5_000_000;
        let early = DirectoryCache::with_jitter_permille(-100);
        let late = DirectoryCache::with_jitter_permille(100);
        let lo = POLL_INTERVAL_MS * 9 / 10;
        let hi = POLL_INTERVAL_MS * 11 / 10;
        assert!(!early.should_poll(t0 + lo - 1, Some(t0), Some(t0), 0));
        assert!(early.should_poll(t0 + lo, Some(t0), Some(t0), 0));
        assert!(!late.should_poll(t0 + hi - 1, Some(t0), Some(t0), 0));
        assert!(late.should_poll(t0 + hi, Some(t0), Some(t0), 0));
        // Out-of-range requests are clamped.
        assert_eq!(
            DirectoryCache::with_jitter_permille(900).jitter_permille(),
            100
        );
        let mut env = TestEnv::new(7, 0);
        let mut c = DirectoryCache::new(&mut env);
        for _ in 0..500 {
            c.reroll(&mut env);
            assert!((-100..=100).contains(&c.jitter_permille()));
        }
    }

    #[test]
    fn schedule_backs_off_after_failures() {
        let c = DirectoryCache::with_jitter_permille(0);
        let t = 10_000_000;
        assert_eq!(DirectoryCache::backoff_ms(1), 60_000);
        assert_eq!(DirectoryCache::backoff_ms(2), 120_000);
        assert_eq!(DirectoryCache::backoff_ms(3), 240_000);
        assert_eq!(DirectoryCache::backoff_ms(6), 1_800_000);
        assert_eq!(DirectoryCache::backoff_ms(50), BACKOFF_MAX_MS);
        assert_eq!(DirectoryCache::backoff_ms(u32::MAX), BACKOFF_MAX_MS);
        assert!(!c.should_poll(t + 59_999, None, Some(t), 1));
        assert!(c.should_poll(t + 60_000, None, Some(t), 1));
        assert!(!c.should_poll(t + 119_999, None, Some(t), 2));
        assert!(c.should_poll(t + 120_000, None, Some(t), 2));
        // Failures retry on the backoff even when a stale success exists, long before the six hour period.
        assert!(c.should_poll(t + 60_000, Some(t - 1000), Some(t), 1));
    }

    #[test]
    fn schedule_survives_a_clock_that_moved_backwards() {
        let c = DirectoryCache::with_jitter_permille(0);
        assert!(c.should_poll(100, Some(10_000), Some(10_000), 0));
        assert!(c.should_poll(100, None, Some(10_000), 3));
    }

    #[test]
    fn connect_failure_hint_is_rate_limited() {
        let c = DirectoryCache::with_jitter_permille(0);
        let t = 1_000_000;
        assert!(c.should_poll_after_connect_failure(t, None));
        assert!(!c.should_poll_after_connect_failure(t + 1, Some(t)));
        assert!(!c.should_poll_after_connect_failure(t + CONNECT_FAILURE_POLL_GAP_MS - 1, Some(t)));
        assert!(c.should_poll_after_connect_failure(t + CONNECT_FAILURE_POLL_GAP_MS, Some(t)));
    }
}
