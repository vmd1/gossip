//! Central state synchronisation.
//!
//! Each device owns a set of named **slots** of JSON state (now playing, active notifications, ...). A feature calls
//! `Core::set_state(slot, value)` whenever its state changes and the core keeps every other device's copy correct:
//!
//! - a changed slot is broadcast as `state.update` (the new version and value);
//! - a newly connected peer is sent every slot of ours;
//! - every minute a device broadcasts a `state.digest` (slot name to version); a receiver that is missing a slot or
//!   holds an older version asks the owner for it with `state.request`, and the owner answers with `state.update`.
//!
//! Setting a slot to `None` clears it: the clear is itself a versioned value, so it reaches devices that were offline
//! when it happened, and "nothing is playing" is state like any other. Everything is last-writer-wins per
//! `(owner, slot)` by version and idempotent: applying the same update twice, or an older one after a newer one, changes
//! nothing. A device can only write its own slots (the owner is the signed sender of the message).
//!
//! One-shot events (ring, reply, dismiss, commands) are not state and stay ordinary messages with dedupe keys.
//! Values over [`MAX_VALUE_BYTES`] are refused; large content belongs in a raw follow-up frame, not a slot.

use std::collections::{BTreeMap, HashMap};

use serde_json::{Map, Value};
use thiserror::Error;

pub const KIND_UPDATE: &str = "state.update";
pub const KIND_DIGEST: &str = "state.digest";
pub const KIND_REQUEST: &str = "state.request";

pub const MAX_VALUE_BYTES: usize = 256 * 1024;
pub const MAX_SLOTS_PER_DEVICE: usize = 64;
/// Slots a single digest, update or request may carry.
pub const MAX_SLOTS_PER_MESSAGE: usize = 64;
const MAX_SLOT_NAME_LEN: usize = 64;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum StateError {
    #[error("a slot name is 1 to 64 characters of a-z, 0-9, '.', '_' or '-'")]
    BadSlotName,
    #[error("the slot value is larger than {MAX_VALUE_BYTES} bytes")]
    TooLarge,
    #[error("a device may own at most {MAX_SLOTS_PER_DEVICE} slots")]
    TooManySlots,
}

pub fn is_valid_slot_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= MAX_SLOT_NAME_LEN
        && name.bytes().all(|b| {
            b.is_ascii_lowercase() || b.is_ascii_digit() || matches!(b, b'.' | b'_' | b'-')
        })
}

/// One slot's current value. `value == None` is a clear (kept, so it propagates).
#[derive(Debug, Clone, PartialEq)]
pub struct SlotValue {
    pub version: u64,
    pub value: Option<Value>,
}

/// This device's own slots.
#[derive(Debug, Default)]
pub struct LocalState {
    slots: BTreeMap<String, SlotValue>,
    last_version: u64,
}

impl LocalState {
    /// Sets (or, with `None`, clears) a slot. Returns the new version, or `None` when nothing changed (the value is
    /// what the slot already holds), so calling this on a timer or after every event is harmless.
    pub fn set(
        &mut self,
        slot: &str,
        value: Option<Value>,
        now_ms: i64,
    ) -> Result<Option<u64>, StateError> {
        if !is_valid_slot_name(slot) {
            return Err(StateError::BadSlotName);
        }
        if let Some(v) = &value {
            if serde_json::to_vec(v).map(|b| b.len()).unwrap_or(usize::MAX) > MAX_VALUE_BYTES {
                return Err(StateError::TooLarge);
            }
        }
        match self.slots.get(slot) {
            Some(cur) if cur.value == value => return Ok(None),
            None if value.is_none() => return Ok(None), // clearing what was never set
            None if self.slots.len() >= MAX_SLOTS_PER_DEVICE => {
                return Err(StateError::TooManySlots)
            }
            _ => {}
        }
        // Versions only grow, even if the clock steps back.
        let version = (now_ms.max(0) as u64).max(self.last_version + 1);
        self.last_version = version;
        self.slots
            .insert(slot.to_owned(), SlotValue { version, value });
        Ok(Some(version))
    }

    pub fn get(&self, slot: &str) -> Option<&SlotValue> {
        self.slots.get(slot)
    }

    /// Slot name to version, tombstones included.
    pub fn digest(&self) -> BTreeMap<String, u64> {
        self.slots
            .iter()
            .map(|(k, v)| (k.clone(), v.version))
            .collect()
    }

    pub fn all(&self) -> impl Iterator<Item = (&String, &SlotValue)> {
        self.slots.iter()
    }

    pub fn is_empty(&self) -> bool {
        self.slots.is_empty()
    }
}

/// What this device holds of other devices' slots.
#[derive(Debug, Default)]
pub struct RemoteState {
    devices: HashMap<String, BTreeMap<String, SlotValue>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Applied {
    /// A strictly newer version replaced what we had (or filled a gap).
    Changed,
    /// The same or an older version: nothing to do.
    Ignored,
}

impl RemoteState {
    /// Applies one slot from `device`. Only a strictly newer version changes anything.
    pub fn apply(&mut self, device: &str, slot: &str, incoming: SlotValue) -> Applied {
        if !is_valid_slot_name(slot) {
            return Applied::Ignored;
        }
        let slots = self.devices.entry(device.to_owned()).or_default();
        match slots.get(slot) {
            Some(cur) if cur.version >= incoming.version => Applied::Ignored,
            None if slots.len() >= MAX_SLOTS_PER_DEVICE => Applied::Ignored,
            _ => {
                slots.insert(slot.to_owned(), incoming);
                Applied::Changed
            }
        }
    }

    pub fn get(&self, device: &str, slot: &str) -> Option<&SlotValue> {
        self.devices.get(device)?.get(slot)
    }

    /// The slots in `digest` that this device lacks or holds an older version of.
    pub fn wanted(&self, device: &str, digest: &BTreeMap<String, u64>) -> Vec<String> {
        let held = self.devices.get(device);
        digest
            .iter()
            .filter(|(slot, version)| {
                is_valid_slot_name(slot)
                    && held
                        .and_then(|h| h.get(*slot))
                        .map_or(true, |cur| cur.version < **version)
            })
            .map(|(slot, _)| slot.clone())
            .take(MAX_SLOTS_PER_MESSAGE)
            .collect()
    }

    /// Drops everything held for `device` (it was revoked). Returns the slots that had a value.
    pub fn forget(&mut self, device: &str) -> Vec<String> {
        self.devices
            .remove(device)
            .map(|slots| {
                slots
                    .into_iter()
                    .filter(|(_, v)| v.value.is_some())
                    .map(|(k, _)| k)
                    .collect()
            })
            .unwrap_or_default()
    }
}

// ---- Wire payloads ---------------------------------------------------------------------------------------------

/// `state.update` payload: `{"slots": [{"slot", "version", "value"}]}`; `value` is `null` for a clear.
pub fn update_payload<'a>(
    slots: impl IntoIterator<Item = (&'a str, &'a SlotValue)>,
) -> Map<String, Value> {
    let list: Vec<Value> = slots
        .into_iter()
        .take(MAX_SLOTS_PER_MESSAGE)
        .map(|(name, v)| {
            let mut m = Map::new();
            m.insert("slot".into(), name.into());
            m.insert("version".into(), v.version.into());
            m.insert("value".into(), v.value.clone().unwrap_or(Value::Null));
            Value::Object(m)
        })
        .collect();
    let mut payload = Map::new();
    payload.insert("slots".into(), Value::Array(list));
    payload
}

pub fn parse_update(payload: &Map<String, Value>) -> Vec<(String, SlotValue)> {
    let Some(Value::Array(items)) = payload.get("slots") else {
        return Vec::new();
    };
    items
        .iter()
        .take(MAX_SLOTS_PER_MESSAGE)
        .filter_map(|item| {
            let slot = item.get("slot")?.as_str()?;
            let version = item.get("version")?.as_u64()?;
            let value = match item.get("value") {
                None | Some(Value::Null) => None,
                Some(v) => Some(v.clone()),
            };
            if let Some(v) = &value {
                if serde_json::to_vec(v).ok()?.len() > MAX_VALUE_BYTES {
                    return None;
                }
            }
            Some((slot.to_owned(), SlotValue { version, value }))
        })
        .collect()
}

/// `state.digest` payload: `{"slots": {"name": version}}`.
pub fn digest_payload(digest: &BTreeMap<String, u64>) -> Map<String, Value> {
    let mut slots = Map::new();
    for (name, version) in digest.iter().take(MAX_SLOTS_PER_MESSAGE) {
        slots.insert(name.clone(), (*version).into());
    }
    let mut payload = Map::new();
    payload.insert("slots".into(), Value::Object(slots));
    payload
}

pub fn parse_digest(payload: &Map<String, Value>) -> BTreeMap<String, u64> {
    let Some(Value::Object(slots)) = payload.get("slots") else {
        return BTreeMap::new();
    };
    slots
        .iter()
        .take(MAX_SLOTS_PER_MESSAGE)
        .filter_map(|(name, v)| Some((name.clone(), v.as_u64()?)))
        .collect()
}

/// `state.request` payload: `{"slots": ["name", ...]}`.
pub fn request_payload(slots: &[String]) -> Map<String, Value> {
    let mut payload = Map::new();
    payload.insert(
        "slots".into(),
        Value::Array(slots.iter().map(|s| Value::String(s.clone())).collect()),
    );
    payload
}

pub fn parse_request(payload: &Map<String, Value>) -> Vec<String> {
    let Some(Value::Array(items)) = payload.get("slots") else {
        return Vec::new();
    };
    items
        .iter()
        .take(MAX_SLOTS_PER_MESSAGE)
        .filter_map(|v| v.as_str().map(str::to_owned))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn slot_names_are_restricted() {
        assert!(is_valid_slot_name("media.nowplaying"));
        assert!(is_valid_slot_name("a-b_c.9"));
        assert!(!is_valid_slot_name(""));
        assert!(!is_valid_slot_name("Media"));
        assert!(!is_valid_slot_name("has space"));
        assert!(!is_valid_slot_name(&"a".repeat(65)));
    }

    #[test]
    fn setting_the_same_value_changes_nothing() {
        let mut s = LocalState::default();
        let v1 = s.set("a", Some(json!({"x": 1})), 1000).unwrap().unwrap();
        assert_eq!(s.set("a", Some(json!({"x": 1})), 2000).unwrap(), None);
        let v2 = s.set("a", Some(json!({"x": 2})), 3000).unwrap().unwrap();
        assert!(v2 > v1);
        assert_eq!(s.get("a").unwrap().version, v2);
    }

    #[test]
    fn a_clear_is_a_versioned_value_but_clearing_nothing_is_a_no_op() {
        let mut s = LocalState::default();
        assert_eq!(s.set("a", None, 1000).unwrap(), None, "never set");
        s.set("a", Some(json!(1)), 1000).unwrap();
        let cleared = s.set("a", None, 2000).unwrap().unwrap();
        assert_eq!(s.get("a").unwrap().value, None);
        assert_eq!(s.digest()["a"], cleared, "the tombstone is in the digest");
        assert_eq!(s.set("a", None, 3000).unwrap(), None, "already clear");
    }

    #[test]
    fn versions_never_go_backwards_when_the_clock_does() {
        let mut s = LocalState::default();
        let v1 = s.set("a", Some(json!(1)), 10_000).unwrap().unwrap();
        let v2 = s.set("a", Some(json!(2)), 5_000).unwrap().unwrap();
        assert!(v2 > v1);
    }

    #[test]
    fn limits_are_enforced() {
        let mut s = LocalState::default();
        assert_eq!(
            s.set("Bad", Some(json!(1)), 1),
            Err(StateError::BadSlotName)
        );
        let big = Value::String("x".repeat(MAX_VALUE_BYTES + 1));
        assert_eq!(s.set("a", Some(big), 1), Err(StateError::TooLarge));
        for i in 0..MAX_SLOTS_PER_DEVICE {
            s.set(&format!("s{i}"), Some(json!(i)), 1).unwrap();
        }
        assert_eq!(
            s.set("extra", Some(json!(1)), 1),
            Err(StateError::TooManySlots)
        );
        assert!(
            s.set("s0", Some(json!("changed")), 2).is_ok(),
            "existing slots still update"
        );
    }

    #[test]
    fn remote_updates_are_last_writer_wins_and_idempotent() {
        let mut r = RemoteState::default();
        let v = |version, value| SlotValue { version, value };
        assert_eq!(r.apply("d", "a", v(5, Some(json!(1)))), Applied::Changed);
        assert_eq!(
            r.apply("d", "a", v(5, Some(json!(1)))),
            Applied::Ignored,
            "same version"
        );
        assert_eq!(
            r.apply("d", "a", v(4, Some(json!(0)))),
            Applied::Ignored,
            "older"
        );
        assert_eq!(
            r.apply("d", "a", v(6, None)),
            Applied::Changed,
            "a clear is newer"
        );
        assert_eq!(r.get("d", "a").unwrap().value, None);
        assert_eq!(
            r.apply("d", "a", v(5, Some(json!(1)))),
            Applied::Ignored,
            "a stale update cannot undo a clear"
        );
    }

    #[test]
    fn a_digest_names_what_is_missing_or_older() {
        let mut r = RemoteState::default();
        r.apply(
            "d",
            "have",
            SlotValue {
                version: 10,
                value: Some(json!(1)),
            },
        );
        r.apply(
            "d",
            "old",
            SlotValue {
                version: 3,
                value: Some(json!(1)),
            },
        );
        let digest = BTreeMap::from([
            ("have".to_owned(), 10),
            ("old".to_owned(), 4),
            ("new".to_owned(), 1),
        ]);
        assert_eq!(
            r.wanted("d", &digest),
            vec!["new".to_owned(), "old".to_owned()]
        );
        assert_eq!(r.wanted("other", &digest).len(), 3);
    }

    #[test]
    fn forgetting_a_device_reports_the_slots_that_had_values() {
        let mut r = RemoteState::default();
        r.apply(
            "d",
            "a",
            SlotValue {
                version: 1,
                value: Some(json!(1)),
            },
        );
        r.apply(
            "d",
            "b",
            SlotValue {
                version: 1,
                value: None,
            },
        );
        assert_eq!(r.forget("d"), vec!["a".to_owned()]);
        assert!(r.get("d", "a").is_none());
    }

    #[test]
    fn payloads_round_trip_and_ignore_junk() {
        let a = SlotValue {
            version: 7,
            value: Some(json!({"k": [1, 2]})),
        };
        let b = SlotValue {
            version: 9,
            value: None,
        };
        let payload = update_payload([("a", &a), ("b", &b)]);
        let parsed = parse_update(&payload);
        assert_eq!(parsed, vec![("a".to_owned(), a), ("b".to_owned(), b)]);

        let junk = json!({"slots": [{"slot": "x"}, {"version": 1}, 5, {"slot": "ok", "version": 2, "value": 3}]});
        let parsed = parse_update(junk.as_object().unwrap());
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].0, "ok");

        let digest = BTreeMap::from([("a".to_owned(), 7u64)]);
        assert_eq!(parse_digest(&digest_payload(&digest)), digest);
        assert_eq!(
            parse_request(&request_payload(&["a".to_owned()])),
            vec!["a".to_owned()]
        );
        assert!(parse_digest(json!({"slots": 5}).as_object().unwrap()).is_empty());
    }
}
