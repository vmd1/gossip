//! Pure geometry of the Universal Control arrangement: which rectangles exist, which touch, how the pointer maps
//! from one to the next. No platform assumptions beyond "a screen is a rectangle in a shared, y-down,
//! point-based space", so a Windows or Linux source feeds it exactly like the Mac does.
//!
//! Source displays are fixed (they come from the OS, keyed by an id such as a display UUID); device screens are
//! placed by the user. A device's size in this space is its logical pixel size divided by `pixels_per_point`, so
//! one point of mouse travel is that many device pixels.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use super::frame::ControlEdge;
use super::geometry::{Point, Rect, Size};
use crate::wire::handshake::DeviceType;

/// Default scale between device pixels and layout points.
pub const DEFAULT_PIXELS_PER_POINT: f64 = 1.5;
/// Typical extra travel Android's pointer acceleration adds to a relative mouse (measured 1.3x to 2x on an
/// SM-T500, Android 12); used as the router's model gain.
pub const EXPECTED_DEVICE_ACCELERATION: f64 = 1.5;
/// Edges closer than this snap together while dragging.
pub const SNAP_DISTANCE: f64 = 24.0;
/// Two edges count as touching when at most this far apart.
pub const TOUCH_TOLERANCE: f64 = 1.0;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum ScreenId {
    /// A display of the controlling computer, by its display id.
    Local(String),
    /// A device, by its Gossip device id.
    Device(String),
}

impl ScreenId {
    pub fn device_id(&self) -> Option<&str> {
        match self {
            Self::Device(id) => Some(id),
            Self::Local(_) => None,
        }
    }

    pub fn is_local(&self) -> bool {
        matches!(self, Self::Local(_))
    }

    fn sort_key(&self) -> String {
        match self {
            Self::Local(s) => format!("0{s}"),
            Self::Device(s) => format!("1{s}"),
        }
    }
}

impl PartialOrd for ScreenId {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for ScreenId {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.sort_key().cmp(&other.sort_key())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Placement {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Placement {
    pub fn rect(&self) -> Rect {
        Rect::new(self.x, self.y, self.width, self.height)
    }
    pub fn from_rect(r: Rect) -> Self {
        Self {
            x: r.x,
            y: r.y,
            width: r.width,
            height: r.height,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct ControlLayout {
    local_displays: BTreeMap<String, Rect>,
    devices: BTreeMap<String, Placement>,
}

#[derive(Serialize, Deserialize)]
struct Stored {
    version: u32,
    devices: BTreeMap<String, Placement>,
}

impl ControlLayout {
    pub fn new(
        local_displays: BTreeMap<String, Rect>,
        devices: BTreeMap<String, Placement>,
    ) -> Self {
        Self {
            local_displays,
            devices,
        }
    }

    pub fn local_displays(&self) -> &BTreeMap<String, Rect> {
        &self.local_displays
    }

    pub fn devices(&self) -> &BTreeMap<String, Placement> {
        &self.devices
    }

    // ---- Queries ----------------------------------------------------------------------------------------------

    pub fn screens(&self) -> Vec<(ScreenId, Rect)> {
        let mut v: Vec<_> = self
            .local_displays
            .iter()
            .map(|(k, r)| (ScreenId::Local(k.clone()), *r))
            .collect();
        v.extend(
            self.devices
                .iter()
                .map(|(k, p)| (ScreenId::Device(k.clone()), p.rect())),
        );
        v
    }

    pub fn rect_of(&self, id: &ScreenId) -> Option<Rect> {
        match id {
            ScreenId::Local(u) => self.local_displays.get(u).copied(),
            ScreenId::Device(d) => self.devices.get(d).map(Placement::rect),
        }
    }

    pub fn is_placed(&self, device_id: &str) -> bool {
        self.devices.contains_key(device_id)
    }

    /// Pixel size to draw a device with before it has ever reported its real one.
    pub fn default_pixel_size(kind: &DeviceType) -> Size {
        if *kind == DeviceType::AndroidPhone {
            Size::new(1080.0, 2400.0)
        } else {
            Size::new(2000.0, 1200.0)
        }
    }

    pub fn device_size(pixel_width: f64, pixel_height: f64, pixels_per_point: f64) -> Size {
        Size::new(
            pixel_width / pixels_per_point,
            pixel_height / pixels_per_point,
        )
    }

    /// The screen across `edge` of `from` at layout coordinate `along` (x for top/bottom edges, y for left/right).
    /// The neighbour must touch the edge and span `along`.
    pub fn neighbor(
        &self,
        from: &ScreenId,
        edge: ControlEdge,
        along: f64,
        excluding: &[ScreenId],
    ) -> Option<ScreenId> {
        let r = self.rect_of(from)?;
        let tol = TOUCH_TOLERANCE;
        for (id, other) in self.screens() {
            if &id == from || excluding.contains(&id) {
                continue;
            }
            let (touches, spans) = match edge {
                ControlEdge::Right => (
                    (other.min_x() - r.max_x()).abs() <= tol,
                    along >= other.min_y() && along <= other.max_y(),
                ),
                ControlEdge::Left => (
                    (other.max_x() - r.min_x()).abs() <= tol,
                    along >= other.min_y() && along <= other.max_y(),
                ),
                ControlEdge::Bottom => (
                    (other.min_y() - r.max_y()).abs() <= tol,
                    along >= other.min_x() && along <= other.max_x(),
                ),
                ControlEdge::Top => (
                    (other.max_y() - r.min_y()).abs() <= tol,
                    along >= other.min_x() && along <= other.max_x(),
                ),
            };
            if touches && spans {
                return Some(id);
            }
        }
        None
    }

    /// Fraction (0..=1) along `edge` of `id` that layout coordinate `along` corresponds to.
    pub fn edge_fraction(&self, id: &ScreenId, edge: ControlEdge, along: f64) -> Option<f64> {
        let r = self.rect_of(id)?;
        let (lo, len) = if matches!(edge, ControlEdge::Left | ControlEdge::Right) {
            (r.min_y(), r.height)
        } else {
            (r.min_x(), r.width)
        };
        (len > 0.0).then(|| ((along - lo) / len).clamp(0.0, 1.0))
    }

    // ---- Editing ----------------------------------------------------------------------------------------------

    /// Replaces the local displays (one was plugged in or rearranged). Returns devices that no longer fit.
    pub fn set_local_displays(&mut self, displays: BTreeMap<String, Rect>) -> Vec<String> {
        self.local_displays = displays;
        self.normalize()
    }

    /// Where a device of `size` dropped near `proposed_origin` ends up: snapped to nearby edges, or `None` when
    /// there is no legal spot. `capture_distance > 0` falls back to the nearest legal flush position within that
    /// many points, so a drop that is merely near an edge attaches instead of being rejected.
    pub fn resolve_drop(
        &self,
        device_id: &str,
        size: Size,
        proposed_origin: Point,
        snap_distance: f64,
        capture_distance: f64,
    ) -> Option<Point> {
        let me = ScreenId::Device(device_id.to_owned());
        let others: Vec<Rect> = self
            .screens()
            .into_iter()
            .filter(|(id, _)| *id != me)
            .map(|(_, r)| r)
            .collect();
        if others.is_empty() {
            return None;
        }
        let mut rect = Rect::from_origin(proposed_origin, size);

        let (mut best_dx, mut best_dy): (Option<f64>, Option<f64>) = (None, None);
        let consider = |delta: f64, best: &mut Option<f64>| {
            if delta.abs() <= snap_distance && best.map_or(true, |b| delta.abs() < b.abs()) {
                *best = Some(delta);
            }
        };
        for o in &others {
            // Touching: my left to their right, my right to their left, and the same vertically.
            consider(o.max_x() - rect.min_x(), &mut best_dx);
            consider(o.min_x() - rect.max_x(), &mut best_dx);
            consider(o.max_y() - rect.min_y(), &mut best_dy);
            consider(o.min_y() - rect.max_y(), &mut best_dy);
            // Flush alignment along a shared edge.
            consider(o.min_x() - rect.min_x(), &mut best_dx);
            consider(o.max_x() - rect.max_x(), &mut best_dx);
            consider(o.min_y() - rect.min_y(), &mut best_dy);
            consider(o.max_y() - rect.max_y(), &mut best_dy);
        }
        let origin = rect.origin();
        let mut candidates = Vec::new();
        if let (Some(dx), Some(dy)) = (best_dx, best_dy) {
            candidates.push(Point::new(origin.x + dx, origin.y + dy));
        }
        if let Some(dx) = best_dx {
            candidates.push(Point::new(origin.x + dx, origin.y));
        }
        if let Some(dy) = best_dy {
            candidates.push(Point::new(origin.x, origin.y + dy));
        }
        candidates.push(origin);
        for c in candidates {
            rect = Rect::from_origin(c, size);
            if Self::is_legal(&rect, &others) {
                return Some(c);
            }
        }
        if capture_distance <= 0.0 {
            return None;
        }
        Self::nearest_legal_flush_origin(size, proposed_origin, &others, capture_distance)
    }

    fn nearest_legal_flush_origin(
        size: Size,
        proposed: Point,
        others: &[Rect],
        limit: f64,
    ) -> Option<Point> {
        let mut best: Option<(Point, f64)> = None;
        for o in others {
            // Keep at least a sliver of shared edge so the screens are properly connected.
            let min_x = o.min_x() - size.width + 40f64.min(o.width / 2.0).min(size.width / 2.0);
            let max_x = o.max_x() - 40f64.min(o.width / 2.0).min(size.width / 2.0);
            let min_y = o.min_y() - size.height + 40f64.min(o.height / 2.0).min(size.height / 2.0);
            let max_y = o.max_y() - 40f64.min(o.height / 2.0).min(size.height / 2.0);
            let cx = proposed.x.max(min_x).min(max_x);
            let cy = proposed.y.max(min_y).min(max_y);
            let candidates = [
                Point::new(o.max_x(), cy),
                Point::new(o.min_x() - size.width, cy),
                Point::new(cx, o.max_y()),
                Point::new(cx, o.min_y() - size.height),
            ];
            for c in candidates {
                if Self::is_legal(&Rect::from_origin(c, size), others) {
                    let d = (c.x - proposed.x).hypot(c.y - proposed.y);
                    if d <= limit && best.map_or(true, |(_, bd)| d < bd) {
                        best = Some((c, d));
                    }
                }
            }
        }
        best.map(|(p, _)| p)
    }

    /// No overlap with any of `others`, and a positive-length shared edge with at least one.
    pub fn is_legal(rect: &Rect, others: &[Rect]) -> bool {
        let mut touching = false;
        for o in others {
            if let Some((w, h)) = rect.intersection_extent(o) {
                if w > TOUCH_TOLERANCE && h > TOUCH_TOLERANCE {
                    return false;
                }
            }
            if Self::shared_edge_length(rect, o) > TOUCH_TOLERANCE {
                touching = true;
            }
        }
        touching
    }

    pub fn shared_edge_length(a: &Rect, b: &Rect) -> f64 {
        let tol = TOUCH_TOLERANCE;
        let overlap = |a0: f64, a1: f64, b0: f64, b1: f64| (a1.min(b1) - a0.max(b0)).max(0.0);
        if (a.max_x() - b.min_x()).abs() <= tol || (b.max_x() - a.min_x()).abs() <= tol {
            return overlap(a.min_y(), a.max_y(), b.min_y(), b.max_y());
        }
        if (a.max_y() - b.min_y()).abs() <= tol || (b.max_y() - a.min_y()).abs() <= tol {
            return overlap(a.min_x(), a.max_x(), b.min_x(), b.max_x());
        }
        0.0
    }

    /// Places (or moves) a device after resolving the drop. Returns the final origin, or `None` (layout unchanged).
    pub fn place(
        &mut self,
        device_id: &str,
        size: Size,
        proposed_origin: Point,
        snap_distance: f64,
        capture_distance: f64,
    ) -> Option<Point> {
        let origin = self.resolve_drop(
            device_id,
            size,
            proposed_origin,
            snap_distance,
            capture_distance,
        )?;
        self.devices.insert(
            device_id.to_owned(),
            Placement::from_rect(Rect::from_origin(origin, size)),
        );
        Some(origin)
    }

    /// Re-sizes a placed device (it reported a new size or rotated). It keeps whichever corner lets it stay legal
    /// (top-left first), so a phone placed with a default size that then reports its real portrait size stays
    /// attached to the same edge instead of being shelved. Returns the ids removed from the layout.
    pub fn resize(&mut self, device_id: &str, to: Size) -> Vec<String> {
        let Some(old) = self.devices.get(device_id).copied() else {
            return Vec::new();
        };
        if (old.width - to.width).abs() < 0.01 && (old.height - to.height).abs() < 0.01 {
            return Vec::new();
        }
        let me = ScreenId::Device(device_id.to_owned());
        let others: Vec<Rect> = self
            .screens()
            .into_iter()
            .filter(|(id, _)| *id != me)
            .map(|(_, r)| r)
            .collect();
        let r = old.rect();
        let origins = [
            r.origin(),
            Point::new(r.max_x() - to.width, r.min_y()),
            Point::new(r.min_x(), r.max_y() - to.height),
            Point::new(r.max_x() - to.width, r.max_y() - to.height),
        ];
        for o in origins {
            if Self::is_legal(&Rect::from_origin(o, to), &others) {
                self.devices.insert(
                    device_id.to_owned(),
                    Placement::from_rect(Rect::from_origin(o, to)),
                );
                return self.normalize();
            }
        }
        let mut p = old;
        p.width = to.width;
        p.height = to.height;
        self.devices.insert(device_id.to_owned(), p);
        self.normalize()
    }

    /// Removes a device and anything that was only reachable through it.
    pub fn remove(&mut self, device_id: &str) -> Vec<String> {
        if self.devices.remove(device_id).is_none() {
            return Vec::new();
        }
        let mut dropped = vec![device_id.to_owned()];
        dropped.extend(self.normalize());
        dropped
    }

    /// Drops devices that overlap something or are not connected (through touching edges) to a local display.
    pub fn normalize(&mut self) -> Vec<String> {
        let mut dropped = Vec::new();
        // Overlaps: drop devices that overlap local displays or earlier-kept devices.
        let mut kept: Vec<Rect> = self.local_displays.values().copied().collect();
        let ids: Vec<String> = self.devices.keys().cloned().collect();
        for id in ids {
            let rect = self.devices[&id].rect();
            let overlaps = kept.iter().any(|r| {
                rect.intersection_extent(r)
                    .is_some_and(|(w, h)| w > TOUCH_TOLERANCE && h > TOUCH_TOLERANCE)
            });
            if overlaps {
                self.devices.remove(&id);
                dropped.push(id);
            } else {
                kept.push(rect);
            }
        }
        // Connectivity: breadth-first from the local displays across shared edges.
        let mut reached: std::collections::HashSet<ScreenId> = self
            .local_displays
            .keys()
            .map(|k| ScreenId::Local(k.clone()))
            .collect();
        let mut frontier: Vec<ScreenId> = reached.iter().cloned().collect();
        while let Some(cur) = frontier.pop() {
            let Some(cr) = self.rect_of(&cur) else {
                continue;
            };
            for (id, p) in &self.devices {
                let sid = ScreenId::Device(id.clone());
                if !reached.contains(&sid)
                    && Self::shared_edge_length(&cr, &p.rect()) > TOUCH_TOLERANCE
                {
                    reached.insert(sid.clone());
                    frontier.push(sid);
                }
            }
        }
        let unreachable: Vec<String> = self
            .devices
            .keys()
            .filter(|id| !reached.contains(&ScreenId::Device((*id).clone())))
            .cloned()
            .collect();
        for id in unreachable {
            self.devices.remove(&id);
            dropped.push(id);
        }
        dropped
    }

    // ---- Persistence ------------------------------------------------------------------------------------------

    pub fn encode_devices(&self) -> String {
        serde_json::to_string_pretty(&Stored {
            version: 1,
            devices: self.devices.clone(),
        })
        .expect("layout serialises")
    }

    pub fn decode_devices(json: &str) -> Option<BTreeMap<String, Placement>> {
        serde_json::from_str::<Stored>(json).ok().map(|s| s.devices)
    }
}
