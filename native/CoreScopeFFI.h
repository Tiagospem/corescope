#include <stdint.h>
// All returned strings are Rust-owned; caller must cs_free once after copying.
char *cs_snapshot(const char *config);
char *cs_signal(int32_t pid, uint64_t start, const char *path, int32_t force);
void cs_reset(void);
// Persistent history: {"op":"series"|"top"|"info"|"flush"|"delete", from, to, bucket}.
char *cs_history(const char *request);
// Containers from local Docker Engine sockets only; action is "stop" or "restart".
char *cs_containers(int32_t stats);
char *cs_container_action(const char *id, const char *action);
// Reclaimable dev space: {"roots":[...],"auto":bool,"docker":bool}. Read-only.
char *cs_dev_space(const char *request);
// Re-checks a folder right before it goes to the Trash: {"ok":true} or {"error":...}.
char *cs_dev_space_verify(const char *path);
// Unused Docker data through the engine; kind is docker_dangling, docker_unused or docker_build_cache.
char *cs_dev_space_docker(const char *socket, const char *kind);
void cs_free(char *pointer);

int32_t cs_is_same(int32_t pid, uint64_t start);
