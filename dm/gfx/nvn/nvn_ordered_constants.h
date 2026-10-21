#pragma once
#import <Metal/Metal.h>
#include "nvn_simulator.h"

typedef NS_ENUM(int, NvnConstantStatus) {
    NvnConstantOK, NvnConstantInvalid, NvnConstantCapacity, NvnConstantAllocation, NvnConstantState
};

// Source copies are never reused by address/version inference. A backing can be
// written again only after the fence of its last consumer has completed. Source
// writes belong to this owner-thread command stream; heap aliasability is rejected.
@interface NvnConstantPool : NSObject
- (instancetype)initWithDevice:(id<MTLDevice>)device budget:(NSUInteger)budget;
- (NvnConstantStatus)beginCompleted:(uint64_t)completed;
// End all prior encoders before opening the event-gated copy batch.
- (id<MTLBlitCommandEncoder>)beginCopyCommand:(id<MTLCommandBuffer>)command;
- (NvnConstantStatus)prepareSource:(id<MTLBuffer>)source offset:(NSUInteger)offset length:(NSUInteger)length
                         required:(NSUInteger)required alignment:(NSUInteger)alignment
                             blit:(id<MTLBlitCommandEncoder>)blit buffer:(id<MTLBuffer> __strong *)buffer;
- (NvnConstantStatus)commitFence:(uint64_t)fence;
@property(nonatomic, readonly) NSUInteger allocatedBytes, recordingBytes, allocationCount, reuseCount;
@end

// The caller has ended the fill/copy blit encoder before opening this encoder.
id<MTLComputePipelineState> nvn_constant_matrix_pipeline(id<MTLDevice> device, NSError **error);
int nvn_constant_matrix_encode(id<MTLCommandBuffer> command, id<MTLComputePipelineState> pipeline,
                               id<MTLBuffer> buffer, float verticalOffset);
