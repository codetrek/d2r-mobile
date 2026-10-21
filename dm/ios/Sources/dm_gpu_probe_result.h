#pragma once
#include <stddef.h>
#include <stdint.h>

enum { DM_GPU_PROBE_WORDS = 64 };
enum dm_gpu_probe_match { DM_GPU_PROBE_INVALID = -1, DM_GPU_PROBE_MISMATCH = 0, DM_GPU_PROBE_MATCH = 1 };

static inline enum dm_gpu_probe_match dm_gpu_probe_check(const uint32_t *words, size_t count) {
    if (!words || count != DM_GPU_PROBE_WORDS) return DM_GPU_PROBE_INVALID;
    for (size_t i = 0; i < count; i++)
        if (words[i] != (((uint32_t)i + 1u) ^ UINT32_C(0x5a5a5a5a))) return DM_GPU_PROBE_MISMATCH;
    return DM_GPU_PROBE_MATCH;
}
