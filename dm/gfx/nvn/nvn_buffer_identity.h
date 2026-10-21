#pragma once
#import <Metal/Metal.h>

// contents is an interior pointer: ARC may autorelease-retain its receiver.
// Only a value escapes this pool, so registration cannot pin caller-owned pages
// on a long-lived Game thread. The caller still owns the buffer and backing.
// https://clang.llvm.org/docs/AutomaticReferenceCounting.html#interior-pointers
static inline BOOL nvn_buffer_identity(id<MTLBuffer> buffer, const void *memory,
                                       NSUInteger length, id<MTLDevice> device) {
    @autoreleasepool {
        return buffer && memory && length && device && buffer.contents == memory &&
               buffer.length == length && buffer.device == device;
    }
}
