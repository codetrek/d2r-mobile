#pragma once
#include "nvn_pso_wire.h"

typedef enum {
    PsoProfileValid, PsoProfileBadHex, PsoProfileBadKey, PsoProfileBadStage,
    PsoProfileObjectPointer, PsoProfileBadFlags, PsoProfileBadSpecialization
} PsoProfileStatus;

enum { PsoProfileMerged = 1, PsoProfileSpecialized = 2, PsoProfileFramebufferFetch = 4 };

static inline int pso_profile_key(const char key[24], int empty) {
    size_t length = 0;
    while (length < 24 && key[length]) length++;
    if (!length && !empty) return 0;
    if (length && length != 18 && length != 19) return 0;
    if (length) {
        for (size_t i = 0; i < 16; i++)
            if (!((key[i] >= '0' && key[i] <= '9') || (key[i] >= 'a' && key[i] <= 'f'))) return 0;
        if (key[16] != '_' || key[17] != 'b' || (length == 19 && key[18] != 'f')) return 0;
    }
    for (size_t i = length; i < 24; i++) if (key[i]) return 0;
    return 1;
}

static inline PsoProfileStatus pso_profile_validate(const pso_skey *key) {
    if (!pso_profile_key(key->vs, 0) || !pso_profile_key(key->fs, 1)) return PsoProfileBadKey;
    if (key->vs_stage != 0 || key->fs_stage != (key->fs[0] ? 1 : 0)) return PsoProfileBadStage;
    if (key->k.vs || key->k.fs || key->k.fsfn) return PsoProfileObjectPointer;
    if (key->merged > 1 || key->fz > 1) return PsoProfileBadFlags;
    // Excluded passes keep their specialization payload opaque. We never
    // reinterpret it as a supported ordinary-pass descriptor.
    if (key->merged || key->fz) return PsoProfileValid;
    if (key->fz_desc.kind || key->fz_desc.fbmask) return PsoProfileBadSpecialization;
    for (size_t i = 0; i < 32; i++) if (key->fz_desc.fx[i]) return PsoProfileBadSpecialization;
    return PsoProfileValid;
}

static inline PsoProfileStatus pso_profile_parse(const char *hex, pso_skey *key) {
    return pso_skey_parse(hex, key) ? PsoProfileBadHex : pso_profile_validate(key);
}

// Merged targets and specialized fragments describe a different render pass.
// We classify them intact; clearing their flags would change their meaning.
static inline unsigned pso_profile_features(const pso_skey *key) {
    return (key->merged ? PsoProfileMerged : 0) | (key->fz ? PsoProfileSpecialized : 0) |
        ((strlen(key->vs) == 19 || strlen(key->fs) == 19) ? PsoProfileFramebufferFetch : 0);
}
