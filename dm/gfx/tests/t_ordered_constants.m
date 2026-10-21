#import <Foundation/Foundation.h>
#include <assert.h>
#include <math.h>
#include "../nvn/nvn_ordered_constants.h"
#include "../nvn/nvn_native_arguments.h"

#include "constant_recording.h"

int main(void) {
    @autoreleasepool {
        ConstantDevice *device = [ConstantDevice new];
        ConstantBuffer *source = [ConstantBuffer new]; source.length = 131072; source.device = device;
        ConstantBlit *blit = [ConstantBlit new];
        ConstantCommand *command = [ConstantCommand new]; command.blit = blit; command.events = [NSMutableArray array];
        NvnConstantPool *pool = [[NvnConstantPool alloc] initWithDevice:(id)device budget:1024];
        id<MTLBuffer> first = nil, second = nil, reused = nil;
        assert([pool prepareSource:(id)source offset:4 length:12 required:512 alignment:16 blit:(id)blit buffer:&first] == NvnConstantState);
        assert(![pool beginCompleted:0]);
        assert([pool prepareSource:(id)source offset:4 length:12 required:512 alignment:16 blit:(id)blit buffer:&first] == NvnConstantInvalid);
        assert([pool beginCopyCommand:(id)command] == (id)blit);
        assert([command.events isEqual:(@[@"signal", @"wait", @"blit"])]);
        assert(![pool prepareSource:(id)source offset:4 length:12 required:512 alignment:16 blit:(id)blit buffer:&first]);
        assert(first.length == 512 && pool.recordingBytes == 512);
        assert(blit.events.count == 2 && [blit.events[0][0] isEqual:@"fill"] && [blit.events[1][0] isEqual:@"copy"]);
        assert([blit.events[1][2] unsignedIntegerValue] == 4 && [blit.events[1][4] unsignedIntegerValue] == 12);
        ConstantArguments *arguments = [ConstantArguments new];
        assert(!nvn_native_encode_constant((id)arguments, first, 512, 16, 3));
        assert(arguments.calls == 1 && arguments.buffer == first);
        assert(nvn_native_encode_constant((id)arguments, first, 513, 16, 3));
        assert(nvn_native_encode_constant((id)arguments, first, 512, 0, 3));
        assert(nvn_native_encode_constant((id)arguments, first, 512, 3, 3));
        ConstantBuffer *oversized = [ConstantBuffer new]; oversized.length = 65537;
        assert(nvn_native_encode_constant((id)arguments, (id)oversized, 512, 16, 3));
        assert(arguments.calls == 1);
        assert(![pool prepareSource:(id)source offset:260 length:256 required:512 alignment:256 blit:(id)blit buffer:&second]);
        assert(first != second && pool.allocatedBytes == 1024 && pool.allocationCount == 2);
        assert([pool prepareSource:(id)source offset:4 length:12 required:256 alignment:16 blit:(id)blit buffer:&reused] == NvnConstantCapacity);
        NSUInteger events = blit.events.count, allocations = device.allocations;
        assert([pool prepareSource:(id)source offset:source.length-4 length:8 required:8 alignment:4 blit:(id)blit buffer:&reused] == NvnConstantInvalid);
        assert([pool prepareSource:(id)source offset:2 length:12 required:8 alignment:4 blit:(id)blit buffer:&reused] == NvnConstantInvalid);
        assert([pool prepareSource:(id)source offset:4 length:14 required:8 alignment:4 blit:(id)blit buffer:&reused] == NvnConstantInvalid);
        assert([pool prepareSource:(id)source offset:NSUIntegerMax length:8 required:8 alignment:4 blit:(id)blit buffer:&reused] == NvnConstantInvalid);
        assert([pool prepareSource:(id)source offset:0 length:65537 required:8 alignment:4 blit:(id)blit buffer:&reused] == NvnConstantInvalid);
        assert([pool prepareSource:(id)source offset:0 length:8 required:65537 alignment:4 blit:(id)blit buffer:&reused] == NvnConstantInvalid);
        assert([pool prepareSource:(id)source offset:0 length:0 required:8 alignment:4 blit:(id)blit buffer:&reused] == NvnConstantInvalid);
        assert([pool prepareSource:(id)source offset:0 length:8 required:0 alignment:4 blit:(id)blit buffer:&reused] == NvnConstantInvalid);
        assert([pool prepareSource:(id)source offset:0 length:8 required:8 alignment:0 blit:(id)blit buffer:&reused] == NvnConstantInvalid);
        assert([pool prepareSource:(id)source offset:0 length:8 required:8 alignment:3 blit:(id)blit buffer:&reused] == NvnConstantInvalid);
        assert([pool prepareSource:(id)source offset:0 length:8 required:8 alignment:131072 blit:(id)blit buffer:&reused] == NvnConstantInvalid);
        source.heap = [NSObject new];
        assert([pool prepareSource:(id)source offset:4 length:12 required:8 alignment:4 blit:(id)blit buffer:&reused] == NvnConstantInvalid);
        source.heap = nil;
        ConstantDevice *otherDevice = [ConstantDevice new]; source.device = otherDevice;
        assert([pool prepareSource:(id)source offset:4 length:12 required:8 alignment:4 blit:(id)blit buffer:&reused] == NvnConstantInvalid);
        source.device = device;
        assert(blit.events.count == events && device.allocations == allocations);
        assert(![pool commitFence:1]);
        assert(![pool beginCompleted:0]);
        assert([pool beginCopyCommand:(id)command] == (id)blit);
        assert([pool prepareSource:(id)source offset:4 length:12 required:256 alignment:16 blit:(id)blit buffer:&reused] == NvnConstantCapacity);
        assert(![pool commitFence:2]);
        assert(![pool beginCompleted:1]);
        assert([pool beginCopyCommand:(id)command] == (id)blit);
        assert(![pool prepareSource:(id)source offset:4 length:12 required:256 alignment:16 blit:(id)blit buffer:&reused]);
        assert(reused == first && pool.reuseCount == 1 && pool.allocatedBytes == 1024);
        assert(blit.events.count == events + 2);
        assert(![pool commitFence:3]);
        assert([pool beginCompleted:0] == NvnConstantState);
        ConstantCompute *compute = [ConstantCompute new]; compute.events = command.events; command.compute = compute;
        NSUInteger beforeMatrix = command.events.count;
        assert(!nvn_constant_matrix_encode((id)command, (id)device, first, .25f));
        assert([[command.events subarrayWithRange:NSMakeRange(beforeMatrix, command.events.count-beforeMatrix)]
            isEqual:(@[@"matrix-begin", @"pipeline", @"matrix-buffer", @"matrix-offset", @"matrix-dispatch", @"matrix-end"])]);
        NSUInteger afterMatrix = command.events.count;
        assert(nvn_constant_matrix_encode((id)command, (id)device, first, NAN));
        ConstantBuffer *tiny = [ConstantBuffer new]; tiny.length = 63;
        assert(nvn_constant_matrix_encode((id)command, (id)device, (id)tiny, .25f));
        assert(command.events.count == afterMatrix);
        puts("ordered constants: production fill/copy/setter order, full spans, zero-tail command, budget and completed-fence-only reuse passed (CPU only)");
    }
}
