#include <stdint.h>
// All returned strings are Rust-owned; caller must cs_free once after copying.
char *cs_snapshot(const char *config);
char *cs_signal(int32_t pid, uint64_t start, const char *path, int32_t force);
void cs_reset(void);
// Persistent history: {"op":"series"|"top"|"info"|"flush"|"delete", from, to, bucket}.
char *cs_history(const char *request);
void cs_free(char *pointer);

int32_t cs_is_same(int32_t pid, uint64_t start);
