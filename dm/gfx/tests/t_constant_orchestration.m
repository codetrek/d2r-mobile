#import <Foundation/Foundation.h>
#include <assert.h>
#include <string.h>
#include "../nvn/nvn_ordered_constants.h"
#include "../nvn/nvn_refl.h"
#include "constant_recording.h"

#define MDIE(...) do { fprintf(stderr, __VA_ARGS__); abort(); } while (0)
typedef struct { uint64_t addr, size; } p_bind_buf;
static struct { p_bind_buf ubo[6][16], ssbo[6][16]; uint64_t tex[6][128], samp[6][128]; } S;
@interface NvShader : NSObject { @public
    id ae; nvn_refl rf; id<MTLBuffer> c1buf; size_t c1off; char key[24];
    NSUInteger native_required[NVN_REFL_MAXB], native_alignment[NVN_REFL_MAXB];
} @end
@implementation NvShader @end
static id<MTLDevice> g_dev;
static id<MTLCommandBuffer> g_cb;
static id<MTLBlitCommandEncoder> g_blit;
static NvnConstantPool *g_sim_constants;
static NvShader *nestedShader;
static BOOL replayPending;
static unsigned nestedReplays;
static id<MTLBuffer> sourceBuffer;
static id<MTLBuffer> zero_bank(void) { abort(); }
static id<MTLBuffer> support_buf(void) { abort(); }
static size_t arena_alloc(size_t size, id<MTLBuffer> __strong *buffer) { (void)size; (void)buffer; abort(); }
static int mtl_addr(uint64_t address, uint64_t length, void **buffer, uint64_t *offset) {
    assert(address == 0x1000 && length == 256); *buffer = (__bridge void *)sourceBuffer; *offset = 0; return 1;
}
static void enc_b_end(id buffer) { (void)buffer; }
static void rp_end(void);
static void sim_prepare_depths(NvShader *shader) {
    if (shader) for (int i = 0; i < shader->rf.nb; i++)
        assert(shader->rf.b[i].kind != NVN_RB_TEX || shader->rf.b[i].dpf != NVN_DPF_DEPTH);
}

// This generated include is the complete, verbatim production preparation
// region. Only the prior-pass callback is modeled; the actual pool records all
// event/fill/copy operations against CPU objects whose contents getter aborts.
#include "constant_preparation.inc"

static void rp_end(void) {
    if (replayPending) { replayPending = NO; nestedReplays++; sim_prepare_constants(nestedShader, 0, 0); }
}
static id<MTLBuffer> buffer(ConstantDevice *device) {
    ConstantBuffer *result = [ConstantBuffer new]; result.length = 65536; result.device = device; return (id)result;
}
static NvShader *shader(id<MTLBuffer> c1, unsigned mutableCount, unsigned firstRegister) {
    NvShader *result = [NvShader new]; result->ae = [NSObject new]; result->c1buf = c1;
    result->rf.nb = 1 + mutableCount; result->rf.b[0] = (nvn_rbind){.kind=NVN_RB_C1, .aid=0};
    result->native_required[0] = 65536; result->native_alignment[0] = 16;
    for (unsigned i = 0; i < mutableCount; i++) {
        result->rf.b[i+1] = (nvn_rbind){.kind=NVN_RB_CBUF, .aid=i+1, .reg=firstRegister+i};
        result->native_required[i+1] = 256; result->native_alignment[i+1] = 16;
        S.ubo[0][firstRegister+i] = (p_bind_buf){.addr=0x1000, .size=256};
    }
    return result;
}
int main(void) {
    @autoreleasepool {
        ConstantDevice *device = [ConstantDevice new]; g_dev = (id)device;
        ConstantBlit *blit = [ConstantBlit new]; ConstantCommand *command = [ConstantCommand new];
        command.blit = blit; command.events = [NSMutableArray array]; g_cb = (id)command;
        g_sim_constants = [[NvnConstantPool alloc] initWithDevice:g_dev budget:1048576];
        assert(![g_sim_constants beginCompleted:0]); sourceBuffer = buffer(device);
        id<MTLBuffer> outerC1 = buffer(device), nestedC1 = buffer(device);
        NvShader *outer = shader(outerC1, 3, 4); nestedShader = shader(nestedC1, 1, 7);
        replayPending = YES; sim_prepare_constants(outer, 0, 0);
        assert(!replayPending && nestedReplays == 1);
        assert(g_sim_prepared[0][0] == outerC1 && g_sim_prepared[0][0] != nestedC1);
        for (unsigned i = 1; i < 4; i++) {
            assert(g_sim_prepared[0][i]);
            for (unsigned j = 1; j < i; j++) assert(g_sim_prepared[0][i] != g_sim_prepared[0][j]);
        }
        assert(g_sim_constants.allocationCount == 4);
        sim_prepare_constants(nil, 1, 0);
        assert(g_sim_prepared[0][0] == outerC1);
        assert(![g_sim_constants commitFence:1]);
        puts("production constant orchestration: nested prior-pass replay drains before outer C1/CBUF slots (CPU only)");
    }
}
