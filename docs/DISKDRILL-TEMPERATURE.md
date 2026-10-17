# Disk temperature: investigation of Disk Drill

*Português: [DISKDRILL-TEMPERATURE.pt-BR.md](DISKDRILL-TEMPERATURE.pt-BR.md)*

Date: 2026-10-16. Scope: static, read-only analysis of the installed Disk Drill and consultation of public sources. No disk was queried by this investigation; no preference, helper, extension, permission or SMART setting was changed. The app and its executables were not run. The REA session was closed on completion.

## Conclusion

The installed Disk Drill includes **smartctl/Smartmontools** and code that recognizes that tool's ATA and NVMe results. This is also confirmed by the [official CleverFiles documentation](https://www.cleverfiles.com/help/monitor-smart-status-disk-health/), in the section “What Mechanism Does Disk Drill for macOS Use to Integrate With S.M.A.R.T.”. It is not a universal temperature that macOS publishes as a common disk property.

There is a better option than depending on Disk Drill: the installed Apple SDK provides the **NVMeSMARTLibExternal.h** interface, with SMART reading and a temperature field. CoreScope can use this SDK contract through a small C adapter of its own. Whether it works with the internal Apple SSD and the external Kingston must be verified by a real read on the host; static analysis alone does not demonstrate access, temperature or compatibility.

## Subsequent result in CoreScope

After this static investigation, CoreScope's independent adapter read both SSDs using `SMARTReadData`, without root: Apple 50.85 °C and Kingston 47.85 °C at 09:55:31. This validates these devices and this connection on the observed host; it does not prove universal support. The execution evidence and its limitations are in [VALIDATION.md](VALIDATION.md). The sections below preserve the scope and uncertainties of the original static investigation.

## Targets and evidence

Disk Drill **6.3**, build **6.3.2326**, identified via `Contents/Info.plist`. Paths below are relative to `/Applications/Disk Drill.app`.

| Item | Observed result | Reference |
| --- | --- | --- |
| Main executable | Universal Mach-O, arm64 slice selected, SHA-256 `7c9721f7db6afb2b66fe5606ca7a06c1b693a6fa5eefb794b786bb4a09a230ad` | REA `open_binary` |
| Main executable imports | `IOCreatePlugInInterfaceForService`, `IORegistryEntryCreateCFProperty`, `IOBSDNameMatching`, `IOServiceGetMatchingService`, `IODestroyPlugInInterface`, `posix_spawn`, authorization APIs | REA `inspect_macho`, `ev_40b5d7747b34e93f3b4c1055b3e7dc3d37b65a7d8a5538adc6639eadc9717728` |
| Bundled smartctl | `Contents/Library/LoginItems/SmartDaemon.app/Contents/MacOS/smartctl`; SHA-256 `82dca2cab9e0b67e15960b4b119f58fa96f4d23e5f49eef499b8a13499629575`; imports `IOCreatePlugInInterfaceForService` | REA `inspect_macho`, `ev_a69e5eb58a28f5d7ad5bd57176f0e84b115610b125acc2eb428a7a0e40bd94e9` |
| Attribute table | `smartattrs.plist` maps 190 to Airflow Temperature and 194 to HDA temperature, both with Temperature format | REA `inspect_plist`, `ev_1f7e093783efd43ee5ae55cdb06294bcafac8c97c934dfb0c391ca9663e980a3` |
| Bundled service | LaunchDaemon `com.cleverfiles.BackService_12`, `KeepAlive=true`, program `Contents/Helpers/BackService_12.app/Contents/MacOS/cfbackd` | REA `inspect_plist`, `ev_b29e0296ca01e56b2ade832fbb350967ad8ba6a99eb847abfdddae5562349267` |

The IDs above are real REA observations, not IDs invented for the shell research. The plist inspection records the file in `normalized_result.source_path`; REA's generic `subject` may still be the session's active binary.

### Complementary static evidence from the shell

`strings -a` on the main executable found `SmartctlProvider`, `SmartctlAttribute`, `SmartmontoolsPath`, `Contents/MacOS/smartctl`, `/usr/local/bin/smartctl`, `/usr/local/sbin/smartctl`, `/usr/sbin/smartctl`, `smartctl detected at %@`, `ata_smart_attributes`, `nvme_smart_health_information_log`, `smart_status.passed`, `temperature` and `smartctl.messages.string`.

`IOATASMARTInterface` also appears among the Objective-C types, along with `SMART Capable` and an unknown-SMART-temperature-format message. These are evidence of implemented/candidate routes, not proof of which route was used on this machine.

The bundled smartctl contains the build identifier **7.5, 2025-04-30, r5715**, the strings `NVMe SMART Capable`, `GetLogPage failed`, and references to ASMedia/JMicron/Realtek bridges. The presence of these names **does not prove support in the Darwin backend**. The file `smartctl_copyrights.txt` identifies Smartmontools and its license. No Disk Drill code or executable was copied into CoreScope.

`codesign -d --entitlements :-` on smartctl showed `disable-library-validation` and `personal-information.addressbook`; this does not demonstrate SMART authorization, nor that CoreScope needs these permissions. The existence of a LaunchDaemon and of authorization imports also does not prove that temperature reads require root.

## Public route verified in the Apple SDK

Installed header:

`/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/IOKit.framework/Versions/A/Headers/storage/nvme/NVMeSMARTLibExternal.h`

The header declares access by tasks outside the kernel and provides:

- Property `kIOPropertyNVMeSMARTCapableKey`: `NVMe SMART Capable`.
- `kIONVMeSMARTUserClientTypeID`: `AA0FA6F9-C2D6-457F-B10B-59A13253292F`.
- `kIONVMeSMARTInterfaceID`: `CCD1DB19-FD9A-4DAF-BF95-12454B230AB6`.
- `NVMeSMARTData`, a packed 512-byte structure whose `TEMPERATURE` field is a `uint16_t` after `CRITICAL_WARNING`.
- `IONVMeSMARTInterface.SMARTReadData(interface, NVMeSMARTData*)`.
- `IONVMeSMARTInterface.GetLogPage(interface, buffer, logPageID, numDWords)`; `numDWords` is zero-based.

Using the SDK header avoids manually reconstructing ABI from a binary. The NVMe temperature is expressed in Kelvin; presenting it in Celsius requires conversion, with validation of the read and of sentinel values. Return unavailable on failure, never fabricate zero degrees.

The [public Darwin implementation of Smartmontools](https://www.smartmontools.org/static/doxygen/os__darwin_8cpp_source.html) corroborates the route: it finds the device by BSD name, walks up the parents in the IOService plane to a SMART-capable one, creates a plugin, queries the NVMe interface and calls GetLogPage. Enumeration uses IOBlockStorageDevice. Its SCSI backend in that revision returns unavailable. That source is a published 2025 revision, not a statement about any future backend.

Suggested independent implementation flow:

1. Start from the BSD name of the physical disk, use `IOBSDNameMatching` and obtain the matching service.
2. Walk the parents in `kIOServicePlane`, checking the NVMe SMART property on each service. Release every acquired reference; bound the traversal and handle disconnection.
3. Create an `IOCFPlugInInterface` with the NVMe user client, query `IONVMeSMARTInterface` with `QueryInterface`, and check the return value and pointers.
4. Read `SMARTReadData`; if needed, evaluate GetLogPage with log 2 and 127 dwords for 512 bytes. This alternative must be validated at runtime, not assumed.
5. Convert the temperature only after success and associate the sample with the correct physical disk. APFS may expose virtual volumes distinct from the backing device.
6. Release the interface via `Release`, the plugin via `IODestroyPlugInInterface`, and IOKit objects via `IOObjectRelease`.

This is a proposal based on the public contract, not pseudocode extracted from Disk Drill.

## Internal Apple, external Kingston and permissions

| Case | What can be concluded now | What remains to be proven |
| --- | --- | --- |
| Internal Apple NVMe SSD | A suitable read API exists in the SDK | Service exposed, unprivileged read and valid value on this macOS |
| Kingston NVMe over Thunderbolt/USB4 with PCIe exposed | May present the same NVMe interface | Actual adapter topology and read success |
| Kingston via USB/SCSI bridge | Support depends on bridge, driver and backend; names in the binary are not enough | Effective pass-through available on this host |
| Read permission | It is not correct to infer root just because Disk Drill has a helper | Return code of the unprivileged read |

The CleverFiles documentation mentions a SAT extension for some external drives and advises against its general use from macOS 11 onward due to lack of maintenance. This investigation did not install, nor does it recommend installing, that extension, lowering boot security or reusing Disk Drill's helpers. The public API should be tried as the normal user; failures must remain explicit.

Optional integration with an **independently installed smartctl** may be a future alternative: read JSON, use fixed query arguments, a bounded timeout, association by physical disk and per-device failure handling. Do not adopt Disk Drill's bundled smartctl as a CoreScope dependency. Its path, version and existence belong to the other application.

## Limits and open questions

REA opened and identified the binaries; Mach-O/plist inspections worked. `search_strings` through the deep native provider returned `provider_unavailable`: Ghidra not configured, Hopper absent, IDA not configured. There is also a declared limitation of the Ghidra provider in selecting a slice in universal Mach-O. No engine was installed. Shell strings are explicitly a fallback, not REA decompilation.

- **Answered:** Disk Drill's technology source — bundled Smartmontools, SMART parsing and IOKit imports.
- **Answered:** there is a public API in the local SDK that allows an independent NVMe read implementation.
- **Partial:** Disk Drill's exact internal flow, subprocess arguments and fallback order; requires deep analysis or controlled observation.
- **Not tested in this investigation:** real temperatures, effective permissions and support for the two local devices. CoreScope's implementation and runtime validation are separate activities.
- **Not established:** cfbackd's involvement in temperature, actual observed frequency, the Kingston adapter's transport, sensor precision/calibration.

The conclusions do not promise universal support for external disks or functional equivalence to Disk Drill.
