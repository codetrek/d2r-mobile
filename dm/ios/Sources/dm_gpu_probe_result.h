#pragma once
#include <stddef.h>
#include <stdint.h>
#include <string.h>

enum { DM_GPU_PROBE_WORDS = 64 };
enum dm_gpu_probe_match { DM_GPU_PROBE_INVALID = -1, DM_GPU_PROBE_MISMATCH = 0, DM_GPU_PROBE_MATCH = 1 };
enum dm_gpu_probe_case { DM_GPU_CASE_INVALID = -1, DM_GPU_CASE_CORE, DM_GPU_CASE_RESIDENCY,
    DM_GPU_CASE_MALLOC, DM_GPU_CASE_VM, DM_GPU_CASE_SHARED, DM_GPU_CASE_ALIAS, DM_GPU_CASE_ALL };

static inline enum dm_gpu_probe_case dm_gpu_probe_parse_case(const char *name) {
    static const char *names[] = {"core", "residency", "nocopy-malloc", "nocopy-vm", "nocopy-shared", "buffer-alias", "all"};
    if (!name) return DM_GPU_CASE_INVALID;
    for (int i = 0; i < 7; i++) if (!strcmp(name, names[i])) return (enum dm_gpu_probe_case)i;
    return DM_GPU_CASE_INVALID;
}

static inline enum dm_gpu_probe_match dm_gpu_probe_check(const uint32_t *words, size_t count) {
    if (!words || count != DM_GPU_PROBE_WORDS) return DM_GPU_PROBE_INVALID;
    for (size_t i = 0; i < count; i++)
        if (words[i] != (((uint32_t)i + 1u) ^ UINT32_C(0x5a5a5a5a))) return DM_GPU_PROBE_MISMATCH;
    return DM_GPU_PROBE_MATCH;
}
