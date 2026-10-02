//! Code vendored from vrfkit v0.2.5 (c4d6cc0, Apache-2.0; NOTICE.md), kept
//! apart from ours so a vrfkit bump is a readable diff: re-copy the source
//! files over these and re-apply the edits listed here.
//!
//! - `sink/*.rs`: `crates/vrfkit/src/sink/`, verbatim except `crate::sink::`
//!   paths spelled `crate::vendor::sink::` and the CLI's `export` feature gates
//!   removed (we always want `ChannelState::players`).
//! - `pass.rs`: `crates/vrfkit/src/pass.rs`, cut to the per-packet walk; the
//!   chunk loop, checkpoint scope and helper thread are ours (`crate::decode`).
//!
//! Lints are relaxed here only: the vendored code builds under vrfkit's own
//! toolchain policy, not ours.

#![allow(dead_code, unused_imports, clippy::all, clippy::pedantic)]

pub mod pass;
pub mod sink;
