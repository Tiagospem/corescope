#include <stdint.h>
typedef struct {
 uint64_t ticks[4], physical, active, wired, compressed, swap;
 // Activity Monitor categories: anonymous (internal), purgeable and file-backed (external) bytes.
 uint64_t internal, purgeable, external;
 uint32_t cores; int cpu_ok, memory_ok, swap_ok;
 // kern.memorystatus_level: percentage of memory the kernel considers available; -1 unavailable.
 int32_t memory_level;
} CSHost;
typedef struct {
 int32_t pid, ppid; uint32_t uid, flags;
 uint64_t start, cpu_ns, resident, footprint, read_bytes, write_bytes, wakeups;
 // Energy used by the process (nanojoules, rusage_info_v6.ri_energy_nj); energy_ok when read.
 uint64_t energy_nj;
 int32_t threads, task_ok, usage_ok, task_error, usage_error, energy_ok; char name[64], path[4096], user[64];
} CSProcess;
typedef struct { uint64_t total, available; char device[1024], mount[1024], kind[32]; } CSVolume;
typedef struct { uint64_t id, read_bytes, write_bytes; int32_t ok; char name[128]; } CSDisk;
void os_host(CSHost *out);
int os_pids(int32_t *out, int capacity);
int os_process(int32_t pid, CSProcess *out);
int os_volumes(CSVolume *out, int capacity);
int os_disks(CSDisk *out, int capacity);
uint32_t os_uid(void);
int32_t os_self(void);
int os_signal(int32_t pid, int force);
// 0 success; 1 unsupported; 2 permission denied; 3 temporarily unavailable.
int os_nvme_temperature(uint64_t driver_id, uint32_t *kelvin);
// Listening TCP sockets owned by pid: up to cap entries; exposed=1 when bound beyond loopback.
typedef struct { uint16_t port; uint8_t exposed; } CSPort;
int os_ports(int32_t pid, CSPort *out, int cap);
// Internal battery: percent, charging, on AC power, minutes to empty/full (-1 unknown). 0 when present.
int os_battery(int32_t *percent, int32_t *charging, int32_t *on_ac, int32_t *minutes);
// Current working directory of a process (same user only). 0 success.
int os_cwd(int32_t pid, char *out, int cap);
// Cumulative bytes on non-loopback interfaces (64-bit counters). 0 success.
int os_network(uint64_t *in_bytes, uint64_t *out_bytes);
// Cumulative ticks per logical CPU (user, system, idle, nice): up to cap CPUs, -1 on failure.
int os_core_ticks(uint64_t *ticks, int cap);
// Cluster type per logical CPU from the IODeviceTree ('P', 'E' or 0 when unknown); count read.
int os_core_kinds(uint8_t *out, int cap);
// hw.perflevelN.logicalcpu for levels 0 (highest performance) and 1; 0 when absent.
void os_perflevels(uint32_t *level0, uint32_t *level1);
