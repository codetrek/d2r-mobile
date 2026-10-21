#import "nvn_ordered_constants.h"
#include <math.h>

@interface NvnConstantBlock : NSObject
@property(nonatomic, strong) id<MTLBuffer> buffer;
@property(nonatomic) uint64_t fence;
@property(nonatomic) BOOL pending;
@end
@implementation NvnConstantBlock @end

@implementation NvnConstantPool {
    id<MTLDevice> _device;
    NSMutableArray<NvnConstantBlock *> *_blocks;
    NSUInteger _budget, _allocatedBytes, _recordingBytes, _allocationCount, _reuseCount;
    uint64_t _completed, _committed;
    BOOL _recording;
    id<MTLEvent> _event;
    id<MTLBlitCommandEncoder> _blit;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device budget:(NSUInteger)budget {
    if (!device || budget < NVN_SIM_CONSTANT_ALIGNMENT) return nil;
    if ((self = [super init])) { _device = device; _budget = budget; _blocks = [NSMutableArray array]; }
    return self;
}
- (NSUInteger)allocatedBytes { return _allocatedBytes; }
- (NSUInteger)recordingBytes { return _recordingBytes; }
- (NSUInteger)allocationCount { return _allocationCount; }
- (NSUInteger)reuseCount { return _reuseCount; }
- (NvnConstantStatus)beginCompleted:(uint64_t)completed {
    if (_recording || completed < _completed) return NvnConstantState;
    _completed = completed; _recordingBytes = 0; _recording = YES;
    return NvnConstantOK;
}
- (id<MTLBlitCommandEncoder>)beginCopyCommand:(id<MTLCommandBuffer>)command {
    if (!_recording || !command || !command.retainedReferences) return nil;
    _blit = nil;
    _event = [_device newEvent];
    if (!_event) return nil;
    // A signal is reached only after this command buffer's preceding passes finish.
    // The following wait gates the copy even when another buffer aliases its source.
    // A distinct event per batch prevents a later command buffer's higher timeline
    // value from satisfying this wait. The caller has ended all active encoders.
    // https://developer.apple.com/documentation/metal/mtlcommandbuffer/encodesignalevent(_:value:)
    [command encodeSignalEvent:_event value:1];
    [command encodeWaitForEvent:_event value:1];
    _blit = [command blitCommandEncoder]; return _blit;
}
- (NvnConstantStatus)prepareSource:(id<MTLBuffer>)source offset:(NSUInteger)offset length:(NSUInteger)length
                         required:(NSUInteger)required alignment:(NSUInteger)alignment
                             blit:(id<MTLBlitCommandEncoder>)blit buffer:(id<MTLBuffer> __strong *)buffer {
    if (!_recording) return NvnConstantState;
    if (!buffer || !blit || blit != _blit || !source || source.device != _device || source.heap || !length || !required ||
        offset % 4 || length % 4 ||
        length > NVN_SIM_CONSTANT_LIMIT || required > NVN_SIM_CONSTANT_LIMIT ||
        !alignment || (alignment & (alignment - 1)) || alignment > NVN_SIM_CONSTANT_LIMIT ||
        offset > source.length || length > source.length - offset) return NvnConstantInvalid;
    NSUInteger needed = (MAX(length, required) + NVN_SIM_CONSTANT_ALIGNMENT - 1) & ~(NSUInteger)(NVN_SIM_CONSTANT_ALIGNMENT - 1);
    NvnConstantBlock *block = nil;
    for (NvnConstantBlock *candidate in _blocks) {
        if (!candidate.pending && candidate.fence && candidate.fence <= _completed && candidate.buffer.length >= needed &&
            (!block || candidate.buffer.length < block.buffer.length)) block = candidate;
    }
    if (block) _reuseCount++;
    else {
        if (needed > _budget - _allocatedBytes || _blocks.count >= 8192) return NvnConstantCapacity;
        id<MTLBuffer> backing = [_device newBufferWithLength:needed options:MTLResourceStorageModePrivate | MTLResourceHazardTrackingModeTracked];
        if (!backing || backing.length != needed || backing.device != _device || backing.hazardTrackingMode != MTLHazardTrackingModeTracked) return NvnConstantAllocation;
        block = [NvnConstantBlock new]; block.buffer = backing;
        [_blocks addObject:block]; _allocatedBytes += needed; _allocationCount++;
    }
    block.pending = YES; _recordingBytes += block.buffer.length;
    // Simulator constants require <=64 KiB backings and 256-byte binding offsets.
    // We bind offset zero; the copy reads current GPU data in this command stream.
    // https://developer.apple.com/documentation/metal/developing-metal-apps-that-run-in-simulator
    [blit fillBuffer:block.buffer range:NSMakeRange(0, block.buffer.length) value:0];
    [blit copyFromBuffer:source sourceOffset:offset toBuffer:block.buffer destinationOffset:0 size:length];
    *buffer = block.buffer;
    return NvnConstantOK;
}
- (NvnConstantStatus)commitFence:(uint64_t)fence {
    if (!_recording || !fence || fence <= _committed) return NvnConstantState;
    for (NvnConstantBlock *block in _blocks) if (block.pending) { block.pending = NO; block.fence = fence; }
    _committed = fence; _recording = NO; _blit = nil;
    return NvnConstantOK;
}
@end

id<MTLComputePipelineState> nvn_constant_matrix_pipeline(id<MTLDevice> device, NSError **error) {
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void matrix_shift(device float *m [[buffer(0)]], constant float &o [[buffer(1)]]) {"
        "m[1]+=o*m[3]; m[5]+=o*m[7]; m[9]+=o*m[11]; m[13]+=o*m[15]; }";
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:error];
    if (!library) return nil;
    id<MTLFunction> function = [library newFunctionWithName:@"matrix_shift"];
    if (!function) return nil;
    return [device newComputePipelineStateWithFunction:function error:error];
}
int nvn_constant_matrix_encode(id<MTLCommandBuffer> command, id<MTLComputePipelineState> pipeline,
                               id<MTLBuffer> buffer, float verticalOffset) {
    if (!command || !pipeline || !buffer || buffer.length < 64 || buffer.length > NVN_SIM_CONSTANT_LIMIT ||
        !isfinite(verticalOffset) || !command.retainedReferences) return -1;
    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    if (!encoder) return -1;
    [encoder setComputePipelineState:pipeline]; [encoder setBuffer:buffer offset:0 atIndex:0];
    [encoder setBytes:&verticalOffset length:sizeof verticalOffset atIndex:1];
    [encoder dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [encoder endEncoding]; return 0;
}
