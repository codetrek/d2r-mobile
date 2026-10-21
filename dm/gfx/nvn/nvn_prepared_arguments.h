#pragma once
#import <Metal/Metal.h>

typedef NS_ENUM(int, NvnArgumentsStatus) { NvnArgumentsOK, NvnArgumentsInvalid, NvnArgumentsCapacity, NvnArgumentsState };

@interface NvnPreparedArguments : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (NvnArgumentsStatus)addResource:(id<MTLResource>)resource usage:(MTLResourceUsage)usage;
- (NvnArgumentsStatus)addSampler:(id<MTLSamplerState>)sampler;
- (NvnArgumentsStatus)seal;
- (NvnArgumentsStatus)bindRender:(id<MTLRenderCommandEncoder>)encoder;
- (NvnArgumentsStatus)bindCompute:(id<MTLComputeCommandEncoder>)encoder;
@property(nonatomic, readonly) NSUInteger length;
@end

@interface NvnArgumentRetirement : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (NvnArgumentsStatus)retireCompletedCommand:(id<MTLCommandBuffer>)command;
@end

// Submission-owner state. A retirement owner holds immutable bundles, including
// indirect samplers, until completion; neither owner retains the command buffer.
@interface NvnArgumentSubmission : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)initWithCommand:(id<MTLCommandBuffer>)command byteBudget:(NSUInteger)bytes bundleBudget:(NSUInteger)bundles;
- (NvnArgumentsStatus)canPrepareLength:(NSUInteger)length;
- (NvnArgumentsStatus)prepareBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset length:(NSUInteger)length
                         alignment:(NSUInteger)alignment index:(NSUInteger)index stage:(int)stage
                         arguments:(NvnPreparedArguments * __strong *)arguments;
- (NvnArgumentsStatus)finishForCommand:(id<MTLCommandBuffer>)command retirement:(NvnArgumentRetirement * __strong *)retirement;
@property(nonatomic, readonly) NSUInteger byteCount, bundleCount;
@end
