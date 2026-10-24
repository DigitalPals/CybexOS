#![recursion_limit = "256"]
//! installer-preview: headless PNG renders of every screen for design review.
//!
//!   installer-preview <static.json> <out-dir> [WIDTHxHEIGHT] [scale] [scenario…]
//!
//! `static.json` comes from `nerdos-installerd --dump-static`. The renders use
//! the real controller, Slint UI and software renderer with fixture snapshots
//! at a fixed moment; nothing contacts the daemon. Compare them with the design
//! reference in installer/ui-reference/.

use std::path::{Path, PathBuf};
use std::rc::Rc;

use nerdos_installer::client::Client;
use nerdos_installer::protocol::{parse, Message};
use nerdos_installer::ui::App;
use nerdos_installer::{InstallerWindow, Store};
use serde_json::{json, Value};
use slint::platform::software_renderer::{MinimalSoftwareWindow, RepaintBufferType};
use slint::platform::{Platform, WindowAdapter, WindowEvent};
use slint::{ComponentHandle, PhysicalSize, Rgb8Pixel, SharedString};

/// 2026-10-23 19:00 UTC, two days before Europe's clocks go back.
const MOMENT: i64 = 1_792_782_000;

struct Headless {
    window: Rc<MinimalSoftwareWindow>,
}

impl Platform for Headless {
    fn create_window_adapter(&self) -> Result<Rc<dyn WindowAdapter>, slint::PlatformError> {
        Ok(self.window.clone())
    }
}

fn base_state() -> Value {
    json!({
        "type": "state", "schema": "nerdos.installer-state.v1", "phase": "setup",
        "message": "", "error": "", "stage": 0, "stages": 6, "elapsed": 0,
        "release": "Authenticated NerdOS 1.0.0-beta.2 • beta channel • exact revision 9dce94a", "development": false,
        "disks": [
            {"path": "/dev/nvme0n1", "serial": "S6Z1NJ0W812345L", "model": "Samsung SSD 990 PRO 1TB", "size": 1000204886016u64,
             "available": true, "reason": "", "filesystems": ["ntfs", "vfat"], "bus": "NVMe"},
            {"path": "/dev/nvme1n1", "serial": "24125A800123", "model": "WD Blue SN580 500GB", "size": 500107862016u64,
             "available": true, "reason": "", "filesystems": ["ext4", "swap"], "bus": "NVMe"},
            {"path": "/dev/sda", "serial": "4C530001230824118312", "model": "SanDisk Ultra USB 3.0", "size": 30752636928u64,
             "available": false, "reason": "In use by this installer · smaller than 64 GiB", "filesystems": ["iso9660"], "bus": "USB"}
        ],
        "hardware": {"nvidia": true},
        "network": {"busy": false, "error": "", "message": "Internet connection ready.", "connected": true, "kind": "ethernet",
                    "interface": "enp5s0", "name": "NerdOS Wired", "address": "192.168.1.42", "ethernetCable": true,
                    "wifi": {"interface": "wlp0s20f3", "networks": [
                        {"ssid": "Lovelace-5G", "signal": 92, "security": "WPA2", "connected": false},
                        {"ssid": "Lovelace", "signal": 70, "security": "WPA2", "connected": false},
                        {"ssid": "Café Babbage", "signal": 48, "security": "", "connected": false},
                        {"ssid": "eduroam", "signal": 30, "security": "WPA2 802.1X", "connected": false}]}},
        "region": {"busy": false, "message": "Detected Europe/Amsterdam from your internet connection.", "detected": "Europe/Amsterdam"},
        "firmware": {"uefi": true, "secureBoot": false},
        "memory": 33325867008u64,
        "graphics": ["Intel Arc Graphics", "NVIDIA GeForce RTX 4070"],
        "review": null, "result": null, "diskTouched": false, "reviewPending": false,
        "draft": {"screen": "welcome", "disk": "/dev/nvme0n1", "encrypted": true, "fullName": "Ada Lovelace", "username": "ada",
                  "userEdited": false, "hostname": "", "hostEdited": false, "timezone": "Europe/Amsterdam", "tzSource": "detected",
                  "locale": "en_US.UTF-8", "layout": "us", "nvidiaOpen": true,
                  "apps": {"developer": true, "proprietary": true, "steam": true, "docker": true, "podman": true, "tailscale": true,
                           "connectedWidgets": true, "assistant": true, "localNetworkServices": true}}
    })
}

fn merge(base: &mut Value, patch: Value) {
    match (base, patch) {
        (Value::Object(base), Value::Object(patch)) => {
            for (key, value) in patch {
                if value.is_object() && base.get(&key).is_some_and(Value::is_object) {
                    merge(base.get_mut(&key).unwrap(), value);
                } else {
                    base.insert(key, value);
                }
            }
        }
        (base, patch) => *base = patch,
    }
}

fn state(patch: Value) -> Message {
    let mut value = base_state();
    merge(&mut value, patch);
    parse(&value.to_string()).expect("fixture state")
}

type Setup = fn(&Store);

fn scenarios() -> Vec<(&'static str, Value, Setup)> {
    let none: Setup = |_| {};
    vec![
        ("01-welcome-checking", json!({"phase": "loading", "message": "Checking this installation medium…", "disks": []}), none),
        ("02-welcome", json!({}), none),
        ("03-welcome-development", json!({"phase": "development", "message": "This is an unreleased development build. Use it only for testing on a backed-up or disposable disk.", "disks": []}), none),
        ("04-welcome-offline", json!({"phase": "preflight", "error": "DNS could not resolve cache.nixos.org. Open the network menu and check the DNS provider and any VPN DNS settings, then retry. No disk has been erased.",
            "network": {"connected": false, "ethernetCable": false, "kind": "", "address": ""}, "disks": []}), none),
        ("05-disk", json!({"draft": {"screen": "disk"}}), none),
        ("06-disk-details", json!({"draft": {"screen": "disk", "encrypted": false}}), |store| store.invoke_toggle_all_disks()),
        ("07-account", json!({"draft": {"screen": "account"}}), |store| {
            store.set_password(SharedString::from("correct horse battery"));
            store.set_confirm(SharedString::from("correct horse battery"));
            store.invoke_passwords_edited();
        }),
        ("08-account-lowercase", json!({"draft": {"screen": "account", "fullName": "", "username": ""}}), |store| {
            store.set_full_name(SharedString::from("John Doe"));
            store.invoke_full_name_edited(SharedString::from("John Doe"));
            let filtered = store.invoke_filter_name(SharedString::from("John.Doe"), 8);
            store.set_username(filtered.text.clone());
            store.invoke_username_edited(filtered.text, filtered.note);
            store.set_password(SharedString::from("hunter22"));
            store.set_confirm(SharedString::from("hunter2"));
            store.invoke_passwords_edited();
        }),
        ("09-timezone-search", json!({"draft": {"screen": "account"}}), |store| {
            store.invoke_open_sheet(SharedString::from("timezone"));
            store.set_tz_query(SharedString::from("kiev"));
            store.invoke_tz_query_edited(SharedString::from("kiev"));
        }),
        ("10-timezone", json!({"draft": {"screen": "account"}}), |store| {
            store.invoke_open_sheet(SharedString::from("timezone"));
        }),
        ("11-review", json!({"phase": "review", "draft": {"screen": "account"}}), none),
        ("12-installing", json!({"phase": "installing", "stage": 4, "elapsed": 754, "diskTouched": true,
            "message": "Building and downloading packages"}), none),
        ("13-done", json!({"phase": "complete", "stage": 6, "diskTouched": true,
            "result": {"username": "ada", "hostname": "ada-nerdos", "encrypted": true}}), none),
        ("14-stopped-secure-boot", json!({"phase": "error", "firmware": {"uefi": true, "secureBoot": true},
            "error": "Secure Boot is enabled. A signed installer and locally enrolled signing keys are required; it will not be disabled."}), none),
        ("15-failed", json!({"phase": "error", "diskTouched": true,
            "error": "Command nixos-install failed (exit 1). See the installation details."}), none),
        ("16-wifi", json!({"network": {"connected": false, "kind": ""}}), |store| {
            store.invoke_open_sheet(SharedString::from("wifi"));
            store.invoke_wifi_select(0);
        }),
        ("17-keyboard", json!({}), |store| store.invoke_open_sheet(SharedString::from("keyboard"))),
        ("18-tools", json!({"draft": {"screen": "disk"}}), |store| store.invoke_open_sheet(SharedString::from("tools"))),
        ("19-log", json!({"phase": "installing", "stage": 4, "elapsed": 754, "diskTouched": true}), |store| {
            store.invoke_open_sheet(SharedString::from("log"));
            store.set_details(SharedString::from(
                "2026-10-23 19:14:02 UTC · Configured DNS servers: 127.0.0.53\n2026-10-23 19:14:03 UTC · Verified HTTPS access to https://cache.nixos.org/nix-cache-info.\n$ sgdisk --zap-all /dev/nvme0n1\n$ cryptsetup luksFormat --type luks2 --batch-mode --key-file - /dev/nvme0n1p2\n$ mkfs.ext4 -L nerdos-root /dev/mapper/nerdos-install-root\n$ nixos-install --root /run/nerdos-install-q3k/target --flake path:/run/…#nerdos --no-root-passwd --no-channel-copy\ncopying path '/nix/store/7xk…-linux-7.2.4' from 'auto'...\ncopying path '/nix/store/m2c…-hyprland-0.56.2' from 'auto'...\ncopying path '/nix/store/s9a…-steam-1.0.0.85' from 'https://cache.nixos.org'...",
            ));
            store.set_details_note(SharedString::from("Private log /run/nerdos-installer.log. Passwords never appear here."));
        }),
        ("20-apps", json!({"phase": "review"}), |store| store.invoke_open_sheet(SharedString::from("apps"))),
        ("21-reconnecting", json!({}), |store| store.set_connected(false)),
    ]
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() < 2 {
        eprintln!("usage: installer-preview <static.json> <out-dir> [WIDTHxHEIGHT] [scale] [scenario…]");
        std::process::exit(2);
    }
    let statics = std::fs::read_to_string(&args[0]).expect("read static.json");
    let out = PathBuf::from(&args[1]);
    std::fs::create_dir_all(&out).expect("create output directory");
    let (width, height) = args
        .get(2)
        .and_then(|r| r.split_once('x'))
        .map(|(w, h)| (w.parse().unwrap_or(1280u32), h.parse().unwrap_or(800u32)))
        .unwrap_or((1280, 800));
    let scale: f32 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(1.0);
    let only: Vec<&String> = args.iter().skip(4).collect();

    let window = MinimalSoftwareWindow::new(RepaintBufferType::NewBuffer);
    slint::platform::set_platform(Box::new(Headless { window: window.clone() })).expect("headless platform");
    window.dispatch_event(WindowEvent::ScaleFactorChanged { scale_factor: scale });
    window.set_size(PhysicalSize::new(width, height));
    let ui = InstallerWindow::new().expect("window");
    ui.show().expect("show");
    let app = App::new(&ui, Client::offline());
    app.borrow_mut().set_preview_time(MOMENT);
    App::message(&app, parse(&statics).expect("static message: run nerdos-installerd --dump-static"));

    for (name, patch, setup) in scenarios() {
        if !only.is_empty() && !only.iter().any(|o| name.contains(o.as_str())) {
            continue;
        }
        let store = ui.global::<Store>();
        store.set_sheet(SharedString::from(""));
        store.set_show_all_disks(false);
        App::message(&app, state(patch));
        store.set_connected(true);
        setup(&store);
        render(&window, width, height, &out.join(format!("{name}.png")));
    }
}

fn render(window: &MinimalSoftwareWindow, width: u32, height: u32, path: &Path) {
    window.request_redraw();
    slint::platform::update_timers_and_animations();
    let mut buffer = vec![Rgb8Pixel::default(); (width * height) as usize];
    window.draw_if_needed(|renderer| {
        renderer.render(&mut buffer, width as usize);
    });
    let bytes: Vec<u8> = buffer.iter().flat_map(|p| [p.r, p.g, p.b]).collect();
    image::save_buffer(path, &bytes, width, height, image::ColorType::Rgb8).expect("write png");
    println!("{}", path.display());
}
