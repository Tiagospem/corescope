# ADR 001 — local core and native interface

*Português: [ARCHITECTURE.pt-BR.md](ARCHITECTURE.pt-BR.md)*

Decision recorded before implementation, on 2026-10-16.

Observed environment: macOS 27.0.1 (26A434), arm64, Swift 6.4, Rust 1.98.1 and Command Line Tools. No pre-existing project. Deployment target: macOS 14, based on the availability of the UI APIs used; compatibility on 14 still requires testing on another machine. Development build for the local architecture, ad hoc signing.

Rust collects and interprets data, keeps bounded buffers, computes rates from a monotonic clock, applies hysteresis and revalidates every process action. A small C adapter uses the SDK headers for the Mach/libproc/IOKit structures; it contains no diagnostics and no storage. This avoids copying kernel ABI layouts into Rust, including VM structures that changed in SDK 27.

SwiftUI provides the window and MenuBarExtra; AppKit provides a non-activating NSPanel. A single serial background Swift service calls Rust, delivers immutable snapshots and receives public pressure, sleep and thermal-state events. There is no server, browser, database, telemetry or collection of arguments/environment.

FFI: UTF-8 JSON in a Rust-allocated pointer, copied by Swift and freed exactly once by `cs_free`. Inputs remain borrowed for the duration of the call. A mutex serializes state; catch_unwind prevents a panic from crossing into C. Invalid pointers remain forbidden by the contract. Signals return an explicit result; identity includes PID, start time in microseconds, UID and executable. macOS does not offer atomic signaling by PID + start time: a residual race window is documented.

Cadences: 3 s by default, 10 s in low-power mode / with no detail surfaces, volume inventory 30 s, physical I/O 6 s; paused during sleep, with deltas reset on wake. Limits: 120 samples and 10 minutes; up to 12 tracked processes. Celsius sensors without a reliable public API are marked unsupported. Pressure events remain unknown until the first event, without confusing RAM occupancy with pressure.

## ADR 002 — NVMe temperature via public interface

The requested investigation of Disk Drill identified Smartmontools; the installed SDK contains `IOKit/storage/nvme/NVMeSMARTLibExternal.h`. For that reason the first version switched to querying `IONVMeSMARTInterface.SMARTReadData` **directly**, without executing or embedding Disk Drill/smartctl. The association starts from the physical driver's ID and walks up only its ancestors to `NVMe SMART Capable`.

A 512-byte, read-only read every 30 s, on the serial queue; COM/IOKit interfaces and ports are released. There is no SMART enabling, self-test, write, root or helper. Rust validates the range, converts Kelvin to Celsius and preserves the source, timestamp and separate states for lack of support, permission and transient failure. The NVMe field has 1 K resolution; decimal places come from unit conversion, not additional precision. The temperature is the controller's composite temperature, and is not attributed to the enclosure/adapter.

Live validation on this hardware: APPLE SSD AP0256Z and KINGSTON SNV3S1000G returned data without elevation. This does not establish support for all SATA/USB/Thunderbolt disks. For ATA/SATA or bridges without a compatible public interface, the lack of support remains explicit. See DISKDRILL-TEMPERATURE.md for the static investigation, which is distinct from this run.
