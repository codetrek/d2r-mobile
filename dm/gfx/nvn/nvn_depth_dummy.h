#pragma once
#import <Metal/Metal.h>

typedef NS_ENUM(int, NvnDepthStatus) {
    NvnDepthOK, NvnDepthUnsupportedType, NvnDepthInvalid, NvnDepthAllocation, NvnDepthDescriptor, NvnDepthEncoder
};
int nvn_depth_dummy_index(MTLTextureType type);
MTLTextureDescriptor *nvn_depth_dummy_descriptor(MTLTextureType type);
NvnDepthStatus nvn_depth_dummy_clear(id<MTLCommandBuffer> command, id<MTLTexture> texture, MTLTextureType type, double value);
NvnDepthStatus nvn_depth_dummy_prepare(id<MTLDevice> device, id<MTLCommandBuffer> command, MTLTextureType type,
                                      id<MTLTexture> __strong *texture);

// The submission owner prepares before opening consumers. A new serial records
// a new clear even for cached textures; failed prior submissions cannot poison it.
@interface NvnDepthDummies : NSObject
- (instancetype)initWithDevice:(id<MTLDevice>)device;
- (NvnDepthStatus)prepareType:(MTLTextureType)type command:(id<MTLCommandBuffer>)command serial:(uint64_t)serial;
- (id<MTLTexture>)textureForType:(MTLTextureType)type serial:(uint64_t)serial;
@end
