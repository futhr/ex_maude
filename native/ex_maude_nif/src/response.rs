//! Prompt framing and bounded response reads, independent of the BEAM API.

use crossbeam_channel::{Receiver, RecvTimeoutError};
use std::sync::Mutex;
use std::time::Instant;

const PROMPT: &[u8] = b"Maude> ";

pub enum ReaderMsg {
    Data(Vec<u8>),
    Io(String),
    Eof,
}

#[derive(Debug, PartialEq, Eq)]
pub enum ReadError {
    Timeout(u64),
    ResponseTooLarge(usize),
    Eof,
    Io(String),
    LockPoisoned(&'static str),
}

pub fn read_until_deadline(
    rx: &Receiver<ReaderMsg>,
    pending: &Mutex<Vec<u8>>,
    timeout_ms: u64,
    max_response_bytes: usize,
    deadline: Instant,
) -> Result<String, ReadError> {
    let mut buf = pending
        .lock()
        .map_err(|_| ReadError::LockPoisoned("pending"))?
        .split_off(0);

    let mut scan_start = 0;
    loop {
        if let Some(idx) = find_prompt_boundary(&buf, scan_start) {
            if idx > max_response_bytes {
                return Err(ReadError::ResponseTooLarge(max_response_bytes));
            }

            let prefix = &buf[..idx];
            let text = std::str::from_utf8(prefix)
                .map_err(|error| ReadError::Io(format!("invalid UTF-8 in Maude output: {error}")))?
                .trim()
                .to_string();

            let remainder = buf[(idx + PROMPT.len())..].to_vec();
            *pending
                .lock()
                .map_err(|_| ReadError::LockPoisoned("pending"))? = remainder;

            return Ok(text);
        }

        if buf.len() > max_response_bytes.saturating_add(PROMPT.len()) {
            return Err(ReadError::ResponseTooLarge(max_response_bytes));
        }

        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(ReadError::Timeout(timeout_ms));
        }

        match rx.recv_timeout(remaining) {
            Ok(ReaderMsg::Data(chunk)) => {
                scan_start = buf.len().saturating_sub(PROMPT.len() - 1);
                buf.extend_from_slice(&chunk);
            }
            Ok(ReaderMsg::Eof) => return Err(ReadError::Eof),
            Ok(ReaderMsg::Io(msg)) => return Err(ReadError::Io(msg)),
            Err(RecvTimeoutError::Timeout) => return Err(ReadError::Timeout(timeout_ms)),
            Err(RecvTimeoutError::Disconnected) => return Err(ReadError::Eof),
        }
    }
}

#[cfg(test)]
thread_local! {
    static SCANNED_WINDOWS: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

fn find_prompt_boundary(haystack: &[u8], start: usize) -> Option<usize> {
    haystack[start..]
        .windows(PROMPT.len())
        .enumerate()
        .map(|(offset, window)| (start + offset, window))
        .find_map(|(idx, window)| {
            #[cfg(test)]
            SCANNED_WINDOWS.with(|count| count.set(count.get() + 1));
            let at_line_start = idx == 0 || matches!(haystack[idx - 1], b'\n' | b'\r');
            (window == PROMPT && at_line_start).then_some(idx)
        })
}

#[cfg(test)]
mod tests {
    use super::find_prompt_boundary;

    #[test]
    fn response_reader_scans_fragmented_output_in_linear_work() {
        use super::*;
        use crossbeam_channel::bounded;
        use std::time::Duration;
        let (tx, rx) = bounded(64);
        let size = 128 * 1024;
        for _ in 0..32 {
            tx.send(ReaderMsg::Data(vec![b'x'; 4096])).unwrap();
        }
        for byte in b"\nMaude> " {
            tx.send(ReaderMsg::Data(vec![*byte])).unwrap();
        }
        let pending = Mutex::new(Vec::new());
        SCANNED_WINDOWS.with(|count| count.set(0));
        let output = read_until_deadline(
            &rx,
            &pending,
            1000,
            size + 1,
            Instant::now() + Duration::from_secs(1),
        )
        .unwrap();
        assert_eq!(output, "x".repeat(size));
        SCANNED_WINDOWS.with(|count| assert!(count.get() < size * 2));
    }

    #[test]
    fn incremental_scan_finds_every_split_prompt() {
        let bytes = b"payload Maude> marker\nMaude> ";
        for split in 0..bytes.len() {
            assert_eq!(find_prompt_boundary(&bytes[..split], 0), None);
            let start = split.saturating_sub(super::PROMPT.len() - 1);
            assert_eq!(find_prompt_boundary(bytes, start), Some(22));
        }
    }

    #[test]
    fn finds_complete_prompt_at_line_boundaries() {
        assert_eq!(find_prompt_boundary(b"Maude> ", 0), Some(0));
        assert_eq!(find_prompt_boundary(b"result\nMaude> ", 0), Some(7));
        assert_eq!(find_prompt_boundary(b"result\rMaude> ", 0), Some(7));
    }

    #[test]
    fn ignores_partial_and_prompt_like_payload_text() {
        assert_eq!(find_prompt_boundary(b"Maude>", 0), None);
        assert_eq!(find_prompt_boundary(b"payload Maude> marker", 0), None);
        assert_eq!(find_prompt_boundary(b"result only", 0), None);
    }
}
