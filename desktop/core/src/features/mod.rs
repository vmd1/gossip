//! The per-device feature toggles, and which message types each feature owns.
//!
//! Toggles are local and never sent over the wire. Off means this device takes no part in the feature: its
//! outgoing messages are skipped and incoming ones dropped before any handler runs. Relaying other devices'
//! messages is unaffected.

use std::collections::HashSet;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Feature {
    Clipboard,
    Dnd,
    Notifications,
    Media,
    ScreenMirroring,
    LockOnLeave,
    Hotspot,
    FindDevice,
    Battery,
    UniversalControl,
}

impl Feature {
    pub const ALL: [Feature; 10] = [
        Feature::Clipboard,
        Feature::Dnd,
        Feature::Notifications,
        Feature::Media,
        Feature::ScreenMirroring,
        Feature::LockOnLeave,
        Feature::Hotspot,
        Feature::FindDevice,
        Feature::Battery,
        Feature::UniversalControl,
    ];

    /// The stable key used to persist the toggle (`feature.<key>.enabled`).
    pub fn key(self) -> &'static str {
        match self {
            Feature::Clipboard => "clipboard",
            Feature::Dnd => "dnd",
            Feature::Notifications => "notifications",
            Feature::Media => "media",
            Feature::ScreenMirroring => "screenMirroring",
            Feature::LockOnLeave => "lockOnLeave",
            Feature::Hotspot => "hotspot",
            Feature::FindDevice => "findDevice",
            Feature::Battery => "battery",
            Feature::UniversalControl => "universalControl",
        }
    }

    pub fn from_key(key: &str) -> Option<Feature> {
        Self::ALL.into_iter().find(|f| f.key() == key)
    }

    /// Envelope `type` prefixes this feature owns. `screen.` is deliberately absent: screen mirroring is gated
    /// inside its controller so a refused request still gets an answer instead of silence.
    pub fn message_prefixes(self) -> &'static [&'static str] {
        match self {
            Feature::Clipboard => &["clipboard."],
            Feature::Dnd => &["dnd."],
            Feature::Notifications => &["notification."],
            Feature::Media => &["media."],
            Feature::ScreenMirroring => &[],
            Feature::LockOnLeave => &["lock_on_leave."],
            Feature::Hotspot => &["hotspot."],
            Feature::FindDevice => &["device."],
            Feature::Battery => &["battery."],
            Feature::UniversalControl => &["control."],
        }
    }

    /// The feature that owns an envelope `type`, if any (`handshake.`, `presence.`, `trust.`, `screen.` and
    /// similar infrastructure types are unowned).
    pub fn for_message_type(kind: &str) -> Option<Feature> {
        Self::ALL
            .into_iter()
            .find(|f| f.message_prefixes().iter().any(|p| kind.starts_with(p)))
    }
}

/// Which features are turned off on this device. Everything is on by default.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct FeatureSettings {
    disabled: HashSet<Feature>,
}

impl FeatureSettings {
    pub fn all_enabled() -> Self {
        Self::default()
    }

    pub fn is_enabled(&self, feature: Feature) -> bool {
        !self.disabled.contains(&feature)
    }

    pub fn set_enabled(&mut self, feature: Feature, enabled: bool) {
        if enabled {
            self.disabled.remove(&feature);
        } else {
            self.disabled.insert(feature);
        }
    }

    /// `false` when `kind` belongs to a feature this device has turned off. Applies to both sending and delivery.
    pub fn is_message_allowed(&self, kind: &str) -> bool {
        Feature::for_message_type(kind).map_or(true, |f| self.is_enabled(f))
    }

    /// Keys of the disabled features, for persistence.
    pub fn disabled_keys(&self) -> Vec<&'static str> {
        let mut keys: Vec<_> = self.disabled.iter().map(|f| f.key()).collect();
        keys.sort_unstable();
        keys
    }
}

pub mod battery;
pub mod clipboard;
pub mod dnd;
pub mod hotspot;
pub mod hotspot_gatt;
pub mod lock_on_leave;
pub mod media;
pub mod notifications;
pub mod ring;

use serde_json::{Map, Value};

/// A message a feature wants sent. The engine fills in sender, id, timestamp and signature.
#[derive(Debug, Clone, PartialEq)]
pub struct Outgoing {
    pub kind: &'static str,
    /// `Some(device)` for a targeted message, `None` for a broadcast.
    pub recipient: Option<String>,
    pub payload: Map<String, Value>,
}

impl Outgoing {
    pub fn broadcast(kind: &'static str, payload: Map<String, Value>) -> Self {
        Self {
            kind,
            recipient: None,
            payload,
        }
    }

    pub fn to(kind: &'static str, recipient: &str, payload: Map<String, Value>) -> Self {
        Self {
            kind,
            recipient: Some(recipient.to_owned()),
            payload,
        }
    }
}

pub(crate) fn object<const N: usize>(fields: [(&str, Value); N]) -> Map<String, Value> {
    fields.into_iter().map(|(k, v)| (k.to_owned(), v)).collect()
}
