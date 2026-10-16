#include <stdint.h>
typedef struct {
 uint64_t ticks[4], physical, active, wired, compressed, swap;
 uint32_t cores; int cpu_ok, memory_ok, swap_ok;
} CSHost;
typedef struct {
 int32_t pid, ppid; uint32_t uid, flags;
 uint64_t start, cpu_ns, resident, footprint, read_bytes, write_bytes, wakeups;
 int32_t threads, task_ok, usage_ok, task_error, usage_error; char name[64], path[4096], user[64];
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
// Current working directory of a process (same user only). 0 success.
int os_cwd(int32_t pid, char *out, int cap);
// Cumulative bytes on non-loopback interfaces (64-bit counters). 0 success.
int os_network(uint64_t *in_bytes, uint64_t *out_bytes);
