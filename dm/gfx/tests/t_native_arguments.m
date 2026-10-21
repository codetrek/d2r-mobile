#import <Foundation/Foundation.h>
#include <assert.h>
#include "../nvn/nvn_native_arguments.h"

@interface BindingBuffer : NSObject
@property NSUInteger length;
@end
@implementation BindingBuffer @end
@interface RecordingArguments : NSObject
@property NSUInteger calls, offset, index;
@property(strong) id buffer;
@end
@implementation RecordingArguments
- (void)setBuffer:(id)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index {
    self.calls++; self.buffer = buffer; self.offset = offset; self.index = index;
}
@end

int main(void) {
    @autoreleasepool {
        BindingBuffer *buffer = [BindingBuffer new]; buffer.length = 65536;
        RecordingArguments *recording = [RecordingArguments new];
        id<MTLArgumentEncoder> encoder = (id<MTLArgumentEncoder>)recording;
        nvn_buffer_map map = {.next = UINT64_C(0x1000000000000000)};
        uint64_t token;
        assert(!nvn_buffer_map_add(&map, (__bridge void *)buffer, buffer.length, &token));
        assert(!nvn_native_encode_buffer(encoder, &map, token, 65536, 65536, 16, 1, 7));
        assert(recording.calls == 1 && recording.buffer == buffer && !recording.offset && recording.index == 7);
        assert(nvn_native_encode_buffer(encoder, &map, token + 256, 65536, 65536, 16, 1, 7));
        assert(nvn_native_encode_buffer(encoder, &map, token, 256, 65536, 16, 1, 7));
        assert(nvn_native_encode_buffer(encoder, &map, token + 256, 65281, 16, 16, 1, 7));
        assert(nvn_native_encode_buffer(encoder, &map, token + 16, 16, 16, 16, 1, 7));
        assert(nvn_native_encode_buffer(encoder, &map, token, 16, 0, 16, 1, 7));
        assert(nvn_native_encode_buffer(encoder, &map, token, 16, 16, 0, 1, 7));
        assert(nvn_native_encode_buffer(encoder, &map, token, 0, 16, 16, 1, 7));
        assert(nvn_native_encode_buffer(encoder, &map, UINT64_MAX, 16, 16, 16, 0, 7));
        assert(recording.calls == 1);
        assert(!nvn_native_encode_buffer(encoder, &map, token + 256, 65280, 16, 16, 1, 8));
        assert(recording.calls == 2 && recording.offset == 256 && recording.index == 8);
        assert(!nvn_native_encode_buffer(encoder, &map, token + 16, 16, 16, 16, 0, 9));
        assert(recording.calls == 3 && recording.offset == 16 && recording.index == 9);
        assert(nvn_native_encode_buffer(encoder, &map, token + 16, 15, 16, 16, 0, 9));
        assert(recording.calls == 3);
        BindingBuffer *large = [BindingBuffer new]; large.length = 65537;
        uint64_t large_token;
        assert(!nvn_buffer_map_add(&map, (__bridge void *)large, large.length, &large_token));
        assert(nvn_native_encode_buffer(encoder, &map, large_token, 16, 16, 16, 1, 10));
        assert(nvn_native_encode_buffer(encoder, &map, token, UINT64_MAX, 16, 16, 0, 10));
        assert(recording.calls == 3);
        nvn_buffer_map_remove(&map, (__bridge void *)buffer);
        assert(nvn_native_encode_buffer(encoder, &map, token, 65536, 65536, 16, 1, 7));
        assert(recording.calls == 3);
        free(map.ranges);
        puts("native argument setter full-span integration passed (CPU only)");
    }
}
