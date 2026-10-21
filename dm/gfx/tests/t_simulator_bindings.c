#include <assert.h>
#include <stdio.h>
#include "../nvn/nvn_buffer_map.h"
#include "../nvn/nvn_simulator.h"

int main(void) {
    nvn_buffer_map map = {.next = UINT64_C(0x1000000000000000)};
    int a = 1, b = 2; uint64_t first, second, offset, again; void *object;
    assert(!nvn_buffer_map_add(&map, &a, 4097, &first));
    assert(!nvn_buffer_map_add(&map, &a, 4097, &again) && first == again && map.count == 1);
    assert(nvn_buffer_map_add(&map, &a, 4096, &again));
    assert(!nvn_buffer_map_add(&map, &b, 256, &second) && second == first + 8192);
    assert(!nvn_buffer_map_get(&map, first + 4096, 1, &object, &offset) && object == &a && offset == 4096);
    assert(nvn_buffer_map_get(&map, first + 4096, 2, &object, &offset));
    assert(nvn_buffer_map_get(&map, first + 4097, 1, &object, &offset));
    assert(nvn_buffer_map_get(&map, UINT64_MAX, UINT64_MAX, &object, &offset));
    assert(nvn_buffer_map_get(&map, first, 0, &object, &offset));
    nvn_buffer_map_remove(&map, &a);
    assert(nvn_buffer_map_get(&map, first, 1, &object, &offset));
    assert(!nvn_buffer_map_get(&map, second, 256, &object, &offset) && object == &b);
    assert(!nvn_buffer_map_add(&map, &a, 4097, &again) && again > second);
    assert(nvn_buffer_map_add(&map, NULL, 1, &again));
    assert(nvn_buffer_map_add(&map, &a, 0, &again));
    free(map.ranges);
    map = (nvn_buffer_map){.next = UINT64_MAX - 4095};
    assert(nvn_buffer_map_add(&map, &a, 1, &again));
    map.next = 1;
    assert(nvn_buffer_map_add(&map, &a, UINT64_MAX, &again));
    int objects[129] = {0};
    map = (nvn_buffer_map){.next = 1};
    for (size_t i = 0; i < 129; i++) assert(!nvn_buffer_map_add(&map, &objects[i], 16, &again));
    assert(map.count == 129 && map.capacity >= map.count);
    assert(!nvn_buffer_map_get(&map, again + 15, 1, &object, &offset) && object == &objects[128] && offset == 15);
    free(map.ranges);
    assert(nvn_sim_constant_range(65536, 256, 65280));
    assert(nvn_sim_constant_range(256, 0, 256));
    assert(!nvn_sim_constant_range(65537, 0, 1));
    assert(!nvn_sim_constant_range(65536, 1, 1));
    assert(!nvn_sim_constant_range(65536, 65536, 1));
    assert(!nvn_sim_constant_range(65536, 0, 0));
    assert(nvn_sim_argument_layout(65536, 65536));
    assert(nvn_sim_argument_layout(8, 8));
    assert(!nvn_sim_argument_layout(0, 8));
    assert(!nvn_sim_argument_layout(65537, 8));
    assert(!nvn_sim_argument_layout(8, 3));
    assert(!nvn_sim_argument_layout(8, 0));
    uint64_t seen = 0;
    assert(!nvn_sim_binding_id(2, 3, &seen));
    assert(!nvn_sim_binding_id(0, 3, &seen));
    assert(!nvn_sim_binding_id(1, 3, &seen) && seen == 7);
    assert(nvn_sim_binding_id(1, 3, &seen));
    assert(nvn_sim_binding_id(3, 3, &seen));
    assert(nvn_sim_binding_id(64, 65, &seen));
    assert(nvn_sim_binding_id(0, 0, &seen));
    puts("simulator binding policy and owned token ranges passed");
}
