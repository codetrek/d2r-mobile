#import <Foundation/Foundation.h>
#include <assert.h>
#include "../Sources/dm_gpu_probe_checkpoint.h"

int main(void) {
    @autoreleasepool {
        NSMutableDictionary *report = [@{@"complete": @NO, @"tests": [NSMutableDictionary dictionary]} mutableCopy];
        NSMutableArray *writes = [NSMutableArray array];
        BOOL (^persist)(void) = ^BOOL {
            NSError *error = nil;
            NSData *data = [NSJSONSerialization dataWithJSONObject:report options:0 error:&error];
            assert(data && !error);
            NSDictionary *snapshot = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
            assert(snapshot && !error); [writes addObject:snapshot]; return YES;
        };
        assert(dm_gpu_probe_checkpoint(report, @"zero_copy_buffer", persist));
        report[@"tests"][@"zero_copy_buffer"] = @{@"status": @"passed"};
        assert(dm_gpu_probe_checkpoint(report, @"command_queue", persist));
        @try { @throw [NSException exceptionWithName:@"OwnedAPIFailure" reason:@"CPU-only sequencing test" userInfo:nil]; }
        @catch (NSException *error) { assert([error.name isEqual:@"OwnedAPIFailure"]); }
        NSDictionary *saved = writes.lastObject;
        assert([saved[@"pending_test"] isEqual:@"command_queue"]);
        assert([saved[@"tests"][@"zero_copy_buffer"][@"status"] isEqual:@"passed"]);
        assert(!saved[@"tests"][@"command_queue"] && ![saved[@"complete"] boolValue]);
        __block BOOL operation = NO;
        if (dm_gpu_probe_checkpoint(report, @"residency_set", ^BOOL { return NO; })) operation = YES;
        assert(!operation);
        puts("PASS gpu_probe_checkpoint: pending queue persisted with completed buffer before API failure; failed persistence stops operation");
    }
}
