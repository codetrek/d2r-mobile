#pragma once
#import <Foundation/Foundation.h>

static inline BOOL dm_gpu_probe_checkpoint(NSMutableDictionary *report, NSString *test, BOOL (^persist)(void)) {
    report[@"pending_test"] = test;
    return persist();
}
