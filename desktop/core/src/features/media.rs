//! Media / Now Playing (`media.nowplaying`, `media.command`).
//!
//! Any device with a media source broadcasts `media.nowplaying`; a controller tracks the latest state per device and
//! sends `media.command` targeted at one chosen device. `media.command` is not naturally idempotent (a duplicate
//! `next` would skip twice), so every command carries a fresh `commandId` and the receiver acts on each only once
//! ([`CommandGuard`]).

use std::collections::HashMap;

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use serde_json::{Map, Value};

use super::{object, Outgoing};
use crate::limits::RecentIds;

const COMMAND_CACHE_SIZE: usize = 64;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    Play,
    Pause,
    Next,
    Previous,
}

impl Action {
    pub fn as_str(self) -> &'static str {
        match self {
            Action::Play => "play",
            Action::Pause => "pause",
            Action::Next => "next",
            Action::Previous => "previous",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "play" => Action::Play,
            "pause" => Action::Pause,
            "next" => Action::Next,
            "previous" => Action::Previous,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct NowPlaying {
    pub title: String,
    pub artist: String,
    pub artwork: Option<Vec<u8>>,
    pub is_playing: bool,
    pub position_ms: i64,
    pub duration_ms: i64,
    pub package_name: String,
}

pub fn parse_now_playing(payload: &Map<String, Value>) -> Option<NowPlaying> {
    let title = payload.get("title")?.as_str()?.to_owned();
    let artist = payload.get("artist")?.as_str()?.to_owned();
    Some(NowPlaying {
        title,
        artist,
        artwork: payload
            .get("artBase64")
            .and_then(Value::as_str)
            .and_then(|a| B64.decode(a).ok()),
        is_playing: payload
            .get("isPlaying")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        position_ms: payload
            .get("positionMs")
            .and_then(Value::as_i64)
            .unwrap_or(0),
        duration_ms: payload
            .get("durationMs")
            .and_then(Value::as_i64)
            .unwrap_or(0),
        package_name: payload
            .get("packageName")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned(),
    })
}

/// `commandId` identifies this command *instance*: a fresh UUID per call, so a duplicate delivery is recognised.
pub fn command_payload(
    action: Action,
    seek_ms: Option<i64>,
    command_id: &str,
) -> Map<String, Value> {
    let mut m = object([
        ("action", action.as_str().into()),
        ("commandId", command_id.into()),
    ]);
    if let Some(seek) = seek_ms {
        m.insert("seekMs".into(), seek.into());
    }
    m
}

/// Controller side: latest state per device, which device is selected, and command construction.
#[derive(Debug, Clone, Default)]
pub struct MediaController {
    by_device: HashMap<String, NowPlaying>,
    selected: Option<String>,
    most_recent: Option<String>,
}

impl MediaController {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn on_now_playing(&mut self, sender: &str, payload: &Map<String, Value>) {
        if let Some(state) = parse_now_playing(payload) {
            self.by_device.insert(sender.to_owned(), state);
            self.most_recent = Some(sender.to_owned());
        }
    }

    /// The user's explicit pick when several devices report a session; `None` falls back to the most recent reporter.
    pub fn select(&mut self, device: Option<String>) {
        self.selected = device;
    }

    /// The device currently shown and controlled: the explicit selection if it still reports, else the most recent.
    pub fn effective_device(&self) -> Option<&str> {
        match &self.selected {
            Some(s) if self.by_device.contains_key(s) => Some(s),
            _ => self.most_recent.as_deref(),
        }
    }

    pub fn now_playing(&self) -> Option<&NowPlaying> {
        self.effective_device().and_then(|d| self.by_device.get(d))
    }

    pub fn state_of(&self, device: &str) -> Option<&NowPlaying> {
        self.by_device.get(device)
    }

    /// A command targeted at the effective device. `command_id` must be fresh.
    pub fn command(
        &self,
        action: Action,
        seek_ms: Option<i64>,
        command_id: &str,
    ) -> Option<Outgoing> {
        let device = self.effective_device()?;
        Some(Outgoing::to(
            "media.command",
            device,
            command_payload(action, seek_ms, command_id),
        ))
    }
}

/// Receiver side: acts on each `commandId` once.
#[derive(Debug, Clone)]
pub struct CommandGuard {
    recent: RecentIds,
}

impl Default for CommandGuard {
    fn default() -> Self {
        Self {
            recent: RecentIds::new(COMMAND_CACHE_SIZE),
        }
    }
}

impl CommandGuard {
    pub fn new() -> Self {
        Self::default()
    }

    /// The action to perform, or `None` for a duplicate or malformed command. A command without a `commandId` is
    /// still accepted once per call (older senders), since there is nothing to de-duplicate on.
    pub fn accept(&mut self, payload: &Map<String, Value>) -> Option<(Action, Option<i64>)> {
        let action = Action::parse(payload.get("action")?.as_str()?)?;
        if let Some(id) = payload.get("commandId").and_then(Value::as_str) {
            if !self.recent.first_time(id) {
                return None;
            }
        }
        Some((action, payload.get("seekMs").and_then(Value::as_i64)))
    }
}
