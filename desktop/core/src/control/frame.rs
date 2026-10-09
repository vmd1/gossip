//! Wire frames of the Universal Control data channel. Each WebSocket message carries one frame, sealed with
//! `crypto::stream` under `Profile::CONTROL`. A frame is `[u8 kind][payload]`, multi-byte integers big-endian.
//! Checked against `schema/control-test-vectors.json`.

/// Screen edge, from the point of view of the screen the pointer enters or leaves through.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum ControlEdge {
    Left = 0,
    Right = 1,
    Top = 2,
    Bottom = 3,
}

impl ControlEdge {
    pub const ALL: [ControlEdge; 4] = [
        ControlEdge::Left,
        ControlEdge::Right,
        ControlEdge::Top,
        ControlEdge::Bottom,
    ];

    pub fn from_u8(v: u8) -> Option<Self> {
        Self::ALL.into_iter().find(|e| *e as u8 == v)
    }

    pub fn opposite(self) -> Self {
        match self {
            Self::Left => Self::Right,
            Self::Right => Self::Left,
            Self::Top => Self::Bottom,
            Self::Bottom => Self::Top,
        }
    }
}

/// Device navigation actions bound to the Mac-side shortcuts (⌘1, ⌘2, ⌘3, ⌘[).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ControlAction {
    Home = 1,
    AppSwitch = 2,
    Notifications = 3,
    Back = 4,
}

impl ControlAction {
    pub fn from_u8(v: u8) -> Option<Self> {
        Some(match v {
            1 => Self::Home,
            2 => Self::AppSwitch,
            3 => Self::Notifications,
            4 => Self::Back,
            _ => return None,
        })
    }

    /// The action bound to ⌘ plus this macOS virtual key code (1, 2, 3 and [).
    pub fn from_mac_key_code(code: u16) -> Option<Self> {
        match code {
            18 => Some(Self::Home),
            19 => Some(Self::AppSwitch),
            20 => Some(Self::Notifications),
            33 => Some(Self::Back),
            _ => None,
        }
    }
}

/// Which input backend the device is using.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ControlBackendKind {
    Uhid = 0,
    TouchOverlay = 1,
}

/// What a device reports about itself on connect and on rotation: its logical, rotation-applied size.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ControlDisplayInfo {
    pub width: u16,
    pub height: u16,
    /// 0 to 3, quarter turns clockwise.
    pub rotation: u8,
    /// A [`ControlBackendKind`] value.
    pub backend: u8,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ControlFrame {
    // controller -> device
    Hello {
        session_id: String,
    },
    /// The pointer enters the device through `edge`, `position` (0..=65535) of the way along it.
    Enter {
        edge: ControlEdge,
        position: u16,
    },
    Leave,
    MouseMove {
        dx: i16,
        dy: i16,
    },
    /// Bit 0 primary, 1 secondary, 2 middle, 3 back, 4 forward.
    Buttons(u8),
    /// 1/120 of a notch (like the Windows wheel delta); positive y is up, positive x is right.
    Scroll {
        dx: i16,
        dy: i16,
    },
    /// `usage` is a USB HID keyboard-page usage; `modifiers` the HID modifier bitmask (LCtrl=1, LShift=2, LAlt=4,
    /// LMeta=8, RCtrl=16, RShift=32, RAlt=64, RMeta=128).
    Key {
        usage: u16,
        down: bool,
        modifiers: u8,
    },
    Text(String),
    Ping,
    /// Asks the device where its real cursor is; answered with `CursorPos` carrying the same token.
    CursorQuery {
        token: u8,
    },
    Action(ControlAction),
    // device -> controller
    HelloAck(ControlDisplayInfo),
    DisplayInfo(ControlDisplayInfo),
    Error(String),
    Pong,
    /// The device's real cursor position in its logical pixels, and how many `MouseMove` frames it had applied
    /// since the last `Enter`, so the controller can compare it with its model at that moment.
    CursorPos {
        token: u8,
        x: u16,
        y: u16,
        applied: u32,
    },
}

mod kind {
    pub const HELLO: u8 = 0x01;
    pub const ENTER: u8 = 0x10;
    pub const LEAVE: u8 = 0x11;
    pub const MOUSE_MOVE: u8 = 0x12;
    pub const BUTTONS: u8 = 0x13;
    pub const SCROLL: u8 = 0x14;
    pub const KEY: u8 = 0x15;
    pub const TEXT: u8 = 0x16;
    pub const PING: u8 = 0x17;
    pub const CURSOR_QUERY: u8 = 0x18;
    pub const ACTION: u8 = 0x19;
    pub const HELLO_ACK: u8 = 0x81;
    pub const DISPLAY_INFO: u8 = 0x82;
    pub const ERROR: u8 = 0x84;
    pub const PONG: u8 = 0x85;
    pub const CURSOR_POS: u8 = 0x86;
}

struct Reader<'a> {
    data: &'a [u8],
}

impl<'a> Reader<'a> {
    fn u8(&mut self) -> Option<u8> {
        let (&first, rest) = self.data.split_first()?;
        self.data = rest;
        Some(first)
    }
    fn u16(&mut self) -> Option<u16> {
        Some(u16::from(self.u8()?) << 8 | u16::from(self.u8()?))
    }
    fn i16(&mut self) -> Option<i16> {
        self.u16().map(|v| v as i16)
    }
    fn u32(&mut self) -> Option<u32> {
        Some(u32::from(self.u16()?) << 16 | u32::from(self.u16()?))
    }
    fn at_end(&self) -> bool {
        self.data.is_empty()
    }
    fn rest_string(&mut self) -> Option<String> {
        let s = std::str::from_utf8(self.data).ok()?.to_owned();
        self.data = &[];
        Some(s)
    }
    fn display(&mut self) -> Option<ControlDisplayInfo> {
        let info = ControlDisplayInfo {
            width: self.u16()?,
            height: self.u16()?,
            rotation: self.u8()?,
            backend: self.u8()?,
        };
        self.at_end().then_some(info)
    }
}

fn push_display(out: &mut Vec<u8>, d: &ControlDisplayInfo) {
    out.extend_from_slice(&d.width.to_be_bytes());
    out.extend_from_slice(&d.height.to_be_bytes());
    out.push(d.rotation);
    out.push(d.backend);
}

impl ControlFrame {
    pub fn encode(&self) -> Vec<u8> {
        let mut o = Vec::new();
        match self {
            Self::Hello { session_id } => {
                o.push(kind::HELLO);
                o.extend_from_slice(session_id.as_bytes());
            }
            Self::Enter { edge, position } => {
                o.extend_from_slice(&[kind::ENTER, *edge as u8]);
                o.extend_from_slice(&position.to_be_bytes());
            }
            Self::Leave => o.push(kind::LEAVE),
            Self::MouseMove { dx, dy } => {
                o.push(kind::MOUSE_MOVE);
                o.extend_from_slice(&dx.to_be_bytes());
                o.extend_from_slice(&dy.to_be_bytes());
            }
            Self::Buttons(mask) => o.extend_from_slice(&[kind::BUTTONS, *mask]),
            Self::Scroll { dx, dy } => {
                o.push(kind::SCROLL);
                o.extend_from_slice(&dx.to_be_bytes());
                o.extend_from_slice(&dy.to_be_bytes());
            }
            Self::Key {
                usage,
                down,
                modifiers,
            } => {
                o.push(kind::KEY);
                o.extend_from_slice(&usage.to_be_bytes());
                o.extend_from_slice(&[u8::from(*down), *modifiers]);
            }
            Self::Text(s) => {
                o.push(kind::TEXT);
                o.extend_from_slice(s.as_bytes());
            }
            Self::Ping => o.push(kind::PING),
            Self::CursorQuery { token } => o.extend_from_slice(&[kind::CURSOR_QUERY, *token]),
            Self::Action(a) => o.extend_from_slice(&[kind::ACTION, *a as u8]),
            Self::HelloAck(d) => {
                o.push(kind::HELLO_ACK);
                push_display(&mut o, d);
            }
            Self::DisplayInfo(d) => {
                o.push(kind::DISPLAY_INFO);
                push_display(&mut o, d);
            }
            Self::Error(s) => {
                o.push(kind::ERROR);
                o.extend_from_slice(s.as_bytes());
            }
            Self::Pong => o.push(kind::PONG),
            Self::CursorPos {
                token,
                x,
                y,
                applied,
            } => {
                o.extend_from_slice(&[kind::CURSOR_POS, *token]);
                o.extend_from_slice(&x.to_be_bytes());
                o.extend_from_slice(&y.to_be_bytes());
                o.extend_from_slice(&applied.to_be_bytes());
            }
        }
        o
    }

    /// `None` for an unknown kind or any malformed or trailing bytes.
    pub fn decode(data: &[u8]) -> Option<Self> {
        let mut r = Reader { data };
        let k = r.u8()?;
        Some(match k {
            kind::HELLO => Self::Hello {
                session_id: r.rest_string()?,
            },
            kind::ENTER => {
                let edge = ControlEdge::from_u8(r.u8()?)?;
                let position = r.u16()?;
                r.at_end().then_some(Self::Enter { edge, position })?
            }
            kind::LEAVE => r.at_end().then_some(Self::Leave)?,
            kind::MOUSE_MOVE => {
                let (dx, dy) = (r.i16()?, r.i16()?);
                r.at_end().then_some(Self::MouseMove { dx, dy })?
            }
            kind::BUTTONS => {
                let m = r.u8()?;
                r.at_end().then_some(Self::Buttons(m))?
            }
            kind::SCROLL => {
                let (dx, dy) = (r.i16()?, r.i16()?);
                r.at_end().then_some(Self::Scroll { dx, dy })?
            }
            kind::KEY => {
                let (usage, down, modifiers) = (r.u16()?, r.u8()?, r.u8()?);
                (r.at_end() && down <= 1).then_some(Self::Key {
                    usage,
                    down: down == 1,
                    modifiers,
                })?
            }
            kind::TEXT => Self::Text(r.rest_string()?),
            kind::PING => r.at_end().then_some(Self::Ping)?,
            kind::CURSOR_QUERY => {
                let token = r.u8()?;
                r.at_end().then_some(Self::CursorQuery { token })?
            }
            kind::ACTION => {
                let a = ControlAction::from_u8(r.u8()?)?;
                r.at_end().then_some(Self::Action(a))?
            }
            kind::HELLO_ACK => Self::HelloAck(r.display()?),
            kind::DISPLAY_INFO => Self::DisplayInfo(r.display()?),
            kind::ERROR => Self::Error(r.rest_string()?),
            kind::PONG => r.at_end().then_some(Self::Pong)?,
            kind::CURSOR_POS => {
                let (token, x, y, applied) = (r.u8()?, r.u16()?, r.u16()?, r.u32()?);
                r.at_end().then_some(Self::CursorPos {
                    token,
                    x,
                    y,
                    applied,
                })?
            }
            _ => return None,
        })
    }
}
