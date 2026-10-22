#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

typedef NS_OPTIONS(NSUInteger, DmMetalLibraryPolicy) {
    DmMetalLibrarySource = 1, DmMetalLibraryBinary = 2,
};

NSString *dm_metal_sha256(NSData *data);
NSDictionary *dm_metal_library_contract(void);
id<MTLLibrary> dm_metal_library_load(id<MTLDevice> device, NSString *path,
                                    DmMetalLibraryPolicy policy, NSTimeInterval timeout,
                                    BOOL *compiledSource, NSError **error);
id<MTLFunction> dm_metal_library_function(id<MTLLibrary> library, NSString *entry,
                                         MTLFunctionType expected, NSTimeInterval timeout, NSError **error);

// Absolute deadlines use systemUptime and include preprocessing, queueing and
// completion. Only the renderer's load deadline of zero is synchronous/unbounded.
id<MTLLibrary> dm_metal_library_load_until(id<MTLDevice> device, NSString *path,
                                          DmMetalLibraryPolicy policy, NSTimeInterval deadline,
                                          BOOL *compiledSource, NSError **error);
id<MTLFunction> dm_metal_library_function_until(id<MTLLibrary> library, NSString *entry,
                                               MTLFunctionType expected, NSTimeInterval deadline, NSError **error);
