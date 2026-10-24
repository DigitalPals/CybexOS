//! The connection to `nerdos-installerd`.
//!
//! A background thread reads newline-delimited JSON and hands each message to
//! the Slint event loop. A separate writer keeps socket I/O off the UI thread.
//! When the daemon restarts, the reader reconnects and the screen resumes from the
//! next snapshot; nothing on screen is the source of truth.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex};
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
    outgoing: Option<mpsc::Sender<(u64, SecretLine)>>,
    generation: Arc<AtomicU64>,
}

// Dropping a queued request also clears its serialized password, including
// requests discarded after a reconnect or a failed write.
struct SecretLine(String);

impl Drop for SecretLine {
    fn drop(&mut self) {
        unsafe {
            for byte in self.0.as_bytes_mut() {
                std::ptr::write_volatile(byte, 0);
            }
        }
    }
}

type Connection = Arc<Mutex<Option<(u64, UnixStream)>>>;

fn writer(connection: Connection) -> mpsc::Sender<(u64, SecretLine)> {
    let (sender, receiver) = mpsc::channel::<(u64, SecretLine)>();
    std::thread::spawn(move || {
        while let Ok((generation, line)) = receiver.recv() {
            if let Some((current, stream)) = connection.lock().unwrap().as_mut() {
                if *current == generation && stream.write_all(line.0.as_bytes()).is_err() {
                    // Wake the reader and reconnect; never replay a queued
                    // password or disk action on a new daemon connection.
                    let _ = stream.shutdown(std::net::Shutdown::Both);
                }
            }
        }
    });
    sender
}

pub enum Event {
    Connected,
    Disconnected,
    Message(Message),
}

impl Client {
    /// Start the reader thread; `deliver` runs on the Slint event loop.
    pub fn start(deliver: impl Fn(Event) + Send + Sync + 'static) -> Self {
        let shared = Arc::new(Mutex::new(None));
        let client = Client {
            outgoing: Some(writer(shared.clone())),
            generation: Arc::new(AtomicU64::new(0)),
        };
        let generation = client.generation.clone();
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
                    let _ = stream.set_write_timeout(Some(Duration::from_millis(250)));
                    let current = generation.fetch_add(1, Ordering::SeqCst) + 1;
                    *shared.lock().unwrap() = Some((current, stream));
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
                                    let _ = slint::invoke_from_event_loop(move || {
                                        d(Event::Message(message))
                                    });
                                }
                            }
                        }
                    }
                    generation.fetch_add(1, Ordering::SeqCst);
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
        let line = SecretLine(text);
        if let Some(sender) = &self.outgoing {
            let _ = sender.send((self.generation.load(Ordering::SeqCst), line));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slow_daemon_does_not_block_the_sender_or_replay_old_requests() {
        let (stream, mut peer) = UnixStream::pair().unwrap();
        stream
            .set_write_timeout(Some(Duration::from_millis(50)))
            .unwrap();
        peer.set_read_timeout(Some(Duration::from_millis(100)))
            .unwrap();
        let connection = Arc::new(Mutex::new(Some((2, stream))));
        let sender = writer(connection.clone());
        // A queued request from a previous connection is discarded.
        sender
            .send((1, SecretLine("old password\n".into())))
            .unwrap();
        sender.send((2, SecretLine("current\n".into()))).unwrap();
        let mut line = String::new();
        BufReader::new(&mut peer).read_line(&mut line).unwrap();
        assert_eq!(line, "current\n");
        // Stop reading until the socket's write buffer fills. Enqueueing must
        // finish while the writer is blocked on that socket.
        let started = std::time::Instant::now();
        for _ in 0..1000 {
            sender.send((2, SecretLine("x".repeat(4096)))).unwrap();
        }
        assert!(started.elapsed() < Duration::from_millis(250));
        drop(sender);
    }
}
