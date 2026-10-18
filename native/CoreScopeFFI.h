#include <stdint.h>
// All returned strings are Rust-owned; caller must cs_free once after copying.
char *cs_snapshot(const char *config);
char *cs_signal(int32_t pid, uint64_t start, const char *path, int32_t force);
void cs_reset(void);
// Persistent history: {"op":"series"|"top"|"info"|"flush"|"delete", from, to, bucket}.
char *cs_history(const char *request);
// Containers from local Docker Engine sockets only; action is "start", "stop" or "restart".
char *cs_containers(int32_t stats);
char *cs_container_action(const char *id, const char *action);
// Reclaimable dev space: {"roots":[...],"auto":bool,"docker":bool}. Read-only.
char *cs_dev_space(const char *request);
// Re-checks a folder right before it goes to the Trash: {"ok":true} or {"error":...}.
char *cs_dev_space_verify(const char *path);
// Unused Docker data through the engine; kind is docker_dangling, docker_unused or docker_build_cache.
char *cs_dev_space_docker(const char *socket, const char *kind);
// Local MySQL/PostgreSQL/Redis, read-only and without passwords: [Database].
char *cs_databases(void);
// .corescope.yml files found under {"roots":[...],"auto":bool}: [{folder,file,config,error}].
char *cs_project_configs(const char *request);
// Logs: {"op":"files"|"tail"|"errors"|"search", folders|source|sources, lines, limit, warnings, query}.
char *cs_logs(const char *request);
// Volumes, restart policies and image dates from the local Docker engines.
char *cs_docker_details(void);
// Darwin background priority on/off for a same-user process (identity revalidated).
char *cs_background(int32_t pid, uint64_t start, int32_t on);
// Ports reachable beyond localhost, riskiest first: [{port,owner,pid,container,project,kind,risk,advice}].
char *cs_exposure(void);
// Projects' preferred ports: {"projects":[{name,folder,ports:{role:port}}]} → [PortClaim].
char *cs_port_claims(const char *request);
void cs_free(char *pointer);

int32_t cs_is_same(int32_t pid, uint64_t start);
char *cs_disk_growth(const char *request);
char *cs_disk_health(void);
char *cs_cleanup_plan(int32_t docker);
char *cs_large_files(uint64_t min_mb, uint32_t limit);
char *cs_volume_holders(const char *mount);
char *cs_db_tool(const char *request);
