# APIs and sources

*Português: [API-SOURCES.pt-BR.md](API-SOURCES.pt-BR.md)*

Verified on 2026-10-16, against the local macOS SDK headers.

| Use | Source |
|---|---|
| Total CPU | `host_statistics(HOST_CPU_LOAD_INFO)`; [Mach host statistics](https://developer.apple.com/documentation/kernel/1502863-host_statistics64) and `mach/host_info.h` |
| Memory | `host_statistics64(HOST_VM_INFO64)`, `hw.memsize`, `vm.swapusage`; structures compiled against the real SDK, with no hand-copied Mach layout. Activity Monitor categories: app memory = `internal_page_count − purgeable_count`, cached files = `external_page_count + purgeable_count` |
| Pressure % | `sysctl kern.memorystatus_level` (share of memory the kernel considers available, the same value `memory_pressure` prints); shown as 100 − level, alongside — not instead of — the Dispatch events |
| Per-core CPU | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`; P/E type from `cluster-type` + `logical-cpu-id` under `IODeviceTree:/cpus/*`, accepted only when it matches `hw.perflevel0/1.logicalcpu`; otherwise the type stays unknown |
| Opt-in history | System `libsqlite3` through its C API (`sqlite3_open_v2`, `prepare_v2`, `bind`, `step`), WAL + `synchronous=NORMAL`, `auto_vacuum=INCREMENTAL`; one transaction per minute |
| Processes | `libproc.h`, `sys/proc_info.h`, `sys/resource.h`: `proc_listpids`, `proc_pidinfo`, `proc_pidpath`, `proc_pid_rusage` |
| Per-process CPU | RUSAGE returns Mach absolute time. Converted via `mach_timebase_info`; [XNU fill_task_rusage](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c). An intermediate 128-bit multiplication avoids overflow; a real load test validates the scale on Apple Silicon |
| Pressure | [DISPATCH_SOURCE_TYPE_MEMORYPRESSURE](https://developer.apple.com/documentation/Dispatch/DISPATCH_SOURCE_TYPE_MEMORYPRESSURE). State is unknown until an event arrives, without inferring “normal” from the absence of events |
| Thermal | [ProcessInfo thermal state](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/RespondToThermalStateChanges.html), read every cycle; no invented Celsius values |
| Physical I/O | [IOBlockStorageDriver](https://developer.apple.com/documentation/kernel/ioblockstoragedriver), public [Statistics](https://developer.apple.com/documentation/iokit/ioblockstoragedriver_h_user-space/defines?language=objc) properties; the registry ID identifies each driver. The child IOMedia provides the device name |
| Volumes | `getmntinfo(MNT_NOWAIT)` / `statfs`, reading the kernel cache to avoid waiting on slow I/O from external devices. `f_bavail` is the space available to the user |
| Panel | [NSPanel](https://developer.apple.com/documentation/appkit/nspanel), nonactivatingPanel, canJoinAllSpaces, fullScreenAuxiliary and NSScreen.visibleFrame |
| Launch at login | [SMAppService.mainApp](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp?language=objc). register/unregister only when the user changes the toggle; no privileged helper |

Direct Rust dependencies: serde and serde_json; cc at build time only. SQLite is the system library (`-lsqlite3`), no crate or bundled engine. Transitive versions pinned in Cargo.lock. No sysinfo, argument collection, web framework or external service.

Limitations: `phys_footprint` is not RSS; per-process attributed I/O is not the exact sum of physical I/O; APFS volumes share blocks. Counters may reset after devices disappear. Readings without a baseline, access failures and lack of support produce a missing value, never a simulated zero. `pkg_idle_wkups` measures package wakeups attributed to the process, not all timers; `interrupt_wkups` is a different counter. Raw energy fields are not converted to watts without a reliable unit.

## NVMe SMART added after the investigation

ABI source: Apple's public header `IOKit/storage/nvme/NVMeSMARTLibExternal.h` in the local SDK. Uses `kIONVMeSMARTUserClientTypeID`, `kIONVMeSMARTInterfaceID`, `NVMeSMARTData.TEMPERATURE` and `SMARTReadData`. The 512-byte buffer comes from the header, not from a structure copied from a third party.

Independent reference flow: [Smartmontools Darwin](https://www.smartmontools.org/static/doxygen/os__darwin_8cpp_source.html). Our implementation is our own, with no redistribution of Disk Drill or smartctl code/binaries. The [official CleverFiles explanation](https://www.cleverfiles.com/help/monitor-smart-status-disk-health/) and the REA evidence are in the dedicated report.
