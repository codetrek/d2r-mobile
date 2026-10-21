#import "nvn_prepared_arguments.h"
#include "nvn_simulator.h"

@interface NvnPreparedArguments ()
- (instancetype)initWithBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset length:(NSUInteger)length index:(NSUInteger)index stage:(int)stage command:(id<MTLCommandBuffer>)command;
- (BOOL)isSealed;
@end
@implementation NvnPreparedArguments {
    id<MTLBuffer> _buffer;
    NSUInteger _offset, _length, _index;
    int _stage;
    BOOL _sealed, _bound;
    __weak id<MTLCommandBuffer> _command;
    NSMutableArray<id<MTLResource>> *_resources;
    NSMutableArray<NSNumber *> *_usage;
    NSMutableArray<id<MTLSamplerState>> *_samplers;
}
- (instancetype)initWithBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset length:(NSUInteger)length index:(NSUInteger)index stage:(int)stage command:(id<MTLCommandBuffer>)command {
    if ((self = [super init])) {
        _command = command; _buffer = buffer; _offset = offset; _length = length; _index = index; _stage = stage;
        _resources = [NSMutableArray array]; _usage = [NSMutableArray array]; _samplers = [NSMutableArray array];
    }
    return self;
}
- (NSUInteger)length { return _length; }
- (BOOL)isSealed { return _sealed; }
- (NvnArgumentsStatus)addResource:(id<MTLResource>)resource usage:(MTLResourceUsage)usage {
    if (_sealed) return NvnArgumentsState;
    if (!resource || resource.device != _buffer.device || !usage || (usage & ~(MTLResourceUsageRead | MTLResourceUsageWrite))) return NvnArgumentsInvalid;
    NSUInteger i = [_resources indexOfObjectIdenticalTo:resource];
    if (i != NSNotFound) { _usage[i] = @(_usage[i].unsignedIntegerValue | usage); return NvnArgumentsOK; }
    if (_resources.count + _samplers.count >= 64) return NvnArgumentsCapacity;
    [_resources addObject:resource]; [_usage addObject:@(usage)]; return NvnArgumentsOK;
}
- (NvnArgumentsStatus)addSampler:(id<MTLSamplerState>)sampler {
    if (_sealed) return NvnArgumentsState;
    if (!sampler || sampler.device != _buffer.device) return NvnArgumentsInvalid;
    if ([_samplers indexOfObjectIdenticalTo:sampler] != NSNotFound) return NvnArgumentsOK;
    if (_resources.count + _samplers.count >= 64) return NvnArgumentsCapacity;
    [_samplers addObject:sampler]; return NvnArgumentsOK;
}
- (NvnArgumentsStatus)seal {
    if (_sealed) return NvnArgumentsState;
    _sealed = YES; return NvnArgumentsOK;
}
- (NvnArgumentsStatus)bindRender:(id<MTLRenderCommandEncoder>)encoder {
    if (!_sealed || _bound || !_command || _command.status > MTLCommandBufferStatusEnqueued) return NvnArgumentsState;
    if (!encoder || _stage == 5 || encoder.device != _buffer.device) return NvnArgumentsInvalid;
    MTLRenderStages stages = _stage == 0 ? MTLRenderStageVertex : MTLRenderStageFragment;
    if (_stage == 0) [encoder setVertexBuffer:_buffer offset:_offset atIndex:_index];
    else [encoder setFragmentBuffer:_buffer offset:_offset atIndex:_index];
    for (NSUInteger i = 0; i < _resources.count; i++) [encoder useResource:_resources[i] usage:_usage[i].unsignedIntegerValue stages:stages];
    _bound = YES; return NvnArgumentsOK;
}
- (NvnArgumentsStatus)bindCompute:(id<MTLComputeCommandEncoder>)encoder {
    if (!_sealed || _bound || !_command || _command.status > MTLCommandBufferStatusEnqueued) return NvnArgumentsState;
    if (!encoder || _stage != 5 || encoder.device != _buffer.device) return NvnArgumentsInvalid;
    [encoder setBuffer:_buffer offset:_offset atIndex:_index];
    for (NSUInteger i = 0; i < _resources.count; i++) [encoder useResource:_resources[i] usage:_usage[i].unsignedIntegerValue];
    _bound = YES; return NvnArgumentsOK;
}
@end

@interface NvnArgumentRetirement ()
- (instancetype)initWithArguments:(NSMutableArray<NvnPreparedArguments *> *)arguments command:(id<MTLCommandBuffer>)command;
@end
@implementation NvnArgumentRetirement {
    NSMutableArray<NvnPreparedArguments *> *_owned;
    __weak id<MTLCommandBuffer> _command;
    BOOL _retired;
}
- (instancetype)initWithArguments:(NSMutableArray<NvnPreparedArguments *> *)arguments command:(id<MTLCommandBuffer>)command {
    if ((self = [super init])) { _owned = arguments; _command = command; }
    return self;
}
- (NvnArgumentsStatus)retireCompletedCommand:(id<MTLCommandBuffer>)command {
    if (_retired) return NvnArgumentsState;
    if (!command || command != _command) return NvnArgumentsInvalid;
    if (command.status != MTLCommandBufferStatusCompleted && command.status != MTLCommandBufferStatusError) return NvnArgumentsState;
    [_owned removeAllObjects]; _owned = nil; _retired = YES; return NvnArgumentsOK;
}
@end

@implementation NvnArgumentSubmission {
    NSUInteger _byteBudget, _bundleBudget, _byteCount;
    NSMutableArray<NvnPreparedArguments *> *_arguments;
    BOOL _closed;
    __weak id<MTLCommandBuffer> _command;
}
- (instancetype)initWithCommand:(id<MTLCommandBuffer>)command byteBudget:(NSUInteger)bytes bundleBudget:(NSUInteger)bundles {
    if (!command || !command.device || !command.retainedReferences || command.status > MTLCommandBufferStatusEnqueued || !bytes || !bundles) return nil;
    if ((self = [super init])) { _command = command; _byteBudget = bytes; _bundleBudget = bundles; _arguments = [NSMutableArray array]; }
    return self;
}
- (NSUInteger)byteCount { return _byteCount; }
- (NSUInteger)bundleCount { return _arguments.count; }
- (NvnArgumentsStatus)canPrepareLength:(NSUInteger)length {
    if (_closed || !_command || _command.status > MTLCommandBufferStatusEnqueued) return NvnArgumentsState;
    if (!length || length > NVN_SIM_CONSTANT_LIMIT) return NvnArgumentsInvalid;
    if (length > _byteBudget - _byteCount || _arguments.count == _bundleBudget) return NvnArgumentsCapacity;
    return NvnArgumentsOK;
}
- (NvnArgumentsStatus)prepareBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset length:(NSUInteger)length
                         alignment:(NSUInteger)alignment index:(NSUInteger)index stage:(int)stage
                         arguments:(NvnPreparedArguments * __strong *)arguments {
    NvnArgumentsStatus status = [self canPrepareLength:length]; if (status) return status;
    if (!buffer || !arguments || buffer.device != _command.device || buffer.storageMode != MTLStorageModeShared || index >= 31 ||
        (stage != 0 && stage != 1 && stage != 5) || !nvn_sim_argument_layout(length, alignment) ||
        !nvn_sim_constant_range(buffer.length, offset, length) || offset % alignment) return NvnArgumentsInvalid;
    NvnPreparedArguments *prepared = [[NvnPreparedArguments alloc] initWithBuffer:buffer offset:offset length:length index:index stage:stage command:_command];
    if (!prepared) return NvnArgumentsInvalid;
    [_arguments addObject:prepared]; _byteCount += length; *arguments = prepared; return NvnArgumentsOK;
}
- (NvnArgumentsStatus)finishForCommand:(id<MTLCommandBuffer>)command retirement:(NvnArgumentRetirement * __strong *)retirement {
    if (_closed || !_command || _command.status > MTLCommandBufferStatusEnqueued) return NvnArgumentsState;
    if (!retirement || !command || command != _command || !command.retainedReferences) return NvnArgumentsInvalid;
    for (NvnPreparedArguments *prepared in _arguments) if (![prepared isSealed]) return NvnArgumentsState;
    // Indirect samplers cannot be declared with useResource. The completion path
    // retires this owner before publishing its fence, independently of mutable
    // encoder/registry state. Other API owners can still keep resources alive.
    // https://developer.apple.com/documentation/metal/mtlcommandbuffer/retainedreferences
    *retirement = [[NvnArgumentRetirement alloc] initWithArguments:_arguments command:command];
    if (!*retirement) return NvnArgumentsInvalid;
    _arguments = nil; _closed = YES; return NvnArgumentsOK;
}
@end
