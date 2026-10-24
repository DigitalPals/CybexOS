//! cybexos-installer: the installer screen on tty1.
//!
//! Runs unprivileged in a logind session on seat0 (see the NixOS unit), draws
//! with Slint's software renderer straight to KMS/DRM and reads input through
//! libinput. It holds no installation state: `cybexos-installerd` does.
//!
//! Exit codes: 0 asks systemd for a restart (a new keyboard layout), and 75
//! means no usable display, after the daemon was asked to start the text
//! installer on tty1 instead.
//!
//! Environment: CYBEXOS_INSTALLER_SOCKET, CYBEXOS_INSTALLER_ZOOM (number or
//! "auto"), CYBEXOS_INSTALLER_RESOLUTION (WIDTHxHEIGHT), XKB_DEFAULT_LAYOUT.

use std::cell::RefCell;
use std::rc::Rc;
use std::time::Duration;

use cybexos_installer::client::{Client, Event};
use cybexos_installer::ui::{App, Shared};
use cybexos_installer::{zoom, InstallerWindow};
use slint::ComponentHandle;

const NO_DISPLAY: i32 = 75;

thread_local! {
    static APP: RefCell<Option<Shared>> = const { RefCell::new(None) };
}

fn configure_display() {
    if std::env::var_os("SLINT_BACKEND").is_none() {
        std::env::set_var("SLINT_BACKEND", "linuxkms-software");
    }
    if std::env::var_os("SLINT_SCALE_FACTOR").is_none() {
        let factor = match std::env::var("CYBEXOS_INSTALLER_ZOOM") {
            Ok(value) if value != "auto" => value.parse().unwrap_or(1.0),
            _ => zoom::zoom_for(zoom::detect_resolution()),
        };
        std::env::set_var("SLINT_SCALE_FACTOR", format!("{factor}"));
        eprintln!("cybexos-installer: display zoom {factor}");
    }
}

fn request_text_installer() {
    use std::io::Write;
    if let Ok(mut stream) = std::os::unix::net::UnixStream::connect(cybexos_installer::client::socket_path()) {
        let _ = stream.write_all(b"{\"action\":\"text-installer\"}\n");
    }
}

fn main() {
    configure_display();
    // A native GPU driver can still be binding when the unit starts; retry
    // before concluding that this machine has no usable display.
    let mut window = None;
    for attempt in 0..4 {
        match InstallerWindow::new() {
            Ok(created) => {
                window = Some(created);
                break;
            }
            Err(error) => {
                eprintln!("cybexos-installer: display unavailable ({error}), attempt {}", attempt + 1);
                std::thread::sleep(Duration::from_secs(2));
            }
        }
    }
    let Some(window) = window else {
        eprintln!("cybexos-installer: no usable display; switching tty1 to the text installer");
        request_text_installer();
        std::process::exit(NO_DISPLAY);
    };
    let client = Client::start(|event: Event| {
        APP.with(|app| {
            if let Some(app) = app.borrow().as_ref() {
                App::handle(app, event);
            }
        });
    });
    let app = App::new(&window, client);
    APP.with(|slot| *slot.borrow_mut() = Some(Rc::clone(&app)));
    if let Err(error) = window.run() {
        eprintln!("cybexos-installer: event loop stopped ({error})");
        std::process::exit(1);
    }
}
