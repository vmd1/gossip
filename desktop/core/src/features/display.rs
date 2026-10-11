//! A device's display size: the `control.display` state slot (`{"width", "height", "rotation"}`; see
//! `crate::state_sync`). It lets a Mac draw an accurately shaped card for the device in its Universal Control layout
//! before any control session exists. The core keeps it correct across reconnects and rotations, so nothing resends it.

use serde_json::{Map, Value};

use super::object;

/// The state slot a device publishes its display size in. Gated by the Universal Control feature (`control.` prefix).
pub const SLOT: &str = "control.display";

/// Sizes outside this range are rejected as nonsense (the largest real panels are well below it).
pub const MAX_DIMENSION: u32 = 16_384;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DisplayInfo {
    pub width: u32,
    pub height: u32,
    /// 0 to 3, quarter turns.
    pub rotation: u8,
}

impl DisplayInfo {
    pub fn payload(&self) -> Map<String, Value> {
        object([
            ("width", u64::from(self.width).into()),
            ("height", u64::from(self.height).into()),
            ("rotation", u64::from(self.rotation).into()),
        ])
    }

    /// The display size in a slot value, or `None` if a field is missing or out of range.
    pub fn parse(payload: &Map<String, Value>) -> Option<Self> {
        let get = |k: &str| payload.get(k).and_then(Value::as_u64);
        let (width, height, rotation) = (get("width")?, get("height")?, get("rotation")?);
        if !(1..=u64::from(MAX_DIMENSION)).contains(&width)
            || !(1..=u64::from(MAX_DIMENSION)).contains(&height)
            || rotation > 3
        {
            return None;
        }
        Some(Self {
            width: width as u32,
            height: height as u32,
            rotation: rotation as u8,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn round_trips_and_rejects_nonsense() {
        let d = DisplayInfo {
            width: 1080,
            height: 2340,
            rotation: 1,
        };
        assert_eq!(DisplayInfo::parse(&d.payload()), Some(d));
        for bad in [
            json!({"width": 0, "height": 5, "rotation": 0}),
            json!({"width": 5, "height": 99999, "rotation": 0}),
            json!({"width": 5, "height": 5, "rotation": 4}),
            json!({"width": -5, "height": 5, "rotation": 0}),
            json!({"width": 5, "height": 5}),
        ] {
            assert_eq!(DisplayInfo::parse(bad.as_object().unwrap()), None, "{bad}");
        }
    }
}
