//! The controller: daemon snapshots in, Store properties out, requests back.
//!
//! The daemon's draft is authoritative. The only things kept here are what a
//! screen needs between snapshots: the time zone picker's search, the Wi-Fi
//! row being joined, clocks and the rendered maps.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};
use slint::{ComponentHandle, Image, Model, ModelRc, SharedString, Timer, TimerMode, VecModel};

use crate::client::{Client, Event};
use crate::map::{LandMask, Marker};
use crate::names;
use crate::protocol::{human_size, Details, Message, State, Static, Usb};
use crate::zones::{Hit, ZoneDb};
use crate::{AppRow, Check, Choice, DiskRow, Filtered, InstallerWindow, StageRow, Store, SummaryRow, UsbRow, WifiRow, ZoneRow};

const STAGES: [(&str, &str); 6] = [
    ("Preparing the selected disk", "A GPT layout with the EFI system partition and the NerdOS root"),
    ("Creating filesystems and encryption", "Your password becomes the disk key"),
    ("Recording hardware and your configuration", "Your settings go into /etc/nixos; your password never enters the Nix store"),
    ("Building and installing your desktop", "Most of it is copied from this medium; the rest downloads"),
    ("Setting up your account and keyboard", ""),
    ("Keeping the tested sources and finishing", "Unmounting and closing encryption before reporting success"),
];

const TIPS: [(&[&str], &str); 6] = [
    (&["Super", "Space"], "opens the launcher: apps, files, calculator and web apps in one place."),
    (&["Super", "Return"], "opens a terminal. Fish is already set up."),
    (&["Super", "K"], "shows every keyboard shortcut the desktop actually has."),
    (&["Super", "Tab"], "opens the window overview with live thumbnails."),
    (&["Super", "I"], "talks to the NerdOS Assistant. Hold it to dictate."),
    (&["Super", "Ctrl", "V"], "opens clipboard history. Ctrl+P pins an entry."),
];

/// What a filesystem type means to someone about to erase it.
pub fn filesystem_label(kind: &str) -> String {
    match kind {
        "ntfs" => "Windows (NTFS)",
        "vfat" | "fat" | "fat16" | "fat32" => "FAT/EFI",
        "exfat" => "exFAT",
        "ext4" => "Linux (ext4)",
        "ext3" | "ext2" => "Linux (ext)",
        "btrfs" => "Linux (Btrfs)",
        "xfs" => "Linux (XFS)",
        "swap" => "swap",
        "crypto_LUKS" => "encrypted data (LUKS)",
        "LVM2_member" => "LVM volumes",
        "zfs_member" => "ZFS",
        "linux_raid_member" => "RAID data",
        "apfs" => "macOS (APFS)",
        "hfsplus" => "macOS (HFS+)",
        "iso9660" | "udf" => "an installer image",
        other => other,
    }
    .to_string()
}

pub fn now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

fn s(text: impl AsRef<str>) -> SharedString {
    SharedString::from(text.as_ref())
}

fn model<T: Clone + PartialEq + 'static>(current: ModelRc<T>, items: Vec<T>) -> ModelRc<T> {
    let Some(rows) = current.as_any().downcast_ref::<VecModel<T>>() else {
        return ModelRc::new(VecModel::from(items));
    };
    for (i, item) in items.iter().enumerate() {
        if i >= rows.row_count() {
            rows.push(item.clone());
        } else if rows.row_data(i).as_ref() != Some(item) {
            rows.set_row_data(i, item.clone());
        }
    }
    while rows.row_count() > items.len() {
        rows.remove(rows.row_count() - 1);
    }
    current
}

pub struct App {
    window: slint::Weak<InstallerWindow>,
    client: Client,
    statics: Static,
    zones: Option<ZoneDb>,
    state: Option<State>,
    mask: LandMask,
    reserved: Vec<String>,
    synced_account: bool,
    user_edited: bool,
    host_edited: bool,
    tz_pick: String,
    tz_hits: Vec<Hit>,
    tz_minute: i64,
    mini_key: String,
    big_key: String,
    region_seen: String,
    elapsed_base: (i64, Instant),
    toast_until: Option<Instant>,
    sheet_opened: Option<Instant>,
    details_pending: bool,
    timers: Vec<Timer>,
    preview_now: Option<i64>,
}

pub type Shared = Rc<RefCell<App>>;

impl App {
    pub fn new(window: &InstallerWindow, client: Client) -> Shared {
        let app = Rc::new(RefCell::new(App {
            window: window.as_weak(),
            client,
            statics: Static::default(),
            zones: None,
            state: None,
            mask: LandMask::embedded(),
            reserved: vec!["root".into(), "nixos".into()],
            synced_account: false,
            user_edited: false,
            host_edited: false,
            tz_pick: String::new(),
            tz_hits: Vec::new(),
            tz_minute: -1,
            mini_key: String::new(),
            big_key: String::new(),
            region_seen: String::new(),
            elapsed_base: (0, Instant::now()),
            toast_until: None,
            sheet_opened: None,
            details_pending: false,
            timers: Vec::new(),
            preview_now: None,
        }));
        bind(&app, window);
        let timer = Timer::default();
        let weak = Rc::downgrade(&app);
        timer.start(TimerMode::Repeated, Duration::from_secs(1), move || {
            if let Some(app) = weak.upgrade() {
                App::second(&app);
            }
        });
        app.borrow_mut().timers.push(timer);
        app
    }

    /// Previews render a fixed moment.
    pub fn set_preview_time(&mut self, time: i64) {
        self.preview_now = Some(time);
    }

    fn now(&self) -> i64 {
        self.preview_now.unwrap_or_else(now)
    }

    fn window(&self) -> Option<InstallerWindow> {
        self.window.upgrade()
    }

    fn send(&self, request: Value) {
        self.client.send(request);
    }

    fn draft(&self, values: Value) {
        self.send(json!({"action": "draft", "values": values}));
    }

    pub fn handle(app: &Shared, event: Event) {
        match event {
            Event::Connected => {
                let mut this = app.borrow_mut();
                this.synced_account = false;
                this.details_pending = false;
                this.send(json!({"action": "hello", "client": "screen"}));
            }
            Event::Disconnected => {
                if let Some(window) = app.borrow().window() {
                    window.global::<Store>().set_connected(false);
                }
            }
            Event::Message(message) => App::message(app, message),
        }
    }

    pub fn message(app: &Shared, message: Message) {
        match message {
            Message::Static(statics) => app.borrow_mut().apply_static(*statics),
            Message::State(state) => app.borrow_mut().apply_state(*state),
            Message::Details(details) => app.borrow_mut().apply_details(details),
            Message::Usb(usb) => app.borrow_mut().apply_usb(usb),
            Message::Restart => {
                // The daemon wrote the new keymap; systemd starts us again
                // with it. Nothing on screen needs saving.
                let _ = slint::quit_event_loop();
                std::process::exit(0);
            }
        }
    }

    // ── static data ──────────────────────────────────────────────────────────

    pub fn apply_static(&mut self, statics: Static) {
        self.zones = Some(ZoneDb::new(&statics.zones, &statics.countries, &statics.aliases, &statics.tzdata));
        self.reserved = statics.reserved.clone();
        self.statics = statics;
        self.mini_key.clear();
        self.big_key.clear();
        let Some(window) = self.window() else { return };
        let store = window.global::<Store>();
        store.set_version(s(&self.statics.version));
        store.set_tz_data(s(&self.statics.tzdata));
        if let Some(esp) = self.statics.layout.get("espGiB").and_then(Value::as_i64) {
            store.set_esp_gib(s(esp.to_string()));
        }
        if let Some(minimum) = self.statics.layout.get("minimumDiskGiB").and_then(Value::as_i64) {
            store.set_minimum_gib(s(minimum.to_string()));
        }
        if let Some(state) = self.state.take() {
            self.apply_state(state);
        }
    }

    // ── state ────────────────────────────────────────────────────────────────

    pub fn apply_state(&mut self, state: State) {
        let Some(window) = self.window() else { return };
        let store = window.global::<Store>();
        store.set_connected(true);
        if self.state.as_ref() == Some(&state) {
            return;
        }
        self.state = Some(state.clone());
        let draft = &state.draft;

        // Routing: the worker's phase decides, the draft picks the setup step.
        let screen = match state.phase.as_str() {
            "setup" => match draft.screen.as_str() {
                "disk" | "account" => draft.screen.clone(),
                _ => "welcome".into(),
            },
            "review" => "review".into(),
            "installing" => "installing".into(),
            "complete" => "done".into(),
            "error" if state.disk_touched => "failed".into(),
            "error" | "cancelled" => "stopped".into(),
            _ => "welcome".into(),
        };
        if store.get_screen() != screen.as_str() {
            store.set_screen(s(&screen));
        }
        if matches!(state.phase.as_str(), "installing" | "complete") && !store.get_sheet().is_empty()
            && store.get_sheet() != "log" && store.get_sheet() != "tools"
        {
            store.set_sheet(s(""));
        }

        // Language and keyboard.
        let language = self.statics.languages.iter().find(|l| l.0 == draft.locale);
        store.set_language_name(s(language.map_or(draft.locale.as_str(), |l| l.1.as_str())));
        store.set_language_code(s(draft.locale.get(..2).unwrap_or("").to_uppercase()));
        let layout = self.statics.layouts.iter().find(|l| l.0 == draft.layout);
        store.set_layout_name(s(layout.map_or(draft.layout.as_str(), |l| l.1.as_str())));
        store.set_layout_code(s(draft.layout.to_uppercase()));
        store.set_languages(model(store.get_languages(),
            self.statics
                .languages
                .iter()
                .map(|(key, label)| Choice { key: s(key), label: s(label), detail: s(key), selected: *key == draft.locale })
                .collect(),
        ));
        store.set_layouts(model(store.get_layouts(),
            self.statics
                .layouts
                .iter()
                .map(|(key, label, console)| Choice {
                    key: s(key),
                    label: s(label),
                    detail: s(if key == console { key.clone() } else { format!("{key} · {console}") }),
                    selected: *key == draft.layout,
                })
                .collect(),
        ));

        self.apply_welcome(&store, &state);
        self.apply_disks(&store, &state);
        self.apply_account(&store, &state);
        self.apply_review(&store, &state);
        self.apply_progress(&store, &state);
        self.apply_network(&store, &state);
        if screen == "account" {
            self.apply_timezone_card(&store, &state);
        }

        // A finished detection moves an open picker to the detected zone.
        if state.region.detected != self.region_seen {
            self.region_seen = state.region.detected.clone();
            if store.get_sheet() == "timezone" && !state.region.detected.is_empty() {
                self.tz_pick = state.region.detected.clone();
                self.refresh_picker(&store);
            }
        }
        store.set_tz_detecting(state.region.busy);
        if store.get_sheet() == "timezone" {
            self.refresh_pick_details(&store);
        }
    }

    fn apply_welcome(&self, store: &Store, state: &State) {
        let phase = state.phase.as_str();
        let started = !matches!(phase, "loading" | "development" | "preflight");
        let mut checks = Vec::new();
        let firmware = if !state.firmware.uefi {
            Check { label: s("Firmware"), value: s("Legacy BIOS boot"), detail: s("Start the installer in UEFI mode"), state: 4 }
        } else if state.firmware.secure_boot {
            Check { label: s("Firmware"), value: s("UEFI · Secure Boot on"), detail: s("This installer is not signed for Secure Boot yet"), state: 4 }
        } else {
            Check { label: s("Firmware"), value: s("UEFI · Secure Boot off"), detail: s(""), state: 0 }
        };
        checks.push(firmware);
        let net = &state.network;
        checks.push(if net.connected {
            let kind = if net.kind == "wifi" { format!("Wi-Fi · {}", net.name) } else { format!("Ethernet · {}", net.interface) };
            let address = if net.address.is_empty() { String::new() } else { format!(" · {}", net.address) };
            Check { label: s("Network"), value: s(format!("{kind}{address}")), detail: s(""), state: 0 }
        } else if net.busy && net.wifi.interface.is_empty() && !net.ethernet_cable {
            Check { label: s("Network"), value: s("Looking for a connection…"), detail: s(""), state: 1 }
        } else {
            Check {
                label: s("Network"),
                value: s(if net.ethernet_cable { "Cable connected, no address yet" } else { "Not connected" }),
                detail: s("Needed to verify the release and download parts of your desktop"),
                state: 3,
            }
        });
        checks.push(match phase {
            "loading" => Check { label: s("Release"), value: s("Verifying this installation medium…"), detail: s(&net.message), state: 1 },
            "development" => Check { label: s("Release"), value: s("Unreleased development build"), detail: s("Use only on a disposable or backed-up disk"), state: 3 },
            "preflight" => Check { label: s("Release"), value: s("Could not be verified"), detail: s("See the message on the left"), state: 4 },
            _ if state.development => Check { label: s("Release"), value: s(format!("Test build {}", self.statics.version)), detail: s("Bundled source, not a published release"), state: 3 },
            _ => Check {
                label: s("Release"),
                value: s(format!("NerdOS {} · signature verified", self.statics.version)),
                detail: s(state.release.split(" • ").nth(1).unwrap_or("")),
                state: 0,
            },
        });
        let available = state.disks.iter().filter(|d| d.available).count();
        checks.push(if !started {
            Check { label: s("Disks"), value: s("Checked after the release"), detail: s(""), state: 2 }
        } else if available == 0 {
            Check { label: s("Disks"), value: s(format!("{} found · none can be used", state.disks.len())), detail: s(format!("Needs a disk of at least {} GiB", self.statics.layout.get("minimumDiskGiB").and_then(Value::as_i64).unwrap_or(64))), state: 3 }
        } else {
            Check { label: s("Disks"), value: s(format!("{} found · {available} can be used", state.disks.len())), detail: s(""), state: 0 }
        });
        let graphics = if state.graphics.is_empty() { "Firmware framebuffer".to_string() } else { state.graphics.join(" + ") };
        checks.push(Check {
            label: s("Graphics"),
            value: s(graphics),
            detail: s(if state.nvidia() { "NVIDIA driver choice on the review page" } else { "" }),
            state: 0,
        });
        let gib = state.memory as f64 / 1_073_741_824.0;
        checks.push(Check {
            label: s("Memory"),
            value: s(format!("{:.0} GB", (state.memory as f64 / 1e9).round())),
            detail: s(if gib < 7.5 { "Under 8 GB: the installation can be slow" } else { "" }),
            state: if gib < 7.5 { 3 } else { 0 },
        });
        let ok = checks.iter().all(|c| c.state == 0);
        let running = checks.iter().any(|c| c.state == 1);
        store.set_checks(model(store.get_checks(), checks));
        store.set_check_summary(s(if running { "checking…" } else if ok { "all good" } else if !net.connected { "needs a network" } else { "" }));
        store.set_busy(running);
        store.set_can_start(phase == "setup");
        store.set_offline(!net.connected);
        store.set_development(phase == "development");
        store.set_development_message(s(if state.message.is_empty() { "This is an unreleased development build." } else { state.message.as_str() }));
        store.set_preflight_error(s(if phase == "preflight" { state.error.as_str() } else { "" }));
    }

    fn apply_disks(&self, store: &Store, state: &State) {
        let show_all = store.get_show_all_disks();
        let rows: Vec<DiskRow> = state
            .disks
            .iter()
            .filter(|d| d.available || show_all)
            .map(|d| {
                let labels: Vec<String> = d.filesystems.iter().map(|f| filesystem_label(f)).collect();
                let contents = if labels.is_empty() { "empty or unrecognised".to_string() } else { format!("has {}", labels.join(", ")) };
                DiskRow {
                    path: s(&d.path),
                    model: s(if d.model.is_empty() { "Disk" } else { d.model.as_str() }),
                    size: s(human_size(d.size)),
                    bus: s(&d.bus),
                    contents: s(contents),
                    serial: s(format!("{} · {} GiB", if d.serial.is_empty() { "unavailable" } else { d.serial.as_str() }, d.size / 1_073_741_824)),
                    available: d.available,
                    reason: s(&d.reason),
                    selected: d.path == state.draft.disk,
                    removable: d.bus == "USB",
                }
            })
            .collect();
        store.set_disks(model(store.get_disks(), rows));
        store.set_hidden_disks(state.disks.iter().filter(|d| !d.available).count() as i32);
        store.set_encrypted(state.draft.encrypted);
        store.set_disk_chosen(state.disks.iter().any(|d| d.available && d.path == state.draft.disk));
        store.set_disk_error(s(if state.phase == "setup" && state.draft.screen == "disk" { state.error.as_str() } else { "" }));
    }

    fn apply_account(&mut self, store: &Store, state: &State) {
        let draft = &state.draft;
        if !self.synced_account {
            // After a (re)connect the daemon's draft fills the fields once;
            // from then on typing here is the source and is sent as drafts.
            self.synced_account = true;
            self.user_edited = draft.user_edited;
            self.host_edited = draft.host_edited;
            store.set_full_name(s(&draft.full_name));
            store.set_username(s(&draft.username));
            store.set_hostname(s(if draft.host_edited && !draft.hostname.is_empty() {
                draft.hostname.clone()
            } else {
                names::hostname_for(&draft.username)
            }));
            store.set_host_edited(self.host_edited);
            self.update_account(store, "", "");
        }
        let layout = self.statics.layouts.iter().find(|l| l.0 == draft.layout);
        store.set_unlock_note(s(if draft.encrypted {
            format!("Also unlocks the disk at startup, typed with the {} layout", layout.map_or("US", |l| l.1.as_str()))
        } else {
            String::new()
        }));
        let error = if state.phase == "setup" && state.draft.screen == "account" { state.error.clone() } else { String::new() };
        store.set_account_error(s(&error));
        // The daemon marks a review in flight until the worker answers.
        store.set_review_busy(state.review_pending);
        if state.phase == "installing" || state.phase == "complete" {
            store.set_password(s(""));
            store.set_confirm(s(""));
        }
    }

    fn update_account(&self, store: &Store, user_note: &str, host_note: &str) {
        let username = store.get_username().to_string();
        let hostname = store.get_hostname().to_string();
        let full_name = store.get_full_name().to_string();
        store.set_name_help(s(names::full_name_problem(&full_name).unwrap_or("")));
        let reserved = self.reserved.iter().any(|r| *r == username) || username.starts_with("nixbld");
        let (help, tone) = if !user_note.is_empty() {
            (user_note.to_string(), 3)
        } else if username.is_empty() {
            ("Lowercase letters, digits and hyphens. Starts with a letter.".to_string(), 0)
        } else if reserved {
            (format!("“{username}” is reserved by the system. Choose another username."), 2)
        } else {
            ("Looks good".to_string(), 1)
        };
        store.set_username_help(s(help));
        store.set_username_tone(tone);
        store.set_username_count(s(format!("{}/{}", username.len(), names::MAX_LEN)));
        let host_valid = names::is_valid(&hostname) && hostname != "root" && hostname != "nixos";
        let (host_help, host_tone) = if !host_note.is_empty() {
            (host_note.replace("names are lowercase", "computer names are lowercase"), 3)
        } else if !host_valid {
            ("Lowercase letters, digits and hyphens. Starts with a letter.".to_string(), if hostname.is_empty() { 0 } else { 2 })
        } else if self.state.as_ref().and_then(|st| st.draft.apps.get("localNetworkServices").copied()).unwrap_or(true) {
            (format!("Visible on your network as {hostname}.local"), 0)
        } else {
            (String::new(), 0)
        };
        store.set_hostname_help(s(host_help));
        store.set_hostname_tone(host_tone);
        store.set_home_note(s(if username.is_empty() { String::new() } else { format!("Home folder /home/{username}") }));
        let password = store.get_password();
        let confirm = store.get_confirm();
        let length = password.chars().count();
        store.set_strength(match length {
            0 => 0,
            1..=7 => 1,
            8..=11 => 2,
            12..=15 => 3,
            _ => 4,
        });
        let (confirm_help, confirm_tone) = if confirm.is_empty() {
            (if length > 0 && length < 8 { "At least 8 characters." } else { "" }, if length > 0 && length < 8 { 2 } else { 0 })
        } else if confirm == password {
            ("Passwords match", 1)
        } else if confirm.chars().count() >= length {
            ("Passwords don't match", 2)
        } else {
            ("", 0)
        };
        store.set_confirm_help(s(confirm_help));
        store.set_confirm_tone(confirm_tone);
        store.set_can_review(
            names::is_valid(&username)
                && !reserved
                && host_valid
                && names::full_name_problem(&full_name).is_none()
                && length >= 8
                && confirm == password,
        );
    }

    fn apply_review(&self, store: &Store, state: &State) {
        let draft = &state.draft;
        let Some(disk) = state.disks.iter().find(|d| d.path == draft.disk) else { return };
        let model_name = if disk.model.is_empty() { format!("The disk {}", disk.path) } else { disk.model.clone() };
        let short = model_name
            .split_whitespace()
            .filter(|w| !w.chars().next().is_some_and(|c| c.is_ascii_digit()) || !w.ends_with("B"))
            .collect::<Vec<_>>()
            .join(" ");
        store.set_erase_title(s(format!("{model_name} will be erased")));
        let labels: Vec<String> = disk.filesystems.iter().map(|f| filesystem_label(f)).collect();
        let including = if labels.is_empty() { String::new() } else { format!(", including {}", labels.join(" and ")) };
        store.set_erase_detail(s(format!(
            "Every partition and file on {} ({}) will be deleted{including}.",
            disk.path,
            human_size(disk.size)
        )));
        store.set_erase_button(s(format!("Erase {} & install", if disk.model.is_empty() || short.len() > 26 { "disk" } else { short.as_str() })));
        let now = self.now();
        let zone_title = self.zones.as_ref().and_then(|z| z.get(&draft.timezone)).map(|z| z.city.clone()).unwrap_or_else(|| draft.timezone.clone());
        let clock = self.zones.as_ref().map(|z| z.clock(&draft.timezone, now, false)).unwrap_or_default();
        let offset = self.zones.as_ref().map(|z| z.long_offset(&draft.timezone, now)).unwrap_or_default();
        let language = self.statics.languages.iter().find(|l| l.0 == draft.locale).map_or(draft.locale.clone(), |l| l.1.clone());
        let layout = self.statics.layouts.iter().find(|l| l.0 == draft.layout);
        let console = layout.map_or(draft.layout.clone(), |l| l.2.clone());
        let hostname = if draft.host_edited && !draft.hostname.is_empty() { draft.hostname.clone() } else { names::hostname_for(&draft.username) };
        let off: Vec<&str> = self
            .statics
            .applications
            .iter()
            .filter(|(id, _, _)| !draft.apps.get(id).copied().unwrap_or(true))
            .map(|(_, name, _)| name.as_str())
            .collect();
        let total = self.statics.applications.len();
        let row = |label: &str, value: String, detail: String, action: &str, action_label: &str, warn: bool, mono: bool| SummaryRow {
            label: s(label),
            value: s(value),
            detail: s(detail),
            action: s(action),
            action_label: s(action_label),
            warn,
            mono,
        };
        let account = if draft.full_name.trim().is_empty() { draft.username.clone() } else { format!("{} · {}", draft.full_name.trim(), draft.username) };
        let mut left = vec![
            row("Account", account, format!("password login · home /home/{}", draft.username), "account", "Change", false, false),
            row("Time zone", format!("{zone_title} · {clock} now"), format!("{} · {offset}", draft.timezone), "timezone", "Change", false, false),
            row(
                "Encryption",
                if draft.encrypted { "On · LUKS2".into() } else { "Off · readable by anyone with the disk".into() },
                if draft.encrypted { "unlocked with your password at startup".into() } else { String::new() },
                "disk",
                "Change",
                !draft.encrypted,
                false,
            ),
        ];
        if state.nvidia() {
            left.push(row(
                "Graphics",
                format!("NVIDIA · {}", if draft.nvidia_open { "open kernel driver" } else { "proprietary legacy driver" }),
                if draft.nvidia_open { "Turing or newer (GTX 16, RTX 20 and up)".into() } else { "Maxwell, Pascal or Volta".into() },
                "gpu",
                "Customize",
                false,
                false,
            ));
        }
        let right = vec![
            row("Computer", hostname, String::new(), "account", "Change", false, true),
            row("Language", format!("{language} · keyboard {}", layout.map_or(draft.layout.as_str(), |l| l.1.as_str())), format!("locale {} · disk unlock keymap {console}", draft.locale), "language", "Change", false, false),
            row(
                "Applications",
                if off.is_empty() { "Everything included".into() } else { format!("{} of {total} groups", total - off.len()) },
                if off.is_empty() { format!("all {total} groups · change any time later") } else { format!("off: {}", off.join(", ")) },
                "apps",
                "Customize",
                false,
                false,
            ),
            row(
                "Release",
                format!("NerdOS {}", self.statics.version),
                if state.development { "unreleased test build".into() } else { "signature verified".into() },
                "",
                "",
                state.development,
                false,
            ),
        ];
        store.set_summary_left(model(store.get_summary_left(), left));
        store.set_summary_right(model(store.get_summary_right(), right));
        store.set_review_error(s(if state.phase == "review" { state.error.as_str() } else { "" }));
        store.set_apps(model(store.get_apps(),
            self.statics
                .applications
                .iter()
                .map(|(id, name, detail)| AppRow { id: s(id), name: s(name), detail: s(detail), on: draft.apps.get(id).copied().unwrap_or(true) })
                .collect(),
        ));
        store.set_nvidia(state.nvidia());
        store.set_nvidia_open(draft.nvidia_open);
        store.set_gpu_names(s(if state.graphics.is_empty() { "NVIDIA graphics".into() } else { state.graphics.join(" + ") }));
    }

    fn apply_progress(&mut self, store: &Store, state: &State) {
        let stage = state.stage.clamp(0, 6) as i32;
        store.set_stage(stage);
        let rows: Vec<StageRow> = STAGES
            .iter()
            .enumerate()
            .map(|(i, (title, detail))| {
                let n = i as i32 + 1;
                let current = n == stage.max(1) && state.phase == "installing";
                StageRow {
                    title: s(*title),
                    detail: s(if current && state.message.contains("Building and downloading") { "Building and downloading packages" } else { detail }),
                    state: if n < stage || state.phase == "complete" { 0 } else if current { 1 } else { 2 },
                }
            })
            .collect();
        store.set_stages(model(store.get_stages(), rows));
        let (keys, text) = TIPS[(stage.max(1) as usize - 1) % TIPS.len()];
        store.set_tip_keys(model(store.get_tip_keys(), keys.iter().map(|k| s(*k)).collect()));
        store.set_tip_text(s(text));
        self.elapsed_base = (state.elapsed, Instant::now());
        store.set_elapsed(s(format_elapsed(state.elapsed)));
        if let Some(result) = &state.result {
            store.set_done_user(s(&result.username));
            store.set_done_host(s(&result.hostname));
            store.set_done_encrypted(result.encrypted);
        }
        // Stopped before any disk change, or failed after it.
        let error = state.error.clone();
        let (kicker, title, body, check_label, check_value, steps, action) = if state.phase == "cancelled" {
            ("STOPPED · NO DISK WAS CHANGED", "Installation cancelled.", "Nothing was written to any disk. Start again whenever you are ready.".to_string(), "", String::new(), vec![], "retry")
        } else if !state.firmware.uefi {
            (
                "STOPPED BEFORE ANY DISK CHANGE",
                "This computer started in legacy BIOS mode.",
                "NerdOS installs only in UEFI mode. None of your disks have been touched.".to_string(),
                "Boot mode",
                "Legacy BIOS".to_string(),
                vec!["Restart and open the boot menu (often F12, F11 or Esc).", "Choose the UEFI entry for this USB drive or network boot.", "If there is none, enable UEFI boot in the firmware settings."],
                // A BIOS boot cannot request the firmware settings screen.
                "restart",
            )
        } else if state.firmware.secure_boot || error.contains("Secure Boot") {
            (
                "STOPPED BEFORE ANY DISK CHANGE",
                "Secure Boot is turned on.",
                "This installer isn't signed for Secure Boot yet, and it never turns Secure Boot off for you. None of your disks have been touched.".to_string(),
                "Secure Boot",
                "Enabled".to_string(),
                vec!["Restart into your firmware settings with the button below.", "Turn Secure Boot off, then save and exit.", "Start the NerdOS installer again."],
                "firmware",
            )
        } else {
            ("STOPPED BEFORE ANY DISK CHANGE", "The installer could not continue.", format!("{} None of your disks have been touched.", error.trim_end_matches('.')), "", String::new(), vec!["Open the details to see what happened.", "Fix the cause, for example the network connection.", "Choose Try again."], "retry")
        };
        store.set_stop_kicker(s(kicker));
        store.set_stop_title(s(title));
        store.set_stop_body(s(body));
        store.set_stop_check_label(s(check_label));
        store.set_stop_check_value(s(check_value));
        store.set_stop_steps(model(store.get_stop_steps(), steps.into_iter().map(s).collect()));
        store.set_stop_action(s(action));
        store.set_fail_title(s("Installation stopped."));
        store.set_fail_message(s(if error.is_empty() { "The installation worker stopped." } else { error.as_str() }));
        store.set_fail_touched(state.disk_touched);
    }

    fn apply_network(&self, store: &Store, state: &State) {
        let net = &state.network;
        store.set_net_connected(net.connected);
        store.set_net_kind(s(&net.kind));
        store.set_net_name(s(&net.name));
        store.set_net_address(s(&net.address));
        store.set_net_busy(net.busy);
        store.set_net_error(s(&net.error));
        store.set_net_message(s(&net.message));
        store.set_wifi_device(!net.wifi.interface.is_empty());
        let rows: Vec<WifiRow> = net
            .wifi
            .networks
            .iter()
            .map(|n| {
                let security = n.security.to_uppercase();
                WifiRow {
                    ssid: s(&n.ssid),
                    bars: ((n.signal + 12) / 25).clamp(0, 4) as i32,
                    secure: !(security.is_empty() || security == "--" || security == "NONE" || security == "OPEN"),
                    enterprise: security.contains("EAP") || security.contains("802.1X"),
                    connected: n.connected,
                }
            })
            .collect();
        let selected = store.get_wifi_selected();
        let previous = (selected >= 0).then(|| store.get_wifi().row_data(selected as usize)).flatten();
        let same_network = previous.as_ref().is_some_and(|old| {
            rows.get(selected as usize).is_some_and(|new| {
                old.ssid == new.ssid && old.secure == new.secure && old.enterprise == new.enterprise
            })
        });
        // Do not retain credentials if a rescan reorders/replaces the network
        // at the selected index. Signal-only changes preserve the input field.
        if rows.iter().any(|r| r.connected) || selected >= 0 && !same_network {
            store.set_wifi_selected(-1);
        }
        store.set_wifi(model(store.get_wifi(), rows));
    }

    fn apply_timezone_card(&mut self, store: &Store, state: &State) {
        let Some(zones) = self.zones.as_ref() else { return };
        let id = state.draft.timezone.clone();
        let now = self.now();
        let zone = zones.get(&id);
        store.set_tz_clock(s(zones.clock(&id, now, false)));
        store.set_tz_city(s(zone.map_or(id.as_str(), |z| z.city.as_str())));
        store.set_tz_sub(s(format!(
            "{} · {}",
            zone.map_or("", |z| if z.fixed { "fixed offset" } else { z.country.as_str() }),
            zones.long_offset(&id, now)
        )));
        store.set_tz_source(s(match state.draft.tz_source.as_str() {
            "detected" => "detected from your connection",
            "manual" => "chosen by you",
            _ => if state.region.busy { "detecting…" } else { "not detected yet" },
        }));
        let minute = now / 60;
        let key = format!("{id}@{minute}");
        if key != self.mini_key {
            self.mini_key = key;
            let marker = zone.and_then(|z| Some(Marker { lat: z.lat?, lon: z.lon? }));
            let canvas = self.mask.render(1016, 340, now, &[], marker.as_ref());
            store.set_mini_map(Image::from_rgba8_premultiplied(canvas.into_buffer()));
        }
    }

    // ── time zone picker ─────────────────────────────────────────────────────

    pub fn open_picker(&mut self, store: &Store) {
        let current = self.state.as_ref().map(|s| s.draft.timezone.clone()).unwrap_or_else(|| "UTC".into());
        self.tz_pick = current;
        store.set_tz_query(s(""));
        self.refresh_picker(store);
    }

    fn refresh_picker(&mut self, store: &Store) {
        let Some(zones) = self.zones.as_ref() else { return };
        let now = self.now();
        let query = store.get_tz_query().to_string();
        self.tz_hits = zones.search(&query, store.get_tz_fixed(), &self.tz_pick, now);
        let rows: Vec<ZoneRow> = self.tz_hits.iter().map(|hit| self.zone_row(zones, hit, now)).collect();
        let selected = self.tz_hits.iter().position(|h| zones.zones[h.index].id == self.tz_pick).map_or(-1, |p| p as i32);
        store.set_tz_results(model(store.get_tz_results(), rows));
        store.set_tz_selected_row(-1);
        store.set_tz_selected_row(selected);
        self.tz_minute = now / 60;
        self.big_key.clear();
        self.refresh_pick_details(store);
    }

    fn zone_row(&self, zones: &ZoneDb, hit: &Hit, now: i64) -> ZoneRow {
        let zone = &zones.zones[hit.index];
        let note = match &hit.alias {
            Some(alias) => format!("formerly {} · {}", alias.rsplit('/').next().unwrap_or(alias).replace('_', " "), zone.id),
            None if !zone.comment.is_empty() && !zone.fixed => format!("{} · {}", zone.comment, zone.id),
            None => zone.id.clone(),
        };
        ZoneRow {
            id: s(&zone.id),
            title: s(&zone.city),
            sub: s(if zone.fixed { if zone.id == "UTC" { "Coordinated Universal Time" } else { "fixed offset" } } else { zone.country.as_str() }),
            note: s(note),
            time: s(zones.clock(&zone.id, now, false)),
            offset: s(zones.short_offset(&zone.id, now)),
            selected: zone.id == self.tz_pick,
        }
    }

    fn refresh_pick_details(&mut self, store: &Store) {
        let Some(zones) = self.zones.as_ref() else { return };
        let now = self.now();
        let id = self.tz_pick.clone();
        let zone = zones.get(&id);
        store.set_tz_pick_clock(s(zones.clock(&id, now, true)));
        store.set_tz_pick_title(s(match zone {
            Some(z) if !z.fixed => format!("{}, {}", z.city, z.country),
            Some(z) => z.city.clone(),
            None => id.clone(),
        }));
        store.set_tz_pick_id(s(format!("{id} · {}", zones.long_offset(&id, now))));
        let change = zones.next_change(&id, now);
        store.set_tz_pick_changes(change.is_some());
        store.set_tz_pick_change(s(change.unwrap_or_else(|| "No clock changes in the next year".into())));
        let source = match self.state.as_ref() {
            Some(st) if st.draft.timezone == id && st.draft.tz_source == "detected" => "Detected from your internet connection",
            Some(st) if st.draft.timezone == id => "Your current choice",
            _ => "Not applied yet",
        };
        store.set_tz_pick_source(s(source));
        let query = store.get_tz_query().to_string();
        let pins: Vec<Marker> = if query.trim().is_empty() {
            Vec::new()
        } else {
            self.tz_hits.iter().filter_map(|h| {
                let z = &zones.zones[h.index];
                Some(Marker { lat: z.lat?, lon: z.lon? })
            }).collect()
        };
        let key = format!("{id}|{query}|{}|{}", store.get_tz_fixed(), now / 60);
        if key != self.big_key {
            self.big_key = key;
            let marker = zone.and_then(|z| Some(Marker { lat: z.lat?, lon: z.lon? }));
            let canvas = self.mask.render(1392, 541, now, &pins, marker.as_ref());
            store.set_big_map(Image::from_rgba8_premultiplied(canvas.into_buffer()));
        }
    }

    fn pick(&mut self, store: &Store, id: &str) {
        self.tz_pick = id.to_string();
        let zones = self.zones.as_ref();
        let results = store.get_tz_results();
        let mut selected = -1;
        for i in 0..results.row_count() {
            if let Some(mut row) = results.row_data(i) {
                let is = row.id == id;
                if is {
                    selected = i as i32;
                }
                if row.selected != is {
                    row.selected = is;
                    results.set_row_data(i, row);
                }
            }
        }
        if selected < 0 && zones.is_some() {
            // Picked on the map outside the current results: show it first.
            store.set_tz_query(s(""));
            self.refresh_picker(store);
            return;
        }
        store.set_tz_selected_row(selected);
        self.refresh_pick_details(store);
    }

    fn use_pick(&mut self, store: &Store) {
        let current = self.state.as_ref().map(|s| s.draft.timezone.clone()).unwrap_or_default();
        if !self.tz_pick.is_empty() && self.tz_pick != current {
            self.draft(json!({"timezone": self.tz_pick, "tzSource": "manual"}));
        }
        store.set_sheet(s(""));
    }

    // ── details and USB ──────────────────────────────────────────────────────

    fn request_details(&mut self) {
        if !self.details_pending {
            self.details_pending = true;
            self.sheet_opened = Some(Instant::now());
            self.send(json!({"action": "details"}));
        }
    }

    fn apply_details(&mut self, details: Details) {
        self.details_pending = false;
        let Some(window) = self.window() else { return };
        let store = window.global::<Store>();
        // Keep the screen light: the most recent part of the bounded log.
        let lines: Vec<&str> = details.text.lines().collect();
        let start = lines.len().saturating_sub(400);
        store.set_details(s(lines[start..].join("\n")));
        store.set_details_error(s(&details.error));
        store.set_details_note(s(format!(
            "Private log /run/nerdos-installer.log{}. Passwords never appear here.",
            if details.truncated || start > 0 { ", most recent part" } else { "" }
        )));
    }

    fn apply_usb(&mut self, usb: Usb) {
        let Some(window) = self.window() else { return };
        let store = window.global::<Store>();
        store.set_usb(model(store.get_usb(),
            usb.targets
                .iter()
                .map(|t| UsbRow { device: s(&t.device), label: s(&t.label), size: s(human_size(t.size)) })
                .collect(),
        ));
        if !usb.saved.is_empty() {
            store.set_usb_message(s(format!("Saved as {} on the USB stick. You can remove it now.", usb.saved)));
        } else if !usb.error.is_empty() {
            store.set_usb_message(s(&usb.error));
        }
    }

    fn toast(&mut self, store: &Store, text: &str) {
        store.set_toast(s(text));
        self.toast_until = Some(Instant::now() + Duration::from_millis(2600));
    }

    // ── once a second ────────────────────────────────────────────────────────

    fn second(app: &Shared) {
        let mut this = app.borrow_mut();
        let Some(window) = this.window() else { return };
        let store = window.global::<Store>();
        if this.toast_until.is_some_and(|t| Instant::now() >= t) {
            this.toast_until = None;
            store.set_toast(s(""));
        }
        let state = this.state.clone();
        let Some(state) = state else { return };
        let running = store.get_busy() || state.phase == "installing" || state.network.busy && !state.network.connected;
        if running {
            store.set_tick((store.get_tick() + 1) % 1000);
        }
        if state.phase == "installing" {
            let (base, at) = this.elapsed_base;
            store.set_elapsed(s(format_elapsed(base + at.elapsed().as_secs() as i64)));
        }
        // Clocks: the card changes once a minute, the picker's clock every second.
        if store.get_screen() == "account" {
            this.apply_timezone_card(&store, &state);
        }
        if store.get_sheet() == "timezone" {
            let now = this.now();
            if now / 60 != this.tz_minute {
                this.refresh_picker(&store);
            } else if let Some(zones) = this.zones.as_ref() {
                store.set_tz_pick_clock(s(zones.clock(&this.tz_pick, now, true)));
            }
        }
        if store.get_sheet() == "log" && this.sheet_opened.is_some_and(|t| t.elapsed() >= Duration::from_secs(2)) {
            this.sheet_opened = Some(Instant::now());
            this.request_details();
        }
    }
}

pub fn format_elapsed(seconds: i64) -> String {
    let seconds = seconds.max(0);
    if seconds >= 3600 {
        format!("{}:{:02}:{:02}", seconds / 3600, seconds % 3600 / 60, seconds % 60)
    } else {
        format!("{:02}:{:02}", seconds / 60, seconds % 60)
    }
}

/// Wire every Store callback to the controller.
fn bind(app: &Shared, window: &InstallerWindow) {
    let store = window.global::<Store>();
    macro_rules! on {
        ($method:ident, |$this:ident, $store:ident $(, $arg:ident : $ty:ty)*| $body:block) => {{
            let weak = Rc::downgrade(app);
            let window_weak = window.as_weak();
            store.$method(move |$($arg: $ty),*| {
                let (Some(app), Some(window)) = (weak.upgrade(), window_weak.upgrade()) else { return Default::default() };
                let $store = window.global::<Store>();
                #[allow(unused_mut)]
                let mut $this = app.borrow_mut();
                $body
            });
        }};
    }

    on!(on_navigate, |this, store, screen: SharedString| {
        store.set_screen(screen.clone());
        this.draft(json!({"screen": screen.as_str()}));
    });
    on!(on_open_sheet, |this, store, sheet: SharedString| {
        match sheet.as_str() {
            "timezone" => this.open_picker(&store),
            "log" => {
                store.set_usb_message(s(""));
                this.sheet_opened = Some(Instant::now());
                this.request_details();
                this.send(json!({"action": "usb-list"}));
            }
            "wifi" => this.send(json!({"action": "network-refresh"})),
            _ => {}
        }
        store.set_sheet(sheet);
    });
    on!(on_close_sheet, |this, store| {
        let _ = &this;
        store.set_sheet(s(""));
    });
    on!(on_start, |this, store| {
        store.set_screen(s("disk"));
        this.draft(json!({"screen": "disk"}));
    });
    on!(on_accept_development, |this, store| {
        let _ = &store;
        this.send(json!({"action": "development"}));
    });
    on!(on_retry, |this, store| {
        let _ = &store;
        this.send(json!({"action": "retry"}));
    });
    on!(on_choose_language, |this, store, key: SharedString| {
        this.draft(json!({"locale": key.as_str()}));
        store.set_sheet(s(""));
    });
    on!(on_choose_layout, |this, store, key: SharedString| {
        let current = this.state.as_ref().map(|s| s.draft.layout.clone()).unwrap_or_default();
        store.set_sheet(s(""));
        if key.as_str() != current {
            store.set_password(s(""));
            store.set_confirm(s(""));
            this.send(json!({"action": "keyboard", "layout": key.as_str()}));
        }
    });
    on!(on_choose_disk, |this, store, path: SharedString| {
        let _ = &store;
        let Some(state) = this.state.as_ref() else { return };
        let available: Vec<&str> = state.disks.iter().filter(|d| d.available).map(|d| d.path.as_str()).collect();
        let target = match path.as_str() {
            "+next" | "+previous" if !available.is_empty() => {
                let current = available.iter().position(|p| *p == state.draft.disk);
                let index = match (path.as_str(), current) {
                    ("+next", Some(i)) => (i + 1).min(available.len() - 1),
                    ("+previous", Some(i)) => i.saturating_sub(1),
                    _ => 0,
                };
                available[index].to_string()
            }
            p if available.contains(&p) => p.to_string(),
            _ => return,
        };
        this.draft(json!({"disk": target}));
    });
    on!(on_toggle_encrypted, |this, store| {
        let _ = &store;
        let encrypted = this.state.as_ref().map(|s| s.draft.encrypted).unwrap_or(true);
        this.draft(json!({"encrypted": !encrypted}));
    });
    on!(on_toggle_all_disks, |this, store| {
        store.set_show_all_disks(!store.get_show_all_disks());
        if let Some(state) = this.state.clone() {
            this.apply_disks(&store, &state);
        }
    });
    on!(on_rescan, |this, store| {
        let _ = &store;
        this.send(json!({"action": "rescan"}));
    });
    on!(on_full_name_edited, |this, store, text: SharedString| {
        let mut values = json!({"fullName": text.as_str()});
        if !this.user_edited {
            let suggestion = names::suggest(&text);
            store.set_username(s(&suggestion));
            values["username"] = json!(suggestion);
            values["userEdited"] = json!(false);
            if !this.host_edited {
                store.set_hostname(s(names::hostname_for(&suggestion)));
            }
        }
        if names::full_name_problem(&text).is_none() {
            this.draft(values);
        }
        this.update_account(&store, "", "");
    });
    let filter_store = window.as_weak();
    store.on_filter_name(move |text, caret| {
        let _ = &filter_store;
        let result = names::filter(&text, caret.max(0) as usize);
        Filtered { text: s(result.text), caret: result.caret as i32, note: s(result.note) }
    });
    on!(on_username_edited, |this, store, text: SharedString, note: SharedString| {
        // The filtered text, before the field shows it.
        store.set_username(text.clone());
        this.user_edited = !text.is_empty();
        if !this.host_edited {
            store.set_hostname(s(names::hostname_for(&text)));
        }
        this.draft(json!({"username": text.as_str(), "userEdited": this.user_edited}));
        this.update_account(&store, &note, "");
    });
    on!(on_hostname_edited, |this, store, text: SharedString, note: SharedString| {
        store.set_hostname(text.clone());
        this.host_edited = !text.is_empty();
        store.set_host_edited(this.host_edited);
        this.draft(json!({"hostname": text.as_str(), "hostEdited": this.host_edited}));
        this.update_account(&store, "", &note);
    });
    on!(on_passwords_edited, |this, store| {
        this.update_account(&store, "", "");
    });
    on!(on_continue_account, |this, store| {
        this.update_account(&store, "", "");
        if !store.get_can_review() {
            return;
        }
        store.set_review_busy(true);
        let request = json!({
            "action": "review",
            "password": store.get_password().as_str(),
            "confirm": store.get_confirm().as_str(),
        });
        this.send(request);
    });
    on!(on_tz_query_edited, |this, store, _text: SharedString| {
        this.refresh_picker(&store);
    });
    on!(on_tz_pick, |this, store, id: SharedString| {
        this.pick(&store, &id);
    });
    on!(on_tz_use, |this, store| {
        this.use_pick(&store);
    });
    on!(on_tz_toggle_fixed, |this, store| {
        store.set_tz_fixed(!store.get_tz_fixed());
        this.refresh_picker(&store);
    });
    on!(on_tz_detect, |this, store| {
        store.set_tz_detecting(true);
        this.send(json!({"action": "detect-region"}));
    });
    on!(on_tz_map_click, |this, store, fx: f32, fy: f32| {
        let (lat, lon) = this.mask.coordinates(fx as f64, fy as f64);
        let id = this.zones.as_ref().and_then(|z| z.nearest(lat, lon)).map(|i| this.zones.as_ref().unwrap().zones[i].id.clone());
        if let Some(id) = id {
            this.pick(&store, &id);
        }
    });
    on!(on_tz_map_hover, |this, store, fx: f32, fy: f32| {
        if fx < 0.0 || fy < 0.0 {
            store.set_tz_hover(s(""));
            return;
        }
        let (lat, lon) = this.mask.coordinates(fx as f64, fy as f64);
        let now = this.now();
        if let Some(zones) = this.zones.as_ref() {
            if let Some(i) = zones.nearest(lat, lon) {
                let zone = &zones.zones[i];
                store.set_tz_hover(s(format!("{} · {}", zone.city, zones.clock(&zone.id, now, false))));
                store.set_tz_hover_x(fx);
                store.set_tz_hover_y(fy);
            }
        }
    });
    on!(on_tz_key, |this, store, key: SharedString| {
        let Some(zones) = this.zones.as_ref() else { return };
        if key.as_str() == "enter" {
            if !this.tz_hits.iter().any(|h| zones.zones[h.index].id == this.tz_pick) {
                if let Some(first) = this.tz_hits.first() {
                    this.tz_pick = zones.zones[first.index].id.clone();
                }
            }
            this.use_pick(&store);
            return;
        }
        if this.tz_hits.is_empty() {
            return;
        }
        let current = this.tz_hits.iter().position(|h| zones.zones[h.index].id == this.tz_pick);
        let next = match (key.as_str(), current) {
            ("down", Some(i)) => (i + 1).min(this.tz_hits.len() - 1),
            ("up", Some(i)) => i.saturating_sub(1),
            _ => 0,
        };
        let id = zones.zones[this.tz_hits[next].index].id.clone();
        this.pick(&store, &id);
    });
    on!(on_back_to_account, |this, store| {
        let _ = &store;
        this.send(json!({"action": "back"}));
    });
    on!(on_install, |this, store| {
        let _ = &store;
        this.send(json!({"action": "install"}));
    });
    on!(on_change, |this, store, action: SharedString| {
        match action.as_str() {
            "account" => this.send(json!({"action": "back"})),
            "disk" => {
                this.send(json!({"action": "back"}));
                this.draft(json!({"screen": "disk"}));
            }
            "timezone" => {
                this.open_picker(&store);
                store.set_sheet(s("timezone"));
            }
            other => store.set_sheet(s(other)),
        }
    });
    on!(on_toggle_app, |this, store, id: SharedString| {
        let _ = &store;
        let on = this.state.as_ref().and_then(|s| s.draft.apps.get(id.as_str()).copied()).unwrap_or(true);
        let mut apps = HashMap::new();
        apps.insert(id.to_string(), !on);
        this.draft(json!({"apps": apps}));
    });
    on!(on_set_nvidia_open, |this, store, open: bool| {
        let _ = &store;
        this.draft(json!({"nvidiaOpen": open}));
    });
    on!(on_wifi_select, |this, store, index: i32| {
        let Some(state) = this.state.as_ref() else { return };
        let Some(network) = state.network.wifi.networks.get(index as usize).cloned() else { return };
        if network.connected {
            return;
        }
        let security = network.security.to_uppercase();
        let open = security.is_empty() || security == "--" || security == "NONE" || security == "OPEN";
        if open || network.known {
            this.send(json!({"action": "network-connect", "network": {
                "ssid": network.ssid, "security": network.security, "uuid": network.uuid, "saved": network.known}}));
            this.toast(&store, &format!("Connecting to {}…", network.ssid));
        } else {
            store.set_wifi_selected(index);
        }
    });
    on!(on_wifi_connect, |this, store, index: i32, password: SharedString, identity: SharedString| {
        let Some(state) = this.state.as_ref() else { return };
        let Some(network) = state.network.wifi.networks.get(index as usize).cloned() else { return };
        this.send(json!({"action": "network-connect", "network": {
            "ssid": network.ssid, "security": network.security, "password": password.as_str(), "identity": identity.as_str()}}));
        store.set_wifi_selected(-1);
        this.toast(&store, &format!("Connecting to {}…", network.ssid));
    });
    on!(on_network_refresh, |this, store| {
        let _ = &store;
        this.send(json!({"action": "network-refresh"}));
    });
    on!(on_tool, |this, store, tool: SharedString| {
        store.set_sheet(s(""));
        match tool.as_str() {
            "shell" => this.send(json!({"action": "shell"})),
            "text-installer" => this.send(json!({"action": "text-installer"})),
            _ => {}
        }
    });
    on!(on_request_details, |this, store| {
        let _ = &store;
        this.request_details();
        this.send(json!({"action": "usb-list"}));
    });
    on!(on_usb_save, |this, store, device: SharedString| {
        store.set_usb_message(s("Saving…"));
        this.send(json!({"action": "usb-save", "device": device.as_str()}));
    });
    on!(on_start_over, |this, store| {
        store.set_sheet(s(""));
        this.send(json!({"action": "start-over"}));
    });
    on!(on_power, |this, store, kind: SharedString| {
        store.set_sheet(s(""));
        let installing = this.state.as_ref().is_some_and(|s| s.phase == "installing");
        if installing {
            this.toast(&store, "Installation is in progress. Keep the computer on until it finishes.");
            return;
        }
        this.send(json!({"action": "power", "kind": kind.as_str()}));
    });
}

#[cfg(test)]
mod tests {
    use super::format_elapsed;

    #[test]
    fn elapsed_time_reads_naturally() {
        assert_eq!(format_elapsed(0), "00:00");
        assert_eq!(format_elapsed(754), "12:34");
        assert_eq!(format_elapsed(3661), "1:01:01");
    }
}
