//! UniFFI bindings over `gossip-core`, for Swift (Mac) and Kotlin (Android).
//!
//! The surface is deliberately plain: records and enums for data, a handful of objects for the stateful pieces,
//! JSON strings for free-form payloads. The core stays free of any FFI types; this crate only converts.
//!
//! Threading: every object is `Send + Sync` and serialises calls internally with a mutex, so the shell may call
//! from any thread. The core's rule still applies (a connection's frames must be fed in order); the shell
//! normally funnels each connection through one queue anyway.

mod control;
mod convert;
mod crypto;
mod engine;
mod error;
mod features;
mod hotspot_gatt;
mod relay_directory;

pub use error::GossipError;

uniffi::setup_scaffolding!();
