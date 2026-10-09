//! # gossip-core
//!
//! The sans-IO core of the Gossip protocol. It owns everything that must be byte-identical across the Mac,
//! Android, Windows and Linux clients: Noise_IK, framing, envelopes and their signatures, the mesh forwarding
//! rules, trust-roster merging and reconciliation scheduling. It never opens a socket, reads a clock or draws
//! randomness itself; the shell feeds it bytes and events and executes the actions it returns.
//!
//! Layers, bottom up: [`crypto`] and [`wire`] (pure functions and codecs), then [`mesh`], [`trust`] and
//! [`reconcile`] (state and rules), then [`session`] and [`engine`] (the per-connection state machine and the
//! whole-device state machine built from them).

pub mod control;
pub mod crypto;
pub mod engine;
pub mod env;
pub mod features;
pub mod limits;
pub mod mesh;
pub mod reconcile;
pub mod relay;
pub mod topic;
pub mod trust;
pub mod wire;
