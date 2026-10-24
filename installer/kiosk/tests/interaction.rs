//! Exercise the actual Slint tree and controller, without display devices.
use nerdos_installer::{
    client::Client,
    protocol::{State, Static},
    ui::App,
    InstallerWindow, Store,
};
use slint::platform::software_renderer::{MinimalSoftwareWindow, RepaintBufferType};
use slint::platform::{Key, Platform, WindowAdapter, WindowEvent};
use slint::{ComponentHandle, PhysicalSize};
use std::{cell::Cell, rc::Rc};

struct Headless(Rc<MinimalSoftwareWindow>);
impl Platform for Headless {
    fn create_window_adapter(&self) -> Result<Rc<dyn WindowAdapter>, slint::PlatformError> {
        Ok(self.0.clone())
    }
}

fn setup() -> (
    InstallerWindow,
    nerdos_installer::ui::Shared,
    Rc<MinimalSoftwareWindow>,
) {
    let surface = MinimalSoftwareWindow::new(RepaintBufferType::NewBuffer);
    slint::platform::set_platform(Box::new(Headless(surface.clone()))).unwrap();
    surface.set_size(PhysicalSize::new(1280, 800));
    let ui = InstallerWindow::new().unwrap();
    ui.show().unwrap();
    let app = App::new(&ui, Client::offline());
    app.borrow_mut().apply_static(Static {
        languages: vec![
            ("en_US.UTF-8".into(), "English".into()),
            ("de_DE.UTF-8".into(), "German".into()),
        ],
        layouts: vec![("us".into(), "US".into(), "us".into())],
        applications: vec![("developer".into(), "Development".into(), "Tools".into())],
        ..Static::default()
    });
    app.borrow_mut().apply_state(State {
        phase: "setup".into(),
        ..State::default()
    });
    draw(&surface);
    (ui, app, surface)
}

fn draw(surface: &MinimalSoftwareWindow) {
    slint::platform::update_timers_and_animations();
    let mut pixels = vec![slint::Rgb8Pixel::default(); 1280 * 800];
    surface.draw_if_needed(|r| {
        r.render(&mut pixels, 1280);
    });
}

fn key(
    ui: &InstallerWindow,
    surface: &MinimalSoftwareWindow,
    text: impl Into<slint::SharedString>,
) {
    let text = text.into();
    ui.window()
        .dispatch_event(WindowEvent::KeyPressed { text: text.clone() });
    ui.window()
        .dispatch_event(WindowEvent::KeyReleased { text });
    draw(surface);
}

#[test]
fn close_is_reachable_and_tab_stays_in_every_sheet() {
    let (ui, _app, surface) = setup();
    let store = ui.global::<Store>();
    let background = Rc::new(Cell::new(0));
    let count = background.clone();
    store.on_navigate(move |_| count.set(count.get() + 1));
    for sheet in [
        "log", "wifi", "keyboard", "language", "apps", "gpu", "timezone",
    ] {
        store.invoke_open_sheet(sheet.into());
        draw(&surface);
        // Initial sheet scope -> first interactive control, Close.
        key(&ui, &surface, Key::Tab);
        key(&ui, &surface, Key::Return);
        assert!(
            store.get_sheet().is_empty(),
            "Close not reachable in {sheet}"
        );
        // From any tab position Escape still closes, and background actions
        // cannot receive focus under the modal.
        store.invoke_open_sheet(sheet.into());
        draw(&surface);
        for _ in 0..45 {
            key(&ui, &surface, Key::Tab);
        }
        key(&ui, &surface, Key::Escape);
        assert!(
            store.get_sheet().is_empty(),
            "Escape not handled in {sheet}"
        );
        store.invoke_open_sheet(sheet.into());
        draw(&surface);
        ui.window().dispatch_event(WindowEvent::KeyPressed {
            text: Key::Shift.into(),
        });
        for _ in 0..45 {
            key(&ui, &surface, Key::Tab);
        }
        ui.window().dispatch_event(WindowEvent::KeyReleased {
            text: Key::Shift.into(),
        });
        key(&ui, &surface, Key::Escape);
        assert!(store.get_sheet().is_empty(), "Shift+Tab escaped {sheet}");
    }
    assert_eq!(background.get(), 0);
}

#[test]
fn snapshots_preserve_list_identity_and_selection_focus() {
    let (ui, app, surface) = setup();
    let store = ui.global::<Store>();
    store.invoke_open_sheet("language".into());
    draw(&surface);
    key(&ui, &surface, Key::Tab); // Close
    key(&ui, &surface, Key::Tab); // English
    key(&ui, &surface, Key::Tab); // German
    let before = store.get_languages();
    let mut next = State {
        phase: "setup".into(),
        ..State::default()
    };
    next.network.busy = true;
    app.borrow_mut().apply_state(next.clone());
    draw(&surface);
    assert!(
        before == store.get_languages(),
        "model was replaced on network update"
    );
    let picked = Rc::new(Cell::new(false));
    let result = picked.clone();
    store.on_choose_language(move |language| result.set(language == "de_DE.UTF-8"));
    key(&ui, &surface, Key::Return);
    assert!(picked.get(), "snapshot lost focus on German row");
    // Updating the selection also preserves the model and focused delegate.
    next.draft.locale = "de_DE.UTF-8".into();
    app.borrow_mut().apply_state(next);
    assert!(before == store.get_languages());
}

#[test]
fn repeated_enter_cannot_activate_install_or_other_actions() {
    let (ui, _app, surface) = setup();
    let store = ui.global::<Store>();
    store.set_screen("review".into());
    draw(&surface);
    let installs = Rc::new(Cell::new(0));
    let count = installs.clone();
    store.on_install(move || count.set(count.get() + 1));
    // Tab through every control while simulating the repeat from a held Enter.
    for _ in 0..25 {
        key(&ui, &surface, Key::Tab);
        ui.window().dispatch_event(WindowEvent::KeyPressRepeated {
            text: Key::Return.into(),
        });
        draw(&surface);
    }
    assert_eq!(installs.get(), 0);
}

#[test]
fn unchanged_snapshots_do_not_repaint_the_screen() {
    let (_ui, app, surface) = setup();
    let state = State {
        phase: "setup".into(),
        ..State::default()
    };
    app.borrow_mut().apply_state(state.clone());
    draw(&surface);
    let started = std::time::Instant::now();
    let mut frames = 0;
    let mut pixels = vec![slint::Rgb8Pixel::default(); 1280 * 800];
    for _ in 0..100 {
        app.borrow_mut().apply_state(state.clone());
        slint::platform::update_timers_and_animations();
        surface.draw_if_needed(|renderer| {
            frames += 1;
            renderer.render(&mut pixels, 1280);
        });
    }
    eprintln!(
        "100 unchanged snapshots: {} ms, {frames} frames",
        started.elapsed().as_millis()
    );
    assert_eq!(
        frames, 0,
        "unchanged state should not schedule a framebuffer repaint"
    );
}

fn log_pixels(surface: &MinimalSoftwareWindow) -> Vec<slint::Rgb8Pixel> {
    surface.request_redraw();
    let mut pixels = vec![slint::Rgb8Pixel::default(); 1280 * 800];
    surface.draw_if_needed(|renderer| {
        renderer.render(&mut pixels, 1280);
    });
    (220..400)
        .flat_map(|y| pixels[y * 1280 + 100..y * 1280 + 700].iter().copied())
        .collect()
}

#[test]
fn log_scrolls_with_keyboard_and_refresh_keeps_the_reading_position() {
    let (ui, _app, surface) = setup();
    let store = ui.global::<Store>();
    let mut text: String = (0..250)
        .map(|i| format!("Log line {i:03}: installation diagnostics\n"))
        .collect();
    store.set_details(text.clone().into());
    store.invoke_open_sheet("log".into());
    draw(&surface);
    key(&ui, &surface, Key::Home);
    let head = log_pixels(&surface);
    key(&ui, &surface, Key::End);
    let tail = log_pixels(&surface);
    assert!(
        head != tail,
        "Home and End must scroll the actual rendered log"
    );
    key(&ui, &surface, Key::PageUp);
    assert!(tail != log_pixels(&surface), "Page Up must scroll the log");
    key(&ui, &surface, Key::Home);
    text.push_str("New diagnostics while reading\n");
    store.set_details(text.into());
    draw(&surface);
    assert!(
        head == log_pixels(&surface),
        "refresh moved the reader to the end"
    );
}

#[test]
fn wifi_refresh_preserves_credentials_but_reordering_clears_selection() {
    use nerdos_installer::protocol::WifiNetwork;
    use std::cell::RefCell;
    let (ui, app, surface) = setup();
    let store = ui.global::<Store>();
    let mut state = State {
        phase: "setup".into(),
        ..State::default()
    };
    state.network.wifi.interface = "wlan0".into();
    state.network.wifi.networks = vec![WifiNetwork {
        ssid: "Test network".into(),
        security: "WPA2".into(),
        signal: 80,
        ..WifiNetwork::default()
    }];
    app.borrow_mut().apply_state(state.clone());
    store.invoke_open_sheet("wifi".into());
    draw(&surface);
    for _ in 0..3 {
        key(&ui, &surface, Key::Tab);
    } // Close, Refresh, network
    key(&ui, &surface, Key::Return);
    assert_eq!(store.get_wifi_selected(), 0);
    key(&ui, &surface, Key::Tab); // Password
    for letter in "testsecret".chars() {
        key(&ui, &surface, letter.to_string());
    }
    state.network.wifi.networks[0].signal = 70;
    app.borrow_mut().apply_state(state.clone());
    draw(&surface);
    let password = Rc::new(RefCell::new(String::new()));
    let observed = password.clone();
    store.on_wifi_connect(move |_, secret, _| *observed.borrow_mut() = secret.to_string());
    key(&ui, &surface, Key::Return);
    assert_eq!(*password.borrow(), "testsecret");
    state.network.wifi.networks.insert(
        0,
        WifiNetwork {
            ssid: "Other network".into(),
            ..WifiNetwork::default()
        },
    );
    app.borrow_mut().apply_state(state);
    assert_eq!(
        store.get_wifi_selected(),
        -1,
        "credentials could move to another SSID"
    );
}
