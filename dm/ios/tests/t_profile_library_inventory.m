#import <Foundation/Foundation.h>
#import "../Sources/dm_profile_libraries.h"
#import "../../gfx/nvn/dm_metal_library.h"
#include <assert.h>

int main(int argc, char **argv) { @autoreleasepool {
    assert(argc == 5);
    NSDictionary *expected = @{@"profile": @"ios-simulator-native-arguments-sampler-alias-v1",
        @"chain": @(argv[2]), @"metadata_sha256": @(argv[3]), @"metadata_id": @(argv[4]),
        @"compiler_source_sha256": dm_metal_library_contract()[@"source_sha256"]};
    NSError *error = nil;
    DmProfileLibraryPlan *plan = [DmProfileLibraryPlan loadRoot:@(argv[1]) expected:expected error:&error];
    if (!plan) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
    NSMutableDictionary *stages = [NSMutableDictionary dictionary];
    for (NSDictionary *item in plan.items) {
        NSString *stage = item[@"stage"];
        stages[stage] = @([stages[stage] unsignedIntegerValue] + 1);
    }
    NSDictionary *receipt = @{@"schema": @"private.profile-library-inventory-cpu.v1", @"keys": @(plan.items.count),
        @"profile": plan.identity, @"stages": stages, @"library_compilation_performed": @NO,
        @"metal_device_created": @NO, @"gpu_commands_submitted": @NO, @"game_executed": @NO};
    NSData *data = [NSJSONSerialization dataWithJSONObject:receipt options:NSJSONWritingSortedKeys error:&error];
    if (!data) return 1;
    fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout);
} return 0; }
