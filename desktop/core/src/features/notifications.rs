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
