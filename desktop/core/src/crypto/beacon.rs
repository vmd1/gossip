//! Keyed, rotating BLE proximity beacons: `tag = HMAC-SHA256(key, "gossip-ble-v1" || window as u64 BE)[..8]`.
//! Checked against `schema/ble-beacon-vectors.json`; see `docs/ble-proximity-protocol.md`.

use hmac::{Hmac, Mac};
use sha2::Sha256;

pub const WINDOW_SECONDS: u64 = 60;
pub const TAG_LEN: usize = 8;
const LABEL: &[u8] = b"gossip-ble-v1";

/// The window number containing `unix_seconds`.
pub fn window(unix_seconds: u64) -> u64 {
    unix_seconds / WINDOW_SECONDS
}

pub fn tag(key: &[u8], window: u64) -> [u8; TAG_LEN] {
    let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(key).expect("HMAC accepts any key length");
    mac.update(LABEL);
    mac.update(&window.to_be_bytes());
    let full = mac.finalize().into_bytes();
    let mut out = [0u8; TAG_LEN];
    out.copy_from_slice(&full[..TAG_LEN]);
    out
}

/// Tags a holder of `key` may be advertising now, allowing one window of clock skew either way.
pub fn acceptable_tags(key: &[u8], unix_seconds: u64) -> [[u8; TAG_LEN]; 3] {
    let w = window(unix_seconds);
    [
        tag(key, w.wrapping_sub(1)),
        tag(key, w),
        tag(key, w.wrapping_add(1)),
    ]
}

/// Seconds until the current window ends.
pub fn seconds_until_next_window(unix_seconds: u64) -> u64 {
    WINDOW_SECONDS - unix_seconds % WINDOW_SECONDS
}

/// The direct-only state slot a device publishes its BLE beacon key in (`{"key": base64 of 32 bytes}`). It is a secret
/// shared with directly connected trusted devices only, so the name carries the `direct.` prefix (see
/// `crate::state_sync`) and it is never flooded through the mesh.
pub const KEY_SLOT: &str = "direct.ble.beacon_key";

pub fn key_slot_payload(key: &[u8; 32]) -> serde_json::Map<String, serde_json::Value> {
    use base64::{engine::general_purpose::STANDARD as B64, Engine};
    let mut m = serde_json::Map::new();
    m.insert("key".into(), B64.encode(key).into());
    m
}

/// The beacon key in a slot value, if it is exactly 32 bytes of base64.
pub fn parse_key_slot(payload: &serde_json::Map<String, serde_json::Value>) -> Option<[u8; 32]> {
    use base64::{engine::general_purpose::STANDARD as B64, Engine};
    let text = payload.get("key")?.as_str()?;
    B64.decode(text).ok()?.try_into().ok()
}
