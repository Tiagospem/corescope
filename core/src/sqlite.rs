//! Minimal binding to the system libsqlite3 (C API); no bundled engine or extra crate.
use std::ffi::{CStr, CString, c_char, c_int, c_void};

#[repr(C)]
struct RawDb(c_void);
#[repr(C)]
struct RawStmt(c_void);
const OK: c_int = 0;
const ROW: c_int = 100;
const DONE: c_int = 101;
const NULL: c_int = 5;
const OPEN_READONLY: c_int = 0x1;
const OPEN_READWRITE: c_int = 0x2;
const OPEN_CREATE: c_int = 0x4;
const OPEN_FULLMUTEX: c_int = 0x10000;
/// SQLITE_TRANSIENT: SQLite copies bound text before the call returns.
const TRANSIENT: isize = -1;
unsafe extern "C" {
    fn sqlite3_open_v2(
        path: *const c_char,
        db: *mut *mut RawDb,
        flags: c_int,
        vfs: *const c_char,
    ) -> c_int;
    fn sqlite3_close_v2(db: *mut RawDb) -> c_int;
    fn sqlite3_errmsg(db: *mut RawDb) -> *const c_char;
    fn sqlite3_exec(
        db: *mut RawDb,
        sql: *const c_char,
        callback: *const c_void,
        arg: *mut c_void,
        error: *mut *mut c_char,
    ) -> c_int;
    fn sqlite3_busy_timeout(db: *mut RawDb, ms: c_int) -> c_int;
    fn sqlite3_prepare_v2(
        db: *mut RawDb,
        sql: *const c_char,
        bytes: c_int,
        stmt: *mut *mut RawStmt,
        tail: *mut *const c_char,
    ) -> c_int;
    fn sqlite3_finalize(stmt: *mut RawStmt) -> c_int;
    fn sqlite3_reset(stmt: *mut RawStmt) -> c_int;
    fn sqlite3_step(stmt: *mut RawStmt) -> c_int;
    fn sqlite3_bind_int64(stmt: *mut RawStmt, index: c_int, value: i64) -> c_int;
    fn sqlite3_bind_double(stmt: *mut RawStmt, index: c_int, value: f64) -> c_int;
    fn sqlite3_bind_null(stmt: *mut RawStmt, index: c_int) -> c_int;
    fn sqlite3_bind_text(
        stmt: *mut RawStmt,
        index: c_int,
        text: *const c_char,
        bytes: c_int,
        destructor: isize,
    ) -> c_int;
    fn sqlite3_column_type(stmt: *mut RawStmt, column: c_int) -> c_int;
    fn sqlite3_column_int64(stmt: *mut RawStmt, column: c_int) -> i64;
    fn sqlite3_column_double(stmt: *mut RawStmt, column: c_int) -> f64;
    fn sqlite3_column_text(stmt: *mut RawStmt, column: c_int) -> *const u8;
    fn sqlite3_column_bytes(stmt: *mut RawStmt, column: c_int) -> c_int;
}

pub struct Db(*mut RawDb);
// SAFETY: opened with SQLITE_OPEN_FULLMUTEX (serialized mode), so the handle may move between
// threads; callers additionally keep it behind the collector mutex.
unsafe impl Send for Db {}

impl Db {
    pub fn open(path: &str, readonly: bool) -> Result<Db, String> {
        let c = CString::new(path).map_err(|_| "Caminho inválido")?;
        let flags = OPEN_FULLMUTEX
            | if readonly {
                OPEN_READONLY
            } else {
                OPEN_READWRITE | OPEN_CREATE
            };
        let mut raw = std::ptr::null_mut();
        // SAFETY: c is NUL-terminated and raw receives a handle that is closed on drop.
        let code = unsafe { sqlite3_open_v2(c.as_ptr(), &mut raw, flags, std::ptr::null()) };
        let db = Db(raw);
        if code != OK {
            return Err(db.error());
        }
        // SAFETY: db.0 is an open connection.
        unsafe { sqlite3_busy_timeout(db.0, 2000) };
        Ok(db)
    }
    fn error(&self) -> String {
        if self.0.is_null() {
            return "SQLite indisponível".into();
        }
        // SAFETY: errmsg returns a NUL-terminated string owned by the connection.
        unsafe { CStr::from_ptr(sqlite3_errmsg(self.0)) }
            .to_string_lossy()
            .into_owned()
    }
    pub fn exec(&self, sql: &str) -> Result<(), String> {
        let c = CString::new(sql).map_err(|_| "SQL inválido")?;
        let null = std::ptr::null_mut();
        // SAFETY: c is NUL-terminated; no callback or error buffer is requested.
        let code = unsafe { sqlite3_exec(self.0, c.as_ptr(), std::ptr::null(), null, null.cast()) };
        if code == OK {
            Ok(())
        } else {
            Err(self.error())
        }
    }
    pub fn prepare(&self, sql: &str) -> Result<Stmt<'_>, String> {
        let c = CString::new(sql).map_err(|_| "SQL inválido")?;
        let mut raw = std::ptr::null_mut();
        // SAFETY: c is NUL-terminated (-1 reads up to the terminator); raw is finalized on drop.
        let code =
            unsafe { sqlite3_prepare_v2(self.0, c.as_ptr(), -1, &mut raw, std::ptr::null_mut()) };
        if code == OK && !raw.is_null() {
            Ok(Stmt { raw, db: self })
        } else {
            Err(self.error())
        }
    }
}
impl Drop for Db {
    fn drop(&mut self) {
        // SAFETY: close_v2 accepts null and defers closing until statements are finalized.
        unsafe { sqlite3_close_v2(self.0) };
    }
}

pub enum Value<'a> {
    Int(i64),
    Real(Option<f64>),
    Text(&'a str),
}
pub struct Stmt<'a> {
    raw: *mut RawStmt,
    db: &'a Db,
}
impl Stmt<'_> {
    /// Rebinds every parameter (1-based, in order) and clears the previous run.
    pub fn bind(&mut self, values: &[Value]) -> Result<&mut Self, String> {
        // SAFETY: raw is a live statement; reset keeps its prepared form.
        unsafe { sqlite3_reset(self.raw) };
        for (i, v) in values.iter().enumerate() {
            let i = i as c_int + 1;
            // SAFETY: TRANSIENT makes SQLite copy text before returning.
            let code = unsafe {
                match v {
                    Value::Int(n) => sqlite3_bind_int64(self.raw, i, *n),
                    Value::Real(Some(f)) if f.is_finite() => sqlite3_bind_double(self.raw, i, *f),
                    Value::Real(_) => sqlite3_bind_null(self.raw, i),
                    Value::Text(t) => sqlite3_bind_text(
                        self.raw,
                        i,
                        t.as_ptr().cast(),
                        t.len() as c_int,
                        TRANSIENT,
                    ),
                }
            };
            if code != OK {
                return Err(self.db.error());
            }
        }
        Ok(self)
    }
    /// true while a row is available.
    pub fn step(&mut self) -> Result<bool, String> {
        // SAFETY: raw is a live statement.
        match unsafe { sqlite3_step(self.raw) } {
            ROW => Ok(true),
            DONE => Ok(false),
            _ => Err(self.db.error()),
        }
    }
    pub fn run(&mut self, values: &[Value]) -> Result<(), String> {
        self.bind(values)?;
        while self.step()? {}
        Ok(())
    }
    fn is_null(&self, column: c_int) -> bool {
        // SAFETY: column is within the result row.
        unsafe { sqlite3_column_type(self.raw, column) == NULL }
    }
    pub fn int(&self, column: c_int) -> Option<i64> {
        // SAFETY: the statement holds a current row.
        (!self.is_null(column)).then(|| unsafe { sqlite3_column_int64(self.raw, column) })
    }
    pub fn real(&self, column: c_int) -> Option<f64> {
        // SAFETY: the statement holds a current row.
        (!self.is_null(column)).then(|| unsafe { sqlite3_column_double(self.raw, column) })
    }
    pub fn text(&self, column: c_int) -> String {
        // SAFETY: text stays valid until the next step/reset; it is copied immediately.
        unsafe {
            let p = sqlite3_column_text(self.raw, column);
            if p.is_null() {
                return String::new();
            }
            let n = sqlite3_column_bytes(self.raw, column).max(0) as usize;
            String::from_utf8_lossy(std::slice::from_raw_parts(p, n)).into_owned()
        }
    }
}
impl Drop for Stmt<'_> {
    fn drop(&mut self) {
        // SAFETY: raw came from prepare_v2 and is finalized exactly once.
        unsafe { sqlite3_finalize(self.raw) };
    }
}
