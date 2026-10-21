#import <Foundation/Foundation.h>
#include <assert.h>
#include "../nvn/nvn_prepared_arguments.h"

@interface ArgumentObject : NSObject
@property(weak) id device;
@property NSUInteger length;
@property MTLStorageMode storageMode;
@end
@implementation ArgumentObject
- (void *)contents { abort(); }
@end
@interface ArgumentCommand : NSObject
@property(weak) id device;
@property BOOL retainedReferences;
@property MTLCommandBufferStatus status;
@property(strong) NSMutableArray *handlers;
@end
@implementation ArgumentCommand
- (instancetype)init { if ((self = [super init])) _handlers = [NSMutableArray array]; return self; }
- (void)addCompletedHandler:(void (^)(id))handler { [self.handlers addObject:[handler copy]]; }
- (void)complete {
    self.status = MTLCommandBufferStatusCompleted;
    NSArray *owned = [self.handlers copy]; [self.handlers removeAllObjects];
    for (void (^handler)(id) in owned) handler(self);
}
@end
@interface ArgumentConsumer : NSObject
@property(weak) id device;
@property NSUInteger calls, offset, index, usage, stages;
@property(strong) NSString *kind;
@end
@implementation ArgumentConsumer
- (void)setVertexBuffer:(id)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index {
    assert(buffer); self.calls++; self.offset = offset; self.index = index; self.kind = @"vertex";
}
- (void)setFragmentBuffer:(id)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index {
    assert(buffer); self.calls++; self.offset = offset; self.index = index; self.kind = @"fragment";
}
- (void)setBuffer:(id)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index {
    assert(buffer); self.calls++; self.offset = offset; self.index = index; self.kind = @"compute";
}
- (void)useResource:(id)resource usage:(MTLResourceUsage)usage stages:(MTLRenderStages)stages {
    assert(resource); self.calls++; self.usage = usage; self.stages = stages;
}
- (void)useResource:(id)resource usage:(MTLResourceUsage)usage { assert(resource); self.calls++; self.usage = usage; }
@end
static ArgumentObject *object(id device, NSUInteger length) {
    ArgumentObject *result = [ArgumentObject new]; result.device = device; result.length = length; result.storageMode = MTLStorageModeShared; return result;
}
int main(void) {
    @autoreleasepool {
        NSObject *device = [NSObject new], *otherDevice = [NSObject new];
        ArgumentCommand *command = [ArgumentCommand new]; command.device = device; command.retainedReferences = YES;
        ArgumentCommand *other = [ArgumentCommand new]; other.device = device; other.retainedReferences = YES;
        NvnArgumentSubmission *submission = [[NvnArgumentSubmission alloc] initWithCommand:(id)command byteBudget:512 bundleBudget:2];
        ArgumentObject *buffer = object(device, 65536);
        NvnPreparedArguments *vertex = nil, *fragment = nil;
        assert([submission prepareBuffer:(id)buffer offset:16 length:256 alignment:16 index:0 stage:0 arguments:&vertex] == NvnArgumentsInvalid);
        assert([submission prepareBuffer:(id)buffer offset:65536 length:256 alignment:16 index:0 stage:0 arguments:&vertex] == NvnArgumentsInvalid);
        assert([submission prepareBuffer:(id)buffer offset:0 length:256 alignment:0 index:0 stage:0 arguments:&vertex] == NvnArgumentsInvalid);
        assert([submission prepareBuffer:(id)buffer offset:0 length:256 alignment:16 index:31 stage:0 arguments:&vertex] == NvnArgumentsInvalid);
        assert([submission prepareBuffer:(id)buffer offset:0 length:256 alignment:16 index:0 stage:2 arguments:&vertex] == NvnArgumentsInvalid);
        assert(submission.bundleCount == 0 && submission.byteCount == 0);
        assert(![submission prepareBuffer:(id)buffer offset:0 length:256 alignment:16 index:0 stage:0 arguments:&vertex]);
        assert(![submission prepareBuffer:(id)buffer offset:256 length:256 alignment:16 index:0 stage:1 arguments:&fragment]);
        assert(vertex != fragment && submission.bundleCount == 2 && submission.byteCount == 512);
        assert([submission canPrepareLength:1] == NvnArgumentsCapacity);
        assert([submission canPrepareLength:0] == NvnArgumentsInvalid);
        ArgumentConsumer *consumer = [ArgumentConsumer new]; consumer.device = device;
        assert([vertex bindRender:(id)consumer] == NvnArgumentsState && !consumer.calls);
        ArgumentObject *resource = object(device, 1), *sampler = object(device, 1), *wrong = object(otherDevice, 1);
        assert([vertex addResource:(id)wrong usage:MTLResourceUsageRead] == NvnArgumentsInvalid);
        assert([vertex addResource:(id)resource usage:0] == NvnArgumentsInvalid);
        assert([vertex addSampler:(id)wrong] == NvnArgumentsInvalid);
        assert(![vertex addResource:(id)resource usage:MTLResourceUsageRead]);
        assert(![vertex addResource:(id)resource usage:MTLResourceUsageWrite]);
        assert(![vertex addSampler:(id)sampler]); assert(![vertex addSampler:(id)sampler]);
        assert(![fragment addResource:(id)resource usage:MTLResourceUsageRead]);
        NvnArgumentRetirement *retirement;
        assert([submission finishForCommand:(id)command retirement:&retirement] == NvnArgumentsState);
        assert(![vertex seal] && ![fragment seal]);
        assert([vertex addSampler:(id)sampler] == NvnArgumentsState);
        assert([vertex bindCompute:(id)consumer] == NvnArgumentsInvalid && !consumer.calls);
        assert(![vertex bindRender:(id)consumer]);
        assert([consumer.kind isEqual:@"vertex"] && consumer.calls == 2 && !consumer.offset && consumer.usage == (MTLResourceUsageRead | MTLResourceUsageWrite) && consumer.stages == MTLRenderStageVertex);
        assert([vertex bindRender:(id)consumer] == NvnArgumentsState && consumer.calls == 2);
        assert(![fragment bindRender:(id)consumer] && [consumer.kind isEqual:@"fragment"] && consumer.offset == 256 && consumer.stages == MTLRenderStageFragment);
        __weak id weakResource = resource, weakSampler = sampler, weakBuffer = buffer;
        assert([submission finishForCommand:(id)other retirement:&retirement] == NvnArgumentsInvalid);
        assert(![submission finishForCommand:(id)command retirement:&retirement]);
        assert([retirement retireCompletedCommand:(id)command] == NvnArgumentsState);
        __block BOOL fencePublished = NO;
        [command addCompletedHandler:^(id completed) {
            assert(![retirement retireCompletedCommand:completed]);
            assert(!weakResource && !weakSampler && !weakBuffer);
            fencePublished = YES;
        }];
        assert([submission canPrepareLength:1] == NvnArgumentsState);
        vertex = fragment = nil; resource = sampler = buffer = nil;
        assert(weakResource && weakSampler && weakBuffer);
        [command complete]; assert(fencePublished && !weakResource && !weakSampler && !weakBuffer);

        assert(![[NvnArgumentSubmission alloc] initWithCommand:(id)command byteBudget:256 bundleBudget:1]);
        command = other;
        NvnArgumentSubmission *computeSubmission = [[NvnArgumentSubmission alloc] initWithCommand:(id)command byteBudget:256 bundleBudget:1];
        buffer = object(device, 65536); NvnPreparedArguments *compute = nil;
        assert(![computeSubmission prepareBuffer:(id)buffer offset:0 length:256 alignment:16 index:0 stage:5 arguments:&compute]);
        for (unsigned i = 0; i < 64; i++) assert(![compute addResource:(id)object(device, 1) usage:MTLResourceUsageRead]);
        assert([compute addResource:(id)object(device, 1) usage:MTLResourceUsageRead] == NvnArgumentsCapacity);
        assert(![compute seal]); consumer.calls = 0;
        assert([compute bindRender:(id)consumer] == NvnArgumentsInvalid && !consumer.calls);
        assert(![compute bindCompute:(id)consumer] && [consumer.kind isEqual:@"compute"] && consumer.calls == 65);
        NvnArgumentRetirement *computeRetirement;
        assert(![computeSubmission finishForCommand:(id)command retirement:&computeRetirement]);
        [command addCompletedHandler:^(id completed) { assert(![computeRetirement retireCompletedCommand:completed]); }];
        [command complete];

        __weak ArgumentCommand *weakCommand;
        NvnArgumentSubmission *abandoned;
        @autoreleasepool {
            ArgumentCommand *owned = [ArgumentCommand new]; owned.device = device; owned.retainedReferences = YES;
            abandoned = [[NvnArgumentSubmission alloc] initWithCommand:(id)owned byteBudget:256 bundleBudget:1];
            weakCommand = owned; owned = nil; assert(!weakCommand);
        }
        assert([abandoned canPrepareLength:16] == NvnArgumentsState);
        puts("owned argument bundles: complete-before-consumer, stage usage, spans/budgets, independent blocks and completion-only sampler/resource ownership passed (CPU only)");
    }
}
