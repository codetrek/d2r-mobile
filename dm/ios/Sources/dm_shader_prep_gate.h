#pragma once

typedef enum { DmPrepIdle, DmPrepPending, DmPrepReady } DmShaderPrepState;
typedef enum { DmPrepPass, DmPrepWait, DmPrepStart } DmShaderPrepDecision;

static inline DmShaderPrepDecision dm_shader_prep_enter(DmShaderPrepState *state) {
    if (*state == DmPrepReady) return DmPrepPass;
    if (*state == DmPrepPending) return DmPrepWait;
    *state = DmPrepPending;
    return DmPrepStart;
}
static inline void dm_shader_prep_ready(DmShaderPrepState *state) { *state = DmPrepReady; }
