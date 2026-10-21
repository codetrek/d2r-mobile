#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>

@interface ConstantBuffer : NSObject
@property NSUInteger length;
@property(weak) id device;
@property id heap;
@property MTLHazardTrackingMode hazardTrackingMode;
@end
@implementation ConstantBuffer
- (void *)contents { abort(); }
@end
@interface ConstantDevice : NSObject
@property NSUInteger allocations;
@end
@implementation ConstantDevice
- (id)newEvent { return [NSObject new]; }
- (id)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options {
    assert(options == (MTLResourceStorageModePrivate | MTLResourceHazardTrackingModeTracked));
    self.allocations++;
    ConstantBuffer *buffer = [ConstantBuffer new]; buffer.length = length; buffer.device = self; buffer.hazardTrackingMode = MTLHazardTrackingModeTracked; return buffer;
}
@end
@interface ConstantBlit : NSObject
@property(strong) NSMutableArray *events;
@end
@implementation ConstantBlit
- (instancetype)init { if ((self = [super init])) _events = [NSMutableArray array]; return self; }
- (void)fillBuffer:(id)buffer range:(NSRange)range value:(uint8_t)value {
    assert(!range.location && range.length == [buffer length] && value == 0);
    [self.events addObject:@[@"fill", buffer, @(range.length)]];
}
- (void)copyFromBuffer:(id)source sourceOffset:(NSUInteger)offset toBuffer:(id)destination destinationOffset:(NSUInteger)destinationOffset size:(NSUInteger)size {
    assert(!destinationOffset);
    [self.events addObject:@[@"copy", source, @(offset), destination, @(size)]];
}
@end
@interface ConstantCompute : NSObject
@property(strong) NSMutableArray *events;
@end
@implementation ConstantCompute
- (void)setComputePipelineState:(id)pipeline { assert(pipeline); [self.events addObject:@"pipeline"]; }
- (void)setBuffer:(id)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index { assert(buffer && !offset && !index); [self.events addObject:@"matrix-buffer"]; }
- (void)setBytes:(const void *)bytes length:(NSUInteger)length atIndex:(NSUInteger)index { assert(length == sizeof(float) && index == 1 && *(const float *)bytes == .25f); [self.events addObject:@"matrix-offset"]; }
- (void)dispatchThreadgroups:(MTLSize)groups threadsPerThreadgroup:(MTLSize)threads { assert(groups.width == 1 && groups.height == 1 && groups.depth == 1 && threads.width == 1 && threads.height == 1 && threads.depth == 1); [self.events addObject:@"matrix-dispatch"]; }
- (void)endEncoding { [self.events addObject:@"matrix-end"]; }
@end
@interface ConstantCommand : NSObject
@property(strong) ConstantBlit *blit;
@property(strong) ConstantCompute *compute;
@property(strong) NSMutableArray *events;
@end
@implementation ConstantCommand
- (BOOL)retainedReferences { return YES; }
- (id)computeCommandEncoder { [self.events addObject:@"matrix-begin"]; return self.compute; }
- (void)encodeSignalEvent:(id)event value:(uint64_t)value { assert(event && value); [self.events addObject:@"signal"]; }
- (void)encodeWaitForEvent:(id)event value:(uint64_t)value { assert(event && value); [self.events addObject:@"wait"]; }
- (id)blitCommandEncoder { [self.events addObject:@"blit"]; return self.blit; }
@end
@interface ConstantArguments : NSObject
@property NSUInteger calls;
@property(strong) id buffer;
@end
@implementation ConstantArguments
- (void)setBuffer:(id)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index {
    assert(!offset && index == 3); self.calls++; self.buffer = buffer;
}
@end
