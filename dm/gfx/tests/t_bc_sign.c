#define BCDEC_IMPLEMENTATION
#define BCDEC_BC4BC5_PRECISE
#include "bcdec.h"
#include <assert.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>

static int reference(int value,unsigned bits) {
    uint64_t modulus=UINT64_C(1)<<bits, sign=modulus/2;
    uint64_t masked=(uint32_t)value&(modulus-1);
    return (int)(masked<sign?(int64_t)masked:(int64_t)masked-(int64_t)modulus);
}
int main(void) {
    unsigned count=0;
    for(unsigned bits=1;bits<=16;bits++) {
        for(unsigned value=0;value<(1u<<bits);value++) { assert(bcdec__extend_sign((int)value,(int)bits)==reference((int)value,bits));count++; }
        int extremes[]={INT_MIN,INT_MAX,-1,0,1,65536};
        for(unsigned i=0;i<sizeof extremes/sizeof *extremes;i++) assert(bcdec__extend_sign(extremes[i],(int)bits)==reference(extremes[i],bits));
    }
    assert(count==131070);
    puts("BC endpoint sign extension: independent int64 arithmetic oracle passed all 131070 values at widths 1-16 plus 96 masked extreme probes");
}
