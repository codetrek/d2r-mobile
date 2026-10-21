#import "nvn_depth_dummy.h"
#include <math.h>
#include <string.h>

int nvn_depth_dummy_index(MTLTextureType type) {
    switch (type) {
        case MTLTextureType2D: return 0;
        case MTLTextureType2DArray: return 1;
        case MTLTextureTypeCube: return 2;
        case MTLTextureTypeCubeArray: return 3;
        default: return -1;
    }
}
MTLTextureDescriptor *nvn_depth_dummy_descriptor(MTLTextureType type) {
    if (nvn_depth_dummy_index(type) < 0) return nil;
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor new];
    descriptor.textureType = type; descriptor.pixelFormat = MTLPixelFormatDepth32Float;
    descriptor.width = descriptor.height = descriptor.depth = descriptor.arrayLength = descriptor.mipmapLevelCount = descriptor.sampleCount = 1;
    // Simulator requires private depth storage. Render-target usage admits the
    // explicit clear, while tracked reads order consumers of the same object.
    // https://developer.apple.com/documentation/metal/developing-metal-apps-that-run-in-simulator
    descriptor.storageMode = MTLStorageModePrivate;
    descriptor.hazardTrackingMode = MTLHazardTrackingModeTracked;
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    return descriptor;
}
static BOOL depth_shape(id<MTLTexture> texture, MTLTextureType type) {
    return texture && texture.textureType == type && texture.pixelFormat == MTLPixelFormatDepth32Float &&
        texture.width == 1 && texture.height == 1 && texture.depth == 1 && texture.arrayLength == 1 &&
        texture.mipmapLevelCount == 1 && texture.sampleCount == 1 && !texture.heap &&
        texture.storageMode == MTLStorageModePrivate && texture.hazardTrackingMode == MTLHazardTrackingModeTracked &&
        texture.usage == (MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
}
NvnDepthStatus nvn_depth_dummy_clear(id<MTLCommandBuffer> command, id<MTLTexture> texture, MTLTextureType type, double value) {
    if (nvn_depth_dummy_index(type) < 0) return NvnDepthUnsupportedType;
    if (!command || !command.retainedReferences || !isfinite(value) || value < 0 || value > 1) return NvnDepthInvalid;
    if (!depth_shape(texture, type) || texture.device != command.device) return NvnDepthDescriptor;
    NSUInteger slices = type == MTLTextureTypeCube || type == MTLTextureTypeCubeArray ? 6 : 1;
    for (NSUInteger slice = 0; slice < slices; slice++) {
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.depthAttachment.texture = texture; pass.depthAttachment.level = 0; pass.depthAttachment.slice = slice;
        pass.depthAttachment.loadAction = MTLLoadActionClear; pass.depthAttachment.storeAction = MTLStoreActionStore;
        pass.depthAttachment.clearDepth = value;
        id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
        if (!encoder) return NvnDepthEncoder;
        [encoder endEncoding];
    }
    return NvnDepthOK;
}
NvnDepthStatus nvn_depth_dummy_prepare(id<MTLDevice> device, id<MTLCommandBuffer> command, MTLTextureType type,
                                      id<MTLTexture> __strong *texture) {
    MTLTextureDescriptor *descriptor = nvn_depth_dummy_descriptor(type);
    if (!descriptor) return NvnDepthUnsupportedType;
    if (!device || !texture || !command || command.device != device || !command.retainedReferences) return NvnDepthInvalid;
    id<MTLTexture> prepared = *texture;
    if (!prepared) prepared = [device newTextureWithDescriptor:descriptor];
    if (!prepared) return NvnDepthAllocation;
    NvnDepthStatus status = nvn_depth_dummy_clear(command, prepared, type, 0);
    if (status) return status;
    *texture = prepared; return NvnDepthOK;
}

@implementation NvnDepthDummies {
    id<MTLDevice> _device;
    id<MTLTexture> _textures[4];
    BOOL _recorded[4];
    uint64_t _serial;
    __weak id<MTLCommandBuffer> _command;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device {
    if (!device) return nil;
    if ((self = [super init])) _device = device;
    return self;
}
- (NvnDepthStatus)prepareType:(MTLTextureType)type command:(id<MTLCommandBuffer>)command serial:(uint64_t)serial {
    int index = nvn_depth_dummy_index(type);
    if (index < 0) return NvnDepthUnsupportedType;
    if (!serial || serial < _serial || !command || command.device != _device || !command.retainedReferences ||
        (serial == _serial && command != _command)) return NvnDepthInvalid;
    if (serial != _serial) { _serial = serial; _command = command; memset(_recorded, 0, sizeof _recorded); }
    if (_recorded[index]) return NvnDepthOK;
    NvnDepthStatus status = nvn_depth_dummy_prepare(_device, command, type, &_textures[index]);
    if (!status) _recorded[index] = YES;
    return status;
}
- (id<MTLTexture>)textureForType:(MTLTextureType)type serial:(uint64_t)serial {
    int index = nvn_depth_dummy_index(type);
    return index < 0 || serial != _serial || !_command || !_recorded[index] ? nil : _textures[index];
}
@end
