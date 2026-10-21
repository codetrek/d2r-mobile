#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <TargetConditionals.h>
#include <mach-o/dyld.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <mach/mach.h>
#include <errno.h>
#include <pthread.h>
#include "dm_gpu_probe_result.h"
#include "../../host/dm_vm.h"
#include "../../gfx/nvn/nvn_buffer_identity.h"
#include "../../gfx/nvn/nvn_ordered_constants.h"
#include "../../gfx/nvn/nvn_native_arguments.h"
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


enum Backing { BackingMalloc, BackingVM, BackingShared };
static dm_vm_pool_leases g_probe_leases = {.next = 1};
static pthread_mutex_t g_probe_lease_lock = PTHREAD_MUTEX_INITIALIZER;
static void probe_lease_release(uint64_t lease) {
    pthread_mutex_lock(&g_probe_lease_lock);
    kern_return_t code = dm_vm_lease_release(&g_probe_leases, lease);
    pthread_mutex_unlock(&g_probe_lease_lock);
    if (code != KERN_SUCCESS) { plog("GPU probe lease release failed: %d", code); abort(); }
}
static int probe_vm_change(void *memory, size_t length, int protection, int discard) {
    pthread_mutex_lock(&g_probe_lease_lock);
    int result = dm_vm_change(&g_probe_leases, memory, length, protection, discard);
    int error = errno; pthread_mutex_unlock(&g_probe_lease_lock); errno = error; return result;
}
static unsigned probe_lease_count(void) {
    pthread_mutex_lock(&g_probe_lease_lock); unsigned count = g_probe_leases.count;
    pthread_mutex_unlock(&g_probe_lease_lock); return count;
}
@interface DmGpuMemory : NSObject { @public _Atomic uint64_t pool_lease; }
@property void *pointer;
@property size_t length;
@property enum Backing backing;
@property(strong) id<MTLBuffer> buffer;
@end
@implementation DmGpuMemory
- (void)dealloc {
    dm_vm_lease_retire(&pool_lease, probe_lease_release);
    _buffer = nil;
    if (_pointer) {
        if (_backing == BackingMalloc) free(_pointer);
        else if (_backing == BackingVM) vm_deallocate(mach_task_self(), (vm_address_t)_pointer, _length);
        else munmap(_pointer, _length);
    }
}
@end

static NSDictionary *region_contract(const void *pointer, size_t length) {
    vm_address_t address = (vm_address_t)pointer;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info = {0};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t code = vm_region_64(mach_task_self(), &address, &size, VM_REGION_BASIC_INFO_64,
                                      (vm_region_info_t)&info, &count, &object);
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    BOOL contained = code == KERN_SUCCESS && address <= (vm_address_t)pointer &&
                     (vm_address_t)pointer - address <= size && length <= size - ((vm_address_t)pointer - address);
    return @{@"query_code": @(code), @"page_size": @(vm_page_size), @"requested_bytes": @(length),
             @"page_aligned": @((uintptr_t)pointer % vm_page_size == 0 && length % vm_page_size == 0),
             @"single_region": @(contained), @"region_bytes": @(size), @"region_shared": @(info.shared),
             @"readable": @((info.protection & VM_PROT_READ) != 0), @"writable": @((info.protection & VM_PROT_WRITE) != 0)};
}

static DmGpuMemory *allocate_memory(enum Backing backing, NSMutableDictionary *detail) {
    DmGpuMemory *owner = [DmGpuMemory new]; owner.length = 0x4000; owner.backing = backing;
    if (!vm_page_size || owner.length % vm_page_size) {
        detail[@"status"] = @"unsupported"; detail[@"stage"] = @"probe_page_size"; return nil;
    }
    if (backing == BackingMalloc) {
        void *pointer = NULL; int code = posix_memalign(&pointer, vm_page_size, owner.length);
        detail[@"allocation_api"] = @"posix_memalign"; detail[@"allocation_code"] = @(code);
        if (!code) owner.pointer = pointer;
    } else if (backing == BackingVM) {
        vm_address_t address = 0;
        kern_return_t code = vm_allocate(mach_task_self(), &address, owner.length, VM_FLAGS_ANYWHERE);
        detail[@"allocation_api"] = @"vm_allocate"; detail[@"allocation_code"] = @(code);
        if (code == KERN_SUCCESS) owner.pointer = (void *)address;
    } else {
        void *pointer = mmap(NULL, owner.length, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);
        detail[@"allocation_api"] = @"mmap_MAP_SHARED_MAP_ANON";
        detail[@"allocation_code"] = @(pointer == MAP_FAILED ? errno : 0);
        if (pointer != MAP_FAILED) owner.pointer = pointer;
    }
    if (!owner.pointer) { detail[@"status"] = @"error"; detail[@"stage"] = @"allocate_backing"; return nil; }
    detail[@"region"] = region_contract(owner.pointer, owner.length);
    memset(owner.pointer, 0, owner.length);
    uint32_t *words = owner.pointer;
    for (size_t i = 0; i < DM_GPU_PROBE_WORDS; i++) words[i] = (uint32_t)i + 1;
    return owner;
}

static NSDictionary *compute_at(id<MTLDevice> device, id<MTLCommandQueue> queue, BOOL arguments,
                             id<MTLBuffer> supplied, const uint32_t *observed, DmGpuMemory *owner,
                             NSUInteger bufferOffset, id<MTLSharedEvent> gate, void (^submitted)(id<MTLCommandBuffer>)) {
    BOOL transform = supplied != nil;
    NSString *body = transform ? @"out[i] = out[i]^0x5a5a5a5au;" : @"out[i] = (i+1u)^0x5a5a5a5au;";
    NSString *source = [@"#include <metal_stdlib>\nusing namespace metal;\n" stringByAppendingString:arguments
        ? @"struct A { device uint *out [[id(0)]]; };\nkernel void probe(constant A &a [[buffer(0)]], uint i [[thread_position_in_grid]]) { a.out[i] = (i+1u)^0x5a5a5a5au; }"
        : [@"kernel void probe(device uint *out [[buffer(0)]], uint i [[thread_position_in_grid]]) { " stringByAppendingFormat:@"%@ }", body]];
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    if (!library) return failure(@"error", @"compile_library", error);
    id<MTLFunction> function = [library newFunctionWithName:@"probe"];
    if (!function) return failure(@"error", @"lookup_function", nil);
    id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:function error:&error];
    if (!pipeline) return failure(@"error", @"create_pipeline", error);
    id<MTLBuffer> output = supplied;
    if (!output) output = [device newBufferWithLength:DM_GPU_PROBE_WORDS * sizeof(uint32_t) options:MTLResourceStorageModeShared];
    if (!output || !output.contents) return failure(@"error", @"shared_output", nil);
    if (bufferOffset > output.length || DM_GPU_PROBE_WORDS * sizeof(uint32_t) > output.length - bufferOffset)
        return failure(@"error", @"output_range", nil);
    if (!transform) memset(output.contents, 0, output.length);
    id<MTLArgumentEncoder> argumentEncoder = nil;
    id<MTLBuffer> argumentBuffer = nil;
    if (arguments) {
        argumentEncoder = [function newArgumentEncoderWithBufferIndex:0];
        if (!argumentEncoder || !argumentEncoder.encodedLength) return failure(@"unsupported", @"argument_encoder", nil);
        argumentBuffer = [device newBufferWithLength:argumentEncoder.encodedLength options:MTLResourceStorageModeShared];
        if (!argumentBuffer) return failure(@"error", @"argument_buffer", nil);
        [argumentEncoder setArgumentBuffer:argumentBuffer offset:0];
        [argumentEncoder setBuffer:output offset:bufferOffset atIndex:0];
    }
    id<MTLCommandBuffer> command = [queue commandBuffer];
    if (!command || !command.retainedReferences) return failure(@"error", @"command_buffer_retention", nil);
    if (gate) [command encodeWaitForEvent:gate value:1];
    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    if (!command || !encoder) return failure(@"error", @"command_encoder", nil);
    [encoder setComputePipelineState:pipeline];
    [encoder setBuffer:arguments ? argumentBuffer : output offset:arguments ? 0 : bufferOffset atIndex:0];
    if (arguments) [encoder useResource:output usage:MTLResourceUsageRead | MTLResourceUsageWrite];
    [encoder dispatchThreadgroups:MTLSizeMake(DM_GPU_PROBE_WORDS, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [encoder endEncoding];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        // The owner keeps alias mappings and no-copy backing alive after a CPU timeout.
        (void)output.length; (void)argumentBuffer.length; (void)owner.length; (void)completed;
        dispatch_semaphore_signal(done);
    }];
    [command commit];
    if (submitted) submitted(command);
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)))
        return failure(@"timeout", @"gpu_completion", nil);
    if (command.status != MTLCommandBufferStatusCompleted) return failure(@"error", @"gpu_completion", command.error);
    BOOL matches = dm_gpu_probe_check(observed ? observed : output.contents, DM_GPU_PROBE_WORDS) == DM_GPU_PROBE_MATCH;
    NSMutableDictionary *result = [@{@"status": matches ? @"passed" : @"error", @"stage": @"readback",
                                     @"word_count": @(DM_GPU_PROBE_WORDS), @"output_match": @(matches),
                                     @"command_completed": @YES, @"command_retained_references": @(command.retainedReferences), @"in_place_transform": @(transform)} mutableCopy];
    if (arguments) { result[@"argument_encoded_length"] = @(argumentEncoder.encodedLength); result[@"argument_alignment"] = @(argumentEncoder.alignment); }
    return result;
}

static NSDictionary *compute(id<MTLDevice> device, id<MTLCommandQueue> queue, BOOL arguments,
                             id<MTLBuffer> supplied, const uint32_t *observed, DmGpuMemory *owner) {
    return compute_at(device, queue, arguments, supplied, observed, owner, 0, nil, nil);
}

static NSDictionary *ordered_constants(id<MTLDevice> device, id<MTLCommandQueue> queue, BOOL (^publish)(NSDictionary *)) {
    NSMutableDictionary *result = [@{@"status": @"pending", @"stage": @"compile_ordered_kernels", @"iterations_requested": @3} mutableCopy];
    NSDictionary *(^failed)(NSString *, NSString *, NSError *) = ^NSDictionary *(NSString *status, NSString *stage, NSError *error) {
        [result addEntriesFromDictionary:failure(status, stage, error)]; return result;
    };
    if (!publish(result)) return failed(@"error", @"result_persistence", nil);
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void write_source(device uint *p [[buffer(0)]], constant uint &seed [[buffer(1)]], uint i [[thread_position_in_grid]]) {"
        "p[i+1]=i+1+seed*128; if(i<16) p[65+i]=as_type<uint>(float(i+1)); }"
        "struct A { constant uint *x [[id(0)]]; constant float *m [[id(1)]]; device uint *out [[id(2)]]; };"
        "kernel void consume(constant A &a [[buffer(0)]], uint i [[thread_position_in_grid]]) {"
        "a.out[i]=a.x[i]^0x5a5a5a5au; if(i<16) a.out[65+i]=as_type<uint>(a.m[i]);"
        "if(i==0) { uint z=0; for(uint j=64;j<128;j++)z|=a.x[j]; for(uint j=16;j<64;j++)z|=as_type<uint>(a.m[j]); a.out[64]=z; } }";
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    if (!library) return failed(@"error", @"compile_ordered_library", error);
    id<MTLFunction> write = [library newFunctionWithName:@"write_source"], read = [library newFunctionWithName:@"consume"];
    if (!write || !read) return failed(@"error", @"ordered_lookup_functions", nil);
    id<MTLComputePipelineState> writer = [device newComputePipelineStateWithFunction:write error:&error];
    if (!writer) return failed(@"error", @"ordered_writer_pipeline", error);
    id<MTLComputePipelineState> reader = [device newComputePipelineStateWithFunction:read error:&error];
    if (!reader) return failed(@"error", @"ordered_reader_pipeline", error);
    id<MTLComputePipelineState> matrix = nvn_constant_matrix_pipeline(device, &error);
    if (!matrix) return failed(@"error", @"ordered_matrix_pipeline", error);
    NvnConstantPool *pool = [[NvnConstantPool alloc] initWithDevice:device budget:1536];
    DmGpuMemory *owner = [DmGpuMemory new]; owner.backing = BackingVM; owner.length = 131072;
    vm_address_t pages = 0;
    if (vm_allocate(mach_task_self(), &pages, owner.length, VM_FLAGS_ANYWHERE) != KERN_SUCCESS)
        return failed(@"error", @"ordered_vm_allocation", nil);
    owner.pointer = (void *)pages;
    dm_vm_pool_region region;
    if (dm_vm_pool_check(owner.pointer, owner.length, &region) != KERN_SUCCESS || region.base != pages || region.length != owner.length)
        return failed(@"error", @"ordered_vm_region", nil);
    result[@"stage"] = @"wrap_ordered_writer_alias";
    result[@"backing_ownership"] = @"owned_vm_retained_by_both_actual_buffer_deallocators";
    result[@"region_bytes"] = @(region.region_length); result[@"protection"] = @(region.protection);
    result[@"wrapped_bytes"] = @(owner.length);
    if (!publish(result)) return failed(@"error", @"result_persistence", nil);
    MTLResourceOptions sourceOptions = MTLResourceStorageModeShared | MTLResourceHazardTrackingModeUntracked;
    id<MTLBuffer> original = [device newBufferWithBytesNoCopy:owner.pointer length:owner.length options:sourceOptions
        deallocator:^(void *memory, NSUInteger length) { (void)memory; (void)length; (void)owner.length; }];
    if (!nvn_buffer_identity(original, owner.pointer, owner.length, device)) return failed(@"error", @"ordered_writer_alias_identity", nil);
    result[@"stage"] = @"wrap_ordered_reader_alias";
    if (!publish(result)) return failed(@"error", @"result_persistence", nil);
    id<MTLBuffer> alias = [device newBufferWithBytesNoCopy:owner.pointer length:owner.length options:sourceOptions
        deallocator:^(void *memory, NSUInteger length) { (void)memory; (void)length; (void)owner.length; }];
    if (!nvn_buffer_identity(alias, owner.pointer, owner.length, device)) return failed(@"error", @"ordered_reader_alias_identity", nil);
    result[@"writer_hazard_mode"] = @(original.hazardTrackingMode); result[@"reader_hazard_mode"] = @(alias.hazardTrackingMode);
    if (original == alias || original.hazardTrackingMode != MTLHazardTrackingModeUntracked || alias.hazardTrackingMode != MTLHazardTrackingModeUntracked)
        return failed(@"unsupported", @"ordered_alias_hazard_mode", nil);
    id<MTLBuffer> observed = [device newBufferWithLength:512 options:MTLResourceStorageModeShared];
    if (!pool || !observed) return failed(@"error", @"ordered_allocation", nil);
    unsigned completedIterations = 0;
    for (uint32_t seed = 0; seed < 3; seed++) {
        @autoreleasepool {
            if ([pool beginCompleted:seed]) return failed(@"error", @"ordered_batch_begin", nil);
            memset(observed.contents, 0xCD, observed.length);
            id<MTLCommandBuffer> command = [queue commandBuffer];
            if (!command || !command.retainedReferences) return failed(@"error", @"ordered_retained_command", nil);
            id<MTLComputeCommandEncoder> writeEncoder = [command computeCommandEncoder];
            if (!writeEncoder) return failed(@"error", @"ordered_write_encoder", nil);
            [writeEncoder setComputePipelineState:writer]; [writeEncoder setBuffer:original offset:0 atIndex:0];
            [writeEncoder setBytes:&seed length:sizeof seed atIndex:1];
            [writeEncoder dispatchThreadgroups:MTLSizeMake(64,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)]; [writeEncoder endEncoding];
            id<MTLBlitCommandEncoder> blit = [pool beginCopyCommand:command];
            if (!blit) return failed(@"unsupported", @"ordered_event_barrier", nil);
            id<MTLBuffer> x, m;
            NvnConstantStatus xStatus = [pool prepareSource:alias offset:4 length:256 required:512 alignment:16 blit:blit buffer:&x];
            NvnConstantStatus mStatus = [pool prepareSource:alias offset:260 length:64 required:128 alignment:16 blit:blit buffer:&m];
            if (xStatus || mStatus) return failed(@"error", @"ordered_prepare", nil);
            [blit endEncoding];
            if (nvn_constant_matrix_encode(command, matrix, m, .25f)) return failed(@"error", @"ordered_matrix_encode", nil);
            id<MTLArgumentEncoder> arguments = [read newArgumentEncoderWithBufferIndex:0];
            if (!arguments || !nvn_sim_argument_layout(arguments.encodedLength, arguments.alignment)) return failed(@"unsupported", @"ordered_argument_layout", nil);
            id<MTLBuffer> argumentBuffer = [device newBufferWithLength:arguments.encodedLength options:MTLResourceStorageModeShared];
            if (!argumentBuffer) return failed(@"error", @"ordered_arguments", nil);
            [arguments setArgumentBuffer:argumentBuffer offset:0];
            if (nvn_native_encode_constant(arguments, x, 512, 16, 0) || nvn_native_encode_constant(arguments, m, 128, 16, 1))
                return failed(@"error", @"ordered_native_setter", nil);
            [arguments setBuffer:observed offset:0 atIndex:2];
            id<MTLComputeCommandEncoder> consumer = [command computeCommandEncoder];
            if (!consumer) return failed(@"error", @"ordered_consumer_encoder", nil);
            [consumer setComputePipelineState:reader]; [consumer setBuffer:argumentBuffer offset:0 atIndex:0];
            [consumer useResource:x usage:MTLResourceUsageRead]; [consumer useResource:m usage:MTLResourceUsageRead];
            [consumer useResource:observed usage:MTLResourceUsageWrite];
            [consumer dispatchThreadgroups:MTLSizeMake(64,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)]; [consumer endEncoding];
            if ([pool commitFence:seed+1]) return failed(@"error", @"ordered_batch_commit", nil);
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
                (void)original.length; (void)alias.length; (void)owner.length; (void)observed.length; (void)x.length; (void)m.length; (void)argumentBuffer.length; (void)completed;
                dispatch_semaphore_signal(done);
            }];
            result[@"stage"] = @"ordered_gpu_completion"; result[@"iteration_pending"] = @(seed);
            if (!publish(result)) return failed(@"error", @"result_persistence", nil);
            [command commit];
            if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC))) return failed(@"timeout", @"ordered_gpu_completion", nil);
            if (command.status != MTLCommandBufferStatusCompleted) return failed(@"error", @"ordered_gpu_completion", command.error);
            const uint32_t *words = observed.contents;
            BOOL values = YES, adjusted = YES, guards = YES;
            for (unsigned i = 0; i < 64; i++) if (words[i] != ((i+1+seed*128)^UINT32_C(0x5a5a5a5a))) values = NO;
            for (unsigned i = 0; i < 16; i++) { float expected = i+1;
                if (i%4 == 1) expected += .25f*(i+3);
                float actual; memcpy(&actual, &words[65+i], sizeof actual); if (actual != expected) adjusted = NO;
            }
            for (unsigned i = 81; i < 128; i++) if (words[i] != UINT32_C(0xcdcdcdcd)) guards = NO;
            BOOL zero = words[64] == 0;
            result[@"word_count"] = @64; result[@"output_match"] = @(values); result[@"zero_tail_match"] = @(zero);
            result[@"matrix_transform_match"] = @(adjusted); result[@"surrounding_bytes_unchanged"] = @(guards);
            if (!values || !zero || !adjusted || !guards) { result[@"status"] = @"error"; result[@"stage"] = @"ordered_readback"; return result; }
            completedIterations++;
        }
    }
    [result removeObjectForKey:@"iteration_pending"];
    result[@"completed_iterations"] = @(completedIterations); result[@"allocation_count"] = @(pool.allocationCount);
    result[@"reuse_count"] = @(pool.reuseCount); result[@"allocated_bytes"] = @(pool.allocatedBytes); result[@"budget_bytes"] = @1536;
    result[@"source_backing_bytes"] = @(original.length); result[@"source_offsets"] = @[@4, @260];
    result[@"same_command_stream"] = @YES; result[@"source_written_on_gpu"] = @YES;
    result[@"distinct_untracked_aliases"] = @YES; result[@"explicit_event_barrier"] = @YES;
    result[@"status"] = pool.allocationCount == 2 && pool.reuseCount == 4 && pool.allocatedBytes == 768 ? @"passed" : @"error";
    result[@"stage"] = @"ordered_readback"; return result;
}

static NSDictionary *protected_pool(id<MTLDevice> device, id<MTLCommandQueue> queue, BOOL (^publish)(NSDictionary *)) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSDictionary *(^failed)(NSString *, NSError *) = ^NSDictionary *(NSString *stage, NSError *error) {
        [result addEntriesFromDictionary:failure(@"error", stage, error)]; return result;
    };
    DmGpuMemory *owner = [DmGpuMemory new]; owner.backing = BackingVM; owner.length = 8u << 20;
    void *reservation = NULL;
    kern_return_t code = dm_vm_reserve(owner.length, &reservation);
    result[@"allocation_api"] = @"vm_allocate_then_vm_protect_none"; result[@"allocation_code"] = @(code);
    result[@"reservation_bytes"] = @(owner.length);
    if (code != KERN_SUCCESS) { result[@"status"] = @"error"; result[@"stage"] = @"reserve"; return result; }
    owner.pointer = reservation;
    size_t page = vm_page_size, opened = 8 * page;
    uint8_t *openBase = (uint8_t *)reservation + 2 * page;
    if (probe_vm_change(openBase, opened, PROT_READ | PROT_WRITE, 0))
        return failed(@"open_reserved_range", [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]);
    memset(openBase, 0xCD, opened);
    uint8_t *pool = openBase + 4096; size_t requested = page + 4096;
    dm_vm_pool_region region;
    code = dm_vm_pool_check(pool, requested, &region);
    result[@"region_code"] = @(code); result[@"opened_bytes"] = @(opened); result[@"pool_requested_bytes"] = @(requested);
    if (code != KERN_SUCCESS) { result[@"status"] = @"error"; result[@"stage"] = @"pool_region"; return result; }
    result[@"rounded_bytes"] = @(region.length); result[@"offset_bytes"] = @((uintptr_t)pool - region.base);
    result[@"region_bytes"] = @(region.region_length); result[@"region_shared"] = @(region.shared);
    result[@"protection"] = @(region.protection); result[@"maximum_protection"] = @(region.maximum_protection);
    result[@"max_buffer_length"] = @(device.maxBufferLength);
    if (region.length > device.maxBufferLength) { result[@"status"] = @"unsupported"; result[@"stage"] = @"max_buffer_length"; return result; }
    uint64_t lease;
    code = dm_vm_lease_acquire(&g_probe_leases, region.base, region.length, &lease);
    if (code != KERN_SUCCESS) { result[@"status"] = @"error"; result[@"stage"] = @"pool_lease"; return result; }
    owner->pool_lease = lease;
    result[@"status"] = @"pending"; result[@"stage"] = @"wrap_protected_pool";
    if (!publish(result)) return failed(@"result_persistence", nil);
    id<MTLBuffer> buffer = [device newBufferWithBytesNoCopy:(void *)region.base length:region.length options:MTLResourceStorageModeShared
        deallocator:^(void *memory, NSUInteger length) {
            (void)memory; (void)length; (void)owner.length;
            dm_vm_lease_retire(&owner->pool_lease, probe_lease_release);
        }];
    if (!nvn_buffer_identity(buffer, (void *)region.base, region.length, device))
        return failed(@"wrapped_pool_identity", nil);
    for (unsigned i = 0; i < DM_GPU_PROBE_WORDS; i++) ((uint32_t *)pool)[i] = i + 1;
    id<MTLSharedEvent> gate = [device newSharedEvent];
    if (!gate || gate.signaledValue) return failed(@"gpu_hold_event", nil);
    __block BOOL liveRejected = NO, unchanged = NO, persisted = YES;
    NSDictionary *computed;
    @autoreleasepool {
        computed = compute_at(device, queue, NO, buffer, (const uint32_t *)pool, owner,
            (uintptr_t)pool - region.base, gate, ^(id<MTLCommandBuffer> command) {
                int status = (int)command.status;
                int changed = probe_vm_change((void *)region.base, region.length, PROT_NONE, 1);
                liveRejected = status != MTLCommandBufferStatusCompleted && status != MTLCommandBufferStatusError && changed == -1 && errno == EBUSY;
                dm_vm_pool_region checked;
                unchanged = dm_vm_pool_check(pool, requested, &checked) == KERN_SUCCESS && ((const uint32_t *)pool)[0] == 1;
                result[@"submitted_command_status"] = @(status); result[@"live_discard_rejected"] = @(liveRejected);
                result[@"live_region_unchanged"] = @(unchanged); result[@"stage"] = @"gpu_waiting_on_owned_event";
                persisted = publish(result);
                gate.signaledValue = 1;
            });
    }
    [result addEntriesFromDictionary:computed];
    if (![computed[@"command_completed"] boolValue]) return result;
    BOOL guards = YES;
    for (size_t i = 0; i < opened; i++) if ((i < 4096 || i >= 4096 + DM_GPU_PROBE_WORDS * sizeof(uint32_t)) && openBase[i] != 0xCD) { guards = NO; break; }
    id<MTLBuffer> debugReference = buffer;
    BOOL stillRejected = probe_vm_change((void *)region.base, region.length, PROT_NONE, 1) == -1 && errno == EBUSY;
    result[@"post_gpu_live_buffer_discard_rejected"] = @(stillRejected);
    result[@"held_buffer_bytes"] = @(debugReference.length);
    buffer = nil; debugReference = nil;
    NSTimeInterval until = NSProcessInfo.processInfo.systemUptime + 5;
    while (probe_lease_count() && NSProcessInfo.processInfo.systemUptime < until) usleep(1000);
    BOOL retired = probe_lease_count() == 0;
    BOOL unmapped = retired && probe_vm_change((void *)region.base, region.length, PROT_NONE, 1) == 0;
    result[@"surrounding_bytes_unchanged"] = @(guards); result[@"actual_deallocator_observed"] = @(retired);
    result[@"post_deallocator_unmap_accepted"] = @(unmapped);
    if (!retired) { result[@"status"] = @"timeout"; result[@"stage"] = @"buffer_deallocator"; }
    else if (!liveRejected || !unchanged || !persisted || !guards || !stillRejected || !unmapped) { result[@"status"] = @"error"; result[@"stage"] = @"pool_lifetime_contract"; }
    return result;
}

static NSDictionary *no_copy(id<MTLDevice> device, id<MTLCommandQueue> queue, enum Backing backing, BOOL (^publish)(NSDictionary *)) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    DmGpuMemory *owner = allocate_memory(backing, result);
    if (!owner) return result;
    NSDictionary *contract = result[@"region"];
    if (![contract[@"single_region"] boolValue] || ![contract[@"page_aligned"] boolValue] ||
        ![contract[@"readable"] boolValue] || ![contract[@"writable"] boolValue]) {
        result[@"status"] = @"error"; result[@"stage"] = @"allocation_contract"; return result;
    }
    result[@"status"] = @"pending"; result[@"stage"] = @"wrap_backing";
    if (!publish(result)) { result[@"status"] = @"error"; result[@"stage"] = @"result_persistence"; return result; }
    owner.buffer = [device newBufferWithBytesNoCopy:owner.pointer length:owner.length options:MTLResourceStorageModeShared deallocator:nil];
    if (!owner.buffer) { result[@"status"] = @"error"; result[@"stage"] = @"wrap_backing"; return result; }
    result[@"buffer_class"] = NSStringFromClass([owner.buffer class]); result[@"device"] = device_info(owner.buffer.device, device);
    result[@"same_contents_pointer"] = @(owner.buffer.contents == owner.pointer);
    result[@"gpu_address_nonzero"] = @([owner.buffer respondsToSelector:@selector(gpuAddress)] && owner.buffer.gpuAddress != 0);
    [result addEntriesFromDictionary:compute(device, queue, NO, owner.buffer, owner.pointer, owner)];
    return result;
}

static NSDictionary *buffer_alias(id<MTLDevice> device, id<MTLCommandQueue> queue, BOOL (^publish)(NSDictionary *)) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    DmGpuMemory *owner = allocate_memory(BackingVM, result);
    if (!owner) return result;
    owner.buffer = [device newBufferWithLength:owner.length options:MTLResourceStorageModeShared];
    if (!owner.buffer || !owner.buffer.contents) return failure(@"error", @"shared_buffer", nil);
    result[@"source_region"] = region_contract(owner.buffer.contents, owner.length);
    NSDictionary *contract = result[@"source_region"];
    if (![contract[@"page_aligned"] boolValue] || ![contract[@"single_region"] boolValue] ||
        ![contract[@"readable"] boolValue] || ![contract[@"writable"] boolValue]) {
        result[@"status"] = @"unsupported"; result[@"stage"] = @"source_allocation_contract"; return result;
    }
    memcpy(owner.buffer.contents, owner.pointer, owner.length);
    result[@"buffer_class"] = NSStringFromClass([owner.buffer class]);
    result[@"device"] = device_info(owner.buffer.device, device);
    result[@"status"] = @"pending"; result[@"stage"] = @"owned_alias_remap";
    if (!publish(result)) { result[@"status"] = @"error"; result[@"stage"] = @"result_persistence"; return result; }
    vm_address_t alias = (vm_address_t)owner.pointer;
    vm_prot_t current = 0, maximum = 0;
    kern_return_t code = vm_remap(mach_task_self(), &alias, owner.length, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
                                  mach_task_self(), (vm_address_t)owner.buffer.contents, FALSE,
                                  &current, &maximum, VM_INHERIT_NONE);
    result[@"remap_code"] = @(code); result[@"remap_copy"] = @NO;
    result[@"read_write_protection"] = @((current & (VM_PROT_READ | VM_PROT_WRITE)) == (VM_PROT_READ | VM_PROT_WRITE));
    if (code != KERN_SUCCESS || alias != (vm_address_t)owner.pointer || ![result[@"read_write_protection"] boolValue]) {
        if (code == KERN_SUCCESS && alias != (vm_address_t)owner.pointer) vm_deallocate(mach_task_self(), alias, owner.length);
        result[@"status"] = @"error"; result[@"stage"] = @"owned_alias_remap"; return result;
    }
    uint32_t *words = owner.pointer; words[0] = 0x17283940;
    BOOL visible = ((uint32_t *)owner.buffer.contents)[0] == 0x17283940;
    result[@"cpu_alias_write_seen"] = @(visible);
    if (!visible) { result[@"status"] = @"error"; result[@"stage"] = @"cpu_alias_visibility"; return result; }
    for (size_t i = 0; i < DM_GPU_PROBE_WORDS; i++) words[i] = (uint32_t)i + 1;
    result[@"alias_region"] = region_contract(owner.pointer, owner.length);
    [result addEntriesFromDictionary:compute(device, queue, NO, owner.buffer, owner.pointer, owner)];
    return result;
}

int dm_gpu_probe(void) {
    @autoreleasepool {
        const char *value = getenv("DM_GPU_PROBE_CASE");
        if (!value) value = "core";
        enum dm_gpu_probe_case selection = dm_gpu_probe_parse_case(value);
        NSMutableDictionary *result = [@{@"schema": @"d2r.host-gpu-probe.v2", @"host_only": @YES,
                                         @"guest_executed": @NO, @"simulator": @(TARGET_OS_SIMULATOR), @"complete": @NO,
                                         @"requested_case": selection == DM_GPU_CASE_INVALID ? NSNull.null : @(value), @"compute_timeout_seconds": @5,
                                         @"parent_device_api": @"No direct iOS parent-device accessor; buffer.device and queue.device are reported separately."} mutableCopy];
        NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *path = [documents stringByAppendingPathComponent:[NSString stringWithFormat:@"gpu-%d-%@.json", getpid(), NSUUID.UUID.UUIDString]];
        if (!write_report(result, path, YES)) return 1;
        plog("GPU probe host-only result: %s", path.fileSystemRepresentation);
        if (selection == DM_GPU_CASE_INVALID) {
            result[@"error"] = @{@"stage": @"case_selection", @"description": @"unknown DM_GPU_PROBE_CASE"};
            write_report(result, path, NO); return 2;
        }
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { result[@"device_status"] = @"unavailable"; write_report(result, path, NO); return 1; }
        result[@"device_status"] = @"available"; result[@"device"] = device_info(device, device);
        NSMutableDictionary *tests = [NSMutableDictionary dictionary]; result[@"tests"] = tests;
        if (!begin_test(result, path, @"shared_buffer")) return 1;
        id<MTLBuffer> shared = [device newBufferWithLength:0x4000 options:MTLResourceStorageModeShared];
        BOOL addressAPI = [shared respondsToSelector:@selector(gpuAddress)];
        tests[@"shared_buffer"] = @{@"status": shared && shared.contents ? @"passed" : @"error", @"gpu_address_api": @(addressAPI),
                                    @"gpu_address_nonzero": @(addressAPI && shared.gpuAddress != 0), @"device": device_info(shared.device, device),
                                    @"class": shared ? NSStringFromClass([shared class]) : @"unavailable"};
        if (!begin_test(result, path, @"command_queue")) return 1;
        id<MTLCommandQueue> queue = [device newCommandQueue];
        tests[@"command_queue"] = @{@"status": queue ? @"passed" : @"error", @"device": device_info(queue.device, device)};
        if (!queue) { result[@"error"] = @{@"stage": @"command_queue"}; write_report(result, path, NO); return 1; }
        if (!begin_test(result, path, @"direct_compute")) return 1;
        tests[@"direct_compute"] = compute(device, queue, NO, nil, NULL, nil);
        if (!begin_test(result, path, @"argument_compute")) return 1;
        tests[@"argument_compute"] = compute(device, queue, YES, nil, NULL, nil);
        if (selection == DM_GPU_CASE_RESIDENCY || selection == DM_GPU_CASE_ALL) {
            if (!begin_test(result, path, @"residency_set")) return 1;
            if (![device respondsToSelector:@selector(newResidencySetWithDescriptor:error:)]) tests[@"residency_set"] = failure(@"unsupported", @"selector_unavailable", nil);
            else {
                NSError *error = nil; MTLResidencySetDescriptor *descriptor = [MTLResidencySetDescriptor new]; descriptor.initialCapacity = 1;
                id<MTLResidencySet> set = [device newResidencySetWithDescriptor:descriptor error:&error];
                if (!set) tests[@"residency_set"] = failure(@"error", @"create_residency_set", error);
                else if (!shared || ![queue respondsToSelector:@selector(addResidencySet:)]) tests[@"residency_set"] = failure(@"unsupported", @"queue_residency", nil);
                else { [set addAllocation:shared]; [set commit]; [queue addResidencySet:set]; [queue removeResidencySet:set]; tests[@"residency_set"] = @{@"status": @"passed", @"queue_registration": @YES}; }
            }
        }
        if (selection == DM_GPU_CASE_CONSTANTS || selection == DM_GPU_CASE_ALL) {
            if (!begin_test(result, path, @"ordered_constants")) return 1;
            tests[@"ordered_constants"] = ordered_constants(device, queue, ^BOOL(NSDictionary *detail) {
                tests[@"ordered_constants"] = detail; return write_report(result, path, NO);
            });
        }
        const enum dm_gpu_probe_case cases[] = {DM_GPU_CASE_VM, DM_GPU_CASE_SHARED, DM_GPU_CASE_ALIAS, DM_GPU_CASE_POOL, DM_GPU_CASE_MALLOC};
        NSString *names[] = {@"nocopy_vm", @"nocopy_shared", @"buffer_alias", @"protected_pool", @"nocopy_malloc"};
        for (int i = 0; i < 5; i++) if (selection == cases[i] || selection == DM_GPU_CASE_ALL) {
            if (!begin_test(result, path, names[i])) return 1;
            NSString *name = names[i];
            BOOL (^publish)(NSDictionary *) = ^BOOL(NSDictionary *detail) { tests[name] = detail; return write_report(result, path, NO); };
            tests[name] = cases[i] == DM_GPU_CASE_POOL ? protected_pool(device, queue, publish)
                : cases[i] == DM_GPU_CASE_ALIAS ? buffer_alias(device, queue, publish)
                : no_copy(device, queue, cases[i] == DM_GPU_CASE_VM ? BackingVM : cases[i] == DM_GPU_CASE_SHARED ? BackingShared : BackingMalloc, publish);
        }
        [result removeObjectForKey:@"pending_test"]; result[@"complete"] = @YES; result[@"loaded_metal_images"] = metal_images();
        if (!write_report(result, path, NO)) return 1;
        plog("GPU probe complete: %s", path.fileSystemRepresentation); return 0;
    }
}
