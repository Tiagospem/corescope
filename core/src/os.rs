use std::ffi::{c_char, c_int};
#[repr(C)]
#[derive(Default)]
pub struct Host {
    pub ticks: [u64; 4],
    pub physical: u64,
    pub active: u64,
    pub wired: u64,
    pub compressed: u64,
    pub swap: u64,
    pub cores: u32,
    pub cpu_ok: c_int,
    pub memory_ok: c_int,
    pub swap_ok: c_int,
}
#[repr(C)]
pub struct RawProcess {
    pub pid: i32,
    pub ppid: i32,
    pub uid: u32,
    pub flags: u32,
    pub start: u64,
    pub cpu_ns: u64,
    pub resident: u64,
    pub footprint: u64,
    pub read_bytes: u64,
    pub write_bytes: u64,
    pub wakeups: u64,
    pub threads: i32,
    pub task_ok: i32,
    pub usage_ok: i32,
    pub task_error: i32,
    pub usage_error: i32,
    pub name: [c_char; 64],
    pub path: [c_char; 4096],
    pub user: [c_char; 64],
}
#[repr(C)]
pub struct RawVolume {
    pub total: u64,
    pub available: u64,
    pub device: [c_char; 1024],
    pub mount: [c_char; 1024],
    pub kind: [c_char; 32],
}
#[repr(C)]
pub struct RawDisk {
    pub id: u64,
    pub read_bytes: u64,
    pub write_bytes: u64,
    pub ok: i32,
    pub name: [c_char; 128],
}
unsafe extern "C" {
    pub fn os_host(out: *mut Host);
    pub fn os_pids(out: *mut i32, capacity: i32) -> i32;
    pub fn os_process(pid: i32, out: *mut RawProcess) -> i32;
    pub fn os_volumes(out: *mut RawVolume, capacity: i32) -> i32;
    pub fn os_disks(out: *mut RawDisk, capacity: i32) -> i32;
    pub fn os_uid() -> u32;
    pub fn os_self() -> i32;
    pub fn os_nvme_temperature(driver_id: u64, kelvin: *mut u32) -> i32;
    pub fn os_signal(pid: i32, force: i32) -> i32;
}
pub fn string(bytes: &[c_char]) -> String {
    let bytes: Vec<u8> = bytes
        .iter()
        .take_while(|&&x| x != 0)
        .map(|&x| x as u8)
        .collect();
    String::from_utf8_lossy(&bytes).into_owned()
}
pub fn process(pid: i32) -> Option<RawProcess> {
    // SAFETY: these C structs contain only integers and fixed-size byte arrays.
    let mut out: RawProcess = unsafe { std::mem::zeroed() };
    // SAFETY: out is a live, writable struct with the ABI in macos.h.
    (unsafe { os_process(pid, &mut out) } == 0).then_some(out)
}
