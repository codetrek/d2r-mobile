#pragma once
#import <Metal/Metal.h>
#include "nvn_buffer_map.h"
#include "nvn_simulator.h"

// Minimum type size/alignment come from the compiler's MTLPointerType reflection.
// The complete bound extent comes from NVN; sizeof(T) is not a dynamic-access proof.
// Unknown layouts are rejected before invoking the native setter.
static inline int nvn_native_encode_buffer(id<MTLArgumentEncoder> encoder, const nvn_buffer_map *map,
                                           uint64_t token, uint64_t requested, uint64_t required,
                                           uint64_t alignment, int constant, NSUInteger index) {
    if (!encoder || !requested || !required || requested < required || !alignment) return -1;
    const nvn_buffer_range *range = nvn_buffer_map_find(map, token, requested);
    if (!range) return -1;
    uint64_t offset = token - range->token;
    if (offset % alignment || (constant && !nvn_sim_constant_range(range->length, offset, requested))) return -1;
    id<MTLBuffer> buffer = (__bridge id<MTLBuffer>)range->object;
    [encoder setBuffer:buffer offset:(NSUInteger)offset atIndex:index];
    return 0;
}
