//! NerdOS installer screen: a stateless Slint kiosk for the installation ISO.
//!
//! It draws `nerdos-installerd`'s state snapshots straight to KMS/DRM and
//! sends the user's requests back. It owns no installation logic: the daemon
//! keeps the draft plan and drives the one disk-writing worker.

slint::include_modules!();

pub mod client;
pub mod map;
pub mod names;
pub mod protocol;
pub mod ui;
pub mod zones;
pub mod zoom;
