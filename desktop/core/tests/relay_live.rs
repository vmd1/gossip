//! Optional integration test against a real relay (`relay/`). Ignored by default; run it with
//! `GOSSIP_RELAY_URL=ws://127.0.0.1:8099 cargo test -p gossip-core --test relay_live -- --ignored --nocapture`
//! against a relay started with the matching `RELAY_ORIGIN` (see desktop/README.md). Two cores that already trust
//! each other join one topic through a plain-`ws://` relay, handshake over it and exchange a message.

use std::collections::VecDeque;
use std::io::ErrorKind;
use std::net::TcpStream;
use std::time::{Duration, Instant};

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use ed25519_dalek::SigningKey;
use gossip_core::crypto::noise::StaticKeypair;
use gossip_core::engine::*;
use gossip_core::env::SystemEnv;
use gossip_core::features::FeatureSettings;
use gossip_core::trust::{TrustSnapshot, TrustedDevice};
use gossip_core::wire::handshake::DeviceType;
use gossip_core::wire::uuid;
use tungstenite::{client::client, Message, WebSocket};

fn identity(n: u8) -> Identity {
    Identity {
        device_id: uuid::format(&[n; 16]),
        device_name: format!("Live {n}"),
        device_type: DeviceType::Mac,
        noise: StaticKeypair::from_secret_bytes([n; 32]),
        signing: SigningKey::from_bytes(&[n.wrapping_add(100); 32]),
    }
}

fn trusting(other: u8) -> TrustSnapshot {
    let o = identity(other);
    TrustSnapshot {
        devices: vec![TrustedDevice {
            device_id: o.device_id.clone(),
            public_key: B64.encode(o.noise.public_bytes()),
            device_name: o.device_name.clone(),
            device_type: "mac".into(),
            added_at: 0,
            signing_public_key: Some(B64.encode(o.signing.verifying_key().to_bytes())),
            beacon_key: None,
        }],
        revoked: Default::default(),
    }
}

struct Peer {
    core: Core<SystemEnv>,
    ws: Option<WebSocket<TcpStream>>,
    delivered: Vec<String>,
}

fn host_port(url: &str) -> String {
    url.trim_start_matches("ws://")
        .split('/')
        .next()
        .unwrap()
        .to_owned()
}

fn run(peers: &mut [Peer], node: usize, actions: Vec<Action>) {
    let mut q: VecDeque<Action> = actions.into();
    while let Some(a) = q.pop_front() {
        let p = &mut peers[node];
        match a {
            Action::RelayConnect { url } => {
                match TcpStream::connect(host_port(&url))
                    .map_err(|e| e.to_string())
                    .and_then(|s| {
                        s.set_read_timeout(Some(Duration::from_millis(20))).ok();
                        client(url.as_str(), s).map_err(|e| e.to_string())
                    }) {
                    Ok((ws, _)) => {
                        p.ws = Some(ws);
                        q.extend(p.core.relay_socket_opened());
                    }
                    Err(e) => {
                        eprintln!("connect failed: {e}");
                        q.extend(p.core.relay_socket_closed());
                    }
                }
            }
            Action::RelaySendText { text } => {
                if let Some(ws) = &mut p.ws {
                    let _ = ws.send(Message::Text(text));
                }
            }
            Action::RelaySendBinary { bytes } => {
                if let Some(ws) = &mut p.ws {
                    let _ = ws.send(Message::Binary(bytes));
                }
            }
            Action::RelayClose => p.ws = None,
            Action::Event(Event::Deliver { envelope, .. })
                if !envelope.kind.starts_with("presence.") =>
            {
                p.delivered.push(envelope.kind.clone());
            }
            Action::Event(Event::RelayError { code }) => eprintln!("relay error: {code}"),
            Action::Event(_) => {}
            Action::Send { .. } | Action::Close { .. } => unreachable!("no LAN in this test"),
        }
    }
}

fn poll(peers: &mut [Peer], node: usize) {
    let Some(ws) = &mut peers[node].ws else {
        return;
    };
    let acts = match ws.read() {
        Ok(Message::Text(t)) => peers[node].core.relay_text_received(&t),
        Ok(Message::Binary(b)) => peers[node].core.relay_binary_received(&b),
        Ok(_) => Vec::new(),
        Err(tungstenite::Error::Io(e))
            if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) =>
        {
            Vec::new()
        }
        Err(e) => {
            eprintln!("socket {node} closed: {e}");
            peers[node].ws = None;
            peers[node].core.relay_socket_closed()
        }
    };
    run(peers, node, acts);
}

#[test]
#[ignore = "needs a running relay; set GOSSIP_RELAY_URL (see desktop/README.md)"]
fn two_cores_meet_through_a_real_relay() {
    let Ok(origin) = std::env::var("GOSSIP_RELAY_URL") else {
        eprintln!("GOSSIP_RELAY_URL not set; nothing to do");
        return;
    };
    let mut peers: Vec<Peer> = [(1u8, 2u8), (2, 1)]
        .iter()
        .map(|(me, other)| Peer {
            core: Core::new(
                SystemEnv,
                identity(*me),
                trusting(*other),
                FeatureSettings::all_enabled(),
            ),
            ws: None,
            delivered: Vec::new(),
        })
        .collect();
    // A fresh topic per run so a previous run's relay state cannot interfere.
    let mut secret = [0u8; 32];
    getrandom_fill(&mut secret);
    for i in 0..2 {
        peers[i].core.set_lan_grace_ms(0);
        let acts = peers[i].core.set_topic(secret, 1);
        run(&mut peers, i, acts);
        let acts = peers[i].core.relay_configure(true, &origin);
        run(&mut peers, i, acts);
    }

    let a_id = uuid::format(&[1; 16]);
    let b_id = uuid::format(&[2; 16]);
    let deadline = Instant::now() + Duration::from_secs(40);
    let mut last_tick = Instant::now();
    let mut sent = false;
    while Instant::now() < deadline {
        for i in 0..2 {
            poll(&mut peers, i);
        }
        if last_tick.elapsed() >= Duration::from_millis(500) {
            last_tick = Instant::now();
            for i in 0..2 {
                let acts = peers[i].core.tick();
                run(&mut peers, i, acts);
            }
        }
        if !sent && peers[0].core.is_relayed(&b_id) && peers[1].core.is_relayed(&a_id) {
            sent = true;
            let e = peers[0].core.new_envelope("clipboard.update").to(&b_id);
            let acts = peers[0].core.send(e).unwrap();
            run(&mut peers, 0, acts);
        }
        if peers[1].delivered.iter().any(|k| k == "clipboard.update") {
            return;
        }
    }
    panic!(
        "no relayed delivery within 40 s (statuses: {:?}/{:?})",
        peers[0].core.relay_status(),
        peers[1].core.relay_status()
    );
}

fn getrandom_fill(buf: &mut [u8]) {
    use gossip_core::env::Env;
    SystemEnv.random_bytes(buf);
}
