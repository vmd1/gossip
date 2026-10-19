//! A device's display size: the `control.display` state slot (`{"width", "height", "rotation"}`; see
//! `crate::state_sync`). It lets a Mac draw an accurately shaped card for the device in its Universal Control layout
//! before any control session exists. The core keeps it correct across reconnects and rotations, so nothing resends it.
//!
//! A computer with several monitors adds an optional `displays` array (`{"id","x","y","width","height"}` per monitor,
//! in the computer's global point space). `width`/`height` stay the primary display's size, so a receiver that doesn't
//! know `displays` keeps working unchanged: the field is additive, not a wire break.

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

/// One monitor of a multi-display computer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DisplayRect {
    /// A stable identifier for the monitor on its computer (a display UUID on a Mac).
    pub id: String,
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
}

/// More monitors than this in one slot value is rejected as nonsense.
pub const MAX_DISPLAYS: usize = 16;

/// Longest accepted monitor identifier, in bytes.
pub const MAX_DISPLAY_ID: usize = 64;

impl DisplayInfo {
    /// [`Self::payload`] plus the `displays` array. An empty list adds nothing, so a single-display device is unchanged.
    pub fn payload_with_displays(&self, displays: &[DisplayRect]) -> Map<String, Value> {
        let mut map = self.payload();
        if !displays.is_empty() {
            let list: Vec<Value> = displays
                .iter()
                .take(MAX_DISPLAYS)
                .map(|d| {
                    Value::Object(object([
                        ("id", d.id.clone().into()),
                        ("x", i64::from(d.x).into()),
                        ("y", i64::from(d.y).into()),
                        ("width", u64::from(d.width).into()),
                        ("height", u64::from(d.height).into()),
                    ]))
                })
                .collect();
            map.insert("displays".to_owned(), Value::Array(list));
        }
        map
    }

    /// The `displays` array in a slot value. Missing means "one display" (an empty list); a malformed entry, a
    /// duplicate id or too many monitors makes the whole list `None`, so a bad value is ignored rather than half-applied.
    pub fn parse_displays(payload: &Map<String, Value>) -> Option<Vec<DisplayRect>> {
        let Some(raw) = payload.get("displays") else {
            return Some(Vec::new());
        };
        let list = raw.as_array()?;
        if list.len() > MAX_DISPLAYS {
            return None;
        }
        let mut out: Vec<DisplayRect> = Vec::with_capacity(list.len());
        for entry in list {
            let o = entry.as_object()?;
            let id = o.get("id")?.as_str()?;
            let (w, h) = (o.get("width")?.as_u64()?, o.get("height")?.as_u64()?);
            let (x, y) = (o.get("x")?.as_i64()?, o.get("y")?.as_i64()?);
            let max = u64::from(MAX_DIMENSION);
            let span = i64::from(MAX_DIMENSION) * 4;
            if id.is_empty()
                || id.len() > MAX_DISPLAY_ID
                || !(1..=max).contains(&w)
                || !(1..=max).contains(&h)
                || !(-span..=span).contains(&x)
                || !(-span..=span).contains(&y)
                || out.iter().any(|d| d.id == id)
            {
                return None;
            }
            out.push(DisplayRect {
                id: id.to_owned(),
                x: x as i32,
                y: y as i32,
                width: w as u32,
                height: h as u32,
            });
        }
        Some(out)
    }

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
        assert_eq!(DisplayInfo::parse_displays(&d.payload()), Some(vec![]), "a single display has no list");
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

    fn rect(id: &str, x: i32, y: i32) -> DisplayRect {
        DisplayRect {
            id: id.into(),
            x,
            y,
            width: 2560,
            height: 1440,
        }
    }

    #[test]
    fn displays_round_trip_and_stay_backward_compatible() {
        let d = DisplayInfo {
            width: 2560,
            height: 1440,
            rotation: 0,
        };
        let list = vec![rect("A", 0, 0), rect("B", -2560, 120)];
        let payload = d.payload_with_displays(&list);
        assert_eq!(DisplayInfo::parse(&payload), Some(d), "an old receiver still reads the size");
        assert_eq!(DisplayInfo::parse_displays(&payload), Some(list));
        assert!(!d.payload_with_displays(&[]).contains_key("displays"));
    }

    #[test]
    fn bad_display_lists_are_rejected_whole() {
        let base = json!({"width": 5, "height": 5, "rotation": 0});
        for bad in [
            json!([{"id": "", "x": 0, "y": 0, "width": 5, "height": 5}]),
            json!([{"id": "A", "x": 0, "y": 0, "width": 0, "height": 5}]),
            json!([{"id": "A", "x": 0, "y": 0, "width": 5, "height": 5}, {"id": "A", "x": 9, "y": 0, "width": 5, "height": 5}]),
            json!([{"id": "A", "x": "0", "y": 0, "width": 5, "height": 5}]),
            json!("nope"),
            json!((0..17).map(|i| json!({"id": format!("d{i}"), "x": 0, "y": 0, "width": 5, "height": 5})).collect::<Vec<_>>()),
        ] {
            let mut m = base.as_object().unwrap().clone();
            m.insert("displays".into(), bad.clone());
            assert_eq!(DisplayInfo::parse_displays(&m), None, "{bad}");
        }
    }
}
