//! Universal Control: the platform-neutral parts. The wire frames of the data channel, the geometry of the screen
//! arrangement and the crossing state machine that decides where the pointer is. Event capture and injection,
//! the WebSocket and the cursor itself belong to the shell. The channel's AEAD is `crypto::stream`.

pub mod frame;
pub mod geometry;
pub mod layout;
pub mod router;

pub use frame::{ControlAction, ControlBackendKind, ControlDisplayInfo, ControlEdge, ControlFrame};
pub use geometry::{Point, Rect, Size};
pub use layout::{ControlLayout, Placement, ScreenId};
pub use router::{PointerAction, PointerRouter, PointerState};
