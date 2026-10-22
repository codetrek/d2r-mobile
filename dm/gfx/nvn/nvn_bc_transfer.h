#pragma once
#import <Metal/Metal.h>
#include "../tex/nvn_deswizzle.h"

// Each region is independent. Linear input strides describe compressed block rows;
// packaged input instead uses the complete, validated Tegra texture descriptor.
typedef struct {
    uint32_t width, height, depth;
    NSUInteger sourceOffset, sourceRow, sourceImage;
    NSUInteger level, slice;
    MTLOrigin origin;
    unsigned sourceLevel, sourceLayer;
} NvnBCRegion;
typedef struct {
    NSUInteger row, rows, image, inputBytes, sourceExtent;
    NSUInteger uploadRow, uploadImage, uploadBytes, inputOffset, uploadOffset;
} NvnBCGeometry;
typedef NS_ENUM(int, NvnBCStatus) { NvnBCOK, NvnBCInvalid, NvnBCUnsupported, NvnBCCapacity, NvnBCAllocation, NvnBCState };

NvnBCStatus nvn_bc_geometry(uint32_t format, const NvnBCRegion *region, NvnBCGeometry *geometry);

// Admission reserves both staging sizes and a job slot before encoding anything.
// Staging allocation starts only after the producer's shared event is reached.
// Packaged jobs require prior successful nvn_deswz_gpu_init on this device.
// Failure after admission is fatal: a failed upload never signals its consumer.
@interface NvnBCTransfers : NSObject
- (instancetype)initWithDevice:(id<MTLDevice>)device readbackQueue:(id<MTLCommandQueue>)reader
                  uploadQueue:(id<MTLCommandQueue>)uploader byteBudget:(NSUInteger)bytes jobBudget:(NSUInteger)jobs;
- (NvnBCStatus)encodeCommand:(id<MTLCommandBuffer>)command source:(id<MTLBuffer>)source
                     offset:(NSUInteger)offset length:(NSUInteger)length format:(uint32_t)format
                    regions:(const NvnBCRegion *)regions count:(NSUInteger)count
                   packaged:(const nvn_texdesc *)packaged destination:(id<MTLTexture>)destination;
@property(nonatomic, readonly) NSUInteger pendingJobs, reservedBytes, allocatedBytes, peakAllocatedBytes, completedJobs;
@end
