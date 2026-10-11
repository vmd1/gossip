//! The engine side of central state synchronisation (see `crate::state_sync` for the model).

use super::*;
use crate::state_sync::{
    self as ss, Applied, SlotValue, StateError, KIND_DIGEST, KIND_REQUEST, KIND_UPDATE,
};

/// The reconcile task name for the periodic digest. Handled inside the engine; never surfaces as a `ReconcileDue`.
pub(super) const STATE_TASK: &str = "state.digest";

impl<E: Env> Core<E> {
    /// Sets (or, with `None`, clears) one of this device's state slots and tells every other device. Calling it with the
    /// value the slot already holds does nothing, so a feature can simply report its current state whenever it likes.
    pub fn set_state(&mut self, slot: &str, value: Option<Value>) -> Result<Out, StateError> {
        let now = self.env.now_ms();
        let changed = self.local_state.set(slot, value, now)?;
        let mut out = Vec::new();
        if changed.is_some() && self.features.is_message_allowed(slot) {
            if let Some(v) = self.local_state.get(slot).cloned() {
                self.send_state_update(None, vec![(slot.to_owned(), v)], &mut out);
            }
        }
        Ok(out)
    }

    /// A slot's current value: this device's own, or the latest received from `device_id`. `None` when unset or cleared.
    pub fn state(&self, device_id: &str, slot: &str) -> Option<Value> {
        let held = if device_id == self.identity.device_id {
            self.local_state.get(slot)
        } else {
            self.remote_state.get(device_id, slot)
        };
        held.and_then(|v| v.value.clone())
    }

    fn send_state_update(
        &mut self,
        peer: Option<&str>,
        slots: Vec<(String, SlotValue)>,
        out: &mut Out,
    ) {
        let (direct, mesh): (Vec<_>, Vec<_>) =
            slots.into_iter().partition(|(n, _)| ss::is_direct_slot(n));
        for chunk in mesh.chunks(ss::MAX_SLOTS_PER_MESSAGE) {
            let payload = ss::update_payload(chunk.iter().map(|(n, v)| (n.as_str(), v)));
            let mut envelope = self.new_envelope(KIND_UPDATE).with_payload(payload);
            match peer {
                Some(p) => envelope = envelope.to(p),
                None => envelope.broadcast = true,
            }
            // Nobody to tell is fine: the digest and the on-connect send reach them later.
            let _ = self.send_into(envelope, &mut Vec::new(), out);
        }
        if direct.is_empty() {
            return;
        }
        let targets: Vec<String> = match peer {
            Some(p) => vec![p.to_owned()],
            None => self.peers.keys().cloned().collect(),
        };
        for target in targets {
            for chunk in direct.chunks(ss::MAX_SLOTS_PER_MESSAGE) {
                let payload = ss::update_payload(chunk.iter().map(|(n, v)| (n.as_str(), v)));
                let envelope = self
                    .new_envelope(KIND_UPDATE)
                    .to(&target)
                    .with_ttl(0)
                    .with_payload(payload);
                let _ = self.send_into(envelope, &mut Vec::new(), out);
            }
        }
    }

    /// A peer just became live: send it every slot of ours.
    pub(super) fn send_state_to(&mut self, peer: &str, out: &mut Out) {
        let slots: Vec<(String, SlotValue)> = self
            .local_state
            .all()
            .filter(|(name, _)| self.features.is_message_allowed(name))
            .map(|(n, v)| (n.clone(), v.clone()))
            .collect();
        if !slots.is_empty() {
            self.send_state_update(Some(peer), slots, out);
        }
    }

    /// The periodic reconcile: broadcast what versions of our slots exist, so anyone who missed an update asks for it.
    /// Direct-only slots are listed to each directly connected peer separately and never flooded.
    pub(super) fn broadcast_state_digest(&mut self, out: &mut Out) {
        if self.local_state.is_empty() {
            return;
        }
        let digest: std::collections::BTreeMap<String, u64> = self
            .local_state
            .digest()
            .into_iter()
            .filter(|(name, _)| self.features.is_message_allowed(name))
            .collect();
        let (direct, mesh): (
            std::collections::BTreeMap<_, _>,
            std::collections::BTreeMap<_, _>,
        ) = digest
            .into_iter()
            .partition(|(name, _)| ss::is_direct_slot(name));
        if !mesh.is_empty() {
            let mut envelope = self
                .new_envelope(KIND_DIGEST)
                .with_payload(ss::digest_payload(&mesh));
            envelope.broadcast = true;
            let _ = self.send_into(envelope, &mut Vec::new(), out);
        }
        if !direct.is_empty() {
            let peers: Vec<String> = self.peers.keys().cloned().collect();
            for peer in peers {
                let envelope = self
                    .new_envelope(KIND_DIGEST)
                    .to(&peer)
                    .with_ttl(0)
                    .with_payload(ss::digest_payload(&direct));
                let _ = self.send_into(envelope, &mut Vec::new(), out);
            }
        }
    }

    /// `state.update`, `state.digest` or `state.request` from `envelope.sender_id`. The sender can only ever write its
    /// own slots, because the owner is the signed sender.
    pub(super) fn handle_state_message(
        &mut self,
        conn: ConnId,
        envelope: &Envelope,
        out: &mut Out,
    ) {
        let from = envelope.sender_id.clone();
        if !self.trust.is_trusted(&from) || self.trust.revoked_at(&from).is_some() {
            return;
        }
        // Direct-only slots count only when this message came straight from its owner.
        let arrived_directly = self
            .conns
            .get(&conn)
            .and_then(|c| c.peer.as_ref())
            .is_some_and(|p| p.device_id == from);
        match envelope.kind.as_str() {
            KIND_UPDATE => {
                for (slot, incoming) in ss::parse_update(&envelope.payload) {
                    if !self.features.is_message_allowed(&slot)
                        || (ss::is_direct_slot(&slot) && !arrived_directly)
                    {
                        continue;
                    }
                    let version = incoming.version;
                    let value = incoming.value.clone();
                    if self.remote_state.apply(&from, &slot, incoming) == Applied::Changed {
                        out.push(Action::Event(Event::StateChanged {
                            device_id: from.clone(),
                            slot,
                            value,
                            version,
                        }));
                    }
                }
            }
            KIND_DIGEST => {
                let digest = ss::parse_digest(&envelope.payload);
                let wanted: Vec<String> = self
                    .remote_state
                    .wanted(&from, &digest)
                    .into_iter()
                    .filter(|slot| self.features.is_message_allowed(slot))
                    .filter(|slot| !ss::is_direct_slot(slot) || arrived_directly)
                    .collect();
                if !wanted.is_empty() {
                    let mut request = self
                        .new_envelope(KIND_REQUEST)
                        .to(&from)
                        .with_payload(ss::request_payload(&wanted));
                    if wanted.iter().all(|s| ss::is_direct_slot(s)) {
                        request = request.with_ttl(0);
                    }
                    let _ = self.send_into(request, &mut Vec::new(), out);
                }
            }
            KIND_REQUEST => {
                let slots: Vec<(String, SlotValue)> = ss::parse_request(&envelope.payload)
                    .into_iter()
                    .filter(|slot| self.features.is_message_allowed(slot))
                    .filter(|slot| !ss::is_direct_slot(slot) || arrived_directly)
                    .filter_map(|slot| self.local_state.get(&slot).map(|v| (slot, v.clone())))
                    .collect();
                if !slots.is_empty() {
                    self.send_state_update(Some(&from), slots, out);
                }
            }
            _ => {}
        }
    }

    /// A device was revoked: drop what we held of it and tell the shell each slot is gone.
    pub(super) fn forget_state_of(&mut self, device_id: &str, out: &mut Out) {
        for slot in self.remote_state.forget(device_id) {
            out.push(Action::Event(Event::StateChanged {
                device_id: device_id.to_owned(),
                slot,
                value: None,
                version: 0,
            }));
        }
    }
}
