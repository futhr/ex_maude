//! ExMaude NIF - Rust NIF for managing Maude subprocess
//!
//! This NIF provides lower-latency communication with Maude by managing
//! the subprocess directly from Rust instead of going through Elixir ports.
//!
//! ## Safety
//!
//! NIFs run in the same OS process as the BEAM VM. A crash in the NIF
//! (segfault, panic, etc.) will crash the entire Erlang VM.
//!
//! Use the `:port` backend (default) for production unless profiling shows
//! the latency improvement from NIF is necessary.

use rustler::{NifResult, ResourceArc};
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;

/// Wrapper around the Maude subprocess with synchronized I/O handles.
pub struct MaudeProcess {
    child: Mutex<Child>,
    stdin: Mutex<std::process::ChildStdin>,
    stdout: Mutex<BufReader<std::process::ChildStdout>>,
}

#[rustler::resource_impl]
impl rustler::Resource for MaudeProcess {}

/// Start a new Maude subprocess.
///
/// # Arguments
/// * `maude_path` - Path to the Maude executable
///
/// # Returns
/// * `Ok(ResourceArc<MaudeProcess>)` - Handle to the running process
/// * `Err` - If spawning fails
#[rustler::nif]
fn start(maude_path: String) -> NifResult<ResourceArc<MaudeProcess>> {
    let mut child = Command::new(&maude_path)
        .args(["-no-banner", "-no-wrap", "-no-advise", "-interactive"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| rustler::Error::Term(Box::new(format!("spawn failed: {}", e))))?;

    let stdin = child
        .stdin
        .take()
        .ok_or_else(|| rustler::Error::Term(Box::new("failed to get stdin".to_string())))?;

    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| rustler::Error::Term(Box::new("failed to get stdout".to_string())))?;

    let process = MaudeProcess {
        child: Mutex::new(child),
        stdin: Mutex::new(stdin),
        stdout: Mutex::new(BufReader::new(stdout)),
    };

    // Read until first prompt to ensure Maude is ready
    read_until_prompt(&process)?;

    Ok(ResourceArc::new(process))
}

/// Execute a Maude command and return the output.
///
/// This function uses a dirty CPU scheduler to avoid blocking the
/// main BEAM schedulers during I/O operations.
///
/// # Arguments
/// * `process` - Handle to the Maude process
/// * `command` - Maude command to execute
///
/// # Returns
/// * `Ok(String)` - Command output (without the prompt)
/// * `Err` - If I/O fails
#[rustler::nif(schedule = "DirtyCpu")]
fn execute(process: ResourceArc<MaudeProcess>, command: String) -> NifResult<String> {
    // Write command to Maude stdin
    {
        let mut stdin = process
            .stdin
            .lock()
            .map_err(|e| rustler::Error::Term(Box::new(format!("stdin lock failed: {}", e))))?;

        writeln!(stdin, "{}", command)
            .map_err(|e| rustler::Error::Term(Box::new(format!("write failed: {}", e))))?;

        stdin
            .flush()
            .map_err(|e| rustler::Error::Term(Box::new(format!("flush failed: {}", e))))?;
    }

    // Read response until we see the prompt
    read_until_prompt(&process)
}

/// Stop the Maude subprocess.
///
/// # Arguments
/// * `process` - Handle to the Maude process
#[rustler::nif]
fn stop(process: ResourceArc<MaudeProcess>) -> NifResult<()> {
    let mut child = process
        .child
        .lock()
        .map_err(|e| rustler::Error::Term(Box::new(format!("child lock failed: {}", e))))?;

    // Send quit command first for graceful shutdown
    if let Ok(mut stdin) = process.stdin.lock() {
        let _ = writeln!(stdin, "quit");
        let _ = stdin.flush();
    }

    // Give it a moment to exit gracefully
    std::thread::sleep(std::time::Duration::from_millis(100));

    // Force kill if still running
    let _ = child.kill();
    let _ = child.wait();

    Ok(())
}

/// Check if the Maude subprocess is still running.
///
/// # Arguments
/// * `process` - Handle to the Maude process
///
/// # Returns
/// * `true` if the process is still running
/// * `false` if the process has exited
#[rustler::nif]
fn alive(process: ResourceArc<MaudeProcess>) -> bool {
    match process.child.lock() {
        Ok(mut child) => match child.try_wait() {
            Ok(None) => true,     // Still running
            Ok(Some(_)) => false, // Exited
            Err(_) => false,      // Error checking status
        },
        Err(_) => false, // Lock failed
    }
}

/// Read from Maude stdout until we see the "Maude>" prompt.
fn read_until_prompt(process: &MaudeProcess) -> NifResult<String> {
    let mut stdout = process
        .stdout
        .lock()
        .map_err(|e| rustler::Error::Term(Box::new(format!("stdout lock failed: {}", e))))?;

    let mut output = String::new();
    let mut line = String::new();

    loop {
        line.clear();
        match stdout.read_line(&mut line) {
            Ok(0) => {
                // EOF - process likely exited
                break;
            }
            Ok(_) => {
                // Check if this line contains the prompt
                if line.contains("Maude>") {
                    // Don't include the prompt in output
                    if let Some(before_prompt) = line.split("Maude>").next() {
                        if !before_prompt.is_empty() {
                            output.push_str(before_prompt);
                        }
                    }
                    break;
                }
                output.push_str(&line);
            }
            Err(e) => {
                return Err(rustler::Error::Term(Box::new(format!(
                    "read failed: {}",
                    e
                ))))
            }
        }
    }

    Ok(output.trim().to_string())
}

rustler::init!("Elixir.ExMaude.Backend.NIF.Native");
