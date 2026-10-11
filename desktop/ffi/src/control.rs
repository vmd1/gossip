//! Universal Control: the data-channel frames, the screen arrangement and the pointer router.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, MutexGuard};

use gossip_core::control as core;
use gossip_core::wire::handshake::DeviceType;

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

// ---- Geometry --------------------------------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct Size {
    pub width: f64,
    pub height: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl From<Point> for core::Point {
    fn from(p: Point) -> Self {
        core::Point::new(p.x, p.y)
    }
}
impl From<core::Point> for Point {
    fn from(p: core::Point) -> Self {
        Self { x: p.x, y: p.y }
    }
}
impl From<Size> for core::Size {
    fn from(s: Size) -> Self {
        core::Size::new(s.width, s.height)
    }
}
impl From<core::Size> for Size {
    fn from(s: core::Size) -> Self {
        Self {
            width: s.width,
            height: s.height,
        }
    }
}
impl From<Rect> for core::Rect {
    fn from(r: Rect) -> Self {
        core::Rect::new(r.x, r.y, r.width, r.height)
    }
}
impl From<core::Rect> for Rect {
    fn from(r: core::Rect) -> Self {
        Self {
            x: r.x,
            y: r.y,
            width: r.width,
            height: r.height,
        }
    }
}

// ---- Frames ----------------------------------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ControlEdge {
    Left,
    Right,
    Top,
    Bottom,
}

impl From<ControlEdge> for core::ControlEdge {
    fn from(e: ControlEdge) -> Self {
        match e {
            ControlEdge::Left => Self::Left,
            ControlEdge::Right => Self::Right,
            ControlEdge::Top => Self::Top,
            ControlEdge::Bottom => Self::Bottom,
        }
    }
}
impl From<core::ControlEdge> for ControlEdge {
    fn from(e: core::ControlEdge) -> Self {
        match e {
            core::ControlEdge::Left => Self::Left,
            core::ControlEdge::Right => Self::Right,
            core::ControlEdge::Top => Self::Top,
            core::ControlEdge::Bottom => Self::Bottom,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ControlAction {
    Home,
    AppSwitch,
    Notifications,
    Back,
}

impl From<ControlAction> for core::ControlAction {
    fn from(a: ControlAction) -> Self {
        match a {
            ControlAction::Home => Self::Home,
            ControlAction::AppSwitch => Self::AppSwitch,
            ControlAction::Notifications => Self::Notifications,
            ControlAction::Back => Self::Back,
        }
    }
}
impl From<core::ControlAction> for ControlAction {
    fn from(a: core::ControlAction) -> Self {
        match a {
            core::ControlAction::Home => Self::Home,
            core::ControlAction::AppSwitch => Self::AppSwitch,
            core::ControlAction::Notifications => Self::Notifications,
            core::ControlAction::Back => Self::Back,
        }
    }
}

/// The action bound to Cmd plus this macOS virtual key code (1, 2, 3 and `[`).
#[uniffi::export]
pub fn control_action_for_mac_key_code(code: u16) -> Option<ControlAction> {
    core::ControlAction::from_mac_key_code(code).map(Into::into)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ControlDisplayInfo {
    pub width: u16,
    pub height: u16,
    pub rotation: u8,
    pub backend: u8,
}

impl From<ControlDisplayInfo> for core::ControlDisplayInfo {
    fn from(d: ControlDisplayInfo) -> Self {
        Self {
            width: d.width,
            height: d.height,
            rotation: d.rotation,
            backend: d.backend,
        }
    }
}
impl From<core::ControlDisplayInfo> for ControlDisplayInfo {
    fn from(d: core::ControlDisplayInfo) -> Self {
        Self {
            width: d.width,
            height: d.height,
            rotation: d.rotation,
            backend: d.backend,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ControlFrame {
    Hello {
        session_id: String,
    },
    Enter {
        edge: ControlEdge,
        position: u16,
    },
    Leave,
    MouseMove {
        dx: i16,
        dy: i16,
    },
    Buttons {
        mask: u8,
    },
    Scroll {
        dx: i16,
        dy: i16,
    },
    Key {
        usage: u16,
        down: bool,
        modifiers: u8,
    },
    Text {
        text: String,
    },
    Ping,
    CursorQuery {
        token: u8,
    },
    Action {
        action: ControlAction,
    },
    HelloAck {
        info: ControlDisplayInfo,
    },
    DisplayInfo {
        info: ControlDisplayInfo,
    },
    Error {
        reason: String,
    },
    Pong,
    CursorPos {
        token: u8,
        x: u16,
        y: u16,
        applied: u32,
    },
}

impl From<ControlFrame> for core::ControlFrame {
    fn from(f: ControlFrame) -> Self {
        use core::ControlFrame as C;
        match f {
            ControlFrame::Hello { session_id } => C::Hello { session_id },
            ControlFrame::Enter { edge, position } => C::Enter {
                edge: edge.into(),
                position,
            },
            ControlFrame::Leave => C::Leave,
            ControlFrame::MouseMove { dx, dy } => C::MouseMove { dx, dy },
            ControlFrame::Buttons { mask } => C::Buttons(mask),
            ControlFrame::Scroll { dx, dy } => C::Scroll { dx, dy },
            ControlFrame::Key {
                usage,
                down,
                modifiers,
            } => C::Key {
                usage,
                down,
                modifiers,
            },
            ControlFrame::Text { text } => C::Text(text),
            ControlFrame::Ping => C::Ping,
            ControlFrame::CursorQuery { token } => C::CursorQuery { token },
            ControlFrame::Action { action } => C::Action(action.into()),
            ControlFrame::HelloAck { info } => C::HelloAck(info.into()),
            ControlFrame::DisplayInfo { info } => C::DisplayInfo(info.into()),
            ControlFrame::Error { reason } => C::Error(reason),
            ControlFrame::Pong => C::Pong,
            ControlFrame::CursorPos {
                token,
                x,
                y,
                applied,
            } => C::CursorPos {
                token,
                x,
                y,
                applied,
            },
        }
    }
}

impl From<core::ControlFrame> for ControlFrame {
    fn from(f: core::ControlFrame) -> Self {
        use core::ControlFrame as C;
        match f {
            C::Hello { session_id } => Self::Hello { session_id },
            C::Enter { edge, position } => Self::Enter {
                edge: edge.into(),
                position,
            },
            C::Leave => Self::Leave,
            C::MouseMove { dx, dy } => Self::MouseMove { dx, dy },
            C::Buttons(mask) => Self::Buttons { mask },
            C::Scroll { dx, dy } => Self::Scroll { dx, dy },
            C::Key {
                usage,
                down,
                modifiers,
            } => Self::Key {
                usage,
                down,
                modifiers,
            },
            C::Text(text) => Self::Text { text },
            C::Ping => Self::Ping,
            C::CursorQuery { token } => Self::CursorQuery { token },
            C::Action(action) => Self::Action {
                action: action.into(),
            },
            C::HelloAck(info) => Self::HelloAck { info: info.into() },
            C::DisplayInfo(info) => Self::DisplayInfo { info: info.into() },
            C::Error(reason) => Self::Error { reason },
            C::Pong => Self::Pong,
            C::CursorPos {
                token,
                x,
                y,
                applied,
            } => Self::CursorPos {
                token,
                x,
                y,
                applied,
            },
        }
    }
}

/// The frame's wire bytes (seal them with a `StreamCipher` before sending).
#[uniffi::export]
pub fn control_frame_encode(frame: ControlFrame) -> Vec<u8> {
    core::ControlFrame::from(frame).encode()
}

/// `None` for an unknown kind or malformed bytes.
#[uniffi::export]
pub fn control_frame_decode(data: Vec<u8>) -> Option<ControlFrame> {
    core::ControlFrame::decode(&data).map(Into::into)
}

// ---- Layout ----------------------------------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ScreenId {
    /// A display of the controlling computer.
    Local { id: String },
    /// A device, by its Gossip device id.
    Device { id: String },
}

impl From<ScreenId> for core::ScreenId {
    fn from(s: ScreenId) -> Self {
        match s {
            ScreenId::Local { id } => Self::Local(id),
            ScreenId::Device { id } => Self::Device(id),
        }
    }
}
impl From<core::ScreenId> for ScreenId {
    fn from(s: core::ScreenId) -> Self {
        match s {
            core::ScreenId::Local(id) => Self::Local { id },
            core::ScreenId::Device(id) => Self::Device { id },
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct LocalDisplay {
    pub id: String,
    pub rect: Rect,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct DevicePlacement {
    pub device_id: String,
    pub rect: Rect,
}

#[uniffi::export]
pub fn control_default_pixel_size(device_type: String) -> Size {
    core::ControlLayout::default_pixel_size(&DeviceType::parse(&device_type)).into()
}

/// A device's size in layout points from its pixel size.
#[uniffi::export]
pub fn control_device_size(pixel_width: f64, pixel_height: f64, pixels_per_point: f64) -> Size {
    core::ControlLayout::device_size(pixel_width, pixel_height, pixels_per_point).into()
}

#[uniffi::export]
pub fn control_default_pixels_per_point() -> f64 {
    core::layout::DEFAULT_PIXELS_PER_POINT
}

#[uniffi::export]
pub fn control_snap_distance() -> f64 {
    core::layout::SNAP_DISTANCE
}

/// The arrangement of screens: fixed local displays plus user-placed devices.
#[derive(uniffi::Object)]
pub struct ControlLayout(Mutex<core::ControlLayout>);

impl ControlLayout {
    pub(crate) fn snapshot(&self) -> core::ControlLayout {
        lock(&self.0).clone()
    }
}

fn local_map(displays: Vec<LocalDisplay>) -> BTreeMap<String, core::Rect> {
    displays
        .into_iter()
        .map(|d| (d.id, d.rect.into()))
        .collect()
}

#[uniffi::export]
impl ControlLayout {
    #[uniffi::constructor]
    pub fn new(local_displays: Vec<LocalDisplay>, devices: Vec<DevicePlacement>) -> Arc<Self> {
        let devices = devices
            .into_iter()
            .map(|d| (d.device_id, core::Placement::from_rect(d.rect.into())))
            .collect();
        Arc::new(Self(Mutex::new(core::ControlLayout::new(
            local_map(local_displays),
            devices,
        ))))
    }

    pub fn devices(&self) -> Vec<DevicePlacement> {
        lock(&self.0)
            .devices()
            .iter()
            .map(|(id, p)| DevicePlacement {
                device_id: id.clone(),
                rect: p.rect().into(),
            })
            .collect()
    }

    pub fn rect_of(&self, id: ScreenId) -> Option<Rect> {
        lock(&self.0).rect_of(&id.into()).map(Into::into)
    }

    pub fn is_placed(&self, device_id: String) -> bool {
        lock(&self.0).is_placed(&device_id)
    }

    /// The screen across `edge` of `from` at layout coordinate `along`.
    pub fn neighbor(
        &self,
        from: ScreenId,
        edge: ControlEdge,
        along: f64,
        excluding: Vec<ScreenId>,
    ) -> Option<ScreenId> {
        let excluding: Vec<core::ScreenId> = excluding.into_iter().map(Into::into).collect();
        lock(&self.0)
            .neighbor(&from.into(), edge.into(), along, &excluding)
            .map(Into::into)
    }

    pub fn edge_fraction(&self, id: ScreenId, edge: ControlEdge, along: f64) -> Option<f64> {
        lock(&self.0).edge_fraction(&id.into(), edge.into(), along)
    }

    /// Replaces the local displays; returns the devices that no longer fit.
    pub fn set_local_displays(&self, displays: Vec<LocalDisplay>) -> Vec<String> {
        lock(&self.0).set_local_displays(local_map(displays))
    }

    /// Where a dropped device would end up (snapped), or `None` if there is no legal spot.
    pub fn resolve_drop(
        &self,
        device_id: String,
        size: Size,
        proposed_origin: Point,
        snap_distance: f64,
        capture_distance: f64,
    ) -> Option<Point> {
        lock(&self.0)
            .resolve_drop(
                &device_id,
                size.into(),
                proposed_origin.into(),
                snap_distance,
                capture_distance,
            )
            .map(Into::into)
    }

    /// Places (or moves) a device; returns its final origin or `None` (layout unchanged).
    pub fn place(
        &self,
        device_id: String,
        size: Size,
        proposed_origin: Point,
        snap_distance: f64,
        capture_distance: f64,
    ) -> Option<Point> {
        lock(&self.0)
            .place(
                &device_id,
                size.into(),
                proposed_origin.into(),
                snap_distance,
                capture_distance,
            )
            .map(Into::into)
    }

    /// Re-sizes a placed device; returns the ids removed from the layout.
    pub fn resize(&self, device_id: String, size: Size) -> Vec<String> {
        lock(&self.0).resize(&device_id, size.into())
    }

    /// Removes a device and anything only reachable through it; returns the removed ids.
    pub fn remove(&self, device_id: String) -> Vec<String> {
        lock(&self.0).remove(&device_id)
    }

    /// The placements as JSON, for persistence.
    pub fn encode_devices(&self) -> String {
        lock(&self.0).encode_devices()
    }
}

/// Parses placements saved by `encode_devices`.
#[uniffi::export]
pub fn control_decode_devices(json: String) -> Option<Vec<DevicePlacement>> {
    core::ControlLayout::decode_devices(&json).map(|m| {
        m.into_iter()
            .map(|(device_id, p)| DevicePlacement {
                device_id,
                rect: p.rect().into(),
            })
            .collect()
    })
}

// ---- Pointer router --------------------------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum PointerState {
    Local,
    Remote { device_id: String, position: Point },
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum PointerAction {
    /// Tell the device the cursor enters through `edge`, `fraction` (0 to 1) along it.
    Enter {
        device_id: String,
        edge: ControlEdge,
        fraction: f64,
    },
    Leave {
        device_id: String,
    },
    /// Relative motion in layout points (convert to device pixels).
    Move {
        device_id: String,
        dx: f64,
        dy: f64,
    },
    /// Put the real cursor here.
    WarpCursor {
        point: Point,
    },
}

impl From<core::PointerAction> for PointerAction {
    fn from(a: core::PointerAction) -> Self {
        use core::PointerAction as A;
        match a {
            A::Enter {
                device_id,
                edge,
                fraction,
            } => Self::Enter {
                device_id,
                edge: edge.into(),
                fraction,
            },
            A::Leave { device_id } => Self::Leave { device_id },
            A::Move { device_id, dx, dy } => Self::Move { device_id, dx, dy },
            A::WarpCursor(p) => Self::WarpCursor { point: p.into() },
        }
    }
}

fn pa(v: Vec<core::PointerAction>) -> Vec<PointerAction> {
    v.into_iter().map(Into::into).collect()
}

/// Decides where the pointer is (the local computer or one device) and turns mouse deltas into actions.
#[derive(uniffi::Object)]
pub struct PointerRouter(Mutex<core::PointerRouter>);

#[uniffi::export]
impl PointerRouter {
    /// Copies the layout's current state; call `set_layout` after the layout changes.
    #[uniffi::constructor]
    pub fn new(layout: Arc<ControlLayout>, push_threshold: f64) -> Arc<Self> {
        Arc::new(Self(Mutex::new(core::PointerRouter::new(
            layout.snapshot(),
            push_threshold,
        ))))
    }

    pub fn set_layout(&self, layout: Arc<ControlLayout>) -> Vec<PointerAction> {
        pa(lock(&self.0).set_layout(layout.snapshot()))
    }

    /// Devices with a live, ready session; anything else is a wall.
    pub fn set_ready_devices(&self, devices: Vec<String>) {
        lock(&self.0).ready_devices = devices.into_iter().collect();
    }

    /// The device moves its cursor this many times further than the deltas sent (pointer acceleration).
    pub fn set_pointer_gain(&self, gain: f64) {
        lock(&self.0).pointer_gain = gain;
    }

    pub fn state(&self) -> PointerState {
        match lock(&self.0).state() {
            core::PointerState::Local => PointerState::Local,
            core::PointerState::Remote {
                device_id,
                position,
            } => PointerState::Remote {
                device_id: device_id.clone(),
                position: (*position).into(),
            },
        }
    }

    /// A local mouse movement while Local; `location` is the cursor position after the OS applied the move.
    pub fn local_moved(&self, delta: Point, location: Point) -> Vec<PointerAction> {
        pa(lock(&self.0).local_moved(delta.into(), location.into()))
    }

    /// A local mouse movement while Remote (deltas only; the real cursor is frozen).
    pub fn remote_moved(&self, delta: Point) -> Vec<PointerAction> {
        pa(lock(&self.0).remote_moved(delta.into()))
    }

    /// Escape hatch or session loss: go back now.
    pub fn force_return(&self, hint: Option<Point>, notify_device: bool) -> Vec<PointerAction> {
        pa(lock(&self.0).force_return(hint.map(Into::into), notify_device))
    }

    pub fn device_became_unavailable(&self, device_id: String) -> Vec<PointerAction> {
        pa(lock(&self.0).device_became_unavailable(&device_id))
    }

    pub fn is_near_exit_edge(&self, margin: f64) -> bool {
        lock(&self.0).is_near_exit_edge(margin)
    }

    /// The device reported where its real cursor is: move the model by (dx, dy).
    pub fn shift_remote_position(&self, dx: f64, dy: f64) {
        lock(&self.0).shift_remote_position(dx, dy);
    }
}
