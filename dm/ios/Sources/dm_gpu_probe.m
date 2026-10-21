#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <TargetConditionals.h>
#include <mach-o/dyld.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "dm_gpu_probe_result.h"
#include "dm_gpu_probe_checkpoint.h"

void plog(const char *format, ...);

static NSDictionary *failure(NSString *status, NSString *stage, NSError *error) {
    NSMutableDictionary *result = [@{@"status": status, @"stage": stage} mutableCopy];
    if (error) result[@"error"] = @{@"domain": error.domain, @"code": @(error.code),
                                  @"description": error.localizedDescription};
    return result;
}

static NSArray *metal_images(void) {
    NSMutableArray *images = [NSMutableArray array];
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && (strstr(name, "Metal") || strstr(name, "AGX"))) [images addObject:@(name)];
    }
    return images;
}

static NSDictionary *device_info(id<MTLDevice> device, id<MTLDevice> original) {
    if (!device) return @{@"status": @"unavailable"};
    BOOL architectureAPI = [device respondsToSelector:@selector(architecture)];
    id architecture = architectureAPI ? device.architecture.name : nil;
    return @{@"status": @"available", @"name": device.name, @"class": NSStringFromClass([device class]),
             @"registry_id": @(device.registryID), @"architecture": architecture ? architecture : NSNull.null,
             @"architecture_api": @(architectureAPI), @"same_as_default": @(device == original),
             @"unified_memory": @(device.hasUnifiedMemory),
             @"metal3_family": @([device supportsFamily:MTLGPUFamilyMetal3]),
             @"apple2_family": @([device supportsFamily:MTLGPUFamilyApple2]),
             @"bc_texture_compression": @(device.supportsBCTextureCompression),
             @"argument_buffers_tier": @(device.argumentBuffersSupport)};
}

static BOOL write_report(NSDictionary *result, NSString *path, BOOL first) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
    if (!data || ![data writeToFile:path options:first ? NSDataWritingWithoutOverwriting : NSDataWritingAtomic error:&error]) {
        plog("GPU probe result write failed: %s", error.localizedDescription.UTF8String);
        return NO;
    }
    return YES;
}

static BOOL begin_test(NSMutableDictionary *result, NSString *path, NSString *test) {
    result[@"loaded_metal_images"] = metal_images();
    if (!dm_gpu_probe_checkpoint(result, test, ^BOOL { return write_report(result, path, NO); })) return NO;
    plog("GPU probe begin: %s", test.UTF8String);
    return YES;
}

static NSDictionary *compute(id<MTLDevice> device, id<MTLCommandQueue> queue, BOOL arguments) {
    NSString *source = arguments
        ? @"#include <metal_stdlib>\nusing namespace metal;\nstruct A { device uint *out [[id(0)]]; };\n"
           "kernel void probe(constant A &a [[buffer(0)]], uint i [[thread_position_in_grid]]) { a.out[i] = (i+1u)^0x5a5a5a5au; }\n"
        : @"#include <metal_stdlib>\nusing namespace metal;\n"
           "kernel void probe(device uint *out [[buffer(0)]], uint i [[thread_position_in_grid]]) { out[i] = (i+1u)^0x5a5a5a5au; }\n";
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    if (!library) return failure(@"error", @"compile_library", error);
    id<MTLFunction> function = [library newFunctionWithName:@"probe"];
    if (!function) return failure(@"error", @"lookup_function", nil);
    id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:function error:&error];
    if (!pipeline) return failure(@"error", @"create_pipeline", error);
    id<MTLBuffer> output = [device newBufferWithLength:DM_GPU_PROBE_WORDS * sizeof(uint32_t) options:MTLResourceStorageModeShared];
    if (!output || !output.contents) return failure(@"unsupported", @"shared_output", nil);
    memset(output.contents, 0, output.length);
    id<MTLBuffer> argumentBuffer = nil;
    id<MTLArgumentEncoder> argumentEncoder = nil;
    if (arguments) {
        argumentEncoder = [function newArgumentEncoderWithBufferIndex:0];
        if (!argumentEncoder || !argumentEncoder.encodedLength) return failure(@"unsupported", @"argument_encoder", nil);
        argumentBuffer = [device newBufferWithLength:argumentEncoder.encodedLength options:MTLResourceStorageModeShared];
        if (!argumentBuffer) return failure(@"unsupported", @"argument_buffer", nil);
        [argumentEncoder setArgumentBuffer:argumentBuffer offset:0];
        [argumentEncoder setBuffer:output offset:0 atIndex:0];
    }
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    if (!command || !encoder) return failure(@"error", @"command_encoder", nil);
    [encoder setComputePipelineState:pipeline];
    [encoder setBuffer:arguments ? argumentBuffer : output offset:0 atIndex:0];
    if (arguments) [encoder useResource:output usage:MTLResourceUsageWrite];
    [encoder dispatchThreads:MTLSizeMake(DM_GPU_PROBE_WORDS, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [encoder endEncoding];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        // Keep indirect resources alive even if the bounded CPU wait expires.
        (void)output.length; (void)argumentBuffer.length; (void)completed;
        dispatch_semaphore_signal(done);
    }];
    [command commit];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)))
        return failure(@"timeout", @"gpu_completion", nil);
    if (command.status != MTLCommandBufferStatusCompleted) return failure(@"error", @"gpu_completion", command.error);
    BOOL matches = dm_gpu_probe_check(output.contents, DM_GPU_PROBE_WORDS) == DM_GPU_PROBE_MATCH;
    NSMutableDictionary *result = [@{@"status": matches ? @"passed" : @"error", @"stage": @"readback",
                                     @"word_count": @(DM_GPU_PROBE_WORDS), @"output_match": @(matches),
                                     @"command_completed": @YES} mutableCopy];
    if (arguments) {
        result[@"argument_encoded_length"] = @(argumentEncoder.encodedLength);
        result[@"argument_alignment"] = @(argumentEncoder.alignment);
    }
    return result;
}

void dm_gpu_probe(void) {
    @autoreleasepool {
        NSMutableDictionary *result = [@{@"schema": @"d2r.host-gpu-probe.v1", @"host_only": @YES,
                                         @"guest_executed": @NO, @"simulator": @(TARGET_OS_SIMULATOR),
                                         @"complete": @NO,
                                         @"compute_timeout_seconds": @5,
                                         @"parent_device_api": @"No direct iOS parent-device accessor; buffer.device and queue.device are reported separately."} mutableCopy];
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            result[@"device_status"] = @"unavailable";
        } else {
            result[@"device_status"] = @"available";
            result[@"device"] = device_info(device, device);
            NSMutableDictionary *tests = [NSMutableDictionary dictionary];
            result[@"tests"] = tests;
            NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            NSString *path = [documents stringByAppendingPathComponent:[NSString stringWithFormat:@"gpu-%d-%@.json", getpid(), NSUUID.UUID.UUIDString]];
            result[@"loaded_metal_images"] = metal_images();
            if (!write_report(result, path, YES)) return;
            plog("GPU probe host-only result: %s", path.fileSystemRepresentation);
            if (!begin_test(result, path, @"shared_buffer")) return;
            id<MTLBuffer> shared = [device newBufferWithLength:0x4000 options:MTLResourceStorageModeShared];
            BOOL addressAPI = [shared respondsToSelector:@selector(gpuAddress)];
            tests[@"shared_buffer"] = @{@"status": shared && shared.contents ? @"passed" : @"unsupported",
                                        @"gpu_address_api": @(addressAPI),
                                        @"gpu_address_nonzero": @(addressAPI && shared.gpuAddress != 0),
                                        @"device": device_info(shared.device, device),
                                        @"class": shared ? NSStringFromClass([shared class]) : @"unavailable"};
            void *memory = NULL;
            if (!begin_test(result, path, @"zero_copy_buffer")) return;
            int allocation = posix_memalign(&memory, 0x4000, 0x4000);
            if (allocation) {
                tests[@"zero_copy_buffer"] = @{@"status": @"error", @"allocation_error": @(allocation)};
            } else {
                memset(memory, 0x17, 0x4000);
                id<MTLBuffer> buffer = [device newBufferWithBytesNoCopy:memory length:0x4000 options:MTLResourceStorageModeShared
                                                          deallocator:nil];
                tests[@"zero_copy_buffer"] = @{@"status": buffer && buffer.contents == memory ? @"passed" : @"unsupported",
                                               @"allocated": @(buffer != nil),
                                               @"class": buffer ? NSStringFromClass([buffer class]) : @"unavailable",
                                               @"device": device_info(buffer.device, device),
                                               @"same_contents_pointer": @(buffer && buffer.contents == memory),
                                               @"gpu_address_nonzero": @([buffer respondsToSelector:@selector(gpuAddress)] && buffer.gpuAddress != 0)};
                buffer = nil;
                free(memory);
            }
            if (!begin_test(result, path, @"command_queue")) return;
            id<MTLCommandQueue> queue = [device newCommandQueue];
            tests[@"command_queue"] = @{@"status": queue ? @"passed" : @"unsupported",
                                         @"device": device_info(queue.device, device)};
            SEL residency = @selector(newResidencySetWithDescriptor:error:);
            if (!begin_test(result, path, @"residency_set")) return;
            if ([device respondsToSelector:residency]) {
                NSError *error = nil;
                MTLResidencySetDescriptor *descriptor = [MTLResidencySetDescriptor new]; descriptor.initialCapacity = 1;
                id<MTLResidencySet> set = [device newResidencySetWithDescriptor:descriptor error:&error];
                if (!set) tests[@"residency_set"] = failure(@"error", @"create_residency_set", error);
                else if (!shared || ![queue respondsToSelector:@selector(addResidencySet:)])
                    tests[@"residency_set"] = failure(@"unsupported", @"queue_residency", nil);
                else {
                    [set addAllocation:shared]; [set commit]; [queue addResidencySet:set];
                    [queue removeResidencySet:set];
                    tests[@"residency_set"] = @{@"status": @"passed", @"queue_registration": @YES};
                }
            } else tests[@"residency_set"] = failure(@"unsupported", @"selector_unavailable", nil);
            if (queue) {
                if (!begin_test(result, path, @"direct_compute")) return;
                tests[@"direct_compute"] = compute(device, queue, NO);
                if (!begin_test(result, path, @"argument_compute")) return;
                tests[@"argument_compute"] = compute(device, queue, YES);
            } else {
                tests[@"direct_compute"] = failure(@"unsupported", @"command_queue", nil);
                tests[@"argument_compute"] = failure(@"unsupported", @"command_queue", nil);
            }
            result[@"tests"] = tests;
            [result removeObjectForKey:@"pending_test"];
            result[@"complete"] = @YES;
            result[@"loaded_metal_images"] = metal_images();
            if (write_report(result, path, NO)) plog("GPU probe complete: %s", path.fileSystemRepresentation);
            return;
        }
        result[@"loaded_metal_images"] = metal_images();
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
        NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *path = [documents stringByAppendingPathComponent:[NSString stringWithFormat:@"gpu-%d-%@.json", getpid(), NSUUID.UUID.UUIDString]];
        if (!data || ![data writeToFile:path options:NSDataWritingWithoutOverwriting error:&error])
            plog("GPU probe result write failed: %s", error.localizedDescription.UTF8String);
        else plog("GPU probe host-only result: %s", path.fileSystemRepresentation);
    }
}
