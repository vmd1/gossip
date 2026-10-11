//! The pure feature state machines. Each is an object holding its own state; the shell feeds it messages and OS
//! events and performs the effects it returns (send this message, apply that setting, raise this alert).

use std::sync::{Arc, Mutex, MutexGuard};

use gossip_core::features::{
    battery, clipboard, display, dnd, hotspot, lock_on_leave, media, notifications, ring,
    Outgoing as CoreOutgoing,
};
use serde_json::{Map, Value};

use crate::convert::{object_json, parse_object};
use crate::error::GossipError;

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// A message a feature wants sent. Pass it to `GossipCore::send_message`.
#[derive(Debug, Clone, uniffi::Record)]
pub struct Outgoing {
    pub kind: String,
    /// `None` means broadcast.
    pub recipient: Option<String>,
    pub payload_json: String,
}

impl From<CoreOutgoing> for Outgoing {
    fn from(o: CoreOutgoing) -> Self {
        Self {
            kind: o.kind.to_owned(),
            recipient: o.recipient,
            payload_json: object_json(o.payload),
        }
    }
}

fn payload(json: &str) -> Result<Map<String, Value>, GossipError> {
    parse_object(json)
}

// ---- Do Not Disturb --------------------------------------------------------------------------------------------

#[derive(Debug, Clone, uniffi::Enum)]
pub enum DndEffect {
    /// Publish this device's state: `GossipCore::set_state(slot, value_json)`.
    SetState { slot: String, value_json: String },
    /// Change the OS Do Not Disturb setting.
    ApplyLocal { enabled: bool },
    /// The believed state changed: persist it (the OS offers no way to read it back).
    Persist { expected: Option<bool> },
}

impl From<dnd::Effect> for DndEffect {
    fn from(e: dnd::Effect) -> Self {
        match e {
            dnd::Effect::SetState { enabled } => Self::SetState {
                slot: dnd::SLOT.to_owned(),
                value_json: object_json(dnd::state_payload(enabled)),
            },
            dnd::Effect::ApplyLocal { enabled } => Self::ApplyLocal { enabled },
            dnd::Effect::Persist(expected) => Self::Persist { expected },
        }
    }
}

#[derive(uniffi::Object)]
pub struct Dnd(Mutex<dnd::Dnd>);

#[uniffi::export]
impl Dnd {
    #[uniffi::constructor]
    pub fn new(persisted_expected: Option<bool>) -> Arc<Self> {
        Arc::new(Self(Mutex::new(dnd::Dnd::new(persisted_expected))))
    }

    pub fn expected(&self) -> Option<bool> {
        lock(&self.0).expected()
    }

    /// Call once at start: publishes the best-known state. The core sends it to every device that connects later.
    pub fn start(&self) -> Vec<DndEffect> {
        lock(&self.0).start().into_iter().map(Into::into).collect()
    }

    /// The local DND/Focus state changed (as observed by the OS hook).
    pub fn local_changed(&self, enabled: bool, now_ms: i64) -> Vec<DndEffect> {
        lock(&self.0)
            .local_changed(enabled, now_ms)
            .into_iter()
            .map(Into::into)
            .collect()
    }

    /// `dnd.set` from a peer.
    pub fn on_set(&self, payload_json: String, now_ms: i64) -> Result<Vec<DndEffect>, GossipError> {
        Ok(lock(&self.0)
            .on_set(&payload(&payload_json)?, now_ms)
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// The `dnd.state` slot of `sender` changed (`value_json` is the slot value).
    pub fn on_peer_state(
        &self,
        sender: String,
        value_json: String,
        now_ms: i64,
    ) -> Result<Vec<DndEffect>, GossipError> {
        Ok(lock(&self.0)
            .on_peer_state(&sender, &payload(&value_json)?, now_ms)
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// A device was revoked: its next state counts as first contact again.
    pub fn forget_peer(&self, sender: String) {
        lock(&self.0).forget_peer(&sender);
    }
}

/// The slot the DND state is published in.
#[uniffi::export]
pub fn dnd_slot() -> String {
    dnd::SLOT.to_owned()
}

// ---- Battery ---------------------------------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct BatteryState {
    pub level: u8,
    pub is_charging: bool,
}

impl From<battery::BatteryState> for BatteryState {
    fn from(b: battery::BatteryState) -> Self {
        Self {
            level: b.level,
            is_charging: b.is_charging,
        }
    }
}

impl From<BatteryState> for battery::BatteryState {
    fn from(b: BatteryState) -> Self {
        Self {
            level: b.level.min(100),
            is_charging: b.is_charging,
        }
    }
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum BatteryEffect {
    /// Publish this device's reading: `GossipCore::set_state(slot, value_json)`.
    SetState { slot: String, value_json: String },
    /// Raise a low-battery notification for `sender`.
    LowBattery { sender: String, level: u8 },
    /// `sender`'s stored state changed (refresh the UI).
    Updated { sender: String },
}

impl From<battery::Effect> for BatteryEffect {
    fn from(e: battery::Effect) -> Self {
        match e {
            battery::Effect::SetState(state) => Self::SetState {
                slot: battery::SLOT.to_owned(),
                value_json: object_json(battery::Battery::payload(state)),
            },
            battery::Effect::LowBattery { sender, level } => Self::LowBattery { sender, level },
            battery::Effect::Updated { sender } => Self::Updated { sender },
        }
    }
}

#[derive(uniffi::Object)]
pub struct Battery(Mutex<battery::Battery>);

#[uniffi::export]
impl Battery {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self(Mutex::new(battery::Battery::new())))
    }

    pub fn state_of(&self, sender: String) -> Option<BatteryState> {
        lock(&self.0).state_of(&sender).map(Into::into)
    }

    /// A local power-source reading: publishes only if it differs from the last one published, so it is safe to call on
    /// every power event.
    pub fn report(&self, reading: Option<BatteryState>) -> Option<BatteryEffect> {
        lock(&self.0)
            .report(reading.map(Into::into))
            .map(Into::into)
    }

    /// A device was revoked: forget its reading and alert state.
    pub fn forget(&self, sender: String) {
        lock(&self.0).forget(&sender);
    }

    pub fn on_update(
        &self,
        sender: String,
        payload_json: String,
    ) -> Result<Vec<BatteryEffect>, GossipError> {
        Ok(lock(&self.0)
            .on_update(&sender, &payload(&payload_json)?)
            .into_iter()
            .map(Into::into)
            .collect())
    }
}

// ---- Find my device --------------------------------------------------------------------------------------------

#[derive(Debug, Clone, uniffi::Enum)]
pub enum RingEffect {
    StartRinger,
    StopRinger,
    ShowAlert,
    CloseAlert,
    Send {
        message: Outgoing,
    },
    /// The set of peers this device asked to ring changed.
    PeersChanged,
}

impl From<ring::Effect> for RingEffect {
    fn from(e: ring::Effect) -> Self {
        match e {
            ring::Effect::StartRinger => Self::StartRinger,
            ring::Effect::StopRinger => Self::StopRinger,
            ring::Effect::ShowAlert => Self::ShowAlert,
            ring::Effect::CloseAlert => Self::CloseAlert,
            ring::Effect::Send(o) => Self::Send { message: o.into() },
            ring::Effect::PeersChanged => Self::PeersChanged,
        }
    }
}

#[derive(uniffi::Object)]
pub struct Ring(Mutex<ring::Ring>);

#[uniffi::export]
impl Ring {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self(Mutex::new(ring::Ring::new())))
    }

    pub fn is_ringing(&self) -> bool {
        lock(&self.0).is_ringing()
    }

    pub fn ringing_peers(&self) -> Vec<String> {
        lock(&self.0).ringing_peers()
    }

    /// Receiving `device.ring`.
    pub fn on_ring(
        &self,
        sender: String,
        payload_json: String,
        now_ms: i64,
    ) -> Result<Vec<RingEffect>, GossipError> {
        Ok(lock(&self.0)
            .on_ring(&sender, &payload(&payload_json)?, now_ms)
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// Silences the ring (also the local Stop button). No-op when not ringing.
    pub fn stop_ringing(&self) -> Vec<RingEffect> {
        lock(&self.0)
            .stop_ringing()
            .into_iter()
            .map(Into::into)
            .collect()
    }

    /// The ring button for `peer`; `ring_id` must be a fresh UUID.
    pub fn toggle(&self, peer: String, ring_id: String, now_ms: i64) -> Vec<RingEffect> {
        lock(&self.0)
            .toggle(&peer, &ring_id, now_ms)
            .into_iter()
            .map(Into::into)
            .collect()
    }

    /// Receiving `device.ring_state` from a peer we asked to ring.
    pub fn on_ring_state(
        &self,
        sender: String,
        payload_json: String,
        now_ms: i64,
    ) -> Result<Vec<RingEffect>, GossipError> {
        Ok(lock(&self.0)
            .on_ring_state(&sender, &payload(&payload_json)?, now_ms)
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// Auto-stop and peer-entry expiry. Call about once a second.
    pub fn tick(&self, now_ms: i64) -> Vec<RingEffect> {
        lock(&self.0)
            .tick(now_ms)
            .into_iter()
            .map(Into::into)
            .collect()
    }
}

// ---- Clipboard -------------------------------------------------------------------------------------------------

#[derive(uniffi::Object)]
pub struct ClipboardGuard(Mutex<clipboard::ClipboardGuard>);

#[uniffi::export]
impl ClipboardGuard {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self(Mutex::new(clipboard::ClipboardGuard::new())))
    }

    /// Whether a freshly observed local text value should be published (records it as sent when it should): the value
    /// to set in the `clipboard.text` slot, as JSON.
    pub fn outgoing_text(&self, me: String, text: String, sensitive: bool) -> Option<String> {
        lock(&self.0)
            .outgoing_text(&me, &text, sensitive)
            .map(object_json)
    }

    /// Same for an image already normalised to PNG; send the message with `png` as its raw follow-up frame.
    pub fn outgoing_image(&self, me: String, png: Vec<u8>, sensitive: bool) -> Option<Outgoing> {
        lock(&self.0)
            .outgoing_image(&me, &png, sensitive)
            .map(Into::into)
    }

    /// An incoming text update: the text to write to the local clipboard, or `None` if refused.
    pub fn incoming_text(&self, payload_json: String) -> Result<Option<String>, GossipError> {
        Ok(lock(&self.0).incoming_text(&payload(&payload_json)?))
    }

    /// An incoming image update with its raw frame: true if it should be written to the local clipboard.
    pub fn incoming_image(&self, payload_json: String, png: Vec<u8>) -> Result<bool, GossipError> {
        Ok(lock(&self.0).incoming_image(&payload(&payload_json)?, &png))
    }
}

/// Whether any pasteboard type marks content that must not be synced (concealed, transient, password managers).
#[uniffi::export]
pub fn clipboard_is_sensitive(types: Vec<String>) -> bool {
    clipboard::is_sensitive(&types)
}

#[uniffi::export]
pub fn clipboard_text_allowed(text: String) -> bool {
    clipboard::text_allowed(&text)
}

#[uniffi::export]
pub fn clipboard_image_bytes_allowed(len: u64) -> bool {
    usize::try_from(len).is_ok_and(clipboard::image_bytes_allowed)
}

/// Refuses data that is not a PNG or whose decoded size is a decompression bomb.
#[uniffi::export]
pub fn clipboard_is_reasonable_png(data: Vec<u8>) -> bool {
    clipboard::is_reasonable_png(&data)
}

// ---- Media -----------------------------------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum MediaAction {
    Play,
    Pause,
    Next,
    Previous,
}

impl From<MediaAction> for media::Action {
    fn from(a: MediaAction) -> Self {
        match a {
            MediaAction::Play => Self::Play,
            MediaAction::Pause => Self::Pause,
            MediaAction::Next => Self::Next,
            MediaAction::Previous => Self::Previous,
        }
    }
}

impl From<media::Action> for MediaAction {
    fn from(a: media::Action) -> Self {
        match a {
            media::Action::Play => Self::Play,
            media::Action::Pause => Self::Pause,
            media::Action::Next => Self::Next,
            media::Action::Previous => Self::Previous,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct NowPlaying {
    pub title: String,
    pub artist: String,
    pub artwork: Option<Vec<u8>>,
    pub is_playing: bool,
    pub position_ms: i64,
    pub duration_ms: i64,
    pub package_name: String,
}

impl From<media::NowPlaying> for NowPlaying {
    fn from(n: media::NowPlaying) -> Self {
        Self {
            title: n.title,
            artist: n.artist,
            artwork: n.artwork,
            is_playing: n.is_playing,
            position_ms: n.position_ms,
            duration_ms: n.duration_ms,
            package_name: n.package_name,
        }
    }
}

#[derive(uniffi::Object)]
pub struct MediaController(Mutex<media::MediaController>);

#[uniffi::export]
impl MediaController {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self(Mutex::new(media::MediaController::new())))
    }

    pub fn on_now_playing(&self, sender: String, payload_json: String) -> Result<(), GossipError> {
        lock(&self.0).on_now_playing(&sender, &payload(&payload_json)?);
        Ok(())
    }

    /// The user's explicit pick when several devices report a session.
    pub fn select(&self, device: Option<String>) {
        lock(&self.0).select(device);
    }

    pub fn effective_device(&self) -> Option<String> {
        lock(&self.0).effective_device().map(str::to_owned)
    }

    pub fn now_playing(&self) -> Option<NowPlaying> {
        lock(&self.0).now_playing().cloned().map(Into::into)
    }

    pub fn state_of(&self, device: String) -> Option<NowPlaying> {
        lock(&self.0).state_of(&device).cloned().map(Into::into)
    }

    /// A command for the effective device; `command_id` must be a fresh UUID.
    pub fn command(
        &self,
        action: MediaAction,
        seek_ms: Option<i64>,
        command_id: String,
    ) -> Option<Outgoing> {
        lock(&self.0)
            .command(action.into(), seek_ms, &command_id)
            .map(Into::into)
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AcceptedCommand {
    pub action: MediaAction,
    pub seek_ms: Option<i64>,
}

/// Receiver side of `media.command`: acts on each `commandId` once.
#[derive(uniffi::Object)]
pub struct CommandGuard(Mutex<media::CommandGuard>);

#[uniffi::export]
impl CommandGuard {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self(Mutex::new(media::CommandGuard::new())))
    }

    /// The action to perform, or `None` for a duplicate or malformed command.
    pub fn accept(&self, payload_json: String) -> Result<Option<AcceptedCommand>, GossipError> {
        Ok(lock(&self.0)
            .accept(&payload(&payload_json)?)
            .map(|(a, seek_ms)| AcceptedCommand {
                action: a.into(),
                seek_ms,
            }))
    }
}

// ---- Notification replies --------------------------------------------------------------------------------------

#[derive(Debug, Clone, uniffi::Record)]
pub struct AcceptedReply {
    pub notification_id: String,
    pub text: String,
}

/// Each reply attempt acts once, so a duplicate delivery cannot message the other person twice.
#[derive(uniffi::Object)]
pub struct ReplyGuard(Mutex<notifications::ReplyGuard>);

#[uniffi::export]
impl ReplyGuard {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self(Mutex::new(notifications::ReplyGuard::new())))
    }

    pub fn accept(&self, payload_json: String) -> Result<Option<AcceptedReply>, GossipError> {
        Ok(lock(&self.0)
            .accept(&payload(&payload_json)?)
            .map(|(notification_id, text)| AcceptedReply {
                notification_id,
                text,
            }))
    }
}

/// The `notification.reply` payload JSON for a fresh attempt (`attempt_id` must be a fresh UUID).
#[uniffi::export]
pub fn notification_reply_payload(
    notification_id: String,
    text: String,
    attempt_id: String,
) -> String {
    object_json(notifications::reply_payload(
        &notification_id,
        &text,
        &attempt_id,
    ))
}

// ---- Hotspot state ---------------------------------------------------------------------------------------------

#[derive(Debug, Clone, uniffi::Record)]
pub struct HotspotState {
    pub enabled: bool,
    pub ssid: Option<String>,
}

#[derive(uniffi::Object)]
pub struct HotspotStates(Mutex<hotspot::HotspotStates>);

#[uniffi::export]
impl HotspotStates {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self(Mutex::new(hotspot::HotspotStates::new())))
    }

    /// Returns whether the stored state changed.
    pub fn on_update(&self, sender: String, payload_json: String) -> Result<bool, GossipError> {
        Ok(lock(&self.0).on_update(&sender, &payload(&payload_json)?))
    }

    /// A device was revoked, or its slot was cleared.
    pub fn forget(&self, sender: String) {
        lock(&self.0).forget(&sender);
    }

    pub fn state_of(&self, sender: String) -> Option<HotspotState> {
        lock(&self.0).state_of(&sender).map(|s| HotspotState {
            enabled: s.enabled,
            ssid: s.ssid.clone(),
        })
    }
}

// ---- Lock on leave ---------------------------------------------------------------------------------------------

#[derive(uniffi::Object)]
pub struct LockOnLeave(Mutex<lock_on_leave::LockOnLeave>);

#[uniffi::export]
impl LockOnLeave {
    #[uniffi::constructor]
    pub fn new(initially_nearby: Vec<String>) -> Arc<Self> {
        Arc::new(Self(Mutex::new(lock_on_leave::LockOnLeave::new(
            initially_nearby.into_iter().collect(),
        ))))
    }

    /// The nearby trusted devices changed. Returns true if the screen should be locked now. `armed` lists the
    /// devices that enabled lock-on-leave for themselves.
    pub fn nearby_changed(
        &self,
        nearby: Vec<String>,
        now_ms: i64,
        feature_enabled: bool,
        armed: Vec<String>,
    ) -> bool {
        lock(&self.0).nearby_changed(nearby.into_iter().collect(), now_ms, feature_enabled, |d| {
            armed.iter().any(|a| a == d)
        })
    }
}

/// Per-device cooldown after lock-on-leave fires, in milliseconds.
#[uniffi::export]
pub fn lock_on_leave_cooldown_ms() -> i64 {
    lock_on_leave::COOLDOWN_MS
}

/// The `lock_on_leave.config` slot value for a phone that arms lock-on-leave for these computers.
#[uniffi::export]
pub fn lock_on_leave_config_payload(armed_for: Vec<String>) -> String {
    object_json(lock_on_leave::config_payload(&armed_for))
}

/// Whether the phone that published this `lock_on_leave.config` slot value armed lock-on-leave for `me`.
#[uniffi::export]
pub fn lock_on_leave_is_armed_for(value_json: String, me: String) -> Result<bool, GossipError> {
    Ok(lock_on_leave::is_armed_for(&payload(&value_json)?, &me))
}

/// The slot names the features publish in.
#[uniffi::export]
pub fn battery_low_threshold() -> u8 {
    battery::LOW_THRESHOLD
}

#[uniffi::export]
pub fn battery_rearm_level() -> u8 {
    battery::REARM_LEVEL
}

#[uniffi::export]
pub fn battery_slot() -> String {
    battery::SLOT.to_owned()
}

#[uniffi::export]
pub fn hotspot_slot() -> String {
    hotspot::SLOT.to_owned()
}

#[uniffi::export]
pub fn lock_on_leave_slot() -> String {
    lock_on_leave::SLOT.to_owned()
}

#[uniffi::export]
pub fn clipboard_text_slot() -> String {
    clipboard::TEXT_SLOT.to_owned()
}

/// The `hotspot.state` slot value.
#[uniffi::export]
pub fn hotspot_state_payload(enabled: bool, ssid: Option<String>) -> String {
    object_json(hotspot::state_payload(enabled, ssid.as_deref()))
}

/// The `battery.state` slot value.
#[uniffi::export]
pub fn battery_payload(state: BatteryState) -> String {
    object_json(battery::Battery::payload(state.into()))
}

/// The `dnd.state` slot value.
#[uniffi::export]
pub fn dnd_state_payload(enabled: bool) -> String {
    object_json(dnd::state_payload(enabled))
}

// ---- Display size -----------------------------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct DisplayInfo {
    pub width: u32,
    pub height: u32,
    pub rotation: u8,
}

/// The slot a device publishes its display size in.
#[uniffi::export]
pub fn display_slot() -> String {
    display::SLOT.to_owned()
}

/// The `control.display` slot value for a display size.
#[uniffi::export]
pub fn display_payload(info: DisplayInfo) -> String {
    object_json(
        display::DisplayInfo {
            width: info.width,
            height: info.height,
            rotation: info.rotation,
        }
        .payload(),
    )
}

/// The display size in a `control.display` slot value, or `None` if it is missing or out of range.
#[uniffi::export]
pub fn display_parse(value_json: String) -> Option<DisplayInfo> {
    let value = payload(&value_json).ok()?;
    display::DisplayInfo::parse(&value).map(|d| DisplayInfo {
        width: d.width,
        height: d.height,
        rotation: d.rotation,
    })
}

// ---- BLE beacon key ---------------------------------------------------------------------------------------------

/// The direct-only slot a device publishes its BLE beacon key in.
#[uniffi::export]
pub fn beacon_key_slot() -> String {
    gossip_core::crypto::beacon::KEY_SLOT.to_owned()
}

/// The `direct.ble.beacon_key` slot value for a 32-byte key.
#[uniffi::export]
pub fn beacon_key_payload(key: Vec<u8>) -> Result<String, GossipError> {
    let key: [u8; 32] = key
        .try_into()
        .map_err(|_| GossipError::invalid("a beacon key is 32 bytes"))?;
    Ok(object_json(gossip_core::crypto::beacon::key_slot_payload(
        &key,
    )))
}

/// The 32-byte key in a `direct.ble.beacon_key` slot value, or `None` if it is malformed.
#[uniffi::export]
pub fn beacon_key_parse(value_json: String) -> Option<Vec<u8>> {
    let value = payload(&value_json).ok()?;
    gossip_core::crypto::beacon::parse_key_slot(&value).map(|k| k.to_vec())
}

/// The `device.ring` payload JSON.
#[uniffi::export]
pub fn ring_payload(action: String, ring_id: String) -> String {
    object_json(ring::Ring::ring_payload(&action, &ring_id))
}
