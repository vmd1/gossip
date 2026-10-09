//! The crossing engine: decides where the pointer is (the local computer, or one device) and turns mouse deltas
//! into actions. A pure state machine over [`ControlLayout`]; the shell performs the actions, so it is testable
//! with fake targets.
//!
//! - **Local**: the cursor moves normally. Pushing against a local display edge that is adjacent to a ready device
//!   for `push_threshold` points of accumulated outward travel enters that device.
//! - **Remote(device)**: deltas are integrated inside that device's rectangle (layout space). Reaching an edge
//!   adjacent to another ready device hands over to it; reaching one adjacent to a local display returns, at the
//!   position the layout alignment gives. Edges with nothing beyond them are walls.

use std::collections::HashSet;

use super::frame::ControlEdge;
use super::geometry::{Point, Rect};
use super::layout::{ControlLayout, ScreenId};

#[derive(Debug, Clone, PartialEq)]
pub enum PointerState {
    Local,
    Remote { device_id: String, position: Point },
}

impl PointerState {
    pub fn remote_device_id(&self) -> Option<&str> {
        match self {
            Self::Remote { device_id, .. } => Some(device_id),
            Self::Local => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum PointerAction {
    /// Tell `device_id` the cursor enters through `edge`, `fraction` (0..=1) along it.
    Enter {
        device_id: String,
        edge: ControlEdge,
        fraction: f64,
    },
    Leave {
        device_id: String,
    },
    /// Relative motion in layout points (the shell converts to device pixels).
    Move {
        device_id: String,
        dx: f64,
        dy: f64,
    },
    /// Put the real cursor here (global local-display coordinates, y down).
    WarpCursor(Point),
}

#[derive(Debug, Clone, PartialEq)]
struct PushKey {
    display: String,
    edge: ControlEdge,
    device_id: String,
}

#[derive(Debug, Clone)]
pub struct PointerRouter {
    layout: ControlLayout,
    state: PointerState,
    /// Devices with a live, ready session; anything else is a wall.
    pub ready_devices: HashSet<String>,
    pub push_threshold: f64,
    /// The device moves its cursor `pointer_gain` times further than the deltas we send (Android applies pointer
    /// acceleration to a relative mouse). The model integrates with this gain so the edge a user sees the cursor
    /// hit is the edge the router crosses; the *sent* delta is unchanged.
    pub pointer_gain: f64,
    /// How far inside the destination the pointer lands after crossing, so it does not instantly re-cross.
    pub inset_points: f64,
    push_accumulator: f64,
    push_key: Option<PushKey>,
}

impl PointerRouter {
    pub fn new(layout: ControlLayout, push_threshold: f64) -> Self {
        Self {
            layout,
            state: PointerState::Local,
            ready_devices: HashSet::new(),
            push_threshold,
            pointer_gain: 1.0,
            inset_points: 2.0,
            push_accumulator: 0.0,
            push_key: None,
        }
    }

    pub fn layout(&self) -> &ControlLayout {
        &self.layout
    }

    pub fn state(&self) -> &PointerState {
        &self.state
    }

    pub fn set_layout(&mut self, layout: ControlLayout) -> Vec<PointerAction> {
        self.layout = layout;
        self.reset_push();
        // The device being controlled may have been shelved.
        if let PointerState::Remote { device_id, .. } = &self.state {
            if !self.layout.is_placed(device_id) {
                return self.force_return(None, true);
            }
        }
        Vec::new()
    }

    pub fn device_became_unavailable(&mut self, device_id: &str) -> Vec<PointerAction> {
        self.ready_devices.remove(device_id);
        if self.state.remote_device_id() == Some(device_id) {
            return self.force_return(None, false);
        }
        Vec::new()
    }

    fn reset_push(&mut self) {
        self.push_accumulator = 0.0;
        self.push_key = None;
    }

    // ---- Local ------------------------------------------------------------------------------------------------

    /// A local mouse movement while Local. `location` is the cursor position after the OS applied the move.
    pub fn local_moved(&mut self, delta: Point, location: Point) -> Vec<PointerAction> {
        if self.state != PointerState::Local {
            return Vec::new();
        }
        let Some((uuid, rect)) = self.nearest_local_display(location) else {
            return Vec::new();
        };
        let eps = 1.5;
        let candidates = [
            (
                ControlEdge::Left,
                location.x <= rect.min_x() + eps && delta.x < 0.0,
                -delta.x,
            ),
            (
                ControlEdge::Right,
                location.x >= rect.max_x() - eps && delta.x > 0.0,
                delta.x,
            ),
            (
                ControlEdge::Top,
                location.y <= rect.min_y() + eps && delta.y < 0.0,
                -delta.y,
            ),
            (
                ControlEdge::Bottom,
                location.y >= rect.max_y() - eps && delta.y > 0.0,
                delta.y,
            ),
        ];
        let mut edge = None;
        let mut push = 0.0;
        for (e, pressed, amount) in candidates {
            if pressed && amount > push {
                edge = Some(e);
                push = amount;
            }
        }
        let Some(edge) = edge else {
            self.reset_push();
            return Vec::new();
        };

        let along = if matches!(edge, ControlEdge::Left | ControlEdge::Right) {
            location.y
        } else {
            location.x
        };
        let Some(ScreenId::Device(device_id)) =
            self.layout
                .neighbor(&ScreenId::Local(uuid.clone()), edge, along, &[])
        else {
            self.reset_push();
            return Vec::new();
        };
        if !self.ready_devices.contains(&device_id) {
            self.reset_push();
            return Vec::new();
        }

        let key = PushKey {
            display: uuid,
            edge,
            device_id: device_id.clone(),
        };
        if self.push_key.as_ref() != Some(&key) {
            self.push_key = Some(key);
            self.push_accumulator = 0.0;
        }
        self.push_accumulator += push;
        if self.push_accumulator < self.push_threshold {
            return Vec::new();
        }
        self.reset_push();
        self.enter_device(&device_id, edge, along)
    }

    // ---- Remote -----------------------------------------------------------------------------------------------

    /// A local mouse movement while Remote (deltas only; the real cursor is frozen).
    pub fn remote_moved(&mut self, delta: Point) -> Vec<PointerAction> {
        let PointerState::Remote {
            device_id: id,
            position: pos,
        } = self.state.clone()
        else {
            return Vec::new();
        };
        let Some(rect) = self.layout.rect_of(&ScreenId::Device(id.clone())) else {
            return Vec::new();
        };
        let mut actions = Vec::new();
        let target = Point::new(
            pos.x + delta.x * self.pointer_gain,
            pos.y + delta.y * self.pointer_gain,
        );
        // Always send the full delta: the device clamps at its own edges, which re-synchronises its cursor with
        // ours whenever the pointer is pushed into a wall.
        if delta.x != 0.0 || delta.y != 0.0 {
            actions.push(PointerAction::Move {
                device_id: id.clone(),
                dx: delta.x,
                dy: delta.y,
            });
        }

        // Which edge, if any, did we cross? Prefer the axis that overshoots more.
        let overs = [
            (ControlEdge::Left, rect.min_x() - target.x),
            (ControlEdge::Right, target.x - rect.max_x()),
            (ControlEdge::Top, rect.min_y() - target.y),
            (ControlEdge::Bottom, target.y - rect.max_y()),
        ];
        let crossed = overs.iter().filter(|(_, o)| *o > 0.0).fold(
            None::<(ControlEdge, f64)>,
            |best, &(e, o)| match best {
                Some((_, bo)) if bo >= o => best,
                _ => Some((e, o)),
            },
        );
        let clamped = Point::new(
            target.x.max(rect.min_x()).min(rect.max_x()),
            target.y.max(rect.min_y()).min(rect.max_y()),
        );

        if let Some((edge, _)) = crossed {
            let along = if matches!(edge, ControlEdge::Left | ControlEdge::Right) {
                clamped.y
            } else {
                clamped.x
            };
            if let Some(next) =
                self.layout
                    .neighbor(&ScreenId::Device(id.clone()), edge, along, &[])
            {
                match next {
                    ScreenId::Device(other) if self.ready_devices.contains(&other) => {
                        actions.push(PointerAction::Leave { device_id: id });
                        actions.extend(self.enter_device(&other, edge, along));
                        return actions;
                    }
                    ScreenId::Local(uuid) => {
                        if let Some(point) = self.local_point(&uuid, edge, along) {
                            actions.push(PointerAction::Leave { device_id: id });
                            actions.push(PointerAction::WarpCursor(point));
                            self.state = PointerState::Local;
                            self.reset_push();
                            return actions;
                        }
                    }
                    ScreenId::Device(_) => {}
                }
            }
        }
        self.state = PointerState::Remote {
            device_id: id,
            position: clamped,
        };
        actions
    }

    /// Escape hatch or session loss: go back now. `hint` is a local point to land near; without one the pointer is
    /// placed where the device was attached (or the first display's centre).
    pub fn force_return(&mut self, hint: Option<Point>, notify_device: bool) -> Vec<PointerAction> {
        let PointerState::Remote {
            device_id: id,
            position: pos,
        } = self.state.clone()
        else {
            return Vec::new();
        };
        let mut actions = Vec::new();
        if notify_device {
            actions.push(PointerAction::Leave {
                device_id: id.clone(),
            });
        }
        if let Some(point) = hint.or_else(|| self.return_point(&id, pos)) {
            actions.push(PointerAction::WarpCursor(point));
        }
        self.state = PointerState::Local;
        self.reset_push();
        actions
    }

    // ---- Closed-loop correction -------------------------------------------------------------------------------

    /// Whether the modelled cursor is within `margin` points of an edge of its device that leads to another
    /// screen: the only place an inaccurate model matters, because that is where it decides to hand over.
    pub fn is_near_exit_edge(&self, margin: f64) -> bool {
        let PointerState::Remote {
            device_id,
            position: pos,
        } = &self.state
        else {
            return false;
        };
        let Some(r) = self.layout.rect_of(&ScreenId::Device(device_id.clone())) else {
            return false;
        };
        let m = margin.min(r.width / 2.0).min(r.height / 2.0);
        let candidates = [
            (ControlEdge::Left, pos.x - r.min_x(), pos.y),
            (ControlEdge::Right, r.max_x() - pos.x, pos.y),
            (ControlEdge::Top, pos.y - r.min_y(), pos.x),
            (ControlEdge::Bottom, r.max_y() - pos.y, pos.x),
        ];
        candidates.into_iter().any(|(edge, distance, along)| {
            distance <= m
                && self
                    .layout
                    .neighbor(&ScreenId::Device(device_id.clone()), edge, along, &[])
                    .is_some()
        })
    }

    /// The device told us where its real cursor is: move the model by `(dx, dy)` (real minus modelled at that
    /// moment), staying inside the device. Never triggers a hand-over by itself; the next movement does.
    pub fn shift_remote_position(&mut self, dx: f64, dy: f64) {
        let PointerState::Remote {
            device_id,
            position: pos,
        } = self.state.clone()
        else {
            return;
        };
        let Some(r) = self.layout.rect_of(&ScreenId::Device(device_id.clone())) else {
            return;
        };
        self.state = PointerState::Remote {
            device_id,
            position: Point::new(
                (pos.x + dx).max(r.min_x()).min(r.max_x()),
                (pos.y + dy).max(r.min_y()).min(r.max_y()),
            ),
        };
        self.reset_push();
    }

    // ---- Helpers ----------------------------------------------------------------------------------------------

    fn enter_device(
        &mut self,
        device_id: &str,
        exit_edge: ControlEdge,
        along: f64,
    ) -> Vec<PointerAction> {
        let sid = ScreenId::Device(device_id.to_owned());
        let Some(rect) = self.layout.rect_of(&sid) else {
            return Vec::new();
        };
        let entry_edge = exit_edge.opposite();
        let fraction = self
            .layout
            .edge_fraction(&sid, entry_edge, along)
            .unwrap_or(0.5);
        let inset = self.inset_points;
        let clamp_y = along.max(rect.min_y()).min(rect.max_y());
        let clamp_x = along.max(rect.min_x()).min(rect.max_x());
        let pos = match entry_edge {
            ControlEdge::Left => Point::new(rect.min_x() + inset, clamp_y),
            ControlEdge::Right => Point::new(rect.max_x() - inset, clamp_y),
            ControlEdge::Top => Point::new(clamp_x, rect.min_y() + inset),
            ControlEdge::Bottom => Point::new(clamp_x, rect.max_y() - inset),
        };
        self.state = PointerState::Remote {
            device_id: device_id.to_owned(),
            position: pos,
        };
        vec![PointerAction::Enter {
            device_id: device_id.to_owned(),
            edge: entry_edge,
            fraction,
        }]
    }

    fn nearest_local_display(&self, p: Point) -> Option<(String, Rect)> {
        let mut best: Option<(String, Rect, f64)> = None;
        for (id, r) in self.layout.local_displays() {
            let dx = (r.min_x() - p.x).max(0.0).max(p.x - r.max_x());
            let dy = (r.min_y() - p.y).max(0.0).max(p.y - r.max_y());
            let d = dx * dx + dy * dy;
            if best.as_ref().map_or(true, |b| d < b.2) {
                best = Some((id.clone(), *r, d));
            }
        }
        best.map(|(id, r, _)| (id, r))
    }

    /// Where on local display `uuid` the pointer lands after leaving across `edge` of a device at layout `along`.
    fn local_point(&self, uuid: &str, edge: ControlEdge, along: f64) -> Option<Point> {
        let r = *self.layout.local_displays().get(uuid)?;
        let inset = self.inset_points;
        let y = along.max(r.min_y() + 1.0).min(r.max_y() - 1.0);
        let x = along.max(r.min_x() + 1.0).min(r.max_x() - 1.0);
        Some(match edge {
            // Out the left of the device: land on the local display's right edge, and so on.
            ControlEdge::Left => Point::new(r.max_x() - inset, y),
            ControlEdge::Right => Point::new(r.min_x() + inset, y),
            ControlEdge::Top => Point::new(x, r.max_y() - inset),
            ControlEdge::Bottom => Point::new(x, r.min_y() + inset),
        })
    }

    fn return_point(&self, device_id: &str, _position: Point) -> Option<Point> {
        let Some(rect) = self.layout.rect_of(&ScreenId::Device(device_id.to_owned())) else {
            return self
                .layout
                .local_displays()
                .values()
                .next()
                .map(|r| Point::new(r.mid_x(), r.mid_y()));
        };
        // The local display closest to where the device sits.
        let mut best: Option<(Rect, f64)> = None;
        for r in self.layout.local_displays().values() {
            let dx = (r.min_x() - rect.mid_x())
                .max(0.0)
                .max(rect.mid_x() - r.max_x());
            let dy = (r.min_y() - rect.mid_y())
                .max(0.0)
                .max(rect.mid_y() - r.max_y());
            let d = dx * dx + dy * dy;
            if best.map_or(true, |b| d < b.1) {
                best = Some((*r, d));
            }
        }
        let (r, _) = best?;
        Some(Point::new(
            rect.mid_x().max(r.min_x() + 2.0).min(r.max_x() - 2.0),
            rect.mid_y().max(r.min_y() + 2.0).min(r.max_y() - 2.0),
        ))
    }
}
