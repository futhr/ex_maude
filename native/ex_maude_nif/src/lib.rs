//! ExMaude NIF — Rust-side management of a Maude subprocess.
//!
//! Each `MaudeProcess` owns a child process plus a dedicated reader thread
//! that streams raw stdout chunks onto a `crossbeam_channel`. NIF entry points
//! drain the channel with `recv_timeout`, which gives us per-command deadlines
//! that `std::io` does not offer for child stdout pipes.
//!
//! Byte-level (not line-level) reads are necessary because Maude emits its
//! `Maude>` prompt **without a trailing newline**, so `read_line` would block
//! forever while waiting for the next byte from the user.
//!
//! All blocking entry points (`start`, `execute_with_timeout`, `stop`) run on
//! the `DirtyIo` scheduler — the work is I/O wait on the Maude pipe, not CPU.
//!
//! ## Safety
//!
//! NIFs share the BEAM's OS process. A segfault in this crate crashes the
//! entire VM. Rustler wraps every `#[rustler::nif]` body in
//! `std::panic::catch_unwind`, so Rust `panic!`s become Elixir exceptions,
//! but we still avoid `unwrap` and convert poisoned mutexes to returned
//! errors as a matter of hygiene.

use crossbeam_channel::{unbounded, Receiver, RecvTimeoutError, Sender};
use rustler::{Error, NifResult, ResourceArc};
use std::io::{Read, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Mutex;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

mod atoms {
    rustler::atoms! {
        timeout,
        eof,
        io_error,
        lock_poisoned,
    }
}

const PROMPT: &[u8] = b"Maude>";
const READER_BUF_SIZE: usize = 4096;
const READER_JOIN_TIMEOUT: Duration = Duration::from_millis(200);
const GRACEFUL_QUIT_WAIT: Duration = Duration::from_millis(50);
const STARTUP_TIMEOUT_MS: u64 = 10_000;
static LAST_SPAWNED_PID: AtomicU32 = AtomicU32::new(0);

enum ReaderMsg {
    Data(Vec<u8>),
    Io(String),
    Eof,
}

/// Wrapper around the Maude subprocess and its two reader threads.
///
/// We capture stdout and stderr separately on the Rust side but merge them
/// into a single channel — Maude emits error/warning text on stderr (e.g.
/// `Warning: no module FOO.`) which we need to surface alongside stdout
/// to match the Port backend's `stderr_to_stdout: true` semantics.
pub struct MaudeProcess {
    child: Mutex<Child>,
    stdin: Mutex<ChildStdin>,
    rx: Receiver<ReaderMsg>,
    readers: Mutex<Vec<JoinHandle<()>>>,
    pending: Mutex<Vec<u8>>,
}

#[rustler::resource_impl]
impl rustler::Resource for MaudeProcess {}

impl Drop for MaudeProcess {
    fn drop(&mut self) {
        shutdown_process(self);
    }
}

/// Probe used by `ExMaude.Backend.available?(:nif)` to detect whether
/// Rustler has populated the native function table.
#[rustler::nif]
fn nif_loaded() -> bool {
    true
}

#[rustler::nif]
fn last_spawned_pid() -> u32 {
    LAST_SPAWNED_PID.load(Ordering::Relaxed)
}

/// Start a new Maude subprocess.
#[rustler::nif(schedule = "DirtyIo")]
fn start(maude_path: String) -> NifResult<ResourceArc<MaudeProcess>> {
    start_process(maude_path, STARTUP_TIMEOUT_MS)
}

#[rustler::nif(schedule = "DirtyIo")]
fn start_with_timeout(
    maude_path: String,
    startup_timeout_ms: u64,
) -> NifResult<ResourceArc<MaudeProcess>> {
    start_process(maude_path, startup_timeout_ms)
}

fn start_process(
    maude_path: String,
    startup_timeout_ms: u64,
) -> NifResult<ResourceArc<MaudeProcess>> {
    let mut child = Command::new(&maude_path)
        .args(["-no-banner", "-no-wrap", "-no-advise", "-interactive"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| io_error(format!("spawn failed: {e}")))?;

    LAST_SPAWNED_PID.store(child.id(), Ordering::Relaxed);

    let Some(stdin) = child.stdin.take() else {
        terminate_child(&mut child);
        return Err(io_error("failed to capture stdin"));
    };

    let Some(stdout) = child.stdout.take() else {
        terminate_child(&mut child);
        return Err(io_error("failed to capture stdout"));
    };

    let Some(stderr) = child.stderr.take() else {
        terminate_child(&mut child);
        return Err(io_error("failed to capture stderr"));
    };

    let (tx, rx) = unbounded::<ReaderMsg>();
    let stdout_handle = spawn_reader(Box::new(stdout), tx.clone(), "stdout");
    let stderr_handle = spawn_reader(Box::new(stderr), tx, "stderr");

    let process = MaudeProcess {
        child: Mutex::new(child),
        stdin: Mutex::new(stdin),
        rx,
        readers: Mutex::new(vec![stdout_handle, stderr_handle]),
        pending: Mutex::new(Vec::new()),
    };

    if let Err(error) = read_until_prompt(&process, startup_timeout_ms) {
        shutdown_process(&process);
        return Err(error);
    }

    Ok(ResourceArc::new(process))
}

/// Execute a Maude command, returning everything before the next prompt.
///
/// `timeout_ms` is the per-command deadline. On timeout, the subprocess is
/// left running but in an indeterminate state — the Elixir wrapper stops
/// the worker so the pool replaces it with a fresh process.
#[rustler::nif(schedule = "DirtyIo")]
fn execute_with_timeout(
    process: ResourceArc<MaudeProcess>,
    command: String,
    timeout_ms: u64,
) -> NifResult<String> {
    {
        let mut stdin = process.stdin.lock().map_err(|_| poison_error("stdin"))?;
        writeln!(stdin, "{command}").map_err(|e| io_error(format!("write failed: {e}")))?;
        stdin
            .flush()
            .map_err(|e| io_error(format!("flush failed: {e}")))?;
    }

    read_until_prompt(&process, timeout_ms)
}

/// Stop the subprocess.
#[rustler::nif(schedule = "DirtyIo")]
fn stop(process: ResourceArc<MaudeProcess>) -> NifResult<()> {
    // Best-effort graceful quit. The order matters:
    //   1. Send `quit .` so Maude exits cleanly when its input parser settles.
    //   2. Sleep briefly to let it finish.
    //   3. Force-kill (idempotent if already exited).
    //   4. Poll-wait with `try_wait` so we don't block forever if waitpid
    //      hangs on a wedged child.
    //   5. Join the reader threads (bounded).

    shutdown_process(&process);
    Ok(())
}

#[rustler::nif]
fn child_pid(process: ResourceArc<MaudeProcess>) -> NifResult<u32> {
    let child = process.child.lock().map_err(|_| poison_error("child"))?;
    Ok(child.id())
}

fn wait_with_timeout(child: &mut Child, timeout: Duration) {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        match child.try_wait() {
            Ok(Some(_)) => return,
            Ok(None) => thread::sleep(Duration::from_millis(5)),
            Err(_) => return,
        }
    }
}

/// Check whether the subprocess is still running.
#[rustler::nif]
fn alive(process: ResourceArc<MaudeProcess>) -> bool {
    let Ok(mut child) = process.child.lock() else {
        return false;
    };

    matches!(child.try_wait(), Ok(None))
}

fn spawn_reader(
    mut reader: Box<dyn Read + Send>,
    tx: Sender<ReaderMsg>,
    source: &'static str,
) -> JoinHandle<()> {
    thread::spawn(move || {
        let mut buf = [0u8; READER_BUF_SIZE];

        loop {
            match reader.read(&mut buf) {
                Ok(0) => {
                    // Only the stdout reader announces EOF — stderr can EOF
                    // long before stdout (Maude doesn't always write to it),
                    // and a spurious EOF would short-circuit recv_timeout.
                    if source == "stdout" {
                        let _ = tx.send(ReaderMsg::Eof);
                    }
                    return;
                }
                Ok(n) => {
                    if tx.send(ReaderMsg::Data(buf[..n].to_vec())).is_err() {
                        return;
                    }
                }
                Err(e) => {
                    let _ = tx.send(ReaderMsg::Io(format!("{source} read failed: {e}")));
                    return;
                }
            }
        }
    })
}

/// Drain stdout chunks into a rolling buffer until `"Maude>"` is found.
fn read_until_prompt(process: &MaudeProcess, timeout_ms: u64) -> NifResult<String> {
    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    let mut buf = process
        .pending
        .lock()
        .map_err(|_| poison_error("pending"))?
        .split_off(0);

    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(timeout_error(timeout_ms));
        }

        match process.rx.recv_timeout(remaining) {
            Ok(ReaderMsg::Data(chunk)) => {
                buf.extend_from_slice(&chunk);

                if let Some(idx) = find_subslice(&buf, PROMPT) {
                    let prefix = &buf[..idx];
                    let text = String::from_utf8_lossy(prefix).trim().to_string();

                    let remainder = buf[(idx + PROMPT.len())..].to_vec();
                    *process
                        .pending
                        .lock()
                        .map_err(|_| poison_error("pending"))? = remainder;

                    return Ok(text);
                }
            }
            Ok(ReaderMsg::Eof) => return Err(eof_error()),
            Ok(ReaderMsg::Io(msg)) => return Err(io_error(msg)),
            Err(RecvTimeoutError::Timeout) => return Err(timeout_error(timeout_ms)),
            Err(RecvTimeoutError::Disconnected) => return Err(eof_error()),
        }
    }
}

fn shutdown_process(process: &MaudeProcess) {
    if let Ok(mut stdin) = process.stdin.lock() {
        let _ = writeln!(stdin, "quit .");
        let _ = stdin.flush();
    }

    thread::sleep(GRACEFUL_QUIT_WAIT);

    if let Ok(mut child) = process.child.lock() {
        terminate_child(&mut child);
    }

    if let Ok(mut readers) = process.readers.lock() {
        for handle in readers.drain(..) {
            join_with_timeout(handle, READER_JOIN_TIMEOUT);
        }
    }
}

fn terminate_child(child: &mut Child) {
    if matches!(child.try_wait(), Ok(None)) {
        let _ = child.kill();
    }
    wait_with_timeout(child, READER_JOIN_TIMEOUT);
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

fn join_with_timeout(handle: JoinHandle<()>, timeout: Duration) {
    // std::thread::JoinHandle has no timed join — poll cheaply for `is_finished`
    // and bail out after `timeout`. The reader is bounded by `read` on a piped
    // stdout that has already been closed by `child.kill()`, so this normally
    // returns instantly.
    let deadline = Instant::now() + timeout;

    while Instant::now() < deadline {
        if handle.is_finished() {
            let _ = handle.join();
            return;
        }
        thread::sleep(Duration::from_millis(5));
    }
}

// Errors are returned to Elixir as `{:error, term}` (Rustler's standard
// `Error::Term` wrapping), where `term` is one of:
//
//   * `{:timeout, ms}`
//   * `:eof`
//   * `{:io_error, msg}`
//   * `{:lock_poisoned, what}`
//
// The wrapper module in `lib/ex_maude/backend/nif.ex` pattern-matches on these.

fn timeout_error(ms: u64) -> Error {
    Error::Term(Box::new((atoms::timeout(), ms)))
}

fn eof_error() -> Error {
    Error::Term(Box::new(atoms::eof()))
}

fn io_error(msg: impl Into<String>) -> Error {
    Error::Term(Box::new((atoms::io_error(), msg.into())))
}

fn poison_error(what: &'static str) -> Error {
    Error::Term(Box::new((atoms::lock_poisoned(), what.to_string())))
}

rustler::init!("Elixir.ExMaude.Backend.NIF.Native");
