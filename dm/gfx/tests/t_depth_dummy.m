#import <Foundation/Foundation.h>
#include <assert.h>
#include <math.h>
#include "../nvn/nvn_depth_dummy.h"

@interface DepthTexture : NSObject
@property MTLTextureType textureType;
@property MTLPixelFormat pixelFormat;
@property NSUInteger width, height, depth, arrayLength, mipmapLevelCount, sampleCount;
@property MTLStorageMode storageMode;
@property MTLHazardTrackingMode hazardTrackingMode;
@property MTLTextureUsage usage;
@property(strong) id heap;
@property(weak) id device;
@end
@implementation DepthTexture
- (void)replaceRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice withBytes:(const void *)bytes bytesPerRow:(NSUInteger)row bytesPerImage:(NSUInteger)image {
    (void)region; (void)level; (void)slice; (void)bytes; (void)row; (void)image; abort();
}
@end
@interface DepthDevice : NSObject
@property NSUInteger allocations;
@property BOOL failAllocation, wrongFormat;
@end
@implementation DepthDevice
- (id)newTextureWithDescriptor:(MTLTextureDescriptor *)d {
    self.allocations++; if (self.failAllocation) return nil;
    DepthTexture *t = [DepthTexture new]; t.device = self;
    t.textureType = d.textureType; t.pixelFormat = self.wrongFormat ? MTLPixelFormatR32Float : d.pixelFormat;
    t.width = d.width; t.height = d.height; t.depth = d.depth; t.arrayLength = d.arrayLength;
    t.mipmapLevelCount = d.mipmapLevelCount; t.sampleCount = d.sampleCount;
    t.storageMode = d.storageMode; t.hazardTrackingMode = d.hazardTrackingMode; t.usage = d.usage; return t;
}
@end
@interface DepthEncoder : NSObject
@property(strong) NSMutableArray *events;
@end
@implementation DepthEncoder
- (void)endEncoding { [self.events addObject:@"end"]; }
@end
@interface DepthCommand : NSObject
@property(weak) id device;
@property BOOL retainedReferences;
@property NSUInteger calls, failAt;
@property(strong) NSMutableArray *events;
@end
@implementation DepthCommand
- (id)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)pass {
    self.calls++;
    if (self.failAt == self.calls) return nil;
    assert(!pass.colorAttachments[0].texture && !pass.stencilAttachment.texture);
    assert(!pass.depthAttachment.level && pass.depthAttachment.loadAction == MTLLoadActionClear && pass.depthAttachment.storeAction == MTLStoreActionStore);
    [self.events addObject:@[@"clear", pass.depthAttachment.texture, @(pass.depthAttachment.slice), @(pass.depthAttachment.clearDepth)]];
    DepthEncoder *encoder = [DepthEncoder new]; encoder.events = self.events; return encoder;
}
@end
int main(void) {
    @autoreleasepool {
        DepthDevice *device = [DepthDevice new]; DepthCommand *command = [DepthCommand new];
        command.device = device; command.retainedReferences = YES; command.events = [NSMutableArray array];
        MTLTextureType supported[] = {MTLTextureType2D, MTLTextureType2DArray, MTLTextureTypeCube, MTLTextureTypeCubeArray};
        for (unsigned i = 0; i < 4; i++) {
            MTLTextureType type = supported[i]; MTLTextureDescriptor *d = nvn_depth_dummy_descriptor(type);
            assert(d.textureType == type && d.pixelFormat == MTLPixelFormatDepth32Float && d.storageMode == MTLStorageModePrivate);
            assert(d.hazardTrackingMode == MTLHazardTrackingModeTracked && d.usage == (MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget));
            assert(d.width == 1 && d.height == 1 && d.depth == 1 && d.arrayLength == 1 && d.mipmapLevelCount == 1 && d.sampleCount == 1);
            id<MTLTexture> texture = nil; NSUInteger start = command.events.count, allocations = device.allocations;
            assert(!nvn_depth_dummy_prepare((id)device, (id)command, type, &texture));
            assert(texture && device.allocations == allocations+1);
            NSUInteger slices = i < 2 ? 1 : 6;
            assert(command.events.count == start + slices*2);
            for (NSUInteger slice = 0; slice < slices; slice++) {
                NSArray *event = command.events[start + 2*slice];
                assert([event[0] isEqual:@"clear"] && event[1] == texture && [event[2] unsignedIntegerValue] == slice && [event[3] doubleValue] == 0);
                assert([command.events[start + 2*slice + 1] isEqual:@"end"]);
            }
            id before = texture;
            assert(!nvn_depth_dummy_clear((id)command, texture, type, .625));
            assert(!nvn_depth_dummy_prepare((id)device, (id)command, type, &texture));
            assert(texture == before && device.allocations == allocations+1);
        }
        MTLTextureType unsupported[] = {MTLTextureType1D, MTLTextureType1DArray, MTLTextureType3D, MTLTextureType2DMultisample, MTLTextureType2DMultisampleArray, MTLTextureTypeTextureBuffer, (MTLTextureType)99};
        NSUInteger calls = command.calls, allocations = device.allocations;
        for (unsigned i = 0; i < sizeof unsupported/sizeof *unsupported; i++) {
            id<MTLTexture> t = nil; assert(!nvn_depth_dummy_descriptor(unsupported[i]));
            assert(nvn_depth_dummy_prepare((id)device, (id)command, unsupported[i], &t) == NvnDepthUnsupportedType);
        }
        command.retainedReferences = NO; id<MTLTexture> texture = nil;
        assert(nvn_depth_dummy_prepare((id)device, (id)command, MTLTextureType2D, &texture) == NvnDepthInvalid);
        command.retainedReferences = YES;
        assert(command.calls == calls && device.allocations == allocations);
        device.failAllocation = YES;
        assert(nvn_depth_dummy_prepare((id)device, (id)command, MTLTextureType2D, &texture) == NvnDepthAllocation && !texture);
        device.failAllocation = NO; device.wrongFormat = YES;
        assert(nvn_depth_dummy_prepare((id)device, (id)command, MTLTextureType2D, &texture) == NvnDepthDescriptor && !texture);
        device.wrongFormat = NO;
        assert(command.calls == calls);
        command.failAt = command.calls + 3;
        assert(nvn_depth_dummy_prepare((id)device, (id)command, MTLTextureTypeCube, &texture) == NvnDepthEncoder && !texture);
        command.failAt = 0;
        assert(!nvn_depth_dummy_prepare((id)device, (id)command, MTLTextureType2D, &texture));
        calls = command.calls;
        assert(nvn_depth_dummy_clear((id)command, texture, MTLTextureTypeCube, 0) == NvnDepthDescriptor);
        assert(nvn_depth_dummy_clear((id)command, texture, MTLTextureType2D, NAN) == NvnDepthInvalid);
        assert(nvn_depth_dummy_clear((id)command, texture, MTLTextureType2D, -1) == NvnDepthInvalid);
        assert(nvn_depth_dummy_clear((id)command, texture, MTLTextureType2D, 1.001) == NvnDepthInvalid);
        DepthTexture *invalid = (DepthTexture *)texture;
        invalid.storageMode = MTLStorageModeShared;
        assert(nvn_depth_dummy_clear((id)command, texture, MTLTextureType2D, 0) == NvnDepthDescriptor);
        invalid.storageMode = MTLStorageModePrivate; invalid.usage = MTLTextureUsageShaderRead;
        assert(nvn_depth_dummy_clear((id)command, texture, MTLTextureType2D, 0) == NvnDepthDescriptor);
        invalid.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget; invalid.hazardTrackingMode = MTLHazardTrackingModeUntracked;
        assert(nvn_depth_dummy_clear((id)command, texture, MTLTextureType2D, 0) == NvnDepthDescriptor);
        invalid.hazardTrackingMode = MTLHazardTrackingModeTracked; invalid.heap = [NSObject new];
        assert(nvn_depth_dummy_clear((id)command, texture, MTLTextureType2D, 0) == NvnDepthDescriptor);
        invalid.heap = nil;
        assert(command.calls == calls);
        NvnDepthDummies *cache = [[NvnDepthDummies alloc] initWithDevice:(id)device];
        assert(![cache textureForType:MTLTextureType2D serial:1]);
        assert(![cache prepareType:MTLTextureType2D command:(id)command serial:1]);
        id first = [cache textureForType:MTLTextureType2D serial:1]; assert(first);
        calls = command.calls; allocations = device.allocations;
        assert(![cache prepareType:MTLTextureType2D command:(id)command serial:1]);
        assert(command.calls == calls && device.allocations == allocations);
        assert(![cache prepareType:MTLTextureType2D command:(id)command serial:2]);
        assert(command.calls == calls+1 && device.allocations == allocations && [cache textureForType:MTLTextureType2D serial:2] == first);
        assert(![cache textureForType:MTLTextureType2D serial:1]);
        assert([cache prepareType:MTLTextureType2D command:(id)command serial:1] == NvnDepthInvalid);
        assert([cache prepareType:MTLTextureType2D command:(id)command serial:0] == NvnDepthInvalid);
        DepthCommand *otherCommand = [DepthCommand new]; otherCommand.device = device; otherCommand.retainedReferences = YES;
        assert([cache prepareType:MTLTextureType2D command:(id)otherCommand serial:2] == NvnDepthInvalid);
        command.failAt = command.calls+1;
        assert([cache prepareType:MTLTextureType2D command:(id)command serial:3] == NvnDepthEncoder);
        assert(![cache textureForType:MTLTextureType2D serial:3]);
        command.failAt = 0;
        assert(![cache prepareType:MTLTextureType2D command:(id)command serial:4]);
        assert([cache textureForType:MTLTextureType2D serial:4] == first);
        __weak DepthCommand *releasedCommand;
        @autoreleasepool {
            DepthCommand *ownedCommand = [DepthCommand new]; ownedCommand.device = device;
            ownedCommand.retainedReferences = YES; ownedCommand.events = [NSMutableArray array];
            assert(![cache prepareType:MTLTextureType2D command:(id)ownedCommand serial:5]);
            releasedCommand = ownedCommand; ownedCommand = nil;
            assert(!releasedCommand);
            assert(![cache textureForType:MTLTextureType2D serial:5]);
        }
        puts("private depth descriptor and production clear orchestration passed (CPU only; no replaceRegion/device factory)");
    }
}
