//! Pure feature logic: DND, battery, ring, clipboard, media, notification replies, hotspot, toggles and limits.

use gossip_core::features::battery::{self, Battery, BatteryState};
use gossip_core::features::clipboard::{self, ClipboardGuard};
use gossip_core::features::dnd::{self, Dnd};
use gossip_core::features::hotspot::HotspotStates;
use gossip_core::features::media::{self, CommandGuard, MediaController};
use gossip_core::features::notifications::{self, ReplyGuard};
use gossip_core::features::ring::{self, Ring};
use gossip_core::features::{Feature, FeatureSettings, Outgoing};
use gossip_core::limits::{
    InboundRateLimiter, PendingFrameQueue, RecentIds, PENDING_BYTE_LIMIT, PENDING_FRAME_LIMIT,
};
use gossip_core::trust::fingerprint_matches;
use serde_json::{json, Map, Value};

fn obj(v: Value) -> Map<String, Value> {
    let Value::Object(m) = v else {
        panic!("not an object")
    };
    m
}

// ---- DND --------------------------------------------------------------------------------------------------------

fn sends(effects: &[dnd::Effect]) -> Vec<(bool, bool)> {
    effects
        .iter()
        .filter_map(|e| match e {
            dnd::Effect::Send(o) => Some((
                o.payload["enabled"].as_bool().unwrap(),
                o.payload["isInitialSync"].as_bool().unwrap(),
            )),
            _ => None,
        })
        .collect()
}

fn applied(effects: &[dnd::Effect]) -> Option<bool> {
    effects.iter().find_map(|e| match e {
        dnd::Effect::ApplyLocal { enabled } => Some(*enabled),
        _ => None,
    })
}

#[test]
fn dnd_local_changes_are_reported_once_and_echoes_suppressed() {
    let mut d = Dnd::new(None);
    assert_eq!(sends(&d.local_changed("me", true, 0)), [(true, false)]);
    assert!(
        d.local_changed("me", true, 10).is_empty(),
        "same state again"
    );
    assert_eq!(sends(&d.local_changed("me", false, 20)), [(false, false)]);
}

#[test]
fn dnd_peer_state_applies_then_cooldown_swallows_the_resulting_local_trigger() {
    let mut d = Dnd::new(Some(false));
    let fx = d.on_update(
        &obj(json!({"enabled": true, "isInitialSync": false})),
        1_000,
    );
    assert_eq!(applied(&fx), Some(true));
    // The OS fires its own "Focus on" trigger for the change we just made: swallowed by the cooldown.
    assert!(d.local_changed("me", true, 1_500).is_empty());
    assert!(
        d.local_changed("me", false, 1_000 + dnd::RECONCILE_COOLDOWN_MS - 1)
            .is_empty(),
        "still inside the cooldown"
    );
    assert!(
        !d.local_changed("me", false, 1_000 + dnd::RECONCILE_COOLDOWN_MS)
            .is_empty(),
        "a real change afterwards is reported"
    );
    // A peer update that agrees with what we believe is an echo.
    let mut e = Dnd::new(Some(true));
    assert!(e.on_update(&obj(json!({"enabled": true})), 0).is_empty());
    // dnd.set always applies.
    assert_eq!(
        applied(&e.on_set(&obj(json!({"enabled": false})), 5)),
        Some(false)
    );
    assert!(e.on_set(&obj(json!({"nope": 1})), 6).is_empty());
}

#[test]
fn dnd_initial_sync_is_an_or_merge_that_converges_from_either_order() {
    for (a0, b0) in [(false, false), (false, true), (true, false), (true, true)] {
        let (mut a, mut b) = (Dnd::new(Some(a0)), Dnd::new(Some(b0)));
        let (ra, rb) = (a.initial_sync("a"), b.initial_sync("b"));
        let pa = |fx: &[dnd::Effect]| match fx.iter().find_map(|e| {
            if let dnd::Effect::Send(o) = e {
                Some(o.payload.clone())
            } else {
                None
            }
        }) {
            Some(p) => p,
            None => panic!(),
        };
        a.on_update(&pa(&rb), 0);
        b.on_update(&pa(&ra), 0);
        assert_eq!(a.expected(), Some(a0 || b0));
        assert_eq!(
            b.expected(),
            Some(a0 || b0),
            "both converge to OR for ({a0}, {b0})"
        );
    }
    // Never observed anything: assumed off.
    let mut fresh = Dnd::new(None);
    assert_eq!(sends(&fresh.initial_sync("me")), [(false, true)]);
    assert_eq!(fresh.expected(), Some(false));
}

// ---- Battery ----------------------------------------------------------------------------------------------------

#[test]
fn low_battery_alerts_once_per_episode_and_tracks_last_write() {
    let mut b = Battery::new();
    let upd = |b: &mut Battery, s: &str, level: u64, charging: bool| {
        b.on_update(s, &obj(json!({"level": level, "isCharging": charging})))
    };
    let alerts = |fx: &[battery::Effect]| {
        fx.iter()
            .filter(|e| matches!(e, battery::Effect::LowBattery { .. }))
            .count()
    };
    let mut total = 0;
    for l in [19, 19, 18] {
        total += alerts(&upd(&mut b, "a", l, false));
    }
    assert_eq!(total, 1);
    assert_eq!(
        b.state_of("a"),
        Some(BatteryState {
            level: 18,
            is_charging: false
        })
    );
    total += alerts(&upd(&mut b, "a", 25, false)) + alerts(&upd(&mut b, "a", 15, false));
    assert_eq!(total, 1, "not re-armed below the re-arm level");
    total += alerts(&upd(&mut b, "a", 40, false)) + alerts(&upd(&mut b, "a", 20, false));
    assert_eq!(total, 2, "re-armed after climbing above it");
    total += alerts(&upd(&mut b, "b", 5, true));
    assert_eq!(total, 2, "charging never alerts");
    assert!(
        b.on_update("a", &obj(json!({"level": 5}))).is_empty(),
        "malformed update ignored"
    );
    assert_eq!(battery::LOW_THRESHOLD, 20);
}

#[test]
fn battery_reports_on_change_and_always_on_resync() {
    let mut b = Battery::new();
    let r = Some(BatteryState {
        level: 80,
        is_charging: false,
    });
    assert!(b.report_if_changed("me", r).is_some());
    assert!(b.report_if_changed("me", r).is_none(), "unchanged");
    assert!(b.report_always("me", r).is_some(), "resync always sends");
    assert!(
        b.report_if_changed("me", None).is_none(),
        "no battery on this device"
    );
    let Some(battery::Effect::Send(o)) = b.report_always(
        "me",
        Some(BatteryState {
            level: 7,
            is_charging: true,
        }),
    ) else {
        panic!()
    };
    assert_eq!((o.kind, o.recipient.is_none()), ("battery.update", true));
    assert_eq!(o.payload["level"], 7);
}

// ---- Ring -------------------------------------------------------------------------------------------------------

fn rp(action: &str, id: &str) -> Map<String, Value> {
    Ring::ring_payload(action, id)
}

fn ring_count(fx: &[ring::Effect], which: ring::Effect) -> usize {
    fx.iter().filter(|e| **e == which).count()
}

#[test]
fn ring_start_stop_and_duplicates_are_idempotent() {
    let mut r = Ring::new();
    let (starts, stops) = (std::cell::Cell::new(0), std::cell::Cell::new(0));
    let feed = |r: &mut Ring, action: &str, id: &str, t: i64| {
        let fx = r.on_ring("peer", &rp(action, id), t);
        starts.set(starts.get() + ring_count(&fx, ring::Effect::StartRinger));
        stops.set(stops.get() + ring_count(&fx, ring::Effect::StopRinger));
    };
    feed(&mut r, "stop", "x", 0);
    assert_eq!(stops.get(), 0);
    feed(&mut r, "start", "a", 0);
    feed(&mut r, "start", "a", 0);
    feed(&mut r, "start", "b", 0);
    assert!(r.is_ringing());
    assert_eq!(starts.get(), 1);
    feed(&mut r, "stop", "c", 1);
    assert!(!r.is_ringing());
    assert_eq!(stops.get(), 1);
    feed(&mut r, "start", "a", 2); // late redelivery of an already-handled start
    assert!(!r.is_ringing());
    assert_eq!(starts.get(), 1);
    feed(&mut r, "start", "d", 3);
    assert_eq!(starts.get(), 2);
    assert!(r.on_ring("p", &obj(json!({})), 0).is_empty());
    assert!(
        r.on_ring("p", &obj(json!({"action": "start"})), 0)
            .is_empty(),
        "no ringId"
    );
}

#[test]
fn ring_auto_stops_and_reports_state_to_the_requester() {
    let mut r = Ring::new();
    let states = |fx: &[ring::Effect]| -> Vec<(String, bool)> {
        fx.iter()
            .filter_map(|e| match e {
                ring::Effect::Send(o) if o.kind == "device.ring_state" => Some((
                    o.recipient.clone().unwrap(),
                    o.payload["ringing"].as_bool().unwrap(),
                )),
                _ => None,
            })
            .collect()
    };
    assert_eq!(
        states(&r.on_ring("peer", &rp("start", "a"), 0)),
        [("peer".to_owned(), true)]
    );
    assert!(r.tick(ring::AUTO_STOP_MS - 1).is_empty());
    assert_eq!(
        states(&r.tick(ring::AUTO_STOP_MS)),
        [("peer".to_owned(), false)]
    );
    assert!(!r.is_ringing());
    // Local stop reports too; a no-op stop sends nothing.
    r.on_ring("peer", &rp("start", "b"), 100_000);
    assert_eq!(states(&r.stop_ringing()), [("peer".to_owned(), false)]);
    assert!(r.stop_ringing().is_empty());
}

#[test]
fn ring_toggle_tracks_peer_state_and_lost_reports_expire() {
    let mut r = Ring::new();
    let fx = r.toggle("phone", "id1", 0);
    assert_eq!(r.ringing_peers(), ["phone"]);
    let ring::Effect::Send(o) = &fx[0] else {
        panic!()
    };
    assert_eq!(
        (o.payload["action"].as_str(), o.recipient.as_deref()),
        (Some("start"), Some("phone"))
    );
    let fx = r.toggle("phone", "id2", 1);
    assert!(r.ringing_peers().is_empty());
    let ring::Effect::Send(o) = &fx[0] else {
        panic!()
    };
    assert_eq!(o.payload["action"], "stop");

    r.on_ring_state("phone", &obj(json!({"ringing": true})), 0);
    r.on_ring_state("phone", &obj(json!({"ringing": true})), 0);
    assert_eq!(r.ringing_peers(), ["phone"]);
    r.on_ring_state("phone", &obj(json!({"ringing": false})), 0);
    assert!(r.ringing_peers().is_empty());
    r.on_ring_state("tablet", &obj(json!({"ringing": true})), 0);
    assert!(r.tick(ring::PEER_EXPIRY_MS - 1).is_empty());
    assert!(
        !r.tick(ring::PEER_EXPIRY_MS).is_empty(),
        "the lost 'stopped' report expires"
    );
    assert!(r.ringing_peers().is_empty());
}

// ---- Clipboard --------------------------------------------------------------------------------------------------

fn png(w: u32, h: u32) -> Vec<u8> {
    let mut v = vec![0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13];
    v.extend_from_slice(b"IHDR");
    v.extend_from_slice(&w.to_be_bytes());
    v.extend_from_slice(&h.to_be_bytes());
    v.extend_from_slice(&[8, 6, 0, 0, 0, 0, 0, 0, 0]);
    v
}

#[test]
fn clipboard_loop_guard_blocks_echo_and_resync_repeats() {
    let mut g = ClipboardGuard::new();
    assert!(
        g.outgoing_text("me", "hello", false).is_some(),
        "a genuine local copy"
    );
    assert!(
        g.outgoing_text("me", "hello", false).is_none(),
        "the periodic resync must not rebroadcast it forever"
    );
    assert_eq!(
        g.incoming_text(&ClipboardGuard::text_payload("peer", "from-peer")),
        Some("from-peer".to_owned())
    );
    assert!(
        g.outgoing_text("me", "from-peer", false).is_none(),
        "our own write echoed back by the next poll"
    );
    assert!(g.outgoing_text("me", "new local", false).is_some());
    assert!(
        g.outgoing_text("me", "hello", false).is_some(),
        "an old value copied again after something else is a real copy"
    );
}

#[test]
fn clipboard_policy_limits() {
    let mut g = ClipboardGuard::new();
    assert!(
        g.outgoing_text("me", "secret", true).is_none(),
        "sensitive content is never sent"
    );
    assert!(clipboard::is_sensitive(&[
        "public.utf8-plain-text",
        "org.nspasteboard.ConcealedType"
    ]));
    assert!(!clipboard::is_sensitive(&["public.utf8-plain-text"]));
    assert!(g
        .outgoing_text("me", &"x".repeat(clipboard::MAX_TEXT_BYTES + 1), false)
        .is_none());
    assert!(g
        .outgoing_text("me", &"x".repeat(clipboard::MAX_TEXT_BYTES), false)
        .is_some());
    assert!(g
        .incoming_text(&obj(
            json!({"text": "x".repeat(clipboard::MAX_TEXT_BYTES + 1)})
        ))
        .is_none());
    assert!(g.incoming_text(&obj(json!({"nope": 1}))).is_none());

    let good = png(1000, 1000);
    assert_eq!(clipboard::png_dimensions(&good), Some((1000, 1000)));
    assert!(clipboard::is_reasonable_png(&good));
    assert!(
        !clipboard::is_reasonable_png(&png(10_000, 10_000)),
        "decompression bomb"
    );
    assert!(!clipboard::is_reasonable_png(&png(0, 5)));
    assert!(!clipboard::is_reasonable_png(
        b"GIF89a not a png at all......."
    ));
    assert!(g.outgoing_image("me", &good, false).is_some());
    assert!(
        g.outgoing_image("me", &good, false).is_none(),
        "image resync suppressed"
    );
    assert!(!g.incoming_image(&obj(json!({"kind": "text"})), &good));
    assert!(!g.incoming_image(&obj(json!({"kind": "image"})), b""));
    assert!(g.incoming_image(&obj(json!({"kind": "image"})), &good));
    assert!(!clipboard::image_bytes_allowed(
        clipboard::MAX_IMAGE_BYTES + 1
    ));
}

// ---- Media ------------------------------------------------------------------------------------------------------

#[test]
fn media_commands_are_acted_on_once() {
    let mut guard = CommandGuard::new();
    let p = media::command_payload(media::Action::Next, None, "cmd-1");
    assert_eq!(guard.accept(&p), Some((media::Action::Next, None)));
    assert_eq!(
        guard.accept(&p),
        None,
        "duplicate delivery must not skip twice"
    );
    let seek = media::command_payload(media::Action::Play, Some(42_000), "cmd-2");
    assert_eq!(
        guard.accept(&seek),
        Some((media::Action::Play, Some(42_000)))
    );
    assert_eq!(
        guard.accept(&obj(json!({"action": "explode", "commandId": "x"}))),
        None
    );
    assert_eq!(guard.accept(&obj(json!({"commandId": "y"}))), None);
}

#[test]
fn media_controller_tracks_devices_and_targets_the_selected_one() {
    let mut c = MediaController::new();
    assert!(
        c.command(media::Action::Play, None, "x").is_none(),
        "nothing reporting yet"
    );
    c.on_now_playing("phone", &obj(json!({"title": "A", "artist": "B", "isPlaying": true, "positionMs": 10, "durationMs": 99, "packageName": "p"})));
    c.on_now_playing("tablet", &obj(json!({"title": "C", "artist": "D"})));
    c.on_now_playing("bad", &obj(json!({"title": "no artist"})));
    assert_eq!(
        c.effective_device(),
        Some("tablet"),
        "most recent reporter by default"
    );
    c.select(Some("phone".into()));
    assert_eq!(c.now_playing().unwrap().title, "A");
    let Outgoing {
        kind,
        recipient,
        payload,
    } = c.command(media::Action::Pause, None, "id").unwrap();
    assert_eq!(
        (kind, recipient.as_deref(), payload["commandId"].as_str()),
        ("media.command", Some("phone"), Some("id"))
    );
    c.select(Some("gone".into()));
    assert_eq!(
        c.effective_device(),
        Some("tablet"),
        "a selection that stopped reporting falls back"
    );
    assert_eq!(
        media::parse_now_playing(&obj(
            json!({"title": "t", "artist": "a", "artBase64": "AQID"})
        ))
        .unwrap()
        .artwork,
        Some(vec![1, 2, 3])
    );
}

#[test]
fn notification_replies_are_sent_once_per_attempt() {
    let mut g = ReplyGuard::new();
    let p = notifications::reply_payload("n1", "on my way", "attempt-1");
    assert_eq!(
        g.accept(&p),
        Some(("n1".to_owned(), "on my way".to_owned()))
    );
    assert_eq!(
        g.accept(&p),
        None,
        "a duplicate must not message the other person twice"
    );
    let second = notifications::reply_payload("n1", "see you", "attempt-2");
    assert!(
        g.accept(&second).is_some(),
        "same notification id, distinct reply"
    );
    assert_eq!(
        g.accept(&obj(json!({"id": "n", "text": "t"}))),
        None,
        "attemptId is required"
    );
}

#[test]
fn hotspot_state_is_last_write_wins_and_idempotent() {
    let mut h = HotspotStates::new();
    assert!(h.on_update("phone", &obj(json!({"enabled": true, "ssid": "net"}))));
    assert!(
        !h.on_update("phone", &obj(json!({"enabled": true, "ssid": "net"}))),
        "unchanged is a no-op"
    );
    assert!(h.on_update("phone", &obj(json!({"enabled": false}))));
    assert_eq!(h.state_of("phone").unwrap().ssid, None);
    assert!(!h.on_update("phone", &obj(json!({"ssid": "x"}))));
}

// ---- Toggles and limits -----------------------------------------------------------------------------------------

#[test]
fn feature_toggles_gate_only_their_own_message_types() {
    let mut s = FeatureSettings::all_enabled();
    assert!(s.is_message_allowed("clipboard.update"));
    s.set_enabled(Feature::Clipboard, false);
    s.set_enabled(Feature::FindDevice, false);
    assert!(!s.is_message_allowed("clipboard.update"));
    assert!(!s.is_message_allowed("device.ring_state"));
    assert!(s.is_message_allowed("dnd.update"));
    for infra in [
        "handshake.hello",
        "presence.heartbeat",
        "trust.roster_update",
        "screen.start",
        "display.info",
        "ble.beacon_key",
    ] {
        assert!(
            s.is_message_allowed(infra),
            "{infra} is never owned by a feature"
        );
    }
    assert_eq!(s.disabled_keys(), ["clipboard", "findDevice"]);
    assert_eq!(Feature::from_key("lockOnLeave"), Some(Feature::LockOnLeave));
    assert_eq!(
        Feature::for_message_type("control.session_start"),
        Some(Feature::UniversalControl)
    );
    s.set_enabled(Feature::Clipboard, true);
    assert!(s.is_message_allowed("clipboard.update"));
}

#[test]
fn inbound_rate_limiter_allows_a_burst_up_to_the_limit_per_second() {
    let mut l = InboundRateLimiter::new(5);
    assert!((0..5).all(|_| l.allow(1_000)));
    assert!(!l.allow(1_500), "over budget inside the window");
    assert!(l.allow(2_000), "a new window");
    let mut d = InboundRateLimiter::default();
    assert!((0..400).all(|i| d.allow(i / 10)));
    assert!(!d.allow(50));
}

#[test]
fn pending_frame_queue_is_bounded_and_drains_in_order() {
    let mut q = PendingFrameQueue::default();
    for i in 0..PENDING_FRAME_LIMIT {
        assert!(q.enqueue(vec![i as u8]));
    }
    assert!(!q.enqueue(vec![0]), "full: the connection should be closed");
    let drained = q.drain();
    assert_eq!(drained.len(), PENDING_FRAME_LIMIT);
    assert_eq!(drained[3], [3]);
    assert!(q.is_empty());
}

#[test]
fn pending_frame_queue_is_also_bounded_by_total_bytes() {
    let mut q = PendingFrameQueue::default();
    let big = vec![0u8; PENDING_BYTE_LIMIT / 2];
    assert!(q.enqueue(big.clone()) && q.enqueue(big.clone()));
    assert!(
        !q.enqueue(vec![0]),
        "the byte budget is spent, even though only two frames are held"
    );
    assert_eq!(q.drain().len(), 2);
    assert!(q.enqueue(big), "draining frees the budget");
    assert!(
        !PendingFrameQueue::default().enqueue(vec![0; PENDING_BYTE_LIMIT + 1]),
        "one oversized frame is refused"
    );
}

#[test]
fn recent_ids_remember_a_bounded_window() {
    let mut r = RecentIds::new(3);
    assert!(r.first_time("a") && r.first_time("b") && r.first_time("c"));
    assert!(!r.first_time("a"));
    assert!(r.first_time("d"), "evicts the oldest");
    assert!(r.first_time("a"), "a was evicted, so it is new again");
}

#[test]
fn ble_fingerprints_accept_both_platform_formats() {
    use base64::{engine::general_purpose::STANDARD as B64, Engine};
    use sha2::{Digest, Sha256};
    let key = [7u8; 32];
    let d = Sha256::digest(key);
    let mac = B64.encode(&d[..8]);
    let android: String = B64
        .encode(d)
        .trim_end_matches('=')
        .chars()
        .take(16)
        .collect();
    assert!(fingerprint_matches(&mac, &key) && fingerprint_matches(&android, &key));
    assert!(!fingerprint_matches("AAAAAAAAAAA=", &key));
}
