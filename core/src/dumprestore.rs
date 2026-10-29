//! Restoring a SQL dump into a local database, for development: a production dump into a test
//! database, replacing one that exists or creating a new one, optionally without the data of the
//! tables that do not matter (audit logs with millions of rows).
//!
//! - Formats: mysqldump / mariadb-dump and pg_dump plain SQL, `.sql` or gzipped (detected by its
//!   magic bytes, decompressed by /usr/bin/gzip). pg_dump's custom format and zip files are
//!   refused with a hint.
//! - The dump is read as a stream of statements, the way the `mysql` client splits it (quotes,
//!   escapes, comments, `/*! */`, DELIMITER, NO_BACKSLASH_ESCAPES) or the way `psql` does
//!   (dollar quotes, COPY blocks, meta-commands). Only the statement being read is in memory.
//! - Analysis (before anything is touched): tables with their exact row counts (tuples counted
//!   outside quotes, COPY lines), data size, views, triggers, routines, definers, the source
//!   database, and what will be left out. A dump that is truncated, names other databases or
//!   holds more than one is refused.
//! - Restore: the dump's own `USE` / `CREATE DATABASE` / `\connect`, server-wide settings
//!   (`SET GLOBAL`, GTID_PURGED), accounts, grants, replication and file-reading statements are
//!   left out; definers that do not exist locally become `CURRENT_USER`; INSERT / COPY of the
//!   skipped tables are dropped while their structure is created. Statements go to the server's
//!   own client (`mysql`, `psql`) inside the container with its own credentials, in batches of
//!   one transaction. An error names the dump line, never the row data.
//! - Jobs: analysis and restore run on their own thread with progress, current table, a log
//!   (also in ~/Library/Application Support/CoreScope/logs) and cancel.
use crate::databases::Endpoint;
use crate::dbsnapshot::{self, MYSQL_ENV};
use serde::Serialize;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

// MARK: input

/// The dump's bytes, decompressed when gzipped, with how much of the file was read.
pub struct Input {
    reader: Box<dyn Read + Send>,
    consumed: Arc<AtomicU64>,
    total: u64,
    gzip: Option<Child>,
    pub compressed: bool,
}
struct Counting<R> {
    inner: R,
    count: Arc<AtomicU64>,
}
impl<R: Read> Read for Counting<R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let n = self.inner.read(buf)?;
        self.count.fetch_add(n as u64, Ordering::Relaxed);
        Ok(n)
    }
}
impl Read for Input {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.reader.read(buf)
    }
}
impl Input {
    pub fn open(path: &Path) -> Result<Input, String> {
        let meta = std::fs::metadata(path).map_err(|e| format!("{}: {e}", path.display()))?;
        if !meta.is_file() {
            return Err("choose a dump file (.sql or .sql.gz)".into());
        }
        let mut file = std::fs::File::open(path).map_err(|e| e.to_string())?;
        let mut magic = [0u8; 5];
        let n = file.read(&mut magic).map_err(|e| e.to_string())?;
        drop(file);
        let magic = &magic[..n];
        if magic.starts_with(b"PK\x03\x04") {
            return Err("this is a .zip: unzip it and choose the .sql inside".into());
        }
        if magic.starts_with(b"PGDMP") {
            return Err(
                "pg_dump custom format: convert it with `pg_restore -f dump.sql <file>` (or dump with --format=plain)".into(),
            );
        }
        let consumed = Arc::new(AtomicU64::new(0));
        let file = std::fs::File::open(path).map_err(|e| e.to_string())?;
        if magic.starts_with(&[0x1f, 0x8b]) {
            let mut child = Command::new("/usr/bin/gzip")
                .arg("-dc")
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .spawn()
                .map_err(|e| format!("gzip: {e}"))?;
            let mut stdin = child.stdin.take().ok_or("gzip pipe")?;
            let stdout = child.stdout.take().ok_or("gzip pipe")?;
            let mut source = Counting {
                inner: file,
                count: consumed.clone(),
            };
            std::thread::spawn(move || {
                let _ = std::io::copy(&mut source, &mut stdin);
            });
            return Ok(Input {
                reader: Box::new(stdout),
                consumed,
                total: meta.len(),
                gzip: Some(child),
                compressed: true,
            });
        }
        Ok(Input {
            reader: Box::new(Counting {
                inner: file,
                count: consumed.clone(),
            }),
            consumed,
            total: meta.len(),
            gzip: None,
            compressed: false,
        })
    }
    /// Share of the file read so far (compressed bytes for a .gz).
    pub fn fraction(&self) -> f64 {
        if self.total == 0 {
            return 1.0;
        }
        (self.consumed.load(Ordering::Relaxed) as f64 / self.total as f64).min(1.0)
    }
    /// After the last byte: a gzip that failed means a corrupt or truncated file.
    pub fn finish(&mut self) -> Result<(), String> {
        if let Some(child) = self.gzip.as_mut() {
            let status = child.wait().map_err(|e| e.to_string())?;
            if !status.success() {
                return Err("the gzip file is corrupt or truncated".into());
            }
        }
        Ok(())
    }
}
impl Drop for Input {
    fn drop(&mut self) {
        if let Some(child) = self.gzip.as_mut() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

/// A read buffer with lookahead.
struct Source<R> {
    r: R,
    buf: Vec<u8>,
    pos: usize,
    eof: bool,
    /// Bytes consumed (decompressed).
    offset: u64,
}
impl<R: Read> Source<R> {
    fn new(r: R) -> Self {
        Source {
            r,
            buf: Vec::with_capacity(256 * 1024),
            pos: 0,
            eof: false,
            offset: 0,
        }
    }
    /// At least `n` bytes ahead, unless the input ends first; false when fewer are left.
    fn ensure(&mut self, n: usize) -> Result<bool, String> {
        while self.buf.len() - self.pos < n && !self.eof {
            if self.pos > 0 && self.pos >= self.buf.len() / 2 {
                self.buf.drain(..self.pos);
                self.pos = 0;
            }
            let start = self.buf.len();
            self.buf.resize(start + 256 * 1024, 0);
            let read = loop {
                match self.r.read(&mut self.buf[start..]) {
                    Ok(k) => break k,
                    Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                    Err(e) => {
                        self.buf.truncate(start);
                        return Err(e.to_string());
                    }
                }
            };
            self.buf.truncate(start + read);
            if read == 0 {
                self.eof = true;
            }
        }
        Ok(self.buf.len() - self.pos >= n)
    }
    fn at(&self, i: usize) -> Option<u8> {
        self.buf.get(self.pos + i).copied()
    }
    fn ahead(&self) -> &[u8] {
        &self.buf[self.pos..]
    }
    fn bump(&mut self, n: usize) {
        self.pos += n;
        self.offset += n as u64;
    }
}

// MARK: scanners

/// What a scanner hands over, in order.
#[derive(Debug, PartialEq)]
pub enum Item {
    /// One statement without its delimiter; `line` is where its code starts.
    Statement { text: Vec<u8>, line: u64 },
    /// MySQL: `DELIMITER x` changed the delimiter.
    Delimiter(Vec<u8>),
    /// PostgreSQL: a psql meta-command line (`\connect db`), without its newline.
    Meta { text: Vec<u8>, line: u64 },
    /// PostgreSQL: one line of a COPY block (with its newline); `end` for the `\.` line.
    CopyLine { data: Vec<u8>, end: bool },
}

#[derive(Clone, Copy, PartialEq)]
enum State {
    Code,
    Single,
    Double,
    Backtick,
    LineComment,
    BlockComment,
}

/// Splits a MySQL dump into statements the way the `mysql` client does.
pub struct MysqlScanner<R> {
    src: Source<R>,
    line: u64,
    line_start: bool,
    delimiter: Vec<u8>,
    /// Set by the caller after a `SET sql_mode` (backslashes are not escapes then).
    pub no_backslash_escapes: bool,
    limit: usize,
    /// The comments after the last statement (where mysqldump writes "Dump completed").
    pub trailing: Vec<u8>,
}
fn truncated(what: &str, line: u64) -> String {
    format!("the dump ends inside {what} (line {line}): it looks truncated")
}
impl<R: Read> MysqlScanner<R> {
    pub fn new(r: R, limit: usize) -> Self {
        MysqlScanner {
            src: Source::new(r),
            line: 1,
            line_start: true,
            delimiter: b";".to_vec(),
            no_backslash_escapes: false,
            limit,
            trailing: Vec::new(),
        }
    }
    pub fn offset(&self) -> u64 {
        self.src.offset
    }
    pub fn delimiter(&self) -> &[u8] {
        &self.delimiter
    }
    /// A `DELIMITER x` line at the start of a statement; consumes it.
    fn delimiter_command(&mut self) -> Result<Option<Vec<u8>>, String> {
        self.src.ensure(1024)?;
        let ahead = self.src.ahead();
        let mut i = 0;
        while i < ahead.len() && matches!(ahead[i], b' ' | b'\t') {
            i += 1;
        }
        const WORD: &[u8] = b"delimiter";
        if ahead.len() < i + WORD.len() + 1
            || !ahead[i..i + WORD.len()].eq_ignore_ascii_case(WORD)
            || !matches!(ahead[i + WORD.len()], b' ' | b'\t')
        {
            return Ok(None);
        }
        let newline = ahead.iter().position(|&b| b == b'\n');
        if newline.is_none() && !self.src.eof {
            return Ok(None);
        }
        let end = newline.unwrap_or(ahead.len());
        let rest = &ahead[i + WORD.len()..end];
        let value: Vec<u8> = rest
            .split(|b| b.is_ascii_whitespace())
            .find(|w| !w.is_empty())
            .unwrap_or(&[])
            .to_vec();
        if value.is_empty() || value.len() > 15 || value.contains(&b'\\') {
            return Err(format!("invalid DELIMITER command on line {}", self.line));
        }
        self.src.bump(end + usize::from(newline.is_some()));
        if newline.is_some() {
            self.line += 1;
        }
        self.line_start = true;
        Ok(Some(value))
    }
    pub fn next_item(&mut self) -> Result<Option<Item>, String> {
        let mut stmt: Vec<u8> = Vec::new();
        let mut has_code = false;
        let mut stmt_line = self.line;
        let mut state = State::Code;
        let mut depth = 0u32;
        let mut quote = 0u8;
        let mut quote_line = 0;
        loop {
            if !self.src.ensure(1)? {
                return match state {
                    State::Single | State::Double | State::Backtick => {
                        Err(truncated("a quoted text", quote_line))
                    }
                    State::BlockComment => Err(truncated("a comment", self.line)),
                    _ if !has_code => {
                        let keep = stmt.len().saturating_sub(4096);
                        self.trailing = stmt[keep..].to_vec();
                        Ok(None)
                    }
                    _ => Ok(Some(Item::Statement {
                        text: stmt,
                        line: stmt_line,
                    })),
                };
            }
            let b = self.src.at(0).unwrap_or(0);
            match state {
                State::Code => {
                    if self.line_start
                        && !has_code
                        && depth == 0
                        && let Some(d) = self.delimiter_command()?
                    {
                        self.delimiter = d.clone();
                        return Ok(Some(Item::Delimiter(d)));
                    }
                    let delim_len = self.delimiter.len();
                    self.src.ensure(delim_len)?;
                    if self.src.ahead().starts_with(&self.delimiter) {
                        self.src.bump(delim_len);
                        self.line_start = false;
                        if !has_code {
                            stmt.clear();
                            continue;
                        }
                        return Ok(Some(Item::Statement {
                            text: stmt,
                            line: stmt_line,
                        }));
                    }
                    self.line_start = false;
                    self.src.ensure(3)?;
                    let next = self.src.at(1);
                    match b {
                        b'\n' => {
                            self.line += 1;
                            self.line_start = true;
                        }
                        b'\'' | b'"' | b'`' => {
                            if !has_code {
                                has_code = true;
                                stmt_line = self.line;
                            }
                            quote = b;
                            quote_line = self.line;
                            state = if b == b'`' {
                                State::Backtick
                            } else if b == b'\'' {
                                State::Single
                            } else {
                                State::Double
                            };
                        }
                        b'#' => state = State::LineComment,
                        b'-' if next == Some(b'-') && self.src.at(2).is_none_or(|c| c <= 0x20) => {
                            state = State::LineComment
                        }
                        b'/' if next == Some(b'*') && self.src.at(2) == Some(b'!') => {
                            if !has_code {
                                has_code = true;
                                stmt_line = self.line;
                            }
                            depth += 1;
                            stmt.extend_from_slice(b"/*!");
                            self.src.bump(3);
                            continue;
                        }
                        b'/' if next == Some(b'*') => {
                            state = State::BlockComment;
                            stmt.extend_from_slice(b"/*");
                            self.src.bump(2);
                            continue;
                        }
                        b'*' if next == Some(b'/') && depth > 0 => {
                            depth -= 1;
                            stmt.extend_from_slice(b"*/");
                            self.src.bump(2);
                            continue;
                        }
                        c if !c.is_ascii_whitespace() && !has_code => {
                            has_code = true;
                            stmt_line = self.line;
                        }
                        _ => {}
                    }
                    stmt.push(b);
                    self.src.bump(1);
                }
                State::Single | State::Double => {
                    // Copy plain bytes in bulk up to the quote, a backslash or a newline.
                    let ahead = self.src.ahead();
                    let run = ahead
                        .iter()
                        .position(|&c| c == quote || c == b'\\' || c == b'\n')
                        .unwrap_or(ahead.len());
                    if run > 0 {
                        stmt.extend_from_slice(&ahead[..run]);
                        self.src.bump(run);
                        continue;
                    }
                    if b == b'\\' && !self.no_backslash_escapes {
                        self.src.ensure(2)?;
                        stmt.push(b);
                        self.src.bump(1);
                        if let Some(c) = self.src.at(0) {
                            if c == b'\n' {
                                self.line += 1;
                            }
                            stmt.push(c);
                            self.src.bump(1);
                        }
                        continue;
                    }
                    if b == b'\n' {
                        self.line += 1;
                    } else if b == quote {
                        state = State::Code;
                    }
                    stmt.push(b);
                    self.src.bump(1);
                }
                State::Backtick => {
                    if b == b'\n' {
                        self.line += 1;
                    } else if b == b'`' {
                        state = State::Code;
                    }
                    stmt.push(b);
                    self.src.bump(1);
                }
                State::LineComment => {
                    if b == b'\n' {
                        self.line += 1;
                        self.line_start = true;
                        state = State::Code;
                    }
                    stmt.push(b);
                    self.src.bump(1);
                }
                State::BlockComment => {
                    self.src.ensure(2)?;
                    if b == b'*' && self.src.at(1) == Some(b'/') {
                        stmt.extend_from_slice(b"*/");
                        self.src.bump(2);
                        state = State::Code;
                        continue;
                    }
                    if b == b'\n' {
                        self.line += 1;
                    }
                    stmt.push(b);
                    self.src.bump(1);
                }
            }
            if stmt.len() > self.limit {
                return Err(format!(
                    "a statement near line {stmt_line} is larger than {} MB",
                    self.limit >> 20
                ));
            }
        }
    }
}

#[derive(Clone, PartialEq)]
enum PgState {
    Code,
    Single { escapes: bool },
    Double,
    Dollar(Vec<u8>),
    LineComment,
    BlockComment(u32),
}

/// Splits a pg_dump plain SQL dump the way `psql` does.
pub struct PgScanner<R> {
    src: Source<R>,
    line: u64,
    line_start: bool,
    in_copy: bool,
    limit: usize,
    pub trailing: Vec<u8>,
}
fn is_ident(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_' || b >= 0x80
}
impl<R: Read> PgScanner<R> {
    pub fn new(r: R, limit: usize) -> Self {
        PgScanner {
            src: Source::new(r),
            line: 1,
            line_start: true,
            in_copy: false,
            limit,
            trailing: Vec::new(),
        }
    }
    pub fn offset(&self) -> u64 {
        self.src.offset
    }
    /// The rest of the current line, newline included.
    fn take_line(&mut self) -> Result<Vec<u8>, String> {
        let mut out = Vec::new();
        loop {
            if !self.src.ensure(1)? {
                return Ok(out);
            }
            let ahead = self.src.ahead();
            if let Some(i) = ahead.iter().position(|&b| b == b'\n') {
                out.extend_from_slice(&ahead[..=i]);
                self.src.bump(i + 1);
                self.line += 1;
                self.line_start = true;
                return Ok(out);
            }
            let n = ahead.len();
            out.extend_from_slice(ahead);
            self.src.bump(n);
            if out.len() > self.limit {
                return Err(format!("a line near {} is too long", self.line));
            }
        }
    }
    pub fn next_item(&mut self) -> Result<Option<Item>, String> {
        if self.in_copy {
            if !self.src.ensure(1)? {
                return Err(truncated("a COPY block", self.line));
            }
            let data = self.take_line()?;
            let end = data == b"\\.\n" || data == b"\\.\r\n" || data == b"\\.";
            if end {
                self.in_copy = false;
            }
            return Ok(Some(Item::CopyLine { data, end }));
        }
        let mut stmt: Vec<u8> = Vec::new();
        let mut has_code = false;
        let mut stmt_line = self.line;
        let mut state = PgState::Code;
        let mut quote_line = 0;
        loop {
            if !self.src.ensure(1)? {
                return match state {
                    PgState::Single { .. } | PgState::Double | PgState::Dollar(_) => {
                        Err(truncated("a quoted text", quote_line))
                    }
                    PgState::BlockComment(_) => Err(truncated("a comment", self.line)),
                    _ if !has_code => {
                        let keep = stmt.len().saturating_sub(4096);
                        self.trailing = stmt[keep..].to_vec();
                        Ok(None)
                    }
                    _ => Ok(Some(Item::Statement {
                        text: stmt,
                        line: stmt_line,
                    })),
                };
            }
            let b = self.src.at(0).unwrap_or(0);
            match state.clone() {
                PgState::Code => {
                    if self.line_start && !has_code && b == b'\\' {
                        let line = self.line;
                        let mut text = self.take_line()?;
                        while text.last().is_some_and(|c| *c == b'\n' || *c == b'\r') {
                            text.pop();
                        }
                        return Ok(Some(Item::Meta { text, line }));
                    }
                    self.line_start = false;
                    self.src.ensure(2)?;
                    let next = self.src.at(1);
                    match b {
                        b';' => {
                            self.src.bump(1);
                            if !has_code {
                                stmt.clear();
                                continue;
                            }
                            if is_copy_from_stdin(&stmt) {
                                // The data starts on the next line.
                                self.take_line()?;
                                self.in_copy = true;
                            }
                            return Ok(Some(Item::Statement {
                                text: stmt,
                                line: stmt_line,
                            }));
                        }
                        b'\n' => {
                            self.line += 1;
                            self.line_start = true;
                        }
                        b'\'' => {
                            let prev = stmt.last().copied();
                            let before =
                                stmt.len().checked_sub(2).and_then(|i| stmt.get(i)).copied();
                            let escapes =
                                matches!(prev, Some(b'E' | b'e')) && !before.is_some_and(is_ident);
                            state = PgState::Single { escapes };
                            quote_line = self.line;
                            if !has_code {
                                has_code = true;
                                stmt_line = self.line;
                            }
                        }
                        b'"' => {
                            state = PgState::Double;
                            quote_line = self.line;
                            if !has_code {
                                has_code = true;
                                stmt_line = self.line;
                            }
                        }
                        b'$' if !stmt.last().is_some_and(|c| is_ident(*c) || *c == b'$') => {
                            // $tag$ … $tag$ (the tag may be empty).
                            self.src.ensure(64)?;
                            let ahead = self.src.ahead();
                            let mut i = 1;
                            while i < ahead.len()
                                && i < 64
                                && (is_ident(ahead[i]) && !(i == 1 && ahead[i].is_ascii_digit()))
                            {
                                i += 1;
                            }
                            if i < ahead.len() && ahead[i] == b'$' {
                                let tag = ahead[..=i].to_vec();
                                stmt.extend_from_slice(&tag);
                                self.src.bump(tag.len());
                                state = PgState::Dollar(tag);
                                quote_line = self.line;
                                if !has_code {
                                    has_code = true;
                                    stmt_line = self.line;
                                }
                                continue;
                            }
                            if !has_code {
                                has_code = true;
                                stmt_line = self.line;
                            }
                        }
                        b'-' if next == Some(b'-') => state = PgState::LineComment,
                        b'/' if next == Some(b'*') => {
                            stmt.extend_from_slice(b"/*");
                            self.src.bump(2);
                            state = PgState::BlockComment(1);
                            continue;
                        }
                        c if !c.is_ascii_whitespace() && !has_code => {
                            has_code = true;
                            stmt_line = self.line;
                        }
                        _ => {}
                    }
                    stmt.push(b);
                    self.src.bump(1);
                }
                PgState::Single { escapes } => {
                    if b == b'\\' && escapes {
                        self.src.ensure(2)?;
                        stmt.push(b);
                        self.src.bump(1);
                        if let Some(c) = self.src.at(0) {
                            if c == b'\n' {
                                self.line += 1;
                            }
                            stmt.push(c);
                            self.src.bump(1);
                        }
                        continue;
                    }
                    if b == b'\'' {
                        self.src.ensure(2)?;
                        if self.src.at(1) == Some(b'\'') {
                            stmt.extend_from_slice(b"''");
                            self.src.bump(2);
                            continue;
                        }
                        state = PgState::Code;
                    } else if b == b'\n' {
                        self.line += 1;
                    }
                    stmt.push(b);
                    self.src.bump(1);
                }
                PgState::Double => {
                    if b == b'"' {
                        state = PgState::Code;
                    } else if b == b'\n' {
                        self.line += 1;
                    }
                    stmt.push(b);
                    self.src.bump(1);
                }
                PgState::Dollar(tag) => {
                    self.src.ensure(tag.len())?;
                    if self.src.ahead().starts_with(&tag) {
                        stmt.extend_from_slice(&tag);
                        self.src.bump(tag.len());
                        state = PgState::Code;
                        continue;
                    }
                    if b == b'\n' {
                        self.line += 1;
                    }
                    stmt.push(b);
                    self.src.bump(1);
                }
                PgState::LineComment => {
                    if b == b'\n' {
                        self.line += 1;
                        self.line_start = true;
                        state = PgState::Code;
                    }
                    stmt.push(b);
                    self.src.bump(1);
                }
                PgState::BlockComment(depth) => {
                    self.src.ensure(2)?;
                    let next = self.src.at(1);
                    if b == b'/' && next == Some(b'*') {
                        stmt.extend_from_slice(b"/*");
                        self.src.bump(2);
                        state = PgState::BlockComment(depth + 1);
                        continue;
                    }
                    if b == b'*' && next == Some(b'/') {
                        stmt.extend_from_slice(b"*/");
                        self.src.bump(2);
                        state = if depth == 1 {
                            PgState::Code
                        } else {
                            PgState::BlockComment(depth - 1)
                        };
                        continue;
                    }
                    if b == b'\n' {
                        self.line += 1;
                    }
                    stmt.push(b);
                    self.src.bump(1);
                }
            }
            if stmt.len() > self.limit {
                return Err(format!(
                    "a statement near line {stmt_line} is larger than {} MB",
                    self.limit >> 20
                ));
            }
        }
    }
}
fn is_copy_from_stdin(stmt: &[u8]) -> bool {
    let t = head_tokens(stmt, 64, false);
    matches!(t.first(), Some(Token { tok: Tok::Word(w), .. }) if w.eq_ignore_ascii_case("COPY"))
        && t.windows(2).any(|w| {
            matches!((&w[0].tok, &w[1].tok), (Tok::Word(a), Tok::Word(b))
                if a.eq_ignore_ascii_case("FROM") && b.eq_ignore_ascii_case("STDIN"))
        })
}

// MARK: statement heads

#[derive(Clone, Debug, PartialEq)]
pub enum Tok {
    /// A bare word as written (compare with `is`).
    Word(String),
    /// A quoted name or string, unquoted, with its quote character.
    Quoted(String, u8),
    Punct(u8),
}
#[derive(Clone, Debug)]
pub struct Token {
    pub tok: Tok,
    pub start: usize,
    pub end: usize,
}
fn is_word(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_' || b == b'$' || b >= 0x80
}
/// The first `max` tokens of a statement, past comments and `/*!NNNNN` openers.
pub fn head_tokens(text: &[u8], max: usize, backslash: bool) -> Vec<Token> {
    let mut out = Vec::new();
    let n = text.len();
    let mut i = 0;
    while i < n && out.len() < max {
        let b = text[i];
        if b.is_ascii_whitespace() {
            i += 1;
            continue;
        }
        if b == b'#'
            || (b == b'-'
                && text.get(i + 1) == Some(&b'-')
                && text.get(i + 2).is_none_or(|c| *c <= 0x20))
        {
            while i < n && text[i] != b'\n' {
                i += 1;
            }
            continue;
        }
        if b == b'/' && text.get(i + 1) == Some(&b'*') {
            if text.get(i + 2) == Some(&b'!') {
                i += 3;
                while i < n && text[i].is_ascii_digit() {
                    i += 1;
                }
                continue;
            }
            match text[i + 2..].windows(2).position(|w| w == b"*/") {
                Some(j) => i += 2 + j + 2,
                None => break,
            }
            continue;
        }
        if b == b'*' && text.get(i + 1) == Some(&b'/') {
            i += 2;
            continue;
        }
        if is_word(b) {
            let s = i;
            while i < n && is_word(text[i]) {
                i += 1;
            }
            out.push(Token {
                tok: Tok::Word(String::from_utf8_lossy(&text[s..i]).into_owned()),
                start: s,
                end: i,
            });
            continue;
        }
        if matches!(b, b'\'' | b'"' | b'`') {
            let s = i;
            i += 1;
            let cap = (i + 512).min(n);
            let mut v = Vec::new();
            let mut closed = false;
            while i < cap {
                let c = text[i];
                if c == b'\\' && backslash && b != b'`' {
                    if let Some(&d) = text.get(i + 1) {
                        v.push(d);
                    }
                    i += 2;
                    continue;
                }
                if c == b {
                    if text.get(i + 1) == Some(&b) {
                        v.push(b);
                        i += 2;
                        continue;
                    }
                    i += 1;
                    closed = true;
                    break;
                }
                v.push(c);
                i += 1;
            }
            if !closed {
                break;
            }
            out.push(Token {
                tok: Tok::Quoted(String::from_utf8_lossy(&v).into_owned(), b),
                start: s,
                end: i,
            });
            continue;
        }
        out.push(Token {
            tok: Tok::Punct(b),
            start: i,
            end: i + 1,
        });
        i += 1;
    }
    out
}
fn word(t: &[Token], i: usize) -> Option<String> {
    match &t.get(i)?.tok {
        Tok::Word(w) => Some(w.to_ascii_uppercase()),
        _ => None,
    }
}
fn punct(t: &[Token], i: usize) -> Option<u8> {
    match t.get(i)?.tok {
        Tok::Punct(p) => Some(p),
        _ => None,
    }
}
fn ident(t: &[Token], i: usize) -> Option<String> {
    match &t.get(i)?.tok {
        Tok::Word(w) => Some(w.clone()),
        Tok::Quoted(q, b'`' | b'"') => Some(q.clone()),
        _ => None,
    }
}
/// `name` or `q.name` at `i`: (name, qualifier, next index, end offset).
fn name_at(t: &[Token], i: usize) -> Option<(String, Option<String>, usize, usize)> {
    let first = ident(t, i)?;
    if punct(t, i + 1) == Some(b'.')
        && let Some(second) = ident(t, i + 2)
    {
        return Some((second, Some(first), i + 3, t[i + 2].end));
    }
    Some((first, None, i + 1, t[i].end))
}
/// Skips `IF [NOT] EXISTS`.
fn skip_if_exists(t: &[Token], mut i: usize) -> usize {
    if word(t, i).as_deref() == Some("IF") {
        i += 1;
        if word(t, i).as_deref() == Some("NOT") {
            i += 1;
        }
        if word(t, i).as_deref() == Some("EXISTS") {
            i += 1;
        }
    }
    i
}
/// A word not used as a user variable (`@name`); `@@global` counts as a word.
fn plain_word(t: &[Token], i: usize) -> bool {
    !(i >= 1 && punct(t, i - 1) == Some(b'@') && !(i >= 2 && punct(t, i - 2) == Some(b'@')))
}

/// What a statement is, for analysis and for the restore.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub enum Kind {
    #[default]
    Other,
    Set,
    CreateTable,
    DropTable,
    CreateView,
    DropView,
    CreateTrigger,
    CreateRoutine,
    CreateEvent,
    Insert,
    Copy,
    AlterDatabase,
    CreateSchema,
}
#[derive(Clone, Debug, Default)]
pub struct Info {
    pub kind: Kind,
    /// The table or view (several for DROP TABLE a, b).
    pub objects: Vec<String>,
    /// A database (MySQL) named on the object: `other`.`t`.
    pub qualifier: Option<String>,
    /// Left out of the restore, and why.
    pub skip: Option<&'static str>,
    /// USE / CREATE / DROP DATABASE / \connect name.
    pub database: Option<String>,
    /// DEFINER clause: byte range and account (`user@host`, or CURRENT_USER).
    pub definer: Option<(usize, usize, String)>,
    pub sql_mode: bool,
    /// ALTER DATABASE name to point at the target.
    pub rename: Option<(usize, usize)>,
    pub charset: Option<String>,
    pub collate: Option<String>,
    /// Where the values start (INSERT), for counting rows.
    pub body: usize,
    /// PostgreSQL CREATE SCHEMA without IF NOT EXISTS: where to add it.
    pub schema_if_not_exists: Option<usize>,
}

const ACCOUNTS: &str = "accounts and grants";
const REPLICATION: &str = "replication";
const EXTERNAL: &str = "reading external files";
const ADMIN: &str = "server administration";

/// `DEFINER = account` starting at the DEFINER word: (start, end, account).
fn definer_at(text: &[u8], start: usize, word_end: usize) -> Option<(usize, usize, String)> {
    let n = text.len();
    let mut i = word_end;
    let ws = |i: &mut usize| {
        while *i < n && text[*i].is_ascii_whitespace() {
            *i += 1;
        }
    };
    ws(&mut i);
    if text.get(i) != Some(&b'=') {
        return None;
    }
    i += 1;
    ws(&mut i);
    let part = |i: &mut usize| -> Option<String> {
        let q = *text.get(*i)?;
        if matches!(q, b'\'' | b'"' | b'`') {
            *i += 1;
            let mut v = Vec::new();
            while *i < n {
                if text[*i] == q {
                    if text.get(*i + 1) == Some(&q) {
                        v.push(q);
                        *i += 2;
                        continue;
                    }
                    *i += 1;
                    return Some(String::from_utf8_lossy(&v).into_owned());
                }
                v.push(text[*i]);
                *i += 1;
            }
            return None;
        }
        let s = *i;
        while *i < n && (is_word(text[*i]) || matches!(text[*i], b'.' | b'-' | b'%')) {
            *i += 1;
        }
        (*i > s).then(|| String::from_utf8_lossy(&text[s..*i]).into_owned())
    };
    let user = part(&mut i)?;
    if user.eq_ignore_ascii_case("CURRENT_USER") {
        if text.get(i) == Some(&b'(') && text.get(i + 1) == Some(&b')') {
            i += 2;
        }
        return Some((start, i, "CURRENT_USER".into()));
    }
    let mut end = i;
    let mut j = i;
    ws(&mut j);
    let mut host = "%".to_string();
    if text.get(j) == Some(&b'@') {
        j += 1;
        ws(&mut j);
        host = part(&mut j)?;
        end = j;
    }
    Some((start, end, format!("{user}@{host}")))
}

pub fn classify_mysql(text: &[u8]) -> Info {
    let t = head_tokens(text, 48, true);
    let mut info = Info::default();
    let w = |i: usize| word(&t, i);
    let first = w(0).unwrap_or_default();
    match first.as_str() {
        "USE" => {
            info.skip = Some("USE");
            info.database = ident(&t, 1);
        }
        "CREATE" => {
            let mut i = 1;
            let mut definer = None;
            loop {
                match w(i).as_deref() {
                    Some("OR") => i += 2,
                    Some("ALGORITHM") | Some("SQL") => i += 3,
                    Some(
                        "TEMPORARY" | "UNIQUE" | "FULLTEXT" | "SPATIAL" | "AGGREGATE" | "UNDO"
                        | "ONLINE" | "OFFLINE",
                    ) => i += 1,
                    Some("DEFINER") if punct(&t, i + 1) == Some(b'=') => {
                        let Some(d) = definer_at(text, t[i].start, t[i].end) else {
                            break;
                        };
                        let end = d.1;
                        definer = Some(d);
                        while t.get(i).is_some_and(|x| x.start < end) {
                            i += 1;
                        }
                    }
                    _ => break,
                }
            }
            match w(i).as_deref() {
                Some("DATABASE" | "SCHEMA") => {
                    info.skip = Some("CREATE DATABASE");
                    let j = skip_if_exists(&t, i + 1);
                    info.database = ident(&t, j);
                    let mut k = j + 1;
                    while k < t.len() {
                        match w(k).as_deref() {
                            Some("CHARACTER") if w(k + 1).as_deref() == Some("SET") => {
                                k += 2;
                                if punct(&t, k) == Some(b'=') {
                                    k += 1;
                                }
                                info.charset = ident(&t, k);
                            }
                            Some("CHARSET") => {
                                k += 1;
                                if punct(&t, k) == Some(b'=') {
                                    k += 1;
                                }
                                info.charset = ident(&t, k);
                            }
                            Some("COLLATE") => {
                                k += 1;
                                if punct(&t, k) == Some(b'=') {
                                    k += 1;
                                }
                                info.collate = ident(&t, k);
                            }
                            _ => {}
                        }
                        k += 1;
                    }
                }
                Some(
                    kind @ ("TABLE" | "VIEW" | "TRIGGER" | "PROCEDURE" | "FUNCTION" | "EVENT"),
                ) => {
                    let j = skip_if_exists(&t, i + 1);
                    if let Some((name, q, _, end)) = name_at(&t, j) {
                        info.objects.push(name);
                        info.qualifier = q;
                        info.body = end;
                    }
                    info.kind = match kind {
                        "TABLE" => Kind::CreateTable,
                        "VIEW" => Kind::CreateView,
                        "TRIGGER" => Kind::CreateTrigger,
                        "EVENT" => Kind::CreateEvent,
                        _ => Kind::CreateRoutine,
                    };
                    if info.kind != Kind::CreateTable {
                        info.definer = definer;
                    }
                }
                Some("USER" | "ROLE") => info.skip = Some(ACCOUNTS),
                Some("SERVER" | "TABLESPACE" | "LOGFILE" | "RESOURCE") => info.skip = Some(ADMIN),
                _ => {}
            }
        }
        "DROP" => match w(1).as_deref() {
            Some("DATABASE" | "SCHEMA") => {
                info.skip = Some("DROP DATABASE");
                info.database = ident(&t, skip_if_exists(&t, 2));
            }
            Some(kind @ ("TABLE" | "TABLES" | "VIEW")) => {
                info.kind = if kind == "VIEW" {
                    Kind::DropView
                } else {
                    Kind::DropTable
                };
                let mut i = skip_if_exists(&t, 2);
                while let Some((name, q, next, _)) = name_at(&t, i) {
                    if info.qualifier.is_none() {
                        info.qualifier = q;
                    }
                    info.objects.push(name);
                    if punct(&t, next) != Some(b',') {
                        break;
                    }
                    i = next + 1;
                }
            }
            Some("TRIGGER" | "PROCEDURE" | "FUNCTION" | "EVENT") => {
                if let Some((_, q, _, _)) = name_at(&t, skip_if_exists(&t, 2)) {
                    info.qualifier = q;
                }
            }
            Some("USER" | "ROLE") => info.skip = Some(ACCOUNTS),
            Some("SERVER" | "TABLESPACE" | "LOGFILE" | "RESOURCE") => info.skip = Some(ADMIN),
            _ => {}
        },
        "INSERT" | "REPLACE" => {
            let t = head_tokens(text, 8, true);
            let mut i = 1;
            while matches!(
                word(&t, i).as_deref(),
                Some("LOW_PRIORITY" | "DELAYED" | "HIGH_PRIORITY" | "IGNORE" | "INTO")
            ) {
                i += 1;
            }
            info.kind = Kind::Insert;
            if let Some((name, q, _, end)) = name_at(&t, i) {
                info.objects.push(name);
                info.qualifier = q;
                info.body = end;
            }
        }
        "LOCK" => {
            let mut i = 1;
            if matches!(w(1).as_deref(), Some("TABLES" | "TABLE")) {
                i = 2;
            }
            if let Some((_, q, _, _)) = name_at(&t, i) {
                info.qualifier = q;
            }
        }
        "ALTER" => match w(1).as_deref() {
            Some("TABLE") => {
                if let Some((name, q, _, _)) = name_at(&t, 2) {
                    info.objects.push(name);
                    info.qualifier = q;
                }
            }
            Some("DATABASE" | "SCHEMA") => {
                info.kind = Kind::AlterDatabase;
                let named = match &t.get(2).map(|x| &x.tok) {
                    Some(Tok::Quoted(..)) => true,
                    Some(Tok::Word(x)) => !matches!(
                        x.to_ascii_uppercase().as_str(),
                        "CHARACTER"
                            | "CHARSET"
                            | "COLLATE"
                            | "DEFAULT"
                            | "ENCRYPTION"
                            | "READ"
                            | "UPGRADE"
                    ),
                    _ => false,
                };
                if named {
                    info.rename = Some((t[2].start, t[2].end));
                }
            }
            Some("USER") => info.skip = Some(ACCOUNTS),
            Some("INSTANCE" | "SERVER" | "RESOURCE" | "TABLESPACE" | "LOGFILE" | "UNDO") => {
                info.skip = Some(ADMIN)
            }
            _ => {}
        },
        "SET" => {
            info.kind = Kind::Set;
            let t = head_tokens(text, 256, true);
            if word(&t, 1).as_deref() == Some("PASSWORD") {
                info.skip = Some(ACCOUNTS);
            }
            for i in 1..t.len() {
                let Some(x) = word(&t, i) else { continue };
                if !plain_word(&t, i) {
                    continue;
                }
                if matches!(x.as_str(), "GLOBAL" | "PERSIST" | "PERSIST_ONLY")
                    && info.skip.is_none()
                {
                    info.skip = Some("SET GLOBAL");
                }
                if x == "SQL_MODE" {
                    info.sql_mode = true;
                }
            }
        }
        "GRANT" | "REVOKE" => info.skip = Some(ACCOUNTS),
        "RENAME" if w(1).as_deref() == Some("USER") => info.skip = Some(ACCOUNTS),
        "START" if w(1).as_deref() != Some("TRANSACTION") => info.skip = Some(REPLICATION),
        "CHANGE" | "STOP" => info.skip = Some(REPLICATION),
        "LOAD" | "SOURCE" | "SYSTEM" | "IMPORT" | "BINLOG" => info.skip = Some(EXTERNAL),
        "FLUSH" | "RESET" | "PURGE" | "SHUTDOWN" | "RESTART" | "INSTALL" | "UNINSTALL" | "KILL"
        | "CLONE" => info.skip = Some(ADMIN),
        _ => {}
    }
    info
}

/// A PostgreSQL name as `schema.table` (quotes removed).
fn pg_name(t: &[Token], i: usize) -> Option<(String, usize, usize)> {
    let (name, q, next, end) = name_at(t, i)?;
    Some((q.map(|q| format!("{q}.{name}")).unwrap_or(name), next, end))
}
pub fn classify_pg(text: &[u8]) -> Info {
    let t = head_tokens(text, 48, false);
    let mut info = Info::default();
    let w = |i: usize| word(&t, i);
    match w(0).unwrap_or_default().as_str() {
        "CREATE" => {
            let mut i = 1;
            while matches!(
                w(i).as_deref(),
                Some("OR" | "REPLACE" | "TEMPORARY" | "TEMP" | "UNLOGGED" | "MATERIALIZED" | "GLOBAL" | "LOCAL" | "CONSTRAINT" | "RECURSIVE")
            ) {
                i += 1;
            }
            match w(i).as_deref() {
                Some("DATABASE") => {
                    info.skip = Some("CREATE DATABASE");
                    info.database = ident(&t, i + 1);
                }
                Some(kind @ ("TABLE" | "VIEW" | "TRIGGER" | "FUNCTION" | "PROCEDURE")) => {
                    let j = skip_if_exists(&t, i + 1);
                    if let Some((name, _, end)) = pg_name(&t, j) {
                        info.objects.push(name);
                        info.body = end;
                    }
                    info.kind = match kind {
                        "TABLE" => Kind::CreateTable,
                        "VIEW" => Kind::CreateView,
                        "TRIGGER" => Kind::CreateTrigger,
                        _ => Kind::CreateRoutine,
                    };
                }
                Some("EVENT") if w(i + 1).as_deref() == Some("TRIGGER") => info.kind = Kind::CreateTrigger,
                Some("SCHEMA") => {
                    info.kind = Kind::CreateSchema;
                    if w(i + 1).as_deref() != Some("IF") {
                        info.schema_if_not_exists = Some(t[i].end);
                    }
                }
                Some("ROLE" | "USER") => info.skip = Some(ACCOUNTS),
                _ => {}
            }
        }
        "DROP" if w(1).as_deref() == Some("DATABASE") => {
            info.skip = Some("DROP DATABASE");
            info.database = ident(&t, skip_if_exists(&t, 2));
        }
        "ALTER" => match w(1).as_deref() {
            Some("DATABASE") => info.skip = Some("ALTER DATABASE"),
            Some("ROLE" | "USER") => info.skip = Some(ACCOUNTS),
            _ => {
                if t.windows(2).any(|p| {
                    matches!((&p[0].tok, &p[1].tok), (Tok::Word(a), Tok::Word(b)) if a.eq_ignore_ascii_case("OWNER") && b.eq_ignore_ascii_case("TO"))
                }) {
                    info.skip = Some("owners");
                }
            }
        },
        "GRANT" | "REVOKE" => info.skip = Some(ACCOUNTS),
        "INSERT" => {
            let i = if w(1).as_deref() == Some("INTO") { 2 } else { 1 };
            info.kind = Kind::Insert;
            if let Some((name, _, end)) = pg_name(&t, i) {
                info.objects.push(name);
                info.body = end;
            }
        }
        "COPY" => {
            info.kind = Kind::Copy;
            if let Some((name, _, _)) = pg_name(&t, 1) {
                info.objects.push(name);
            }
        }
        _ => {}
    }
    info
}

/// Rows in an INSERT … VALUES (…), (…): top-level tuples after VALUES, outside quotes. Zero
/// for INSERT … SELECT.
pub fn count_tuples(text: &[u8], from: usize, backslash: bool) -> u64 {
    let n = text.len();
    let mut i = from.min(n);
    let mut depth = 0u32;
    let mut values = false;
    let mut rows = 0;
    while i < n {
        let c = text[i];
        match c {
            b'\'' | b'"' | b'`' => {
                i += 1;
                while i < n {
                    if text[i] == b'\\' && backslash && c != b'`' {
                        i += 2;
                        continue;
                    }
                    if text[i] == c {
                        if text.get(i + 1) == Some(&c) {
                            i += 2;
                            continue;
                        }
                        break;
                    }
                    i += 1;
                }
            }
            b'(' => {
                if values && depth == 0 {
                    rows += 1;
                }
                depth += 1;
            }
            b')' => depth = depth.saturating_sub(1),
            _ if depth == 0 && is_word(c) => {
                let s = i;
                while i < n && is_word(text[i]) {
                    i += 1;
                }
                let w = &text[s..i];
                if w.eq_ignore_ascii_case(b"VALUES") || w.eq_ignore_ascii_case(b"VALUE") {
                    values = true;
                } else if !values && w.eq_ignore_ascii_case(b"SELECT") {
                    return 0;
                }
                continue;
            }
            _ => {}
        }
        i += 1;
    }
    rows
}

// MARK: analysis

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct TableInfo {
    pub name: String,
    pub rows: u64,
    /// Size of its INSERT / COPY data in the dump.
    pub data_bytes: u64,
}
#[derive(Clone, Debug, Serialize)]
pub struct LeftOut {
    pub kind: String,
    pub count: u64,
}
#[derive(Clone, Debug, Serialize)]
pub struct Analysis {
    pub file: String,
    pub bytes: u64,
    pub modified: i64,
    pub compressed: bool,
    pub uncompressed_bytes: u64,
    /// "mysql" or "postgres".
    pub dialect: &'static str,
    pub tool: Option<String>,
    pub server_version: Option<String>,
    pub source_database: Option<String>,
    pub charset: Option<String>,
    pub collate: Option<String>,
    pub statements: u64,
    pub largest_statement: u64,
    /// Most rows first.
    pub tables: Vec<TableInfo>,
    pub total_rows: u64,
    pub views: u64,
    pub triggers: u64,
    pub routines: u64,
    pub events: u64,
    pub definers: Vec<String>,
    /// Statements the restore leaves out (USE, SET GLOBAL…), with counts.
    pub left_out: Vec<LeftOut>,
    pub notes: Vec<String>,
}

/// The first 64 KB, decompressed: which client the dump is for.
pub fn sniff(path: &Path) -> Result<&'static str, String> {
    let mut input = Input::open(path)?;
    let mut head = vec![0u8; 64 * 1024];
    let mut got = 0;
    while got < head.len() {
        match input.read(&mut head[got..]) {
            Ok(0) => break,
            Ok(k) => got += k,
            Err(e) => return Err(e.to_string()),
        }
    }
    let head = String::from_utf8_lossy(&head[..got]);
    let pg = [
        "-- PostgreSQL database dump",
        "SET statement_timeout",
        "\\connect ",
        "pg_catalog.set_config",
        " FROM stdin;",
    ];
    let my = [
        "-- MySQL dump",
        "-- MariaDB dump",
        "/*!40",
        "ENGINE=",
        "LOCK TABLES `",
    ];
    if my.iter().any(|m| head.contains(m)) {
        return Ok("mysql");
    }
    if pg.iter().any(|m| head.contains(m)) {
        return Ok("postgres");
    }
    Ok(if head.contains('`') {
        "mysql"
    } else {
        "unknown"
    })
}
fn header_value<'a>(head: &'a str, prefix: &str) -> Option<&'a str> {
    head.lines()
        .find_map(|l| l.strip_prefix(prefix))
        .map(str::trim)
        .filter(|v| !v.is_empty())
}
fn modified(path: &Path) -> i64 {
    std::fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}
const LIMIT: usize = 512 << 20;

/// Reads the whole dump once. `hint` is the target's kind when the dump does not say.
pub fn analyze(
    path: &Path,
    hint: Option<&str>,
    progress: &dyn Fn(f64, Option<&str>),
    cancel: &AtomicBool,
) -> Result<Analysis, String> {
    let dialect = match sniff(path)? {
        "unknown" => match hint {
            Some("postgres") => "postgres",
            _ => "mysql",
        },
        d => d,
    };
    let input = Input::open(path)?;
    let meta = std::fs::metadata(path).map_err(|e| e.to_string())?;
    let mut a = Analysis {
        file: path.to_string_lossy().into_owned(),
        bytes: meta.len(),
        modified: modified(path),
        compressed: input.compressed,
        uncompressed_bytes: 0,
        dialect,
        tool: None,
        server_version: None,
        source_database: None,
        charset: None,
        collate: None,
        statements: 0,
        largest_statement: 0,
        tables: Vec::new(),
        total_rows: 0,
        views: 0,
        triggers: 0,
        routines: 0,
        events: 0,
        definers: Vec::new(),
        left_out: Vec::new(),
        notes: Vec::new(),
    };
    let mut objects: BTreeMap<String, Kind> = BTreeMap::new();
    let mut data: HashMap<String, TableInfo> = HashMap::new();
    let mut triggers = HashSet::new();
    let mut routines = HashSet::new();
    let mut events = HashSet::new();
    let mut definers = HashSet::new();
    let mut databases: Vec<String> = Vec::new();
    let mut left: BTreeMap<&'static str, u64> = BTreeMap::new();
    let mut header = false;
    let mut last = Instant::now();
    let mut copy_table: Option<String> = None;
    let fraction = |input: &Input| input.fraction();
    let note_database = |name: Option<String>, databases: &mut Vec<String>| {
        if let Some(n) = name
            && !databases.contains(&n)
        {
            databases.push(n);
        }
    };
    macro_rules! tick {
        ($input:expr, $table:expr) => {
            if last.elapsed() > Duration::from_millis(200) {
                if cancel.load(Ordering::Relaxed) {
                    return Err("cancelled".into());
                }
                progress(fraction($input), $table);
                last = Instant::now();
            }
        };
    }
    if dialect == "mysql" {
        let mut s = MysqlScanner::new(input, LIMIT);
        while let Some(item) = s.next_item()? {
            let Item::Statement { text, line } = item else {
                continue;
            };
            a.statements += 1;
            a.largest_statement = a.largest_statement.max(text.len() as u64);
            if a.statements == 1 {
                let head = String::from_utf8_lossy(&text[..text.len().min(2048)]);
                if let Some(l) = head
                    .lines()
                    .find(|l| l.starts_with("-- MySQL dump") || l.starts_with("-- MariaDB dump"))
                {
                    header = true;
                    a.tool = Some(
                        if l.contains("MariaDB") {
                            "mariadb-dump"
                        } else {
                            "mysqldump"
                        }
                        .into(),
                    );
                }
                if let Some(l) = head.lines().find(|l| l.starts_with("-- Host:"))
                    && let Some(db) = l.split("Database:").nth(1)
                {
                    a.source_database = Some(db.trim().to_string()).filter(|d| !d.is_empty());
                }
                a.server_version = header_value(&head, "-- Server version").map(str::to_string);
            }
            let info = classify_mysql(&text);
            if info.sql_mode {
                s.no_backslash_escapes = String::from_utf8_lossy(&text)
                    .to_ascii_uppercase()
                    .contains("NO_BACKSLASH_ESCAPES");
            }
            if let Some(q) = &info.qualifier {
                return Err(format!(
                    "the statement on line {line} names the database `{q}` explicitly: restore needs a dump of one database without qualified names"
                ));
            }
            if let Some(kind) = info.skip {
                *left.entry(kind).or_default() += 1;
                if matches!(kind, "USE" | "CREATE DATABASE" | "DROP DATABASE") {
                    note_database(info.database.clone(), &mut databases);
                }
                if kind == "CREATE DATABASE" {
                    a.charset = info.charset.clone();
                    a.collate = info.collate.clone();
                }
                continue;
            }
            if let Some((_, _, acc)) = &info.definer
                && acc != "CURRENT_USER"
            {
                definers.insert(acc.clone());
            }
            let name = info.objects.first().cloned();
            match info.kind {
                Kind::CreateTable | Kind::CreateView => {
                    if let Some(n) = &name {
                        objects.insert(n.clone(), info.kind);
                    }
                }
                Kind::DropTable | Kind::DropView => {
                    for n in &info.objects {
                        objects.remove(n);
                    }
                }
                Kind::CreateTrigger => {
                    triggers.insert(name.clone().unwrap_or_default());
                }
                Kind::CreateRoutine => {
                    routines.insert(name.clone().unwrap_or_default());
                }
                Kind::CreateEvent => {
                    events.insert(name.clone().unwrap_or_default());
                }
                Kind::Insert => {
                    if let Some(n) = &name {
                        let rows = count_tuples(&text, info.body, !s.no_backslash_escapes);
                        let e = data.entry(n.clone()).or_insert_with(|| TableInfo {
                            name: n.clone(),
                            rows: 0,
                            data_bytes: 0,
                        });
                        e.rows += rows;
                        e.data_bytes += text.len() as u64;
                    }
                }
                _ => {}
            }
            let table = name
                .as_deref()
                .filter(|_| matches!(info.kind, Kind::Insert | Kind::CreateTable));
            let f = s.offset();
            a.uncompressed_bytes = f;
            if last.elapsed() > Duration::from_millis(200) {
                if cancel.load(Ordering::Relaxed) {
                    return Err("cancelled".into());
                }
                progress(s.src.r.fraction(), table);
                last = Instant::now();
            }
        }
        a.uncompressed_bytes = s.offset();
        if header && !String::from_utf8_lossy(&s.trailing).contains("Dump completed") {
            return Err(
                "the dump has no \"Dump completed\" line at the end: it looks incomplete".into(),
            );
        }
        s.src.r.finish()?;
    } else {
        let mut s = PgScanner::new(input, LIMIT);
        while let Some(item) = s.next_item()? {
            match item {
                Item::CopyLine { data: line, end } => {
                    if let Some(t) = &copy_table {
                        if end {
                            copy_table = None;
                        } else if let Some(e) = data.get_mut(t) {
                            e.rows += 1;
                            e.data_bytes += line.len() as u64;
                        }
                    }
                    tick!(&s.src.r, copy_table.as_deref());
                    continue;
                }
                Item::Meta { text, .. } => {
                    let meta = String::from_utf8_lossy(&text);
                    let mut parts = meta.split_whitespace();
                    match parts.next() {
                        Some("\\connect" | "\\c") => {
                            *left.entry("\\connect").or_default() += 1;
                            let db = parts
                                .find(|p| !p.starts_with('-'))
                                .map(|d| d.trim_matches('"').to_string());
                            note_database(db, &mut databases);
                        }
                        Some("\\restrict" | "\\unrestrict") => {}
                        _ => *left.entry("psql meta-commands").or_default() += 1,
                    }
                    continue;
                }
                Item::Delimiter(_) => continue,
                Item::Statement { text, .. } => {
                    a.statements += 1;
                    a.largest_statement = a.largest_statement.max(text.len() as u64);
                    if a.statements == 1 {
                        let head = String::from_utf8_lossy(&text[..text.len().min(4096)]);
                        if head.contains("-- PostgreSQL database dump") {
                            header = true;
                            a.tool = Some("pg_dump".into());
                        }
                        a.server_version = header_value(&head, "-- Dumped from database version")
                            .map(str::to_string);
                    }
                    let info = classify_pg(&text);
                    if let Some(kind) = info.skip {
                        *left.entry(kind).or_default() += 1;
                        if kind == "CREATE DATABASE" || kind == "DROP DATABASE" {
                            note_database(info.database.clone(), &mut databases);
                        }
                        continue;
                    }
                    let name = info.objects.first().cloned();
                    match info.kind {
                        Kind::CreateTable | Kind::CreateView => {
                            if let Some(n) = &name {
                                objects.insert(n.clone(), info.kind);
                            }
                        }
                        Kind::CreateTrigger => {
                            triggers.insert(name.clone().unwrap_or_default());
                        }
                        Kind::CreateRoutine => {
                            routines.insert(name.clone().unwrap_or_default());
                        }
                        Kind::Copy => {
                            if let Some(n) = &name {
                                data.entry(n.clone()).or_insert_with(|| TableInfo {
                                    name: n.clone(),
                                    rows: 0,
                                    data_bytes: 0,
                                });
                                copy_table = name.clone();
                            }
                        }
                        Kind::Insert => {
                            if let Some(n) = &name {
                                let rows = count_tuples(&text, info.body, false);
                                let e = data.entry(n.clone()).or_insert_with(|| TableInfo {
                                    name: n.clone(),
                                    rows: 0,
                                    data_bytes: 0,
                                });
                                e.rows += rows;
                                e.data_bytes += text.len() as u64;
                            }
                        }
                        _ => {}
                    }
                    tick!(&s.src.r, name.as_deref());
                }
            }
        }
        a.uncompressed_bytes = s.offset();
        if header
            && !String::from_utf8_lossy(&s.trailing).contains("PostgreSQL database dump complete")
        {
            return Err("the dump has no \"PostgreSQL database dump complete\" line at the end: it looks incomplete".into());
        }
        s.src.r.finish()?;
    }
    if a.statements == 0 {
        return Err("no SQL statements in this file".into());
    }
    if databases.len() > 1 {
        return Err(format!(
            "the dump holds more than one database ({}): dump only the one to restore",
            databases.join(", ")
        ));
    }
    if a.source_database.is_none() {
        a.source_database = databases.first().cloned();
    }
    for (name, kind) in &objects {
        match kind {
            Kind::CreateView => a.views += 1,
            _ => {
                data.entry(name.clone()).or_insert_with(|| TableInfo {
                    name: name.clone(),
                    rows: 0,
                    data_bytes: 0,
                });
            }
        }
    }
    let mut tables: Vec<TableInfo> = data
        .into_values()
        .filter(|t| objects.get(&t.name) != Some(&Kind::CreateView))
        .collect();
    tables.sort_by(|x, y| {
        y.rows
            .cmp(&x.rows)
            .then(y.data_bytes.cmp(&x.data_bytes))
            .then(x.name.cmp(&y.name))
    });
    a.total_rows = tables.iter().map(|t| t.rows).sum();
    a.tables = tables;
    a.triggers = triggers.len() as u64;
    a.routines = routines.len() as u64;
    a.events = events.len() as u64;
    let mut d: Vec<String> = definers.into_iter().collect();
    d.sort();
    a.definers = d;
    a.left_out = left
        .into_iter()
        .map(|(k, c)| LeftOut {
            kind: k.into(),
            count: c,
        })
        .collect();
    if !header {
        a.notes
            .push("no mysqldump / pg_dump header: completeness cannot be checked".into());
    }
    if a.tables.is_empty() {
        a.notes.push("no tables in this dump".into());
    }
    progress(1.0, None);
    Ok(a)
}

// MARK: restore

#[derive(Clone, Copy, Debug, PartialEq, serde::Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    /// Drop the database (after a snapshot) and recreate it from the dump.
    Replace,
    /// A new database; refused when the name exists.
    Create,
}
fn yes() -> bool {
    true
}
#[derive(Clone, Debug, serde::Deserialize, Serialize)]
pub struct Request {
    pub file: String,
    pub target: String,
    pub mode: Mode,
    /// Tables created empty: their INSERT / COPY data is left out. Missing: the project's
    /// `databases.<target>.skip_data` from .corescope.yml.
    #[serde(default)]
    pub skip_data: Option<Vec<String>>,
    #[serde(default)]
    pub drop_triggers: bool,
    /// PostgreSQL: leave out OWNER TO (local roles rarely match production's).
    #[serde(default = "yes")]
    pub drop_owners: bool,
    /// Snapshot an existing database before it is replaced.
    #[serde(default = "yes")]
    pub snapshot_first: bool,
    /// Run the project's `before_restore` / `after_restore` commands (.corescope.yml).
    #[serde(default = "yes")]
    pub run_hooks: bool,
    /// Close other sessions on the database before dropping it (else wait up to 30 s).
    #[serde(default = "yes")]
    pub kill_connections: bool,
    /// A server on the Mac: its user and password (from the app's Keychain).
    #[serde(default)]
    pub user: Option<String>,
    #[serde(default, skip_serializing)]
    pub password: Option<String>,
}
#[derive(Clone, Debug, Serialize, Default)]
pub struct Outcome {
    pub target: String,
    pub created: bool,
    pub seconds: u64,
    pub statements: u64,
    pub rows_skipped: u64,
    pub tables_without_data: Vec<String>,
    pub definers_replaced: u64,
    pub left_out: u64,
    pub snapshot: Option<String>,
    pub tables_in_database: Option<u64>,
    /// Other sessions closed before the drop.
    pub connections_closed: u64,
    /// The project commands that ran (before and after).
    pub hooks: Vec<String>,
    /// An after_restore command failed: the data is restored, the follow-up is not.
    pub after_restore_error: Option<String>,
}

/// The project that describes `target` on this server: (folder, project name, its spec).
pub fn database_spec(
    target: &str,
    e: &Endpoint,
    home: &Path,
) -> Option<(String, String, crate::projectconfig::DatabaseSpec)> {
    let list = crate::projects::load(&crate::projects::default_path(home));
    for p in list {
        let Some(found) = crate::projectconfig::load(Path::new(&p.folder)) else {
            continue;
        };
        let Some(config) = found.config else { continue };
        let Some(spec) = config.databases.get(target) else {
            continue;
        };
        let matches = match spec.server.as_deref() {
            None => true,
            Some(s) => e.container.as_deref() == Some(s) || s.parse::<u16>().ok() == Some(e.port),
        };
        if matches {
            return Some((p.folder, config.name.unwrap_or(p.name), spec.clone()));
        }
    }
    None
}
/// A project's commands, one after the other, in its folder (the user's login shell), with the
/// output in the job's log. The first failure stops.
fn run_hooks(
    commands: &[String],
    folder: &str,
    env: &[(&str, String)],
    job: &Job,
) -> Result<(), String> {
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into());
    for c in commands {
        job.check()?;
        job.log(&format!("$ {c}"));
        let mut child = Command::new(&shell)
            .args(["-l", "-c", c])
            .current_dir(folder)
            .envs(env.iter().map(|(k, v)| (*k, v.as_str())))
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|err| format!("{c}: {err}"))?;
        let lines = Arc::new(Mutex::new(Vec::<String>::new()));
        let mut readers = Vec::new();
        for pipe in [
            child
                .stdout
                .take()
                .map(|p| Box::new(p) as Box<dyn Read + Send>),
            child
                .stderr
                .take()
                .map(|p| Box::new(p) as Box<dyn Read + Send>),
        ]
        .into_iter()
        .flatten()
        {
            let sink = lines.clone();
            readers.push(std::thread::spawn(move || {
                let mut r = std::io::BufReader::new(pipe);
                let mut line = String::new();
                while std::io::BufRead::read_line(&mut r, &mut line).unwrap_or(0) > 0 {
                    if let Ok(mut l) = sink.lock() {
                        l.push(line.trim_end().to_string());
                    }
                    line.clear();
                }
            }));
        }
        let started = Instant::now();
        let status = loop {
            if let Some(st) = child.try_wait().map_err(|err| err.to_string())? {
                break st;
            }
            if job.cancelled() || started.elapsed() > Duration::from_secs(30 * 60) {
                let _ = child.kill();
                let _ = child.wait();
                return Err(if job.cancelled() {
                    "cancelled".into()
                } else {
                    format!("{c}: passed 30 min")
                });
            }
            if let Ok(mut l) = lines.lock() {
                for line in l.drain(..) {
                    job.log(&format!("  {line}"));
                }
            }
            std::thread::sleep(Duration::from_millis(200));
        };
        for r in readers {
            let _ = r.join();
        }
        if let Ok(mut l) = lines.lock() {
            for line in l.drain(..) {
                job.log(&format!("  {line}"));
            }
        }
        if !status.success() {
            return Err(format!("{c} exited with {}", status.code().unwrap_or(-1)));
        }
    }
    Ok(())
}

const SYSTEM: [&str; 7] = [
    "mysql",
    "sys",
    "information_schema",
    "performance_schema",
    "postgres",
    "template0",
    "template1",
];

/// (program, args, env) for a client run against `database` (None: the server, no database).
/// A client program, its arguments and environment.
type ClientCommand = (PathBuf, Vec<String>, Vec<(String, String)>);
fn client(
    e: &Endpoint,
    req: &Request,
    database: Option<&str>,
    query: Option<&str>,
    home: &Path,
) -> Result<ClientCommand, String> {
    let docker = || dbsnapshot::docker_cli(home).ok_or_else(|| "docker CLI not found".to_string());
    let db = database.unwrap_or("");
    match (&e.container, e.kind) {
        (Some(c), "mysql") => {
            let mut args = vec!["exec".into()];
            if query.is_none() {
                args.push("-i".into());
            }
            let run = match query {
                Some(_) => r#""$M" -u"$U" -N -B --raw ${2:+-D "$2"} -e "$1""#,
                None => {
                    r#""$M" -u"$U" --default-character-set=utf8mb4 --max-allowed-packet=1073741824 -D "$2""#
                }
            };
            args.extend([
                c.clone(),
                "sh".into(),
                "-c".into(),
                format!(r#"{MYSQL_ENV}M="$(command -v mariadb || command -v mysql)"; exec {run}"#),
                "sh".into(),
                query.unwrap_or("").into(),
                db.into(),
            ]);
            Ok((docker()?, args, vec![]))
        }
        (Some(c), "postgres") => {
            let mut args = vec!["exec".into()];
            if query.is_none() {
                args.push("-i".into());
            }
            let run = match query {
                Some(_) => {
                    r#"psql -X -At -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d "${2:-postgres}" -c "$1""#
                }
                None => r#"psql -X -q -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d "$2""#,
            };
            args.extend([
                c.clone(),
                "sh".into(),
                "-c".into(),
                format!(r#"export PGPASSWORD="${{POSTGRES_PASSWORD:-}}"; exec {run}"#),
                "sh".into(),
                query.unwrap_or("").into(),
                db.into(),
            ]);
            Ok((docker()?, args, vec![]))
        }
        (None, "mysql") => {
            let tool = dbsnapshot::host_tool(&["mariadb", "mysql"])
                .ok_or("the mysql client is not installed on this Mac")?;
            let mut args = vec![
                "-h127.0.0.1".into(),
                format!("-P{}", e.port),
                format!("-u{}", req.user.as_deref().unwrap_or("root")),
            ];
            match query {
                Some(q) => {
                    args.extend(["-N".into(), "-B".into(), "--raw".into()]);
                    if !db.is_empty() {
                        args.push(format!("-D{db}"));
                    }
                    args.extend(["-e".into(), q.into()]);
                }
                None => args.extend([
                    "--default-character-set=utf8mb4".into(),
                    "--max-allowed-packet=1073741824".into(),
                    format!("-D{db}"),
                ]),
            }
            let env = req
                .password
                .clone()
                .map(|p| vec![("MYSQL_PWD".to_string(), p)])
                .unwrap_or_default();
            Ok((tool, args, env))
        }
        (None, "postgres") => {
            let tool =
                dbsnapshot::host_tool(&["psql"]).ok_or("psql is not installed on this Mac")?;
            let mut args: Vec<String> = vec![
                "-X".into(),
                "-h".into(),
                "127.0.0.1".into(),
                "-p".into(),
                e.port.to_string(),
                "-w".into(),
                "-v".into(),
                "ON_ERROR_STOP=1".into(),
            ];
            if let Some(u) = &req.user {
                args.extend(["-U".into(), u.clone()]);
            }
            args.extend([
                "-d".into(),
                if db.is_empty() {
                    "postgres".into()
                } else {
                    db.into()
                },
            ]);
            match query {
                Some(q) => args.extend(["-At".into(), "-c".into(), q.into()]),
                None => args.push("-q".into()),
            }
            let env = req
                .password
                .clone()
                .map(|p| vec![("PGPASSWORD".to_string(), p)])
                .unwrap_or_default();
            Ok((tool, args, env))
        }
        _ => Err("restoring a dump works with MySQL/MariaDB and PostgreSQL".into()),
    }
}
fn clean_error(stderr: &str) -> String {
    stderr
        .lines()
        .filter(|l| !l.contains("Using a password") && !l.trim().is_empty())
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(600)
        .collect()
}
/// One query; its output (MySQL: tab-separated, unescaped).
pub(crate) fn query(
    e: &Endpoint,
    req: &Request,
    database: Option<&str>,
    sql: &str,
    home: &Path,
) -> Result<String, String> {
    let (program, args, env) = client(e, req, database, Some(sql), home)?;
    let out = Command::new(program)
        .args(args)
        .envs(env)
        .env("PGCONNECT_TIMEOUT", "5")
        .stdin(Stdio::null())
        .output()
        .map_err(|err| err.to_string())?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        Err(clean_error(&String::from_utf8_lossy(&out.stderr)))
    }
}
/// Newlines before a statement's first code byte (past whitespace and comments).
fn newlines_before_code(text: &[u8]) -> u64 {
    let n = text.len();
    let mut i = 0;
    let mut lines = 0;
    while i < n {
        let b = text[i];
        if b == b'\n' {
            lines += 1;
            i += 1;
        } else if b.is_ascii_whitespace() {
            i += 1;
        } else if b == b'#' || (b == b'-' && text.get(i + 1) == Some(&b'-')) {
            while i < n && text[i] != b'\n' {
                i += 1;
            }
        } else if b == b'/' && text.get(i + 1) == Some(&b'*') && text.get(i + 2) != Some(&b'!') {
            let end = text[i + 2..]
                .windows(2)
                .position(|w| w == b"*/")
                .map_or(n, |j| i + 2 + j + 2);
            lines += text[i..end].iter().filter(|&&c| c == b'\n').count() as u64;
            i = end;
        } else {
            break;
        }
    }
    lines
}
pub(crate) fn safe_word(s: &str) -> bool {
    !s.is_empty() && s.len() <= 64 && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
}

/// Statement text written to the client, with the dump line each part came from (an error
/// names the client's line; this gives the dump's).
struct Out<W: Write> {
    w: W,
    line: u64,
    marks: Vec<(u64, i64)>,
}
impl<W: Write> Out<W> {
    fn put(&mut self, bytes: &[u8]) -> std::io::Result<()> {
        self.line += bytes.iter().filter(|&&b| b == b'\n').count() as u64;
        self.w.write_all(bytes)
    }
    fn at(&mut self, dump_line: u64, leading_newlines: u64) {
        let off = (self.line + leading_newlines) as i64 - dump_line as i64;
        if self.marks.last().map(|m| m.1) != Some(off) {
            self.marks.push((self.line, off));
        }
    }
}
/// "ERROR 1050 (42S01) at line 29: …" / "psql:<stdin>:29: ERROR: …" → the dump's line.
fn map_error(stderr: &str, marks: &[(u64, i64)]) -> String {
    let dump_line = |out_line: u64| -> Option<u64> {
        let i = marks.partition_point(|m| m.0 < out_line);
        let off = marks.get(i.checked_sub(1)?)?.1;
        u64::try_from(out_line as i64 - off).ok()
    };
    let text = clean_error(stderr);
    let find = |marker: &str| -> Option<(usize, usize, u64)> {
        let s = text.find(marker)? + marker.len();
        let digits: String = text[s..]
            .chars()
            .take_while(|c| c.is_ascii_digit())
            .collect();
        Some((s, s + digits.len(), digits.parse().ok()?))
    };
    for marker in ["at line ", "psql:<stdin>:"] {
        if let Some((s, e, n)) = find(marker)
            && let Some(line) = dump_line(n)
        {
            let label = if marker == "at line " {
                "at dump line "
            } else {
                "dump line "
            };
            return format!("{}{label}{line}{}", &text[..s - marker.len()], &text[e..]);
        }
    }
    text
}

/// Restores `req` into `e`. Analysis first (cached), then: snapshot, drop/create, import.
pub fn restore(req: &Request, e: &Endpoint, job: &Job, home: &Path) -> Result<Outcome, String> {
    let started = Instant::now();
    let path = PathBuf::from(&req.file);
    let target = req.target.as_str();
    if !safe_word(target) {
        return Err(format!(
            "invalid database name: {target:?} (letters, digits and _)"
        ));
    }
    if SYSTEM.contains(&target.to_ascii_lowercase().as_str()) {
        return Err(format!("{target} is a system database"));
    }
    if let Some(c) = &e.container
        && !dbsnapshot::valid_container(c)
    {
        return Err("invalid container name".into());
    }
    job.phase("analyzing", "Reading the dump");
    let a = analyze_cached(&path, Some(e.kind), Some(job))?;
    if a.dialect != e.kind {
        return Err(format!(
            "this is a {} dump and the server is {}",
            a.dialect, e.kind
        ));
    }
    let names: HashSet<&str> = a.tables.iter().map(|t| t.name.as_str()).collect();
    let spec = database_spec(target, e, home);
    let skip_list: Vec<String> = match &req.skip_data {
        Some(list) => {
            if let Some(unknown) = list.iter().find(|t| !names.contains(t.as_str())) {
                return Err(format!("{unknown} is not a table of this dump"));
            }
            list.clone()
        }
        // The project's defaults, for the tables this dump has.
        None => spec
            .as_ref()
            .map(|(_, _, s)| {
                s.skip_data
                    .iter()
                    .filter(|t| names.contains(t.as_str()))
                    .cloned()
                    .collect()
            })
            .unwrap_or_default(),
    };
    let skip: HashSet<&str> = skip_list.iter().map(String::as_str).collect();
    let hook_env: Vec<(&str, String)> = vec![
        ("CORESCOPE_DATABASE", target.to_string()),
        ("CORESCOPE_DUMP", req.file.clone()),
        ("CORESCOPE_DB_KIND", e.kind.to_string()),
        (
            "CORESCOPE_DB_CONTAINER",
            e.container.clone().unwrap_or_default(),
        ),
        ("CORESCOPE_DB_PORT", e.port.to_string()),
    ];
    let list = match e.kind {
        "mysql" => query(e, req, None, "SHOW DATABASES", home)?,
        _ => query(e, req, None, "select datname from pg_database", home)?,
    };
    let exists = list.lines().any(|l| l.trim() == target);
    if req.mode == Mode::Create && exists {
        return Err(format!(
            "{target} already exists: choose replace, or another name"
        ));
    }
    let mut outcome = Outcome {
        target: target.into(),
        created: !exists,
        ..Outcome::default()
    };
    if req.run_hooks
        && let Some((folder, project, s)) = &spec
        && !s.before_restore.is_empty()
    {
        job.phase("before", &format!("before_restore ({project})"));
        run_hooks(&s.before_restore, folder, &hook_env, job)
            .map_err(|err| format!("before_restore: {err} (the database was not touched)"))?;
        outcome.hooks.extend(s.before_restore.iter().cloned());
    }
    if exists && req.snapshot_first {
        job.phase(
            "snapshot",
            &format!("Snapshot of {target} before replacing it"),
        );
        let dir = dbsnapshot::default_dir(home);
        let s = dbsnapshot::create(e, target, &dir, home, crate::now() as i64)
            .map_err(|err| format!("snapshot failed, nothing was changed: {err}"))?;
        job.log(&format!("Snapshot {} ({} KB)", s.id, s.bytes / 1024));
        outcome.snapshot = Some(s.id);
    }
    job.check()?;
    // What the server allows.
    let mut accounts: HashSet<String> = HashSet::new();
    let mut log_bin_off = false;
    let mut adapt = Adapt::default();
    if e.kind == "mysql" {
        let version = query(e, req, None, "SELECT VERSION()", home).unwrap_or_default();
        let mysql = !version.trim().is_empty() && !version.contains("MariaDB");
        adapt.no_auto_create_user = mysql
            && version
                .trim()
                .split('.')
                .next()
                .and_then(|major| major.parse::<u32>().ok())
                .is_some_and(|major| major >= 8);
        // mysqldump leaves generated columns out of its INSERTs; mariadb-dump writes their values.
        let from_mysql = a.tool.as_deref() == Some("mysqldump")
            && !a
                .server_version
                .as_deref()
                .is_some_and(|v| v.contains("MariaDB"));
        if mysql && !from_mysql {
            adapt.generated = Some(a.tables.iter().map(|t| (t.name.clone(), t.rows)).collect());
        }
        if let Ok(list) = query(
            e,
            req,
            None,
            "SELECT CONCAT(User,'@',Host) FROM mysql.user",
            home,
        ) {
            accounts = list.lines().map(|l| l.trim().to_string()).collect();
        }
        log_bin_off = query(e, req, None, "SET SESSION sql_log_bin = 0", home).is_ok();
        let packet: u64 = query(e, req, None, "SELECT @@max_allowed_packet", home)?
            .trim()
            .parse()
            .unwrap_or(0);
        if packet > 0 && a.largest_statement + 4096 > packet {
            let want = ((a.largest_statement + (a.largest_statement >> 3)) >> 20)
                .max(1)
                .saturating_add(1)
                << 20;
            let want = want.min(1 << 30);
            query(e, req, None, &format!("SET GLOBAL max_allowed_packet = {want}"), home).map_err(|err| {
                format!(
                    "the dump has a {} MB statement and the server allows {} MB (max_allowed_packet); raising it failed: {err}",
                    a.largest_statement >> 20,
                    packet >> 20
                )
            })?;
            job.log(&format!(
                "max_allowed_packet raised from {} MB to {} MB (until the server restarts)",
                packet >> 20,
                want >> 20
            ));
        }
    }
    job.phase(
        "preparing",
        &format!(
            "{} {target}",
            if exists { "Recreating" } else { "Creating" }
        ),
    );
    job.set(|s| s.database_touched = true);
    if e.kind == "mysql" {
        if exists {
            // Sessions on the database (an app, its workers) would hold the DROP for a long time.
            let ids: Vec<u64> = query(
                e,
                req,
                None,
                &format!("SELECT ID FROM information_schema.PROCESSLIST WHERE DB = '{target}' AND ID <> CONNECTION_ID()"),
                home,
            )
            .unwrap_or_default()
            .lines()
            .filter_map(|l| l.trim().parse().ok())
            .collect();
            if !ids.is_empty() {
                job.log(&format!(
                    "{} other sessions on {target}{}",
                    ids.len(),
                    if req.kill_connections {
                        ": closing them"
                    } else {
                        ""
                    }
                ));
                if req.kill_connections {
                    for id in &ids {
                        if query(e, req, None, &format!("KILL {id}"), home).is_ok() {
                            outcome.connections_closed += 1;
                        }
                    }
                }
            }
            query(e, req, None, &format!("SET SESSION lock_wait_timeout = 30; DROP DATABASE `{target}`"), home).map_err(|err| {
                if err.contains("1205") {
                    format!("{target} is in use by another session (waited 30 s): stop what uses it, or close its connections")
                } else {
                    err
                }
            })?;
        }
        let charset = a
            .charset
            .clone()
            .filter(|c| safe_word(c))
            .unwrap_or_else(|| "utf8mb4".into());
        let collate = a.collate.clone().filter(|c| safe_word(c));
        let create = |collate: Option<&str>| {
            let c = collate.map(|c| format!(" COLLATE {c}")).unwrap_or_default();
            query(
                e,
                req,
                None,
                &format!("CREATE DATABASE `{target}` CHARACTER SET {charset}{c}"),
                home,
            )
        };
        // A MySQL 8 collation (utf8mb4_0900_ai_ci) does not exist on MariaDB: the default then.
        if create(collate.as_deref()).is_err() {
            create(None)?;
        }
        query(
            e,
            req,
            Some(target),
            &format!(
                "CREATE TABLE `{MARKER}` (started_at datetime NOT NULL, dump varchar(255) NOT NULL) COMMENT='CoreScope: a dump restore is running or failed; dropped when it succeeds'; INSERT INTO `{MARKER}` VALUES (NOW(), '{}')",
                marker_name(&req.file)
            ),
            home,
        )?;
    } else {
        if exists {
            let _ = query(
                e,
                req,
                None,
                &format!(
                    "select pg_terminate_backend(pid) from pg_stat_activity where datname = '{target}' and pid <> pg_backend_pid()"
                ),
                home,
            );
            query(e, req, None, &format!("DROP DATABASE \"{target}\""), home)?;
        }
        query(e, req, None, &format!("CREATE DATABASE \"{target}\""), home)?;
        query(
            e,
            req,
            Some(target),
            &format!(
                "CREATE TABLE public.{MARKER} (started_at timestamptz NOT NULL DEFAULT now(), dump text NOT NULL); INSERT INTO public.{MARKER} (dump) VALUES ('{}')",
                marker_name(&req.file)
            ),
            home,
        )?;
    }
    job.phase("importing", "Importing");
    let (program, args, env) = client(e, req, Some(target), None, home)?;
    let mut child = Command::new(program)
        .args(args)
        .envs(env)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|err| err.to_string())?;
    let stderr = Arc::new(Mutex::new(String::new()));
    if let Some(mut pipe) = child.stderr.take() {
        let sink = stderr.clone();
        std::thread::spawn(move || {
            let mut buf = [0u8; 8192];
            while let Ok(n) = pipe.read(&mut buf) {
                if n == 0 {
                    break;
                }
                let mut s = sink.lock().unwrap_or_else(|p| p.into_inner());
                if s.len() < 64 * 1024 {
                    s.push_str(&String::from_utf8_lossy(&buf[..n]));
                }
            }
        });
    }
    let stdin = child.stdin.take().ok_or("client pipe")?;
    let mut out = Out {
        // Small, so progress follows what the server took.
        w: std::io::BufWriter::with_capacity(64 << 10, stdin),
        line: 1,
        marks: Vec::new(),
    };
    let input = Input::open(&path)?;
    // Progress comes from the server (docker exec buffers what is sent): tables created and the
    // table being loaded.
    let done = AtomicBool::new(false);
    let total = (a.tables.len() as u64 + a.views).max(1);
    let (result, status, marks, flushed) = std::thread::scope(|scope| {
        scope.spawn(|| server_progress(e, req, target, total, job, home, &done));
        let result = if e.kind == "mysql" {
            import_mysql(
                input,
                &mut out,
                req,
                &skip,
                &accounts,
                log_bin_off,
                &adapt,
                job,
                &mut outcome,
            )
        } else {
            import_pg(input, &mut out, req, &skip, job, &mut outcome)
        };
        let Out { mut w, marks, .. } = out;
        let flushed = w.flush();
        drop(w);
        if result.is_err() && job.cancelled() {
            let _ = child.kill();
        }
        let status = child.wait();
        done.store(true, Ordering::Relaxed);
        (result, status, marks, flushed)
    });
    let status = status.map_err(|err| err.to_string())?;
    // Give the stderr reader a moment to drain.
    std::thread::sleep(Duration::from_millis(100));
    let text = stderr.lock().map(|s| s.clone()).unwrap_or_default();
    if job.cancelled() {
        return Err("cancelled".into());
    }
    if !status.success() {
        let message = map_error(&text, &marks);
        let message = if message.is_empty() {
            result.err().unwrap_or_else(|| "the client failed".into())
        } else {
            message
        };
        return Err(message);
    }
    result?;
    flushed.map_err(|err| err.to_string())?;
    job.phase("checking", "Checking the result");
    let drop_marker = match e.kind {
        "mysql" => format!("DROP TABLE IF EXISTS `{MARKER}`"),
        _ => format!("DROP TABLE IF EXISTS public.{MARKER}"),
    };
    query(e, req, Some(target), &drop_marker, home)?;
    let count = match e.kind {
        "mysql" => query(
            e,
            req,
            None,
            &format!(
                "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '{target}'"
            ),
            home,
        ),
        _ => query(
            e,
            req,
            Some(target),
            "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema')",
            home,
        ),
    };
    outcome.tables_in_database = count.ok().and_then(|c| c.trim().parse().ok());
    outcome.tables_without_data = {
        let mut t = outcome.tables_without_data.clone();
        for name in &skip_list {
            if !t.contains(name) {
                t.push(name.clone());
            }
        }
        t.sort();
        t
    };
    if req.run_hooks
        && let Some((folder, project, s)) = &spec
        && !s.after_restore.is_empty()
    {
        job.phase("after", &format!("after_restore ({project})"));
        match run_hooks(&s.after_restore, folder, &hook_env, job) {
            Ok(()) => outcome.hooks.extend(s.after_restore.iter().cloned()),
            Err(err) => {
                job.log(&format!(
                    "after_restore failed: {err} (the data is restored)"
                ));
                outcome.after_restore_error = Some(err);
            }
        }
    }
    outcome.seconds = started.elapsed().as_secs();
    Ok(outcome)
}

/// Every 1.5 s while the client imports: tables already in the target and the statement it runs.
fn server_progress(
    e: &Endpoint,
    req: &Request,
    target: &str,
    total: u64,
    job: &Job,
    home: &Path,
    done: &AtomicBool,
) {
    let (sql, sep) = match e.kind {
        "mysql" => (
            format!(
                "SELECT (SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '{target}'), IFNULL((SELECT LEFT(REPLACE(REPLACE(INFO, '\\n', ' '), '\\t', ' '), 300) FROM information_schema.PROCESSLIST WHERE DB = '{target}' AND COMMAND = 'Query' AND ID <> CONNECTION_ID() LIMIT 1), '')"
            ),
            '\t',
        ),
        _ => (
            format!(
                "select (select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema')), coalesce((select replace(left(query, 300), E'\\n', ' ') from pg_stat_activity where datname = '{target}' and pid <> pg_backend_pid() and state = 'active' limit 1), '')"
            ),
            '|',
        ),
    };
    loop {
        for _ in 0..15 {
            if done.load(Ordering::Relaxed) {
                return;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        let database = if e.kind == "mysql" {
            None
        } else {
            Some(target)
        };
        let Ok(out) = query(e, req, database, &sql, home) else {
            continue;
        };
        let line = out.lines().next().unwrap_or("");
        let (count, info) = line.split_once(sep).unwrap_or((line, ""));
        // Less the restore's own marker table.
        let created = count.trim().parse::<u64>().unwrap_or(0).saturating_sub(1);
        let table = if info.trim().is_empty() {
            None
        } else if e.kind == "mysql" {
            classify_mysql(info.as_bytes()).objects.first().cloned()
        } else {
            classify_pg(info.as_bytes()).objects.first().cloned()
        };
        let fraction = (created as f64 / total as f64).min(0.99);
        job.set(|s| {
            s.fraction = s.fraction.max(fraction);
            if table.is_some() {
                s.table = table;
            }
        });
    }
}
impl Request {
    /// Only the credentials, for queries outside a restore.
    pub(crate) fn credentials(user: Option<&str>, password: Option<&str>) -> Request {
        Request {
            file: String::new(),
            target: String::new(),
            mode: Mode::Create,
            skip_data: None,
            drop_triggers: false,
            drop_owners: true,
            snapshot_first: false,
            run_hooks: false,
            kill_connections: false,
            user: user.map(str::to_string),
            password: password.map(str::to_string),
        }
    }
}
/// Other sessions connected to `database` (an app, its workers, a GUI).
pub fn sessions(
    e: &Endpoint,
    database: &str,
    user: Option<&str>,
    password: Option<&str>,
    home: &Path,
) -> Result<u64, String> {
    if !safe_word(database) {
        return Err("invalid database name".into());
    }
    let req = Request {
        file: String::new(),
        target: database.into(),
        mode: Mode::Create,
        skip_data: None,
        drop_triggers: false,
        drop_owners: true,
        snapshot_first: false,
        run_hooks: false,
        kill_connections: false,
        user: user.map(str::to_string),
        password: password.map(str::to_string),
    };
    let sql = match e.kind {
        "mysql" => format!(
            "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE DB = '{database}' AND ID <> CONNECTION_ID()"
        ),
        _ => format!(
            "select count(*) from pg_stat_activity where datname = '{database}' and pid <> pg_backend_pid()"
        ),
    };
    query(e, &req, None, &sql, home)?
        .trim()
        .parse()
        .map_err(|_| "unexpected answer".to_string())
}
/// In the target while a restore runs; dropped when it succeeds (left behind it says the
/// database is incomplete).
pub const MARKER: &str = "__corescope_restore_incomplete";
fn marker_name(file: &str) -> String {
    Path::new(file)
        .file_name()
        .map(|n| {
            n.to_string_lossy()
                .chars()
                .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
                .take(200)
                .collect()
        })
        .unwrap_or_default()
}

// MARK: generated columns

/// mariadb-dump writes the values of generated columns in its INSERTs and MySQL refuses them
/// (error 3105). Such a table is created with those columns as plain ones, gets its data, and
/// then one ALTER TABLE drops them and adds them back as they were, with the keys and checks on
/// them (one statement: a key a foreign key needs cannot be dropped on its own).
#[derive(Debug, PartialEq)]
struct Generated {
    columns: Vec<String>,
    /// The CREATE TABLE with the generated columns as plain ones.
    create: Vec<u8>,
    alter: Vec<u8>,
}
fn quote_name(name: &str) -> String {
    format!("`{}`", name.replace('`', "``"))
}
/// The columns, keys and constraints between a CREATE TABLE's parentheses (byte ranges without
/// the whitespace around them) and where the closing parenthesis is.
fn table_elements(
    text: &[u8],
    from: usize,
    backslash: bool,
) -> Option<(Vec<(usize, usize)>, usize)> {
    let n = text.len();
    let mut i = from;
    loop {
        match text.get(i)? {
            b if b.is_ascii_whitespace() => i += 1,
            b'/' if text.get(i + 1) == Some(&b'*') && text.get(i + 2) != Some(&b'!') => {
                i += 2 + text[i + 2..].windows(2).position(|w| w == b"*/")? + 2
            }
            b'(' => break,
            _ => return None,
        }
    }
    let trim = |mut s: usize, mut e: usize| {
        while s < e && text[s].is_ascii_whitespace() {
            s += 1;
        }
        while e > s && text[e - 1].is_ascii_whitespace() {
            e -= 1;
        }
        (s, e)
    };
    let mut elements = Vec::new();
    let mut start = i + 1;
    let mut depth = 0u32;
    while i < n {
        let b = text[i];
        match b {
            b'\'' | b'"' | b'`' => {
                i += 1;
                while i < n {
                    if text[i] == b'\\' && backslash && b != b'`' {
                        i += 2;
                    } else if text[i] != b {
                        i += 1;
                    } else if text.get(i + 1) == Some(&b) {
                        i += 2;
                    } else {
                        break;
                    }
                }
            }
            b'/' if text.get(i + 1) == Some(&b'*') && text.get(i + 2) != Some(&b'!') => {
                i += 2 + text[i + 2..].windows(2).position(|w| w == b"*/")? + 2;
                continue;
            }
            b'#' => {
                while i < n && text[i] != b'\n' {
                    i += 1;
                }
            }
            b'-' if text.get(i + 1) == Some(&b'-')
                && text.get(i + 2).is_none_or(|c| c.is_ascii_whitespace()) =>
            {
                while i < n && text[i] != b'\n' {
                    i += 1;
                }
            }
            b'(' => depth += 1,
            b')' => {
                depth -= 1;
                if depth == 0 {
                    let (s, e) = trim(start, i);
                    if s < e {
                        elements.push((s, e));
                    }
                    return Some((elements, i));
                }
            }
            b',' if depth == 1 => {
                let (s, e) = trim(start, i);
                if s < e {
                    elements.push((s, e));
                }
                start = i + 1;
            }
            _ => {}
        }
        i += 1;
    }
    None
}
/// Names inside the first parenthesis of a key or constraint (a key's columns, a foreign key's
/// own columns, a check's expression).
fn first_group_names(t: &[Token]) -> Vec<String> {
    let Some(open) = t.iter().position(|x| x.tok == Tok::Punct(b'(')) else {
        return Vec::new();
    };
    let mut depth = 0;
    let mut names = Vec::new();
    for (k, x) in t.iter().enumerate().skip(open) {
        match x.tok {
            Tok::Punct(b'(') => depth += 1,
            Tok::Punct(b')') => {
                depth -= 1;
                if depth == 0 {
                    break;
                }
            }
            _ => names.extend(ident(t, k)),
        }
    }
    names
}
/// `text` is a CREATE TABLE of `table` whose name ends at `body`. None when it has no generated
/// column, or one this cannot move: under a foreign key, a column check or the partitioning.
fn generated_columns(text: &[u8], table: &str, body: usize, backslash: bool) -> Option<Generated> {
    struct Column {
        element: usize,
        name: String,
        /// `GENERATED ALWAYS AS (…) VIRTUAL|STORED`, and the space before it.
        cut: Option<(usize, usize)>,
        virtual_: bool,
        /// MariaDB's PERSISTENT, which MySQL calls STORED.
        persistent: Option<(usize, usize)>,
    }
    enum Drop {
        Primary,
        Index(String),
        Check(String),
        ForeignKey,
        Unnamed,
    }
    let (elements, close) = table_elements(text, body, backslash)?;
    let mut columns: Vec<Column> = Vec::new();
    let mut others: Vec<(usize, Drop, Vec<String>)> = Vec::new();
    for (k, &(s, e)) in elements.iter().enumerate() {
        let t = head_tokens(&text[s..e], 1 << 16, backslash);
        let mut i = 0;
        let mut constraint = None;
        if word(&t, 0).as_deref() == Some("CONSTRAINT") {
            i = 1;
            if !matches!(
                word(&t, 1).as_deref(),
                Some("PRIMARY" | "UNIQUE" | "FOREIGN" | "CHECK")
            ) {
                constraint = ident(&t, 1);
                i = 2;
            }
        }
        let drop = match word(&t, i).as_deref() {
            Some("PRIMARY") => Drop::Primary,
            Some("UNIQUE" | "KEY" | "INDEX" | "FULLTEXT" | "SPATIAL") => {
                i += 1;
                while matches!(word(&t, i).as_deref(), Some("KEY" | "INDEX")) {
                    i += 1;
                }
                match if punct(&t, i) == Some(b'(') {
                    constraint
                } else {
                    ident(&t, i)
                } {
                    Some(name) => Drop::Index(name),
                    None => Drop::Unnamed,
                }
            }
            Some("FOREIGN") => Drop::ForeignKey,
            Some("CHECK") => constraint.map_or(Drop::Unnamed, Drop::Check),
            Some("PERIOD") => continue,
            _ if i == 0 => {
                let name = ident(&t, 0)?;
                let mut column = Column {
                    element: k,
                    name,
                    cut: None,
                    virtual_: true,
                    persistent: None,
                };
                let mut depth = 0;
                for j in 1..t.len() {
                    match t[j].tok {
                        Tok::Punct(b'(') => depth += 1,
                        Tok::Punct(b')') => depth -= 1,
                        _ => {}
                    }
                    if depth != 0 || column.cut.is_some() {
                        if depth == 0 && word(&t, j).as_deref() == Some("CHECK") {
                            return None;
                        }
                        continue;
                    }
                    if word(&t, j).as_deref() != Some("AS") || punct(&t, j + 1) != Some(b'(') {
                        continue;
                    }
                    let from = if j >= 3
                        && word(&t, j - 1).as_deref() == Some("ALWAYS")
                        && word(&t, j - 2).as_deref() == Some("GENERATED")
                    {
                        j - 2
                    } else {
                        j
                    };
                    let mut d = 0;
                    let end = (j + 1..t.len()).find(|&x| {
                        match t[x].tok {
                            Tok::Punct(b'(') => d += 1,
                            Tok::Punct(b')') => d -= 1,
                            _ => {}
                        }
                        d == 0
                    })?;
                    let mut last = end;
                    match word(&t, end + 1).as_deref() {
                        Some("VIRTUAL") => last = end + 1,
                        Some(kind @ ("STORED" | "PERSISTENT")) => {
                            last = end + 1;
                            column.virtual_ = false;
                            if kind == "PERSISTENT" {
                                column.persistent = Some((s + t[last].start, s + t[last].end));
                            }
                        }
                        _ => {}
                    }
                    column.cut = Some((s + t[from - 1].end, s + t[last].end));
                }
                columns.push(column);
                continue;
            }
            _ => Drop::Unnamed,
        };
        others.push((k, drop, first_group_names(&t)));
    }
    let generated: Vec<&Column> = columns.iter().filter(|c| c.cut.is_some()).collect();
    if generated.is_empty() {
        return None;
    }
    let tail = head_tokens(&text[close + 1..], 1 << 16, backslash);
    if (0..tail.len()).any(|k| word(&tail, k).as_deref() == Some("PARTITION")) {
        return None;
    }
    let on = |names: &[String], virtual_only: bool| {
        generated.iter().any(|c| {
            (c.virtual_ || !virtual_only) && names.iter().any(|n| n.eq_ignore_ascii_case(&c.name))
        })
    };
    // MySQL lists keys on virtual columns after the others and the rest in the order they were
    // added: the keys after the first one on a stored column are added back too.
    let first_stored = others
        .iter()
        .filter(|(_, d, names)| {
            matches!(d, Drop::Primary | Drop::Index(_)) && on(names, false) && !on(names, true)
        })
        .map(|(k, _, _)| *k)
        .min();
    let mut again = Vec::new();
    for (k, drop, names) in &others {
        let after_stored = first_stored.is_some_and(|f| *k > f) && matches!(drop, Drop::Index(_));
        if !on(names, false) && !after_stored {
            continue;
        }
        let clause = match drop {
            Drop::Primary => "DROP PRIMARY KEY".to_string(),
            Drop::Index(name) => format!("DROP INDEX {}", quote_name(name)),
            Drop::Check(name) => format!("DROP CHECK {}", quote_name(name)),
            Drop::ForeignKey | Drop::Unnamed => return None,
        };
        again.push((*k, clause));
    }
    let mut alter = format!("ALTER TABLE {} ", quote_name(table)).into_bytes();
    let mut first = true;
    let mut part = |alter: &mut Vec<u8>, bytes: &[u8]| {
        if !first {
            alter.extend_from_slice(b", ");
        }
        first = false;
        alter.extend_from_slice(bytes);
    };
    for (_, clause) in &again {
        part(&mut alter, clause.as_bytes());
    }
    for c in &generated {
        part(
            &mut alter,
            format!("DROP COLUMN {}", quote_name(&c.name)).as_bytes(),
        );
    }
    for c in &generated {
        let (s, e) = elements[c.element];
        let mut def = b"ADD COLUMN ".to_vec();
        match c.persistent {
            Some((a, b)) => {
                def.extend_from_slice(&text[s..a]);
                def.extend_from_slice(b"STORED");
                def.extend_from_slice(&text[b..e]);
            }
            None => def.extend_from_slice(&text[s..e]),
        }
        match columns.iter().rev().find(|p| p.element < c.element) {
            Some(p) => def.extend_from_slice(format!(" AFTER {}", quote_name(&p.name)).as_bytes()),
            None => def.extend_from_slice(b" FIRST"),
        }
        part(&mut alter, &def);
    }
    for (k, _) in &again {
        let (s, e) = elements[*k];
        let mut add = b"ADD ".to_vec();
        add.extend_from_slice(&text[s..e]);
        part(&mut alter, &add);
    }
    let mut create = text.to_vec();
    for c in generated.iter().rev() {
        if let Some((a, b)) = c.cut {
            create.drain(a..b);
        }
    }
    Some(Generated {
        columns: generated.iter().map(|c| c.name.clone()).collect(),
        create,
        alter,
    })
}

/// A table created with its generated columns as plain ones, until its rows are in.
struct Refill {
    table: String,
    alter: Vec<u8>,
    /// The CREATE TABLE's dump line, for an error in the ALTER.
    line: u64,
    rows: u64,
    seen: u64,
}
fn put_refill<W: Write>(
    out: &mut Out<W>,
    r: &Refill,
    delim: &[u8],
    job: &Job,
) -> std::io::Result<()> {
    job.log(&format!("Table {}: generated columns added back", r.table));
    out.at(r.line, 0);
    out.put(&r.alter)?;
    out.put(delim)?;
    out.put(b"\n")
}

/// What a MySQL target refuses from this dump, adapted on the way.
#[derive(Default)]
struct Adapt {
    /// The dump may hold values for generated columns (MariaDB): the rows of each table.
    generated: Option<HashMap<String, u64>>,
    /// MySQL 8 dropped the sql_mode NO_AUTO_CREATE_USER, which MariaDB and MySQL 5.7 dumps set
    /// for their triggers and routines.
    no_auto_create_user: bool,
}
/// `SET sql_mode = '…,NO_AUTO_CREATE_USER,…'` without that mode.
fn without_no_auto_create_user(text: &mut Vec<u8>) {
    const MODE: &[u8] = b"NO_AUTO_CREATE_USER";
    while let Some(at) = text
        .windows(MODE.len())
        .position(|w| w.eq_ignore_ascii_case(MODE))
    {
        let end = at + MODE.len();
        if text.get(end) == Some(&b',') {
            text.drain(at..=end);
        } else if at > 0 && text[at - 1] == b',' {
            text.drain(at - 1..end);
        } else {
            text.drain(at..end);
        }
    }
}

/// Feeds a MySQL dump to the client, filtered.
#[allow(clippy::too_many_arguments)]
fn import_mysql<W: Write>(
    input: Input,
    out: &mut Out<W>,
    req: &Request,
    skip: &HashSet<&str>,
    accounts: &HashSet<String>,
    log_bin_off: bool,
    adapt: &Adapt,
    job: &Job,
    outcome: &mut Outcome,
) -> Result<(), String> {
    let io = |err: std::io::Error| format!("the client stopped reading: {err}");
    let mut s = MysqlScanner::new(input, LIMIT);
    let mut delim = b";".to_vec();
    out.put(b"SET SESSION foreign_key_checks = 0;\nSET SESSION unique_checks = 0;\nSET SESSION autocommit = 0;\n").map_err(io)?;
    if log_bin_off {
        out.put(b"SET SESSION sql_log_bin = 0;\n").map_err(io)?;
    }
    let mut pending_bytes = 0usize;
    let mut pending = 0u32;
    let mut skipped_tables: HashSet<String> = HashSet::new();
    let mut table: Option<String> = None;
    let mut refills: Vec<Refill> = Vec::new();
    while let Some(item) = s.next_item()? {
        job.check()?;
        let (text, line) = match item {
            Item::Delimiter(d) => {
                out.put(b"DELIMITER ").map_err(io)?;
                out.put(&d).map_err(io)?;
                out.put(b"\n").map_err(io)?;
                delim = d;
                continue;
            }
            Item::Statement { text, line } => (text, line),
            _ => continue,
        };
        let info = classify_mysql(&text);
        if info.sql_mode {
            s.no_backslash_escapes = String::from_utf8_lossy(&text)
                .to_ascii_uppercase()
                .contains("NO_BACKSLASH_ESCAPES");
        }
        if info.skip.is_some() {
            outcome.left_out += 1;
            continue;
        }
        if let Some(q) = &info.qualifier {
            return Err(format!("line {line} names the database `{q}`"));
        }
        let object = info.objects.first().cloned();
        if info.kind == Kind::Insert
            && let Some(o) = &object
            && skip.contains(o.as_str())
        {
            outcome.rows_skipped += count_tuples(&text, info.body, !s.no_backslash_escapes);
            skipped_tables.insert(o.clone());
            continue;
        }
        if info.kind == Kind::CreateTrigger && req.drop_triggers {
            outcome.left_out += 1;
            continue;
        }
        // After a table's last row, past its ENABLE KEYS and UNLOCK TABLES.
        if refills.iter().any(|r| r.seen >= r.rows) {
            let holds = match word(&head_tokens(&text, 1, true), 0).as_deref() {
                Some("UNLOCK") => true,
                Some("ALTER") => refills
                    .iter()
                    .any(|r| r.seen >= r.rows && object.as_deref() == Some(r.table.as_str())),
                _ => false,
            };
            if !holds {
                let (due, waiting) = std::mem::take(&mut refills)
                    .into_iter()
                    .partition::<Vec<_>, _>(|r| r.seen >= r.rows);
                refills = waiting;
                for r in &due {
                    put_refill(out, r, &delim, job).map_err(io)?;
                    outcome.statements += 1;
                }
            }
        }
        if info.kind == Kind::DropTable {
            refills.retain(|r| !info.objects.contains(&r.table));
        }
        let mut text = text;
        if info.kind == Kind::Insert
            && let Some(r) = refills
                .iter_mut()
                .find(|r| object.as_deref() == Some(r.table.as_str()))
        {
            r.seen += count_tuples(&text, info.body, !s.no_backslash_escapes);
        }
        if info.sql_mode && adapt.no_auto_create_user {
            without_no_auto_create_user(&mut text);
        }
        if info.kind == Kind::CreateTable
            && let Some(rows) = &adapt.generated
            && let Some(o) = &object
            && rows.get(o).is_some_and(|&n| n > 0)
            && !skip.contains(o.as_str())
            && let Some(g) = generated_columns(&text, o, info.body, !s.no_backslash_escapes)
        {
            job.log(&format!(
                "Table {o}: generated columns {} created plain for the data (MySQL refuses the values the dump has for them)",
                g.columns.join(", ")
            ));
            text = g.create;
            refills.push(Refill {
                table: o.clone(),
                alter: g.alter,
                line,
                rows: rows[o],
                seen: 0,
            });
        }
        if let Some((a, b, acc)) = &info.definer
            && acc != "CURRENT_USER"
            && !accounts.contains(acc)
        {
            text.splice(*a..*b, b"DEFINER=CURRENT_USER".iter().copied());
            outcome.definers_replaced += 1;
        }
        if let Some((a, b)) = info.rename {
            text.splice(a..b, format!("`{}`", req.target).bytes());
        }
        if matches!(info.kind, Kind::CreateTable | Kind::Insert) && object != table {
            if info.kind == Kind::CreateTable
                && let Some(o) = &object
            {
                job.log(&format!("Table {o}"));
            }
            table = object.clone();
            job.set(|st| st.table = object.clone());
        }
        let leading = newlines_before_code(&text);
        out.at(line, leading);
        out.put(&text).map_err(io)?;
        out.put(&delim).map_err(io)?;
        out.put(b"\n").map_err(io)?;
        outcome.statements += 1;
        pending += 1;
        pending_bytes += text.len();
        if pending >= 500 || pending_bytes >= 8 << 20 {
            out.put(b"COMMIT").map_err(io)?;
            out.put(&delim).map_err(io)?;
            out.put(b"\n").map_err(io)?;
            pending = 0;
            pending_bytes = 0;
        }
    }
    for r in &refills {
        put_refill(out, r, &delim, job).map_err(io)?;
        outcome.statements += 1;
    }
    out.put(b"COMMIT").map_err(io)?;
    out.put(&delim).map_err(io)?;
    out.put(b"\n").map_err(io)?;
    s.src.r.finish()?;
    let mut t: Vec<String> = skipped_tables.into_iter().collect();
    t.sort();
    outcome.tables_without_data = t;
    Ok(())
}

/// Feeds a PostgreSQL dump to psql, filtered.
fn import_pg<W: Write>(
    input: Input,
    out: &mut Out<W>,
    req: &Request,
    skip: &HashSet<&str>,
    job: &Job,
    outcome: &mut Outcome,
) -> Result<(), String> {
    let io = |err: std::io::Error| format!("psql stopped reading: {err}");
    let mut s = PgScanner::new(input, LIMIT);
    let mut skipping_copy = false;
    let mut skipped_tables: HashSet<String> = HashSet::new();
    let mut table: Option<String> = None;
    while let Some(item) = s.next_item()? {
        job.check()?;
        match item {
            Item::CopyLine { data, end } => {
                if skipping_copy {
                    if end {
                        skipping_copy = false;
                    } else {
                        outcome.rows_skipped += 1;
                    }
                    continue;
                }
                out.put(&data).map_err(io)?;
            }
            Item::Meta { text, line } => {
                let meta = String::from_utf8_lossy(&text);
                let cmd = meta.split_whitespace().next().unwrap_or("");
                if matches!(cmd, "\\connect" | "\\c" | "\\restrict" | "\\unrestrict") {
                    outcome.left_out += 1;
                    continue;
                }
                out.at(line, 0);
                out.put(&text).map_err(io)?;
                out.put(b"\n").map_err(io)?;
            }
            Item::Statement { text, line } => {
                let info = classify_pg(&text);
                if let Some(k) = info.skip
                    && (k != "owners" || req.drop_owners)
                {
                    outcome.left_out += 1;
                    continue;
                }
                let object = info.objects.first().cloned();
                if matches!(info.kind, Kind::Copy | Kind::Insert)
                    && let Some(o) = &object
                    && skip.contains(o.as_str())
                {
                    skipped_tables.insert(o.clone());
                    if info.kind == Kind::Copy {
                        skipping_copy = true;
                    } else {
                        outcome.rows_skipped += count_tuples(&text, info.body, false);
                    }
                    continue;
                }
                if info.kind == Kind::CreateTrigger && req.drop_triggers {
                    outcome.left_out += 1;
                    continue;
                }
                let mut text = text;
                if let Some(at) = info.schema_if_not_exists {
                    text.splice(at..at, b" IF NOT EXISTS".iter().copied());
                }
                if matches!(info.kind, Kind::CreateTable | Kind::Copy | Kind::Insert)
                    && object != table
                {
                    if info.kind == Kind::CreateTable
                        && let Some(o) = &object
                    {
                        job.log(&format!("Table {o}"));
                    }
                    table = object.clone();
                    job.set(|st| st.table = object.clone());
                }
                let leading = newlines_before_code(&text);
                out.at(line, leading);
                out.put(&text).map_err(io)?;
                out.put(b";\n").map_err(io)?;
                outcome.statements += 1;
            }
            Item::Delimiter(_) => {}
        }
    }
    s.src.r.finish()?;
    let mut t: Vec<String> = skipped_tables.into_iter().collect();
    t.sort();
    outcome.tables_without_data = t;
    Ok(())
}

// MARK: jobs

#[derive(Clone, Debug, Serialize, Default)]
pub struct JobStatus {
    pub id: String,
    /// "analyze" or "restore".
    pub kind: String,
    /// running, succeeded, failed, cancelled.
    pub state: String,
    pub phase: String,
    pub fraction: f64,
    pub table: Option<String>,
    pub file: String,
    pub target: Option<String>,
    pub started: i64,
    pub ended: Option<i64>,
    pub error: Option<String>,
    pub result: Option<serde_json::Value>,
    /// The last lines of the log.
    pub log: Vec<String>,
    pub log_file: Option<String>,
    /// The target was dropped or created: a failure may leave it incomplete.
    pub database_touched: bool,
    /// The server a restore writes to (label, container or port).
    pub server: Option<String>,
    pub container: Option<String>,
    pub port: Option<u16>,
}
pub struct Job {
    status: Mutex<JobStatus>,
    cancel: AtomicBool,
    log_file: Option<PathBuf>,
    started: Instant,
}
impl Job {
    fn new(
        id: String,
        kind: &str,
        file: &str,
        target: Option<String>,
        log_file: Option<PathBuf>,
    ) -> Job {
        Job {
            status: Mutex::new(JobStatus {
                id,
                kind: kind.into(),
                state: "running".into(),
                file: file.into(),
                target,
                started: crate::now() as i64,
                log_file: log_file.as_ref().map(|p| p.to_string_lossy().into_owned()),
                ..JobStatus::default()
            }),
            cancel: AtomicBool::new(false),
            log_file,
            started: Instant::now(),
        }
    }
    pub fn set(&self, f: impl FnOnce(&mut JobStatus)) {
        let mut s = self.status.lock().unwrap_or_else(|p| p.into_inner());
        f(&mut s);
    }
    pub fn log(&self, line: &str) {
        let secs = self.started.elapsed().as_secs();
        let entry = format!("[{:02}:{:02}] {line}", secs / 60, secs % 60);
        if let Some(path) = &self.log_file
            && let Ok(mut f) = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)
        {
            let _ = writeln!(f, "{entry}");
        }
        self.set(|s| {
            s.log.push(entry);
            if s.log.len() > 300 {
                s.log.remove(0);
            }
        });
    }
    fn phase(&self, phase: &str, line: &str) {
        self.set(|s| {
            s.phase = phase.into();
            s.fraction = 0.0;
        });
        self.log(line);
    }
    fn cancelled(&self) -> bool {
        self.cancel.load(Ordering::Relaxed)
    }
    fn check(&self) -> Result<(), String> {
        if self.cancelled() {
            Err("cancelled".into())
        } else {
            Ok(())
        }
    }
    pub fn snapshot(&self) -> JobStatus {
        self.status.lock().map(|s| s.clone()).unwrap_or_default()
    }
}
fn jobs() -> &'static Mutex<Vec<Arc<Job>>> {
    static JOBS: OnceLock<Mutex<Vec<Arc<Job>>>> = OnceLock::new();
    JOBS.get_or_init(|| Mutex::new(Vec::new()))
}
/// Analyses by file path, with the size and modification time they were made from.
type AnalysisCache = Mutex<HashMap<String, (u64, i64, Analysis)>>;
fn analyses() -> &'static AnalysisCache {
    static CACHE: OnceLock<AnalysisCache> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}
/// The analysis of `path`, read again only when the file changed.
pub fn analyze_cached(
    path: &Path,
    hint: Option<&str>,
    job: Option<&Job>,
) -> Result<Analysis, String> {
    let key = path.to_string_lossy().into_owned();
    let size = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
    let mtime = modified(path);
    if let Some((s, m, a)) = analyses().lock().ok().and_then(|c| c.get(&key).cloned())
        && s == size
        && m == mtime
    {
        return Ok(a);
    }
    let never = AtomicBool::new(false);
    let cancel = job.map(|j| &j.cancel).unwrap_or(&never);
    let progress = |f: f64, table: Option<&str>| {
        if let Some(j) = job {
            let t = table.map(str::to_string);
            j.set(|s| {
                s.fraction = f;
                if t.is_some() {
                    s.table = t;
                }
            });
        }
    };
    let a = analyze(path, hint, &progress, cancel)?;
    if let Ok(mut c) = analyses().lock() {
        c.insert(key, (size, mtime, a.clone()));
    }
    Ok(a)
}
fn register(job: Job) -> Arc<Job> {
    let job = Arc::new(job);
    if let Ok(mut list) = jobs().lock() {
        // Keep the last 20 finished ones.
        let finished: Vec<usize> = list
            .iter()
            .enumerate()
            .filter(|(_, j)| j.snapshot().state != "running")
            .map(|(i, _)| i)
            .collect();
        if finished.len() > 20 {
            let drop = finished[0];
            list.remove(drop);
        }
        list.push(job.clone());
    }
    job
}
fn finish(job: &Job, result: Result<serde_json::Value, String>) {
    let cancelled = job.cancelled();
    match &result {
        Ok(_) => job.log("Done"),
        Err(e) => {
            job.log(&format!(
                "{}: {e}",
                if cancelled { "Cancelled" } else { "Failed" }
            ));
            if job.snapshot().database_touched && job.snapshot().kind == "restore" {
                job.log("The target database may be incomplete: restore again, or its snapshot");
            }
        }
    }
    let record = job.log_file.as_ref().map(|l| l.with_extension("json"));
    let ended = |s: &mut JobStatus, result: &Result<serde_json::Value, String>| {
        s.ended = Some(crate::now() as i64);
        s.fraction = if result.is_ok() { 1.0 } else { s.fraction };
        match result {
            Ok(v) => {
                s.state = "succeeded".into();
                s.result = Some(v.clone());
            }
            Err(e) => {
                s.state = if cancelled {
                    "cancelled".into()
                } else {
                    "failed".into()
                };
                s.error = Some(e.clone());
            }
        }
    };
    // The record first (a CLI waiting on this job exits as soon as it ends).
    if let Some(path) = record {
        let mut st = job.snapshot();
        ended(&mut st, &result);
        st.log.clear();
        if let Ok(json) = serde_json::to_vec_pretty(&st) {
            let _ = std::fs::write(path, json);
        }
    }
    job.set(|s| ended(s, &result));
}
/// Past restores, newest first (a server's when `container` or `port` is given).
pub fn history(home: &Path, container: Option<&str>, port: Option<u16>) -> Vec<serde_json::Value> {
    let logs = home.join("Library/Application Support/CoreScope/logs");
    let mut out: Vec<serde_json::Value> = std::fs::read_dir(&logs)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| {
            let n = e.file_name().to_string_lossy().into_owned();
            n.starts_with("restore-") && n.ends_with(".json")
        })
        .filter_map(|e| {
            serde_json::from_slice::<serde_json::Value>(&std::fs::read(e.path()).ok()?).ok()
        })
        .filter(|v| match (container, port) {
            (Some(c), _) => v["container"].as_str() == Some(c),
            (None, Some(p)) => v["port"].as_u64() == Some(p as u64) && v["container"].is_null(),
            _ => true,
        })
        .collect();
    out.sort_by_key(|v| std::cmp::Reverse(v["started"].as_i64().unwrap_or(0)));
    out.truncate(30);
    out
}
fn new_id(kind: &str) -> String {
    static N: AtomicU64 = AtomicU64::new(0);
    format!(
        "{kind}-{}-{}",
        crate::now() as u64,
        N.fetch_add(1, Ordering::Relaxed)
    )
}
/// Analyses a dump on its own thread; the job's result is the analysis.
pub fn start_analyze(file: String, hint: Option<String>) -> String {
    let id = new_id("analyze");
    let job = register(Job::new(id.clone(), "analyze", &file, None, None));
    std::thread::spawn(move || {
        job.phase("analyzing", "Reading the dump");
        let r = analyze_cached(Path::new(&file), hint.as_deref(), Some(&job))
            .and_then(|a| serde_json::to_value(a).map_err(|e| e.to_string()));
        finish(&job, r);
    });
    id
}
/// Restores on its own thread; refused while another restore writes into the same target.
pub fn start_restore(req: Request, e: Endpoint, home: PathBuf) -> Result<String, String> {
    let busy = jobs().lock().map(|l| {
        l.iter().any(|j| {
            let s = j.snapshot();
            s.kind == "restore"
                && s.state == "running"
                && s.target.as_deref() == Some(req.target.as_str())
        })
    });
    if busy.unwrap_or(false) {
        return Err(format!("a restore into {} is already running", req.target));
    }
    let id = new_id("restore");
    let logs = home.join("Library/Application Support/CoreScope/logs");
    let _ = std::fs::create_dir_all(&logs);
    let log_file = logs.join(format!("{id}.log"));
    let job = register(Job::new(
        id.clone(),
        "restore",
        &req.file,
        Some(req.target.clone()),
        Some(log_file),
    ));
    job.set(|s| {
        s.server = Some(e.label.clone());
        s.container = e.container.clone();
        s.port = Some(e.port);
    });
    std::thread::spawn(move || {
        job.log(&format!(
            "Restore {} into {} ({}, {:?}); without data: {}",
            req.file,
            req.target,
            e.label,
            req.mode,
            match &req.skip_data {
                None => "the project's defaults".into(),
                Some(l) if l.is_empty() => "none".into(),
                Some(l) => l.join(", "),
            }
        ));
        let r = restore(&req, &e, &job, &home).and_then(|o| {
            job.log(&format!(
                "{} statements in {} s; {} rows left out; {} definers set to CURRENT_USER; {} statements left out",
                o.statements, o.seconds, o.rows_skipped, o.definers_replaced, o.left_out
            ));
            serde_json::to_value(o).map_err(|err| err.to_string())
        });
        finish(&job, r);
    });
    Ok(id)
}
pub fn status(id: &str) -> Option<JobStatus> {
    jobs()
        .lock()
        .ok()?
        .iter()
        .find(|j| j.snapshot().id == id)
        .map(|j| j.snapshot())
}
pub fn all() -> Vec<JobStatus> {
    jobs()
        .lock()
        .map(|l| l.iter().map(|j| j.snapshot()).collect())
        .unwrap_or_default()
}
pub fn cancel(id: &str) -> bool {
    let Ok(list) = jobs().lock() else {
        return false;
    };
    match list.iter().find(|j| j.snapshot().id == id) {
        Some(j) => {
            j.cancel.store(true, Ordering::Relaxed);
            true
        }
        None => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn statements(input: &str) -> Result<Vec<(String, u64)>, String> {
        let mut s = MysqlScanner::new(input.as_bytes(), 1 << 20);
        let mut out = Vec::new();
        while let Some(item) = s.next_item()? {
            match item {
                Item::Statement { text, line } => {
                    let info = classify_mysql(&text);
                    let t = String::from_utf8_lossy(&text).into_owned();
                    if info.sql_mode {
                        s.no_backslash_escapes =
                            t.to_ascii_uppercase().contains("NO_BACKSLASH_ESCAPES");
                    }
                    out.push((t.trim().to_string(), line));
                }
                Item::Delimiter(d) => {
                    out.push((format!("DELIMITER {}", String::from_utf8_lossy(&d)), 0))
                }
                _ => {}
            }
        }
        Ok(out)
    }
    /// Reads one byte at a time, like a slow pipe.
    struct OneByte<'a>(&'a [u8]);
    impl Read for OneByte<'_> {
        fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
            if self.0.is_empty() || buf.is_empty() {
                return Ok(0);
            }
            buf[0] = self.0[0];
            self.0 = &self.0[1..];
            Ok(1)
        }
    }

    const DUMP: &str = "-- MySQL dump 10.13  Distrib 8.4.0, for Linux (x86_64)\n--\n-- Host: localhost    Database: shop_prod\n-- Server version\t8.4.0\n\n/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;\nSET @@GLOBAL.GTID_PURGED=/*!80000 '+'*/ 'abc:1-9';\nCREATE DATABASE /*!32312 IF NOT EXISTS*/ `shop_prod` /*!40100 DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci */;\nUSE `shop_prod`;\nDROP TABLE IF EXISTS `clients`;\nCREATE TABLE `clients` (\n  `id` int NOT NULL,\n  `name` varchar(50)\n) ENGINE=InnoDB;\nLOCK TABLES `clients` WRITE;\nINSERT INTO `clients` VALUES (1,'Cliente; Um'),(2,'texto com \\'aspas\\' e -- tracos'),(3,'Cliente /* dois */'),(4,'D''Avila'),(5,'barra \\\\');\nINSERT INTO `clients` VALUES (6,'linha\nDELIMITER ;;\ncontinua');\nUNLOCK TABLES;\nDROP TABLE IF EXISTS `audit`;\nCREATE TABLE `audit` (`id` int);\nINSERT INTO `audit` VALUES (1),(2),(3),(4);\nDELIMITER ;;\n/*!50003 CREATE*/ /*!50017 DEFINER=`app`@`%`*/ /*!50003 TRIGGER `t1` BEFORE INSERT ON `clients` FOR EACH ROW BEGIN INSERT INTO audit VALUES ('insert; ok'); END */;;\nCREATE DEFINER=`root`@`localhost` FUNCTION `f`() RETURNS int\nBEGIN\n  RETURN 1;\nEND ;;\nDELIMITER ;\nGRANT SELECT ON *.* TO 'x'@'%';\n-- Dump completed on 2026-10-21 10:00:00\n";

    #[test]
    fn mysql_scanner_keeps_strings_and_delimiters() {
        let all = statements(DUMP).unwrap();
        let find = |p: &str| all.iter().find(|(s, _)| s.contains(p)).cloned();
        let first_insert = find("Cliente; Um").unwrap();
        assert!(
            first_insert.0.ends_with("'barra \\\\')"),
            "{}",
            first_insert.0
        );
        assert_eq!(count_tuples(first_insert.0.as_bytes(), 0, true), 5);
        let multi =
            find("DELIMITER ;;\ncontinua").expect("a DELIMITER line inside a string stays data");
        assert!(multi.0.starts_with("INSERT INTO `clients` VALUES (6,"));
        let trigger = find("TRIGGER `t1`").unwrap();
        assert!(trigger.0.ends_with("END */"), "{}", trigger.0);
        assert!(
            find("RETURN 1;\nEND").is_some(),
            "a function body with ; under DELIMITER ;;"
        );
        assert!(
            all.iter().any(|(s, _)| s == "DELIMITER ;;")
                && all.iter().any(|(s, _)| s == "DELIMITER ;")
        );
        // Byte by byte gives the same statements.
        let mut slow = MysqlScanner::new(OneByte(DUMP.as_bytes()), 1 << 20);
        let mut n = 0;
        while let Some(Item::Statement { .. } | Item::Delimiter(_)) = slow.next_item().unwrap() {
            n += 1;
        }
        assert_eq!(n, all.len());
    }

    #[test]
    fn mysql_scanner_modes_lines_and_truncation() {
        let all = statements("SET sql_mode='NO_BACKSLASH_ESCAPES';\nINSERT INTO t VALUES ('C:\\');\nSET sql_mode=@saved;\nINSERT INTO t VALUES ('a\\';b');\n").unwrap();
        assert_eq!(all[1].0, "INSERT INTO t VALUES ('C:\\')");
        assert_eq!(
            all[3].0, "INSERT INTO t VALUES ('a\\';b')",
            "escapes are back after sql_mode=@saved"
        );
        let all = statements("delimiter $$\nCREATE PROCEDURE p() BEGIN SELECT ';'; END$$\nDELIMITER ;\nSELECT 2 -- fim").unwrap();
        assert_eq!(all.last().unwrap().0, "SELECT 2 -- fim");
        assert_eq!(all[1].1, 2, "line numbers");
        assert!(
            statements("INSERT INTO t VALUES ('x")
                .unwrap_err()
                .contains("truncated")
        );
        assert!(
            statements("SELECT 1; /* open")
                .unwrap_err()
                .contains("truncated")
        );
        let big = format!(
            "INSERT INTO t VALUES ('{}');",
            "ab;'' \\' -- /* ".repeat(60_000)
        );
        assert_eq!(statements(&big).unwrap().len(), 1);
        let mut small = MysqlScanner::new(big.as_bytes(), 512 << 10);
        assert!(small.next_item().unwrap_err().contains("larger than"));
    }

    #[test]
    fn mysql_classifier() {
        let c = |s: &str| classify_mysql(s.as_bytes());
        assert_eq!(c("SET @@GLOBAL.GTID_PURGED='x'").skip, Some("SET GLOBAL"));
        assert_eq!(
            c("SET @global = 'GLOBAL', @@SESSION.SQL_LOG_BIN = 0").skip,
            None
        );
        assert_eq!(c("SET PERSIST x=1").skip, Some("SET GLOBAL"));
        assert_eq!(c("CHANGE MASTER TO x").skip, Some(REPLICATION));
        assert_eq!(c("START TRANSACTION").skip, None);
        assert_eq!(c("LOAD DATA INFILE 'x' INTO TABLE t").skip, Some(EXTERNAL));
        assert_eq!(c("FLUSH PRIVILEGES").skip, Some(ADMIN));
        assert_eq!(c("USE `prod`").database.as_deref(), Some("prod"));
        assert_eq!(
            c("CREATE TABLE outro.t (id int)").qualifier.as_deref(),
            Some("outro")
        );
        assert_eq!(
            c("INSERT IGNORE INTO outro.t VALUES (1)")
                .qualifier
                .as_deref(),
            Some("outro")
        );
        let r = c(&format!(
            "-- c\nREPLACE INTO t VALUES('{}')",
            "x".repeat(4096)
        ));
        assert_eq!((r.kind, r.objects[0].as_str()), (Kind::Insert, "t"));
        assert_eq!(c("ALTER DATABASE CHARACTER SET utf8mb4").rename, None);
        assert!(
            c("ALTER DATABASE `prod` CHARACTER SET utf8mb4")
                .rename
                .is_some()
        );
        let v = c(
            "CREATE OR REPLACE ALGORITHM=MERGE DEFINER = 'app'@'10.0.0.%' SQL SECURITY DEFINER VIEW v AS SELECT 1",
        );
        assert_eq!(
            (v.kind, v.definer.as_ref().map(|d| d.2.as_str())),
            (Kind::CreateView, Some("app@10.0.0.%"))
        );
        let text = "/*!50003 CREATE*/ /*!50017 DEFINER=`x`@`%`*/ /*!50003 TRIGGER t BEFORE INSERT ON a FOR EACH ROW SET @a=1 */";
        let d = c(text).definer.unwrap();
        assert_eq!((&text[d.0..d.1], d.2.as_str()), ("DEFINER=`x`@`%`", "x@%"));
        assert_eq!(
            c("CREATE DEFINER=root@localhost PROCEDURE p() SELECT 1")
                .definer
                .unwrap()
                .2,
            "root@localhost"
        );
        assert_eq!(
            c("CREATE DEFINER=CURRENT_USER() FUNCTION f() RETURNS int RETURN 1")
                .definer
                .unwrap()
                .2,
            "CURRENT_USER"
        );
        assert!(
            c("CREATE SQL SECURITY DEFINER VIEW v AS SELECT 'DEFINER=`x`@`y`'")
                .definer
                .is_none()
        );
        let db = c(
            "CREATE DATABASE /*!32312 IF NOT EXISTS*/ `p` /*!40100 DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci */",
        );
        assert_eq!(
            (
                db.database.as_deref(),
                db.charset.as_deref(),
                db.collate.as_deref()
            ),
            (Some("p"), Some("utf8mb4"), Some("utf8mb4_0900_ai_ci"))
        );
        assert_eq!(
            count_tuples(b"INSERT INTO t (a, b) VALUES (1,'x),(y'),(2,'(')", 13, true),
            2
        );
        assert_eq!(count_tuples(b"INSERT INTO t SELECT * FROM u", 13, true), 0);
    }

    fn write_temp(name: &str, body: &[u8]) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("corescope-dump-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join(name);
        std::fs::write(&p, body).unwrap();
        p
    }

    #[test]
    fn analysis_of_mysql_and_gzip() {
        let none = AtomicBool::new(false);
        let p = write_temp("a.sql", DUMP.as_bytes());
        let a = analyze(&p, None, &|_, _| {}, &none).unwrap();
        assert_eq!(a.dialect, "mysql");
        assert_eq!(a.source_database.as_deref(), Some("shop_prod"));
        assert_eq!(a.tool.as_deref(), Some("mysqldump"));
        let rows: Vec<(&str, u64)> = a.tables.iter().map(|t| (t.name.as_str(), t.rows)).collect();
        assert_eq!(rows, [("clients", 6), ("audit", 4)]);
        assert_eq!((a.triggers, a.routines), (1, 1));
        assert_eq!(a.definers, ["app@%", "root@localhost"]);
        let kinds: Vec<&str> = a.left_out.iter().map(|l| l.kind.as_str()).collect();
        assert!(
            kinds.contains(&"SET GLOBAL") && kinds.contains(&"USE") && kinds.contains(&ACCOUNTS),
            "{kinds:?}"
        );
        assert_eq!(a.charset.as_deref(), Some("utf8mb4"));
        // gzip, and a truncated one.
        let gz = std::process::Command::new("/usr/bin/gzip")
            .args(["-kf", p.to_str().unwrap()])
            .status()
            .unwrap();
        assert!(gz.success());
        let gzp = p.with_extension("sql.gz");
        let g = analyze(&gzp, None, &|_, _| {}, &none).unwrap();
        assert!(g.compressed && g.tables.len() == 2);
        let bytes = std::fs::read(&gzp).unwrap();
        let cut = write_temp("cut.sql.gz", &bytes[..bytes.len() / 2]);
        assert!(analyze(&cut, None, &|_, _| {}, &none).is_err());
        // Missing footer, two databases, a qualified name.
        let nofoot = write_temp(
            "nofoot.sql",
            DUMP.replace("-- Dump completed", "-- x").as_bytes(),
        );
        assert!(
            analyze(&nofoot, None, &|_, _| {}, &none)
                .unwrap_err()
                .contains("incomplete")
        );
        let two = write_temp("two.sql", b"USE a;\nCREATE TABLE t (i int);\nUSE b;\n");
        assert!(
            analyze(&two, None, &|_, _| {}, &none)
                .unwrap_err()
                .contains("more than one")
        );
        let q = write_temp("q.sql", b"INSERT INTO other.t VALUES (1);\n");
        assert!(
            analyze(&q, None, &|_, _| {}, &none)
                .unwrap_err()
                .contains("explicitly")
        );
        let zip = write_temp("x.sql", b"PK\x03\x04rest");
        assert!(
            analyze(&zip, None, &|_, _| {}, &none)
                .unwrap_err()
                .contains("zip")
        );
    }

    const PG: &str = "--\n-- PostgreSQL database dump\n--\n\\restrict abc\n-- Dumped from database version 16.2\nSET statement_timeout = 0;\nCREATE SCHEMA public;\nCREATE FUNCTION public.f() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE NOTICE 'a;b'; RETURN NEW; END; $$;\nALTER FUNCTION public.f() OWNER TO prod;\nCREATE TABLE public.users (id integer, name text);\nCREATE TABLE public.audit (id integer);\nCOPY public.users (id, name) FROM stdin;\n1\tAna\n2\tO'Brien; x\n\\.\nCOPY public.audit (id) FROM stdin;\n1\n2\n3\n\\.\nINSERT INTO public.audit VALUES (4), (5);\nCREATE TRIGGER t BEFORE INSERT ON public.users FOR EACH ROW EXECUTE FUNCTION public.f();\nGRANT ALL ON SCHEMA public TO prod;\n\\unrestrict abc\n--\n-- PostgreSQL database dump complete\n--\n";

    #[test]
    fn postgres_scanner_and_analysis() {
        let mut s = PgScanner::new(PG.as_bytes(), 1 << 20);
        let mut items = Vec::new();
        while let Some(i) = s.next_item().unwrap() {
            items.push(i);
        }
        let copies = items
            .iter()
            .filter(|i| matches!(i, Item::CopyLine { end: false, .. }))
            .count();
        assert_eq!(copies, 5);
        assert!(items.iter().any(|i| matches!(i, Item::Statement { text, .. } if String::from_utf8_lossy(text).contains("'a;b'; RETURN NEW; END; $$"))));
        assert!(
            items
                .iter()
                .any(|i| matches!(i, Item::Meta { text, .. } if text.starts_with(b"\\restrict")))
        );
        let none = AtomicBool::new(false);
        let p = write_temp("pg.sql", PG.as_bytes());
        let a = analyze(&p, None, &|_, _| {}, &none).unwrap();
        assert_eq!(a.dialect, "postgres");
        let rows: Vec<(&str, u64)> = a.tables.iter().map(|t| (t.name.as_str(), t.rows)).collect();
        assert_eq!(rows, [("public.audit", 5), ("public.users", 2)]);
        assert_eq!((a.triggers, a.routines), (1, 1));
        assert_eq!(
            classify_pg(b"CREATE SCHEMA public").schema_if_not_exists,
            Some(13)
        );
        assert_eq!(
            classify_pg(b"ALTER TABLE public.t OWNER TO x").skip,
            Some("owners")
        );
    }

    /// As mariadb-dump 10.11 writes it.
    const HABILITACOES: &str = "CREATE TABLE `habilitacoes` (\n  `id` bigint(20) unsigned NOT NULL AUTO_INCREMENT,\n  `leilao_id` bigint(20) unsigned NOT NULL,\n  `user_id` bigint(20) unsigned NOT NULL,\n  `valor` decimal(12,2) NOT NULL DEFAULT 0.00,\n  `deleted_at` timestamp NULL DEFAULT NULL,\n  `habilitacao_ativa` tinyint(1) GENERATED ALWAYS AS (if(`deleted_at` is null,1,NULL)) VIRTUAL,\n  `valor_centavos` bigint(20) GENERATED ALWAYS AS (`valor` * 100) STORED,\n  `valor_dobro` bigint(20) GENERATED ALWAYS AS (`valor_centavos` * 2) VIRTUAL,\n  `observacao` varchar(255) DEFAULT NULL COMMENT 'texto; com, virgula e (parenteses)',\n  PRIMARY KEY (`id`),\n  UNIQUE KEY `habilitacoes_unica` (`leilao_id`,`user_id`,`habilitacao_ativa`),\n  KEY `habilitacoes_user_id` (`user_id`),\n  KEY `habilitacoes_valor_centavos` (`valor_centavos`),\n  KEY `habilitacoes_observacao` (`observacao`),\n  CONSTRAINT `habilitacoes_leilao_fk` FOREIGN KEY (`leilao_id`) REFERENCES `leiloes` (`id`) ON DELETE CASCADE,\n  CONSTRAINT `habilitacoes_valor_chk` CHECK (`valor_centavos` >= 0)\n) ENGINE=InnoDB AUTO_INCREMENT=7 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci";

    fn generated(text: &str) -> Option<Generated> {
        let info = classify_mysql(text.as_bytes());
        generated_columns(text.as_bytes(), &info.objects[0], info.body, true)
    }

    #[test]
    fn generated_columns_become_plain_and_come_back_with_their_keys() {
        let g = generated(HABILITACOES).unwrap();
        assert_eq!(
            g.columns,
            ["habilitacao_ativa", "valor_centavos", "valor_dobro"]
        );
        let plain = HABILITACOES
            .replace(
                " GENERATED ALWAYS AS (if(`deleted_at` is null,1,NULL)) VIRTUAL",
                "",
            )
            .replace(" GENERATED ALWAYS AS (`valor` * 100) STORED", "")
            .replace(" GENERATED ALWAYS AS (`valor_centavos` * 2) VIRTUAL", "");
        assert_eq!(String::from_utf8(g.create).unwrap(), plain);
        // The key the foreign key uses goes in the same statement; the keys after the first one
        // on a stored column come back too (MySQL keeps them in that order); the user_id key and
        // the foreign key stay.
        assert_eq!(
            String::from_utf8(g.alter).unwrap(),
            "ALTER TABLE `habilitacoes` DROP INDEX `habilitacoes_unica`, DROP INDEX `habilitacoes_valor_centavos`, \
             DROP INDEX `habilitacoes_observacao`, DROP CHECK `habilitacoes_valor_chk`, \
             DROP COLUMN `habilitacao_ativa`, DROP COLUMN `valor_centavos`, DROP COLUMN `valor_dobro`, \
             ADD COLUMN `habilitacao_ativa` tinyint(1) GENERATED ALWAYS AS (if(`deleted_at` is null,1,NULL)) VIRTUAL AFTER `deleted_at`, \
             ADD COLUMN `valor_centavos` bigint(20) GENERATED ALWAYS AS (`valor` * 100) STORED AFTER `habilitacao_ativa`, \
             ADD COLUMN `valor_dobro` bigint(20) GENERATED ALWAYS AS (`valor_centavos` * 2) VIRTUAL AFTER `valor_centavos`, \
             ADD UNIQUE KEY `habilitacoes_unica` (`leilao_id`,`user_id`,`habilitacao_ativa`), \
             ADD KEY `habilitacoes_valor_centavos` (`valor_centavos`), ADD KEY `habilitacoes_observacao` (`observacao`), \
             ADD CONSTRAINT `habilitacoes_valor_chk` CHECK (`valor_centavos` >= 0)"
        );
        // The first column, MariaDB's PERSISTENT and a bare AS.
        let g = generated("CREATE TABLE codigos (\n  upper_code varchar(20) AS (ucase(code)) PERSISTENT INVISIBLE,\n  code varchar(20) NOT NULL,\n  PRIMARY KEY (code),\n  UNIQUE KEY codigos_upper (upper_code)\n)").unwrap();
        assert_eq!(
            String::from_utf8(g.create).unwrap(),
            "CREATE TABLE codigos (\n  upper_code varchar(20) INVISIBLE,\n  code varchar(20) NOT NULL,\n  PRIMARY KEY (code),\n  UNIQUE KEY codigos_upper (upper_code)\n)"
        );
        assert_eq!(
            String::from_utf8(g.alter).unwrap(),
            "ALTER TABLE `codigos` DROP INDEX `codigos_upper`, DROP COLUMN `upper_code`, ADD COLUMN upper_code varchar(20) AS (ucase(code)) STORED INVISIBLE FIRST, ADD UNIQUE KEY codigos_upper (upper_code)"
        );
    }

    #[test]
    fn tables_left_as_they_are() {
        for text in [
            // No generated column, the words only in strings.
            "CREATE TABLE t (\n  a varchar(40) DEFAULT 'x GENERATED ALWAYS AS (1) VIRTUAL' COMMENT 'AS (y), z',\n  b int\n)",
            "CREATE TABLE t LIKE u",
            // A foreign key on it, a check on the column itself, partitioned.
            "CREATE TABLE t (\n  a int,\n  g int GENERATED ALWAYS AS (a) STORED,\n  CONSTRAINT t_fk FOREIGN KEY (g) REFERENCES p (id)\n)",
            "CREATE TABLE t (\n  a int,\n  g int GENERATED ALWAYS AS (a) VIRTUAL CHECK (g > 0)\n)",
            "CREATE TABLE t (\n  a int,\n  g int GENERATED ALWAYS AS (a) VIRTUAL\n) ENGINE=InnoDB /*!50100 PARTITION BY HASH (`g`) PARTITIONS 2 */",
        ] {
            assert_eq!(generated(text), None, "{text}");
        }
    }

    #[test]
    fn sql_mode_without_no_auto_create_user() {
        for (from, to) in [
            (
                "SET sql_mode = 'STRICT_TRANS_TABLES,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION'",
                "SET sql_mode = 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION'",
            ),
            (
                "SET sql_mode = 'no_auto_create_user,X'",
                "SET sql_mode = 'X'",
            ),
            (
                "SET sql_mode = 'X,NO_AUTO_CREATE_USER'",
                "SET sql_mode = 'X'",
            ),
            ("SET sql_mode = 'NO_AUTO_CREATE_USER'", "SET sql_mode = ''"),
        ] {
            let mut text = from.as_bytes().to_vec();
            without_no_auto_create_user(&mut text);
            assert_eq!(String::from_utf8(text).unwrap(), to);
        }
    }

    fn imported(name: &str, dump: &str, adapt: &Adapt) -> String {
        let p = write_temp(name, dump.as_bytes());
        let mut out = Out {
            w: Vec::new(),
            line: 1,
            marks: Vec::new(),
        };
        let job = Job::new("test".into(), "restore", "", None, None);
        import_mysql(
            Input::open(&p).unwrap(),
            &mut out,
            &Request::credentials(None, None),
            &HashSet::new(),
            &HashSet::new(),
            false,
            adapt,
            &job,
            &mut Outcome::default(),
        )
        .unwrap();
        String::from_utf8(out.w).unwrap()
    }

    #[test]
    fn import_adds_generated_columns_back_after_the_rows() {
        let dump = format!(
            "/*M!999999\\- enable the sandbox mode */ \n-- MariaDB dump 10.19  Distrib 10.11.19-MariaDB\n\nDROP TABLE IF EXISTS `habilitacoes`;\n{HABILITACOES};\nLOCK TABLES `habilitacoes` WRITE;\n/*!40000 ALTER TABLE `habilitacoes` DISABLE KEYS */;\nINSERT INTO `habilitacoes` VALUES\n(1,1,10,100.50,NULL,1,10050,20100,'a'),\n(2,1,10,90.00,'2026-01-02 03:04:05',NULL,9000,18000,'b; (c)');\nINSERT INTO `habilitacoes` VALUES (3,2,10,1.00,NULL,1,100,200,NULL);\n/*!40000 ALTER TABLE `habilitacoes` ENABLE KEYS */;\nUNLOCK TABLES;\n/*!50003 SET sql_mode              = 'STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION' */ ;\nDROP TABLE IF EXISTS `simples`;\nCREATE TABLE `simples` (`id` int NOT NULL, `g` int GENERATED ALWAYS AS (`id`) VIRTUAL);\n-- Dump completed on 2026-10-23 18:49:31\n"
        );
        let rows: HashMap<String, u64> =
            HashMap::from([("habilitacoes".into(), 3), ("simples".into(), 0)]);
        let adapt = Adapt {
            generated: Some(rows),
            no_auto_create_user: true,
        };
        let out = imported("generated.sql", &dump, &adapt);
        let at = |p: &str| out.find(p).unwrap_or_else(|| panic!("{p} not in\n{out}"));
        assert!(
            at("`habilitacao_ativa` tinyint(1),") < at("INSERT INTO `habilitacoes` VALUES\n(1,")
        );
        let alter = at("ALTER TABLE `habilitacoes` DROP INDEX");
        assert!(at("(3,2,10,1.00,NULL,1,100,200,NULL)") < alter);
        assert!(at("UNLOCK TABLES") < alter && alter < at("/*!50003 SET sql_mode"));
        assert!(
            out.contains("'STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION'")
        );
        // A table without rows keeps its CREATE TABLE.
        assert!(out.contains("`g` int GENERATED ALWAYS AS (`id`) VIRTUAL"));
        assert_eq!(out.matches("ALTER TABLE `habilitacoes` DROP").count(), 1);
        // MariaDB as the target: the dump as it is.
        let plain = imported("generated-mariadb.sql", &dump, &Adapt::default());
        assert!(!plain.contains("ALTER TABLE `habilitacoes` DROP") && plain.contains(HABILITACOES));
        // A dump without generated columns goes out the same.
        let all = HashMap::from([("clients".into(), 6), ("audit".into(), 4)]);
        let adapt = Adapt {
            generated: Some(all),
            no_auto_create_user: true,
        };
        assert_eq!(
            imported("plain-adapted.sql", DUMP, &adapt),
            imported("plain.sql", DUMP, &Adapt::default())
        );
    }
}
