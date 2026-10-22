#include "../Sources/dm_gpu_probe_result.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    const char *cases[] = {"core", "residency", "nocopy-malloc", "nocopy-vm", "nocopy-shared", "buffer-alias", "protected-pool", "ordered-constants", "private-depth", "prepared-arguments", "bc-transfers", "all"};
    for (int i = 0; i < 12; i++) assert(dm_gpu_probe_parse_case(cases[i]) == (enum dm_gpu_probe_case)i);
    assert(dm_gpu_probe_parse_case(NULL) == DM_GPU_CASE_INVALID);
    assert(dm_gpu_probe_parse_case("") == DM_GPU_CASE_INVALID);
    assert(dm_gpu_probe_parse_case("core-extra") == DM_GPU_CASE_INVALID);
    assert(dm_gpu_probe_parse_case("Core") == DM_GPU_CASE_INVALID);
    uint32_t words[DM_GPU_PROBE_WORDS];
    for (size_t i = 0; i < DM_GPU_PROBE_WORDS; i++) words[i] = ((uint32_t)i + 1u) ^ UINT32_C(0x5a5a5a5a);
    assert(words[0] == UINT32_C(0x5a5a5a5b));
    assert(words[63] == UINT32_C(0x5a5a5a1a));
    assert(dm_gpu_probe_check(words, 64) == DM_GPU_PROBE_MATCH);
    assert(dm_gpu_probe_check(NULL, 64) == DM_GPU_PROBE_INVALID);
    assert(dm_gpu_probe_check(words, 0) == DM_GPU_PROBE_INVALID);
    assert(dm_gpu_probe_check(words, 63) == DM_GPU_PROBE_INVALID);
    words[0] = 0;
    assert(dm_gpu_probe_check(words, 64) == DM_GPU_PROBE_MISMATCH);
    words[0] = UINT32_C(0x5a5a5a5b); words[63] = 0;
    assert(dm_gpu_probe_check(words, 64) == DM_GPU_PROBE_MISMATCH);
    puts("PASS gpu_probe_result: exact owned GPU output, partial/wrong output and invalid span rejected");
}
