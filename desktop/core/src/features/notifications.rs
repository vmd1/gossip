//! Notification mirroring (`notification.*`): the pure parts.
//!
//! `notification.reply` is the highest-severity idempotency case in the protocol: handling it fires the source
//! app's own `PendingIntent`, which for a messaging app sends the reply to a real person, so a duplicate delivery
//! would send it twice. Each reply carries a fresh `attemptId` (not the notification `id`, which is reused across
//! distinct replies to the same notification) and the handler acts on each attempt once.

use serde_json::{Map, Value};

use super::object;
use crate::limits::RecentIds;

const ATTEMPT_CACHE_SIZE: usize = 128;

pub fn reply_payload(notification_id: &str, text: &str, attempt_id: &str) -> Map<String, Value> {
    object([
        ("id", notification_id.into()),
        ("text", text.into()),
        ("attemptId", attempt_id.into()),
    ])
}

#[derive(Debug, Clone)]
pub struct ReplyGuard {
    recent: RecentIds,
}

impl Default for ReplyGuard {
    fn default() -> Self {
        Self {
            recent: RecentIds::new(ATTEMPT_CACHE_SIZE),
        }
    }
}

impl ReplyGuard {
    pub fn new() -> Self {
        Self::default()
    }

    /// `(notification id, reply text)` to act on, or `None` for a duplicate attempt or a reply without an
    /// `attemptId` (required, because without it a duplicate cannot be told from a second legitimate reply).
    pub fn accept(&mut self, payload: &Map<String, Value>) -> Option<(String, String)> {
        let attempt = payload.get("attemptId")?.as_str()?;
        let id = payload.get("id")?.as_str()?.to_owned();
        let text = payload.get("text")?.as_str()?.to_owned();
        if !self.recent.first_time(attempt) {
            return None;
        }
        Some((id, text))
    }
}

/// `notification.action`: press one of the notification's own buttons, `index` being its position in
/// `Notification.actions`. Pressing a button is not idempotent either (it can archive or answer twice), so it
/// carries a fresh `attemptId` like a reply.
pub fn action_payload(notification_id: &str, index: i32, attempt_id: &str) -> Map<String, Value> {
    object([
        ("id", notification_id.into()),
        ("index", index.into()),
        ("attemptId", attempt_id.into()),
    ])
}

#[derive(Debug, Clone)]
pub struct ActionGuard {
    recent: RecentIds,
}

impl Default for ActionGuard {
    fn default() -> Self {
        Self {
            recent: RecentIds::new(ATTEMPT_CACHE_SIZE),
        }
    }
}

impl ActionGuard {
    pub fn new() -> Self {
        Self::default()
    }

    /// `(notification id, button index)` to press, or `None` for a duplicate attempt, a negative index or a press
    /// without an `attemptId` (required: the message is newer than any sender that could omit it).
    pub fn accept(&mut self, payload: &Map<String, Value>) -> Option<(String, i32)> {
        let attempt = payload.get("attemptId")?.as_str()?;
        let id = payload.get("id")?.as_str()?.to_owned();
        let index = i32::try_from(payload.get("index")?.as_i64()?)
            .ok()
            .filter(|i| *i >= 0)?;
        if !self.recent.first_time(attempt) {
            return None;
        }
        Some((id, index))
    }
}
