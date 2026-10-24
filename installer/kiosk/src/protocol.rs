//! Messages from `nerdos-installerd` (`nerdos.installer-state.v1`).
//!
//! Every field is optional and unknown fields are ignored, so an older screen
//! keeps working against a newer daemon. A message with another schema is
//! rejected; the screen then shows its reconnecting state.

use std::collections::HashMap;

use serde::Deserialize;
use serde_json::Value;

pub const SCHEMA: &str = "nerdos.installer-state.v1";

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct Static {
    pub schema: String,
    pub zones: Vec<(String, String, f64, f64, String)>,
    pub countries: HashMap<String, String>,
    pub aliases: HashMap<String, String>,
    pub tzdata: String,
    /// `[xkb layout, name, console keymap]`
    pub layouts: Vec<(String, String, String)>,
    /// `[locale, name]`
    pub languages: Vec<(String, String)>,
    /// `[id, name, description]`
    pub applications: Vec<(String, String, String)>,
    pub defaults: HashMap<String, bool>,
    pub reserved: Vec<String>,
    pub version: String,
    pub layout: HashMap<String, Value>,
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
#[serde(default)]
pub struct Disk {
    pub path: String,
    pub serial: String,
    pub model: String,
    pub size: u64,
    pub available: bool,
    pub reason: String,
    pub filesystems: Vec<String>,
    pub bus: String,
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
#[serde(default)]
pub struct WifiNetwork {
    pub ssid: String,
    pub signal: i64,
    pub security: String,
    pub connected: bool,
    pub known: bool,
    pub uuid: String,
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
#[serde(default)]
pub struct Wifi {
    pub interface: String,
    pub networks: Vec<WifiNetwork>,
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
#[serde(default)]
pub struct Network {
    pub busy: bool,
    pub error: String,
    pub message: String,
    pub connected: bool,
    pub kind: String,
    pub interface: String,
    pub name: String,
    pub address: String,
    #[serde(rename = "ethernetCable")]
    pub ethernet_cable: bool,
    pub wifi: Wifi,
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
#[serde(default)]
pub struct Region {
    pub busy: bool,
    pub message: String,
    pub detected: String,
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
#[serde(default)]
pub struct Firmware {
    pub uefi: bool,
    #[serde(rename = "secureBoot")]
    pub secure_boot: bool,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(default)]
pub struct Draft {
    pub screen: String,
    pub disk: String,
    pub encrypted: bool,
    #[serde(rename = "fullName")]
    pub full_name: String,
    pub username: String,
    #[serde(rename = "userEdited")]
    pub user_edited: bool,
    pub hostname: String,
    #[serde(rename = "hostEdited")]
    pub host_edited: bool,
    pub timezone: String,
    #[serde(rename = "tzSource")]
    pub tz_source: String,
    pub locale: String,
    pub layout: String,
    pub apps: HashMap<String, bool>,
    #[serde(rename = "nvidiaOpen")]
    pub nvidia_open: bool,
}

impl Default for Draft {
    fn default() -> Self {
        Draft {
            screen: "welcome".into(),
            disk: String::new(),
            encrypted: true,
            full_name: String::new(),
            username: String::new(),
            user_edited: false,
            hostname: String::new(),
            host_edited: false,
            timezone: "UTC".into(),
            tz_source: "default".into(),
            locale: "en_US.UTF-8".into(),
            layout: "us".into(),
            apps: HashMap::new(),
            nvidia_open: true,
        }
    }
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
#[serde(default)]
pub struct InstallResult {
    pub username: String,
    pub hostname: String,
    pub encrypted: bool,
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
#[serde(default)]
pub struct State {
    pub schema: String,
    pub phase: String,
    pub message: String,
    pub error: String,
    pub stage: i64,
    pub stages: i64,
    pub elapsed: i64,
    pub release: String,
    pub development: bool,
    pub disks: Vec<Disk>,
    pub hardware: HashMap<String, Value>,
    pub network: Network,
    pub region: Region,
    pub firmware: Firmware,
    pub memory: u64,
    pub graphics: Vec<String>,
    pub review: Option<HashMap<String, Value>>,
    pub result: Option<InstallResult>,
    #[serde(rename = "diskTouched")]
    pub disk_touched: bool,
    pub draft: Draft,
    #[serde(rename = "reviewPending")]
    pub review_pending: bool,
}

impl State {
    pub fn nvidia(&self) -> bool {
        self.hardware.get("nvidia").and_then(Value::as_bool).unwrap_or(false)
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct Details {
    pub text: String,
    pub truncated: bool,
    pub error: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct UsbTarget {
    pub device: String,
    pub label: String,
    pub size: u64,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct Usb {
    pub targets: Vec<UsbTarget>,
    pub error: String,
    pub saved: String,
}

#[derive(Debug, Clone)]
pub enum Message {
    Static(Box<Static>),
    State(Box<State>),
    Details(Details),
    Usb(Usb),
    Restart,
}

pub fn parse(line: &str) -> Option<Message> {
    let value: Value = serde_json::from_str(line).ok()?;
    let kind = value.get("type")?.as_str()?.to_string();
    match kind.as_str() {
        "static" | "state" => {
            if value.get("schema").and_then(Value::as_str) != Some(SCHEMA) {
                return None;
            }
            if kind == "static" {
                serde_json::from_value(value).ok().map(|s| Message::Static(Box::new(s)))
            } else {
                serde_json::from_value(value).ok().map(|s| Message::State(Box::new(s)))
            }
        }
        "details" => serde_json::from_value(value).ok().map(Message::Details),
        "usb" => serde_json::from_value(value).ok().map(Message::Usb),
        "restart" => Some(Message::Restart),
        _ => None,
    }
}

pub fn human_size(bytes: u64) -> String {
    if bytes >= 1_000_000_000_000 {
        format!("{:.1} TB", bytes as f64 / 1e12)
    } else {
        format!("{} GB", (bytes as f64 / 1e9).round() as u64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn state_parses_with_unknown_fields_and_rejects_other_schemas() {
        let line = r#"{"type":"state","schema":"nerdos.installer-state.v1","phase":"setup","future":1,
            "disks":[{"path":"/dev/vda","size":85899345920,"available":true}],
            "draft":{"username":"ada","fullName":"Ada"},"hardware":{"nvidia":true}}"#;
        let Some(Message::State(state)) = parse(line) else { panic!("state") };
        assert_eq!(state.phase, "setup");
        assert_eq!(state.draft.username, "ada");
        assert!(state.draft.encrypted, "absent fields keep safe defaults");
        assert!(state.nvidia());
        assert!(parse(r#"{"type":"state","schema":"other","phase":"setup"}"#).is_none());
        assert!(parse("not json").is_none());
    }

    #[test]
    fn sizes_read_like_the_drive_label() {
        assert_eq!(human_size(1_000_204_886_016), "1.0 TB");
        assert_eq!(human_size(500_107_862_016), "500 GB");
    }
}
