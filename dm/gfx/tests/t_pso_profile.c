#include <assert.h>
#include <stdio.h>
#include "../nvn/nvn_pso_profile.h"

static pso_skey ordinary(void) {
    pso_skey key = {0};
    memcpy(key.vs, "0123456789abcdef_b", 19);
    memcpy(key.fs, "fedcba9876543210_b", 19);
    key.fs_stage = 1;
    return key;
}
static void check(pso_skey key, PsoProfileStatus expected) {
    char hex[sizeof key * 2 + 1]; pso_skey decoded;
    pso_skey_hex(&key, hex);
    assert(pso_profile_parse(hex, &decoded) == expected);
    if (!expected) assert(memcmp(&key, &decoded, sizeof key) == 0);
}
int main(void) {
    pso_skey key = ordinary(); check(key, PsoProfileValid);
    assert(pso_profile_features(&key) == 0);
    memset(key.fs, 0, sizeof key.fs); key.fs_stage = 0; check(key, PsoProfileValid);
    key = ordinary(); memset(key.vs, 'a', sizeof key.vs); check(key, PsoProfileBadKey);
    key = ordinary(); key.vs[23] = 'a'; check(key, PsoProfileBadKey);
    key = ordinary(); key.vs[0] = 'g'; check(key, PsoProfileBadKey);
    key = ordinary(); key.vs[0] = 0; check(key, PsoProfileBadKey);
    key = ordinary(); key.vs_stage = 1; check(key, PsoProfileBadStage);
    key = ordinary(); key.fs_stage = 0; check(key, PsoProfileBadStage);
    key = ordinary(); memset(key.fs, 0, sizeof key.fs); check(key, PsoProfileBadStage);
    key = ordinary(); key.k.vs = (void *)1; check(key, PsoProfileObjectPointer);
    key = ordinary(); key.k.fs = (void *)1; check(key, PsoProfileObjectPointer);
    key = ordinary(); key.k.fsfn = (void *)1; check(key, PsoProfileObjectPointer);
    key = ordinary(); key.merged = 2; check(key, PsoProfileBadFlags);
    key = ordinary(); key.fz = 2; check(key, PsoProfileBadFlags);
    for (size_t i = 0; i < sizeof key.fz_desc; i++) {
        key = ordinary(); ((unsigned char *)&key.fz_desc)[i] = 1; check(key, PsoProfileBadSpecialization);
    }
    for (unsigned flags = 1; flags < 4; flags++) {
        key = ordinary(); key.merged = flags & 1; key.fz = (flags >> 1) & 1;
        memset(&key.fz_desc, 0xff, sizeof key.fz_desc);
        check(key, PsoProfileValid); assert(pso_profile_features(&key) == flags);
    }
    key = ordinary(); memcpy(key.fs, "fedcba9876543210_bf", 20);
    check(key, PsoProfileValid); assert(pso_profile_features(&key) == PsoProfileFramebufferFetch);
    char hex[sizeof key * 2 + 1]; pso_skey decoded; pso_skey_hex(&key, hex);
    assert(pso_profile_parse(hex + 1, &decoded) == PsoProfileBadHex);
    hex[0] = 'g'; assert(pso_profile_parse(hex, &decoded) == PsoProfileBadHex);
    puts("PSO_PROFILE OK native ordinary/excluded records and malformed-key/stage/pointer/flag/descriptor checks");
    return 0;
}
