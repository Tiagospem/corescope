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
    pub internal: u64,
    pub purgeable: u64,
    pub external: u64,
    pub cores: u32,
    pub cpu_ok: c_int,
    pub memory_ok: c_int,
    pub swap_ok: c_int,
    pub memory_level: i32,
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
    pub energy_nj: u64,
    pub threads: i32,
    pub task_ok: i32,
    pub usage_ok: i32,
    pub task_error: i32,
    pub usage_error: i32,
    pub energy_ok: i32,
    pub sid: i32,
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
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct RawPort {
    pub port: u16,
    pub exposed: u8,
}
unsafe extern "C" {
    pub fn os_ports(pid: i32, out: *mut RawPort, capacity: i32) -> i32;
    pub fn os_cwd(pid: i32, out: *mut c_char, capacity: i32) -> i32;
    pub fn os_network(in_bytes: *mut u64, out_bytes: *mut u64) -> i32;
    pub fn os_battery(
        percent: *mut i32,
        charging: *mut i32,
        on_ac: *mut i32,
        minutes: *mut i32,
    ) -> i32;
    pub fn os_pressure_level() -> i32;
    pub fn os_background(pid: i32, on: i32) -> i32;
}
/// "normal", "warning" or "critical" (kern.memorystatus_vm_pressure_level), when readable.
pub fn pressure_level() -> Option<&'static str> {
    // SAFETY: no arguments; reads one sysctl.
    match unsafe { os_pressure_level() } {
        1 => Some("normal"),
        2 => Some("warning"),
        4 => Some("critical"),
        _ => None,
    }
}
/// (percent, charging, on AC power, minutes to empty or full) for an internal battery.
pub fn battery() -> Option<(i32, bool, bool, Option<i32>)> {
    let (mut percent, mut charging, mut ac, mut minutes) = (0, 0, 0, -1);
    // SAFETY: all four pointers reference live i32 values.
    (unsafe { os_battery(&mut percent, &mut charging, &mut ac, &mut minutes) } == 0).then(|| {
        (
            percent,
            charging != 0,
            ac != 0,
            (minutes >= 0).then_some(minutes),
        )
    })
}
/// Listening TCP ports of a same-user process; empty when inaccessible.
pub fn ports(pid: i32) -> Vec<RawPort> {
    let mut out = [RawPort::default(); 32];
    // SAFETY: out holds 32 writable entries matching CSPort.
    let n = unsafe { os_ports(pid, out.as_mut_ptr(), out.len() as i32) };
    out[..n.max(0) as usize].to_vec()
}
pub fn cwd(pid: i32) -> String {
    let mut out = [0 as c_char; 1024];
    // SAFETY: out is a writable buffer of the declared capacity.
    if unsafe { os_cwd(pid, out.as_mut_ptr(), out.len() as i32) } == 0 {
        string(&out)
    } else {
        String::new()
    }
}
pub fn network() -> Option<(u64, u64)> {
    let (mut rx, mut tx) = (0, 0);
    // SAFETY: both pointers reference live u64 values.
    (unsafe { os_network(&mut rx, &mut tx) } == 0).then_some((rx, tx))
}
unsafe extern "C" {
    pub fn os_core_ticks(ticks: *mut u64, capacity: i32) -> i32;
    pub fn os_core_kinds(out: *mut u8, capacity: i32) -> i32;
    pub fn os_perflevels(level0: *mut u32, level1: *mut u32);
}
/// Cumulative (user, system, idle, nice) ticks per logical CPU; None when Mach refuses.
pub fn core_ticks() -> Option<Vec<[u64; 4]>> {
    let mut raw = [0u64; 4 * 256];
    // SAFETY: raw holds 256 CPUs of four u64 tick counters each.
    let n = unsafe { os_core_ticks(raw.as_mut_ptr(), 256) };
    (n > 0).then(|| {
        raw.as_chunks::<4>()
            .0
            .iter()
            .take(n as usize)
            .copied()
            .collect()
    })
}
/// Cluster type per logical CPU (b'P', b'E' or 0) as published in the device tree.
pub fn core_kinds(count: usize) -> Vec<u8> {
    let mut out = vec![0u8; count.min(256)];
    // SAFETY: out is writable for its full length.
    unsafe { os_core_kinds(out.as_mut_ptr(), out.len() as i32) };
    out
}
pub fn perflevels() -> (u32, u32) {
    let (mut p, mut e) = (0, 0);
    // SAFETY: both pointers reference live u32 values.
    unsafe { os_perflevels(&mut p, &mut e) };
    (p, e)
}
