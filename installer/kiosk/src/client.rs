//! The connection to `nerdos-installerd`.
//!
//! A background thread reads newline-delimited JSON and hands each message to
//! the Slint event loop. Requests are written from the UI thread. When the
//! daemon restarts, the thread reconnects and the screen resumes from the
//! next snapshot; nothing on screen is the source of truth.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::Value;

use crate::protocol::{parse, Message};

const MAX_LINE: usize = 1024 * 1024;

pub fn socket_path() -> PathBuf {
    std::env::var_os("NERDOS_INSTALLER_SOCKET")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/nerdos-installer/control.sock"))
}

#[derive(Clone, Default)]
pub struct Client {
    stream: Arc<Mutex<Option<UnixStream>>>,
}

pub enum Event {
    Connected,
    Disconnected,
    Message(Message),
}

impl Client {
    /// Start the reader thread; `deliver` runs on the Slint event loop.
    pub fn start(deliver: impl Fn(Event) + Send + Sync + 'static) -> Self {
        let client = Client::default();
        let shared = client.stream.clone();
        let deliver = Arc::new(deliver);
        std::thread::spawn(move || loop {
            match UnixStream::connect(socket_path()) {
                Ok(stream) => {
                    let reader = match stream.try_clone() {
                        Ok(reader) => reader,
                        Err(_) => {
                            std::thread::sleep(Duration::from_millis(500));
                            continue;
                        }
                    };
                    *shared.lock().unwrap() = Some(stream);
                    let d = deliver.clone();
                    let _ = slint::invoke_from_event_loop(move || d(Event::Connected));
                    let mut reader = BufReader::new(reader);
                    let mut line = String::new();
                    loop {
                        line.clear();
                        match (&mut reader).take(MAX_LINE as u64).read_line(&mut line) {
                            Ok(0) | Err(_) => break,
                            Ok(_) => {
                                if let Some(message) = parse(line.trim_end()) {
                                    let d = deliver.clone();
                                    let _ = slint::invoke_from_event_loop(move || d(Event::Message(message)));
                                }
                            }
                        }
                    }
                    *shared.lock().unwrap() = None;
                    let d = deliver.clone();
                    let _ = slint::invoke_from_event_loop(move || d(Event::Disconnected));
                }
                Err(_) => std::thread::sleep(Duration::from_millis(400)),
            }
        });
        client
    }

    /// A client that never connects (previews and tests).
    pub fn offline() -> Self {
        Client::default()
    }

    pub fn send(&self, request: Value) {
        let mut text = request.to_string();
        text.push('\n');
        if let Some(stream) = self.stream.lock().unwrap().as_mut() {
            let _ = stream.write_all(text.as_bytes());
        }
        // The request may carry a password: overwrite our copy of the bytes.
        unsafe {
            for byte in text.as_bytes_mut() {
                std::ptr::write_volatile(byte, 0);
            }
        }
    }
}
