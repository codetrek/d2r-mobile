#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include "../nvn/nvn_buffer_identity.h"

static unsigned deallocated;
@interface AnnotatedBuffer : NSObject
@property void *memory;
@property NSUInteger length;
@property(strong) id device;
- (void *)contents NS_RETURNS_INNER_POINTER;
@end
@implementation AnnotatedBuffer
- (void *)contents { return self.memory; }
- (void)dealloc { deallocated++; }
@end

__attribute__((noinline)) static BOOL registration_check(AnnotatedBuffer *buffer, const void *memory,
                                                        NSUInteger length, id device) {
    return nvn_buffer_identity((id<MTLBuffer>)buffer, memory, length, (id<MTLDevice>)device);
}

int main(void) {
    @autoreleasepool {
        uint32_t words[64] = {0};
        NSObject *device = [NSObject new];
        __weak AnnotatedBuffer *weak;
        for (unsigned i = 0; i < 32; i++) {
            AnnotatedBuffer *buffer = [AnnotatedBuffer new];
            buffer.memory = words; buffer.length = sizeof words; buffer.device = device;
            weak = buffer;
            assert(registration_check(buffer, words, sizeof words, device));
            assert(!registration_check(buffer, words + 1, sizeof words, device));
            assert(!registration_check(buffer, words, sizeof words - 1, device));
            assert(!registration_check(buffer, words, sizeof words, nil));
            buffer = nil;
            // The outer pool deliberately stays alive through this assertion.
            assert(!weak && deallocated == i + 1);
        }
        assert(!registration_check(nil, words, sizeof words, device));
        puts("buffer identity scoped interior-pointer lifetime passed (CPU only)");
    }
}
