//! Universal Control: frame codec (shared vectors) and the layout/router ports of the Swift test suites.

use std::collections::BTreeMap;

use gossip_core::control::*;
use gossip_core::wire::handshake::DeviceType;
use serde_json::Value;

// ---- Frame codec against schema/control-test-vectors.json ---------------------------------------------------

fn frame_from_json(f: &Value) -> ControlFrame {
    let n = |k: &str| f[k].as_i64().unwrap();
    match f["type"].as_str().unwrap() {
        "hello" => ControlFrame::Hello {
            session_id: f["sessionId"].as_str().unwrap().into(),
        },
        "hello_ack" => ControlFrame::HelloAck(ControlDisplayInfo {
            width: n("width") as u16,
            height: n("height") as u16,
            rotation: n("rotation") as u8,
            backend: n("backend") as u8,
        }),
        "display_info" => ControlFrame::DisplayInfo(ControlDisplayInfo {
            width: n("width") as u16,
            height: n("height") as u16,
            rotation: n("rotation") as u8,
            backend: n("backend") as u8,
        }),
        "enter" => ControlFrame::Enter {
            edge: ControlEdge::from_u8(n("edge") as u8).unwrap(),
            position: n("position") as u16,
        },
        "leave" => ControlFrame::Leave,
        "mouse_move" => ControlFrame::MouseMove {
            dx: n("dx") as i16,
            dy: n("dy") as i16,
        },
        "buttons" => ControlFrame::Buttons(n("mask") as u8),
        "scroll" => ControlFrame::Scroll {
            dx: n("dx") as i16,
            dy: n("dy") as i16,
        },
        "key" => ControlFrame::Key {
            usage: n("usage") as u16,
            down: f["down"].as_bool().unwrap(),
            modifiers: n("modifiers") as u8,
        },
        "text" => ControlFrame::Text(f["text"].as_str().unwrap().into()),
        "ping" => ControlFrame::Ping,
        "pong" => ControlFrame::Pong,
        "error" => ControlFrame::Error(f["reason"].as_str().unwrap().into()),
        other => panic!("vector has a frame type the test does not know: {other}"),
    }
}

#[test]
fn control_frames_match_the_shared_vectors() {
    let dir = std::env::var_os("GOSSIP_SCHEMA_DIR")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| {
            [env!("CARGO_MANIFEST_DIR"), "..", "..", "schema"]
                .iter()
                .collect()
        });
    let v: Value =
        serde_json::from_slice(&std::fs::read(dir.join("control-test-vectors.json")).unwrap())
            .unwrap();
    for case in v["cases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let bytes = hex::decode(case["plaintextHex"].as_str().unwrap()).unwrap();
        let frame = frame_from_json(&case["frame"]);
        assert_eq!(frame.encode(), bytes, "encode {name}");
        assert_eq!(ControlFrame::decode(&bytes), Some(frame), "decode {name}");
    }
}

#[test]
fn control_frames_round_trip_and_reject_malformed_input() {
    let frames = [
        ControlFrame::Action(ControlAction::Notifications),
        ControlFrame::CursorQuery { token: 9 },
        ControlFrame::CursorPos {
            token: 3,
            x: 1919,
            y: 1079,
            applied: 70_000,
        },
        ControlFrame::Key {
            usage: 0xE3,
            down: false,
            modifiers: 0x88,
        },
    ];
    for f in frames {
        assert_eq!(ControlFrame::decode(&f.encode()), Some(f.clone()), "{f:?}");
        let mut extra = f.encode();
        extra.push(0);
        // Frames with a fixed shape refuse trailing bytes (text-like frames take the rest by design).
        if !matches!(
            f,
            ControlFrame::Text(_) | ControlFrame::Hello { .. } | ControlFrame::Error(_)
        ) {
            assert_eq!(
                ControlFrame::decode(&extra),
                None,
                "trailing byte after {f:?}"
            );
        }
        let encoded = f.encode();
        assert_eq!(
            ControlFrame::decode(&encoded[..encoded.len() - 1]),
            None,
            "truncated {f:?}"
        );
    }
    assert_eq!(ControlFrame::decode(&[]), None);
    assert_eq!(ControlFrame::decode(&[0x7f]), None, "unknown kind");
    assert_eq!(ControlFrame::decode(&[0x10, 9, 0, 0]), None, "bad edge");
    assert_eq!(
        ControlFrame::decode(&[0x15, 0, 4, 2, 0]),
        None,
        "key down flag must be 0 or 1"
    );
    assert_eq!(
        ControlFrame::decode(&[0x16, 0xff, 0xfe]),
        None,
        "text must be UTF-8"
    );
    assert_eq!(
        ControlAction::from_mac_key_code(18),
        Some(ControlAction::Home)
    );
    assert_eq!(
        ControlAction::from_mac_key_code(33),
        Some(ControlAction::Back)
    );
    assert_eq!(ControlAction::from_mac_key_code(0), None);
}

// ---- Layout (ported from ControlLayoutTests.swift) ------------------------------------------------------------

const MAC: &str = "MAC-1";
const TABLET: Size = Size::new(800.0, 500.0);
const SNAP: f64 = layout::SNAP_DISTANCE;

fn layout() -> ControlLayout {
    ControlLayout::new(
        BTreeMap::from([(MAC.to_owned(), Rect::new(0.0, 0.0, 1440.0, 900.0))]),
        BTreeMap::new(),
    )
}

fn place(l: &mut ControlLayout, id: &str, size: Size, x: f64, y: f64) -> Option<Point> {
    l.place(id, size, Point::new(x, y), SNAP, 0.0)
}

#[test]
fn places_against_edge_and_snaps_within_distance() {
    let mut l = layout();
    assert_eq!(
        place(&mut l, "t", TABLET, 1450.0, 20.0),
        Some(Point::new(1440.0, 0.0))
    );
    let mut l2 = layout();
    assert_eq!(
        place(&mut l2, "u", TABLET, 1450.0, 40.0),
        Some(Point::new(1440.0, 40.0))
    );
    assert!(l.is_placed("t"));
}

#[test]
fn rejects_floating_and_overlapping_spots() {
    let mut l = layout();
    assert_eq!(place(&mut l, "t", TABLET, 2000.0, 0.0), None);
    assert!(!l.is_placed("t"));
    assert_eq!(place(&mut l, "t", TABLET, 600.0, 100.0), None);
}

#[test]
fn devices_attach_to_each_other_and_overlap_is_rejected() {
    let mut l = layout();
    place(&mut l, "a", TABLET, 1440.0, 0.0);
    assert_eq!(
        place(&mut l, "b", Size::new(400.0, 700.0), 2243.0, 100.0).map(|p| p.x),
        Some(2240.0)
    );
    assert_eq!(place(&mut l, "c", TABLET, 1500.0, 100.0), None);
}

#[test]
fn moving_a_device_ignores_its_own_old_placement() {
    let mut l = layout();
    place(&mut l, "a", TABLET, 1440.0, 0.0);
    assert!(place(&mut l, "a", TABLET, 1440.0, 100.0).is_some());
    assert_eq!(l.devices()["a"].y, 100.0);
}

#[test]
fn neighbor_lookup_uses_layout_alignment() {
    let mut l = layout();
    place(&mut l, "t", TABLET, 1440.0, 200.0);
    let mac = ScreenId::Local(MAC.into());
    let t = ScreenId::Device("t".into());
    assert_eq!(
        l.neighbor(&mac, ControlEdge::Right, 300.0, &[]),
        Some(t.clone())
    );
    assert_eq!(l.neighbor(&mac, ControlEdge::Right, 100.0, &[]), None);
    assert_eq!(l.neighbor(&mac, ControlEdge::Left, 300.0, &[]), None);
    assert_eq!(l.neighbor(&t, ControlEdge::Left, 300.0, &[]), Some(mac));
    assert!((l.edge_fraction(&t, ControlEdge::Left, 450.0).unwrap() - 0.5).abs() < 1e-4);
}

#[test]
fn removing_a_middle_device_shelves_the_ones_only_reachable_through_it() {
    let mut l = layout();
    place(&mut l, "a", TABLET, 1440.0, 0.0);
    place(&mut l, "b", TABLET, 2240.0, 0.0);
    let mut removed = l.remove("a");
    removed.sort();
    assert_eq!(removed, ["a", "b"]);
    assert!(l.devices().is_empty());
}

#[test]
fn display_change_shelves_devices_that_no_longer_touch() {
    let mut l = layout();
    place(&mut l, "a", TABLET, 1440.0, 0.0);
    let dropped = l.set_local_displays(BTreeMap::from([(
        MAC.to_owned(),
        Rect::new(0.0, 0.0, 1000.0, 900.0),
    )]));
    assert_eq!(dropped, ["a"]);
}

#[test]
fn resize_keeps_top_left_and_shelves_on_overlap() {
    let mut l = layout();
    place(&mut l, "a", TABLET, 1440.0, 0.0);
    place(&mut l, "b", TABLET, 2240.0, 0.0);
    assert_eq!(l.resize("a", Size::new(500.0, 800.0)), ["b"]);
    assert_eq!(l.devices()["a"].width, 500.0);
    assert_eq!(l.devices()["a"].x, 1440.0);
}

#[test]
fn persistence_round_trip() {
    let mut l = layout();
    place(&mut l, "a", TABLET, 1440.0, 40.0);
    let decoded = ControlLayout::decode_devices(&l.encode_devices()).unwrap();
    assert_eq!(&decoded, l.devices());
    assert!(ControlLayout::decode_devices("{not json").is_none());
}

#[test]
fn capture_distance_attaches_a_near_miss_instead_of_rejecting() {
    let mut l = layout();
    assert_eq!(
        layout().resolve_drop("t", TABLET, Point::new(1590.0, 100.0), SNAP, 0.0),
        None
    );
    assert_eq!(
        l.place("t", TABLET, Point::new(1590.0, 100.0), SNAP, 200.0),
        Some(Point::new(1440.0, 100.0))
    );
    assert_eq!(
        layout().resolve_drop("t", TABLET, Point::new(3000.0, 100.0), SNAP, 200.0),
        None,
        "too far even for capture"
    );
}

#[test]
fn larger_snap_distance_snaps_from_further() {
    let mut l = layout();
    assert_eq!(
        l.place("t", TABLET, Point::new(1480.0, 300.0), 60.0, 0.0),
        Some(Point::new(1440.0, 300.0))
    );
}

#[test]
fn resize_to_portrait_keeps_device_attached_on_each_side() {
    let portrait = Size::new(400.0, 900.0);
    for (x, y, name) in [
        (1440.0, 0.0, "right"),
        (-800.0, 0.0, "left"),
        (100.0, 900.0, "bottom"),
        (100.0, -500.0, "top"),
    ] {
        let mut l = layout();
        assert!(place(&mut l, "p", TABLET, x, y).is_some(), "{name}");
        let shelved = l.resize("p", portrait);
        assert!(shelved.is_empty(), "{name}: shelved {shelved:?}");
        assert!(l.is_placed("p"), "{name}");
        assert_eq!(
            (l.devices()["p"].width, l.devices()["p"].height),
            (400.0, 900.0),
            "{name}"
        );
    }
}

#[test]
fn resize_to_same_size_is_a_no_op() {
    let mut l = layout();
    place(&mut l, "p", TABLET, 1440.0, 0.0);
    let before = l.clone();
    assert!(l.resize("p", TABLET).is_empty());
    assert_eq!(l, before);
}

#[test]
fn default_and_scaled_device_sizes() {
    assert_eq!(
        ControlLayout::default_pixel_size(&DeviceType::AndroidPhone),
        Size::new(1080.0, 2400.0)
    );
    assert_eq!(
        ControlLayout::default_pixel_size(&DeviceType::AndroidTablet),
        Size::new(2000.0, 1200.0)
    );
    assert_eq!(
        ControlLayout::device_size(1500.0, 750.0, layout::DEFAULT_PIXELS_PER_POINT),
        Size::new(1000.0, 500.0)
    );
}

// ---- Pointer router (ported from PointerRouterTests.swift) ----------------------------------------------------

fn router_layout() -> ControlLayout {
    let mut l = layout();
    let size = Size::new(800.0, 500.0);
    place(&mut l, "A", size, 1440.0, 100.0);
    place(&mut l, "B", size, 2240.0, 100.0);
    l
}

fn router(ready: &[&str]) -> PointerRouter {
    let mut r = PointerRouter::new(router_layout(), 30.0);
    r.ready_devices = ready.iter().map(|s| (*s).to_owned()).collect();
    r
}

fn push_right(r: &mut PointerRouter, y: f64, steps: usize) -> Vec<PointerAction> {
    (0..steps)
        .flat_map(|_| r.local_moved(Point::new(5.0, 0.0), Point::new(1439.5, y)))
        .collect()
}

#[test]
fn entering_needs_a_sustained_push() {
    let mut r = router(&["A", "B"]);
    assert!(
        r.local_moved(Point::new(5.0, 0.0), Point::new(1439.5, 300.0))
            .is_empty(),
        "a touch is not enough"
    );
    assert_eq!(*r.state(), PointerState::Local);
    r.local_moved(Point::new(-5.0, 0.0), Point::new(1300.0, 300.0));
    for _ in 0..5 {
        r.local_moved(Point::new(5.0, 0.0), Point::new(1439.5, 300.0));
    }
    assert_eq!(
        *r.state(),
        PointerState::Local,
        "25 points total, below the 30 threshold"
    );
    let actions = push_right(&mut r, 300.0, 10);
    assert_eq!(actions.len(), 1);
    let PointerAction::Enter {
        device_id,
        edge,
        fraction,
    } = &actions[0]
    else {
        panic!("{actions:?}")
    };
    assert_eq!((device_id.as_str(), *edge), ("A", ControlEdge::Left));
    assert!(
        (fraction - (300.0 - 100.0) / 500.0).abs() < 0.001,
        "entry is aligned with where the cursor left"
    );
    assert_eq!(r.state().remote_device_id(), Some("A"));
}

#[test]
fn no_crossing_where_nothing_is_placed_or_the_device_is_not_ready() {
    let mut r = router(&["A", "B"]);
    assert!(push_right(&mut r, 50.0, 10).is_empty(), "above the tablet");
    let mut not_ready = router(&[]);
    assert!(push_right(&mut not_ready, 300.0, 10).is_empty());
    let mut left = router(&["A", "B"]);
    for _ in 0..20 {
        assert!(left
            .local_moved(Point::new(-5.0, 0.0), Point::new(0.5, 300.0))
            .is_empty());
    }
}

#[test]
fn moves_are_forwarded_and_clamped_inside_the_rectangle() {
    let mut r = router(&["A", "B"]);
    push_right(&mut r, 300.0, 10);
    assert_eq!(
        r.remote_moved(Point::new(10.0, 20.0)),
        [PointerAction::Move {
            device_id: "A".into(),
            dx: 10.0,
            dy: 20.0
        }]
    );
    let wall = r.remote_moved(Point::new(0.0, -1000.0));
    assert_eq!(
        wall,
        [PointerAction::Move {
            device_id: "A".into(),
            dx: 0.0,
            dy: -1000.0
        }]
    );
    let PointerState::Remote { position, .. } = r.state() else {
        panic!()
    };
    assert!((position.y - 100.0).abs() < 0.001);
}

#[test]
fn handover_a_to_b_then_back_to_the_local_display() {
    let mut r = router(&["A", "B"]);
    push_right(&mut r, 300.0, 10);
    let to_b = r.remote_moved(Point::new(900.0, 0.0));
    assert_eq!(to_b.len(), 3);
    assert_eq!(
        to_b[1],
        PointerAction::Leave {
            device_id: "A".into()
        }
    );
    let PointerAction::Enter {
        device_id, edge, ..
    } = &to_b[2]
    else {
        panic!("{to_b:?}")
    };
    assert_eq!((device_id.as_str(), *edge), ("B", ControlEdge::Left));
    assert_eq!(r.state().remote_device_id(), Some("B"));

    let to_a = r.remote_moved(Point::new(-900.0, 0.0));
    assert_eq!(
        to_a[1],
        PointerAction::Leave {
            device_id: "B".into()
        }
    );
    assert_eq!(r.state().remote_device_id(), Some("A"));
    let home = r.remote_moved(Point::new(-900.0, 0.0));
    assert_eq!(
        home[1],
        PointerAction::Leave {
            device_id: "A".into()
        }
    );
    let Some(PointerAction::WarpCursor(p)) = home.last() else {
        panic!("{home:?}")
    };
    assert!(
        (p.x - 1438.0).abs() < 0.01,
        "lands just inside the right edge"
    );
    assert_eq!(*r.state(), PointerState::Local);
}

#[test]
fn handover_to_an_unavailable_device_is_a_wall() {
    let mut r = router(&["A"]);
    push_right(&mut r, 300.0, 10);
    assert_eq!(
        r.remote_moved(Point::new(900.0, 0.0)),
        [PointerAction::Move {
            device_id: "A".into(),
            dx: 900.0,
            dy: 0.0
        }]
    );
    assert_eq!(r.state().remote_device_id(), Some("A"));
}

#[test]
fn losing_the_session_returns_without_talking_to_the_device() {
    let mut r = router(&["A", "B"]);
    push_right(&mut r, 300.0, 10);
    let actions = r.device_became_unavailable("A");
    assert_eq!(actions.len(), 1);
    assert!(matches!(actions[0], PointerAction::WarpCursor(_)));
    assert_eq!(*r.state(), PointerState::Local);
    assert!(r.device_became_unavailable("B").is_empty());
}

#[test]
fn force_return_and_shelving_the_active_device() {
    let mut r = router(&["A", "B"]);
    push_right(&mut r, 300.0, 10);
    assert_eq!(
        r.force_return(Some(Point::new(700.0, 400.0)), true),
        [
            PointerAction::Leave {
                device_id: "A".into()
            },
            PointerAction::WarpCursor(Point::new(700.0, 400.0))
        ]
    );
    assert!(r.force_return(None, true).is_empty(), "idempotent");

    let mut r2 = router(&["A", "B"]);
    push_right(&mut r2, 300.0, 10);
    let mut shelved = router_layout();
    shelved.remove("A");
    let after = r2.set_layout(shelved);
    assert_eq!(*r2.state(), PointerState::Local);
    assert!(after.contains(&PointerAction::Leave {
        device_id: "A".into()
    }));
}

#[test]
fn vertical_crossing_and_two_displays() {
    let mut l = ControlLayout::new(
        BTreeMap::from([
            ("M1".to_owned(), Rect::new(0.0, 0.0, 1000.0, 800.0)),
            ("M2".to_owned(), Rect::new(1000.0, 0.0, 1000.0, 800.0)),
        ]),
        BTreeMap::new(),
    );
    place(&mut l, "P", Size::new(400.0, 600.0), 600.0, 800.0);
    let mut r = PointerRouter::new(l, 10.0);
    r.ready_devices.insert("P".into());
    assert!(
        r.local_moved(Point::new(5.0, 0.0), Point::new(999.5, 400.0))
            .is_empty(),
        "between displays the cursor passes normally"
    );
    let actions: Vec<_> = (0..5)
        .flat_map(|_| r.local_moved(Point::new(0.0, 5.0), Point::new(700.0, 799.5)))
        .collect();
    let Some(PointerAction::Enter {
        device_id, edge, ..
    }) = actions.first()
    else {
        panic!("{actions:?}")
    };
    assert_eq!((device_id.as_str(), *edge), ("P", ControlEdge::Top));
}

#[test]
fn pointer_gain_makes_the_model_track_a_device_that_accelerates() {
    let mut l = ControlLayout::new(
        BTreeMap::from([("M".to_owned(), Rect::new(0.0, 0.0, 1000.0, 800.0))]),
        BTreeMap::new(),
    );
    place(&mut l, "A", Size::new(600.0, 400.0), 1000.0, 100.0);
    let mut r = PointerRouter::new(l, 10.0);
    r.ready_devices.insert("A".into());
    r.pointer_gain = 1.5;
    r.local_moved(Point::new(20.0, 0.0), Point::new(999.5, 300.0));
    let PointerState::Remote { position: p0, .. } = r.state().clone() else {
        panic!("did not enter")
    };
    let actions = r.remote_moved(Point::new(100.0, 0.0));
    assert!(
        actions.contains(&PointerAction::Move {
            device_id: "A".into(),
            dx: 100.0,
            dy: 0.0
        }),
        "sent delta is not scaled"
    );
    let PointerState::Remote { position: p1, .. } = r.state().clone() else {
        panic!()
    };
    assert!((p1.x - p0.x - 150.0).abs() < 0.001);
}

#[test]
fn closed_loop_correction_only_matters_near_an_exit_edge() {
    let mut r = router(&["A", "B"]);
    push_right(&mut r, 300.0, 10);
    // Just entered A at its left edge, which leads back to the local display.
    assert!(r.is_near_exit_edge(20.0));
    r.remote_moved(Point::new(300.0, 0.0));
    assert!(!r.is_near_exit_edge(20.0), "middle of A");
    let before = r.state().clone();
    r.shift_remote_position(5.0, 0.0);
    let (PointerState::Remote { position: a, .. }, PointerState::Remote { position: b, .. }) =
        (before, r.state().clone())
    else {
        panic!()
    };
    assert!((b.x - a.x - 5.0).abs() < 1e-9);
    r.shift_remote_position(1.0e6, 0.0);
    let PointerState::Remote { position, .. } = r.state() else {
        panic!()
    };
    assert!(position.x <= 2240.0 + 1e-9, "stays inside the device");
}
