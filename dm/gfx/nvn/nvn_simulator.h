#pragma once
#include <stddef.h>
#include <stdint.h>

#ifndef DM_NVN_SIMULATOR
#define DM_NVN_SIMULATOR 0
#endif

enum { NVN_SIM_CONSTANT_LIMIT = 65536, NVN_SIM_CONSTANT_ALIGNMENT = 256 };

// Apple documents tighter constant-buffer restrictions for Simulator:
// https://developer.apple.com/documentation/metal/developing-metal-apps-that-run-in-simulator
static inline int nvn_sim_constant_range(uint64_t backing, uint64_t offset, uint64_t length) {
    return backing && backing <= NVN_SIM_CONSTANT_LIMIT && length &&
           offset % NVN_SIM_CONSTANT_ALIGNMENT == 0 && offset <= backing && length <= backing - offset;
}

static inline int nvn_sim_argument_layout(size_t length, size_t alignment) {
    return length && length <= NVN_SIM_CONSTANT_LIMIT && alignment &&
           !(alignment & (alignment - 1)) && alignment <= NVN_SIM_CONSTANT_LIMIT;
}

static inline int nvn_sim_binding_id(unsigned id, unsigned count, uint64_t *seen) {
    if (!count || count > 64 || id >= count || (*seen & (UINT64_C(1) << id))) return -1;
    *seen |= UINT64_C(1) << id; return 0;
}
