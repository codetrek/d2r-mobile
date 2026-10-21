#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

// Tokens identify host-owned buffer ranges only. Native argument encoders receive
// the resolved object and offset; these values never enter shader-visible bytes.
typedef struct { void *object; uint64_t token, length; } nvn_buffer_range;
typedef struct { nvn_buffer_range *ranges; size_t count, capacity; uint64_t next; } nvn_buffer_map;
enum { NVN_BUFFER_MAP_LIMIT = 131072 };

static inline int nvn_buffer_map_add(nvn_buffer_map *map, void *object, uint64_t length, uint64_t *token) {
    if (!object || !length || !map->next) return -1;
    for (size_t i = 0; i < map->count; i++) if (map->ranges[i].object == object) {
        if (map->ranges[i].length != length) return -1;
        *token = map->ranges[i].token; return 0;
    }
    if (length > UINT64_MAX - 4095 || map->count == NVN_BUFFER_MAP_LIMIT) return -1;
    uint64_t extent = (length + 4095) & ~UINT64_C(4095);
    if (extent > UINT64_MAX - map->next) return -1;
    if (map->count == map->capacity) {
        size_t capacity = map->capacity ? map->capacity * 2 : 64;
        if (capacity > NVN_BUFFER_MAP_LIMIT) capacity = NVN_BUFFER_MAP_LIMIT;
        void *grown = realloc(map->ranges, capacity * sizeof *map->ranges);
        if (!grown) return -1;
        map->ranges = grown; map->capacity = capacity;
    }
    *token = map->next;
    map->ranges[map->count++] = (nvn_buffer_range){object, *token, length};
    map->next += extent;
    return 0;
}

static inline const nvn_buffer_range *nvn_buffer_map_find(const nvn_buffer_map *map, uint64_t token, uint64_t length) {
    if (!length) return NULL;
    for (size_t i = 0; i < map->count; i++) {
        const nvn_buffer_range *range = &map->ranges[i];
        if (token >= range->token && token - range->token < range->length &&
            length <= range->length - (token - range->token)) {
            return range;
        }
    }
    return NULL;
}

static inline int nvn_buffer_map_get(const nvn_buffer_map *map, uint64_t token, uint64_t length,
                                     void **object, uint64_t *offset) {
    const nvn_buffer_range *range = nvn_buffer_map_find(map, token, length);
    if (!range) return -1;
    *object = range->object; *offset = token - range->token; return 0;
}

static inline void nvn_buffer_map_remove(nvn_buffer_map *map, const void *object) {
    for (size_t i = 0; i < map->count; i++) if (map->ranges[i].object == object) {
        map->ranges[i] = map->ranges[--map->count]; return;
    }
}
