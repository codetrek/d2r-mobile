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
#include "../../gfx/nvn/nvn_depth_dummy.h"
#include "../../gfx/nvn/nvn_prepared_arguments.h"
#include "../../gfx/nvn/nvn_bc_transfer.h"
#include "../../gfx/tex/nvn_bc_vectors.h"
#include "../../gfx/tex/nvn_bcdec.h"
#include "../../gfx/tex/nvn_deswizzle_gpu.h"
#include "../../gfx/nvn/nvn_native_arguments.h"
#include "dm_gpu_probe_checkpoint.h"
#include "dm_profile_libraries.h"

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

static NSDictionary *prepared_arguments(id<MTLDevice> device, id<MTLCommandQueue> queue, BOOL (^publish)(NSDictionary *)) {
    NSMutableDictionary *result = [@{@"status": @"pending", @"stage": @"compile_owned_arguments"} mutableCopy];
    NSDictionary *(^failed)(NSString *, NSString *, NSError *) = ^NSDictionary *(NSString *status, NSString *stage, NSError *error) {
        [result addEntriesFromDictionary:failure(status, stage, error)]; return result;
    };
    if (!publish(result)) return failed(@"error", @"result_persistence", nil);
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct A { device uint *out [[id(0)]]; texture2d<float> image [[id(1)]]; sampler s [[id(2)]]; };"
        "kernel void owned(constant A &a [[buffer(0)]],uint i [[thread_position_in_grid]]) {"
        "uint4 p=uint4(round(a.image.sample(a.s,float2(.5f),level(0.0f))*255.0f));"
        "uint color=p.x|(p.y<<8)|(p.z<<16)|(p.w<<24); a.out[i]=(i+1)^color; }";
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    if (!library) return failed(@"error", @"owned_library", error);
    id<MTLFunction> function = [library newFunctionWithName:@"owned"];
    if (!function) return failed(@"error", @"owned_function", nil);
    id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:function error:&error];
    if (!pipeline) return failed(@"error", @"owned_pipeline", error);
    id<MTLCommandBuffer> command = [queue commandBuffer];
    NvnArgumentSubmission *submission = [[NvnArgumentSubmission alloc] initWithCommand:command byteBudget:4096 bundleBudget:2];
    id<MTLBuffer> output = [device newBufferWithLength:768 options:MTLResourceStorageModeShared];
    if (!submission || !output) return failed(@"error", @"owned_submission", nil);
    memset(output.contents, 0xCD, output.length);
    NSMutableArray<NvnPreparedArguments *> *bundles = [NSMutableArray array];
    uint32_t colors[] = {UINT32_C(0x78563412), UINT32_C(0x12345678)};
    NSUInteger encodedLength = 0, alignment = 0;
    for (unsigned i = 0; i < 2; i++) {
        @autoreleasepool {
            result[@"stage"] = @"owned_resource_preparation"; result[@"bundle_pending"] = @(i);
            if (!publish(result)) return failed(@"error", @"result_persistence", nil);
            id<MTLArgumentEncoder> encoder = [function newArgumentEncoderWithBufferIndex:0];
            if (!encoder || !nvn_sim_argument_layout(encoder.encodedLength, encoder.alignment)) return failed(@"unsupported", @"owned_argument_layout", nil);
            if (i && (encodedLength != encoder.encodedLength || alignment != encoder.alignment)) return failed(@"error", @"owned_layout_changed", nil);
            encodedLength = encoder.encodedLength; alignment = encoder.alignment;
            id<MTLBuffer> bytes = [device newBufferWithLength:encodedLength options:MTLResourceStorageModeShared];
            NvnPreparedArguments *prepared;
            if ([submission prepareBuffer:bytes offset:0 length:encodedLength alignment:alignment index:0 stage:5 arguments:&prepared])
                return failed(@"error", @"owned_block_admission", nil);
            MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
            descriptor.storageMode = MTLStorageModeShared; descriptor.usage = MTLTextureUsageShaderRead;
            id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
            if (!texture) return failed(@"error", @"owned_texture", nil);
            uint8_t pixel[] = {(uint8_t)colors[i],(uint8_t)(colors[i]>>8),(uint8_t)(colors[i]>>16),(uint8_t)(colors[i]>>24)};
            [texture replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:pixel bytesPerRow:4];
            MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
            sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge; sd.supportArgumentBuffers = YES;
            id<MTLSamplerState> sampler = [device newSamplerStateWithDescriptor:sd];
            if ([prepared addResource:output usage:MTLResourceUsageWrite] || [prepared addResource:texture usage:MTLResourceUsageRead] || [prepared addSampler:sampler])
                return failed(@"error", @"owned_resource_admission", nil);
            [encoder setArgumentBuffer:bytes offset:0]; [encoder setBuffer:output offset:i*256 atIndex:0];
            [encoder setTexture:texture atIndex:1]; [encoder setSamplerState:sampler atIndex:2];
            [encoder setArgumentBuffer:nil offset:0];
            if ([prepared seal]) return failed(@"error", @"owned_seal", nil);
            [bundles addObject:prepared];
        }
    }
    result[@"bundles_before_consumer"] = @(submission.bundleCount); result[@"encoded_bytes"] = @(submission.byteCount);
    for (NvnPreparedArguments *prepared in bundles) {
        result[@"stage"] = @"owned_compute_consumer";
        if (!publish(result)) return failed(@"error", @"result_persistence", nil);
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        if (!encoder) return failed(@"error", @"owned_compute_encoder", nil);
        [encoder setComputePipelineState:pipeline];
        if ([prepared bindCompute:encoder]) return failed(@"error", @"owned_compute_binding", nil);
        [encoder dispatchThreadgroups:MTLSizeMake(64,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)]; [encoder endEncoding];
    }
    NvnArgumentRetirement *retirement;
    if ([submission finishForCommand:command retirement:&retirement]) return failed(@"error", @"owned_completion_retention", nil);
    bundles = nil; submission = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NvnArgumentsStatus retirementStatus = NvnArgumentsState;
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        retirementStatus = [retirement retireCompletedCommand:completed]; dispatch_semaphore_signal(done);
    }];
    result[@"stage"] = @"owned_gpu_completion";
    if (!publish(result)) return failed(@"error", @"result_persistence", nil);
    [command commit];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC))) return failed(@"timeout", @"owned_gpu_completion", nil);
    if (command.status != MTLCommandBufferStatusCompleted) return failed(@"error", @"owned_gpu_completion", command.error);
    if (retirementStatus) return failed(@"error", @"owned_completion_retirement", nil);
    const uint32_t *words = output.contents; BOOL match = YES, guards = YES;
    for (unsigned j = 0; j < 2; j++) for (unsigned i = 0; i < 64; i++) if (words[j*64+i] != ((i+1)^colors[j])) match = NO;
    for (unsigned i = 128; i < 192; i++) if (words[i] != UINT32_C(0xcdcdcdcd)) guards = NO;
    [result removeObjectForKey:@"bundle_pending"];
    result[@"argument_encoded_length"] = @(encodedLength); result[@"argument_alignment"] = @(alignment);
    result[@"word_count"] = @128; result[@"output_match"] = @(match); result[@"surrounding_bytes_unchanged"] = @(guards);
    result[@"status"] = match && guards ? @"passed" : @"error"; result[@"stage"] = @"owned_readback"; return result;
}

static NSDictionary *bc_transfers(id<MTLDevice> device, id<MTLCommandQueue> queue, BOOL (^publish)(NSDictionary *)) {
    NSMutableDictionary *result=[@{@"status":@"pending",@"stage":@"bc_compile_writer"} mutableCopy];
    NSDictionary *(^failed)(NSString *,NSString *,NSError *)=^NSDictionary *(NSString *status,NSString *stage,NSError *error) {
        [result addEntriesFromDictionary:failure(status,stage,error)];return result;
    };
    if (!publish(result)) return failed(@"error",@"result_persistence",nil);
    NSError *error=nil;
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void copy_words(device const uint *seed [[buffer(0)]],device uint *out [[buffer(1)]],uint i [[thread_position_in_grid]]) { out[i]=seed[i]; }";
    id<MTLLibrary> library=[device newLibraryWithSource:source options:nil error:&error];
    id<MTLFunction> function=[library newFunctionWithName:@"copy_words"];
    id<MTLComputePipelineState> writer=function?[device newComputePipelineStateWithFunction:function error:&error]:nil;
    if (!writer || nvn_deswz_gpu_init(device)) return failed(@"error",@"bc_writer_deswizzler",error);
    id<MTLCommandQueue> reader=[device newCommandQueue],uploader=[device newCommandQueue];
    NvnBCTransfers *transfers=[[NvnBCTransfers alloc] initWithDevice:device readbackQueue:reader uploadQueue:uploader byteBudget:1<<20 jobBudget:2];
    DmGpuMemory *owner=[DmGpuMemory new];owner.backing=BackingVM;owner.length=131072;
    vm_address_t pages=0;
    if (!transfers || vm_allocate(mach_task_self(),&pages,owner.length,VM_FLAGS_ANYWHERE)!=KERN_SUCCESS) return failed(@"error",@"bc_vm_allocation",nil);
    owner.pointer=(void *)pages;memset(owner.pointer,0xCD,owner.length);
    dm_vm_pool_region region;
    if (dm_vm_pool_check(owner.pointer,owner.length,&region)!=KERN_SUCCESS || region.base!=pages || region.length!=owner.length)
        return failed(@"error",@"bc_vm_region",nil);
    MTLResourceOptions options=MTLResourceStorageModeShared|MTLResourceHazardTrackingModeUntracked;
    result[@"stage"]=@"bc_wrap_writer";if (!publish(result)) return failed(@"error",@"result_persistence",nil);
    id<MTLBuffer> original=[device newBufferWithBytesNoCopy:owner.pointer length:owner.length options:options
        deallocator:^(void *memory,NSUInteger length){(void)memory;(void)length;(void)owner.length;}];
    if (!nvn_buffer_identity(original,owner.pointer,owner.length,device)) return failed(@"error",@"bc_writer_identity",nil);
    result[@"stage"]=@"bc_wrap_reader";if (!publish(result)) return failed(@"error",@"result_persistence",nil);
    id<MTLBuffer> alias=[device newBufferWithBytesNoCopy:owner.pointer length:owner.length options:options
        deallocator:^(void *memory,NSUInteger length){(void)memory;(void)length;(void)owner.length;}];
    if (!nvn_buffer_identity(alias,owner.pointer,owner.length,device)) return failed(@"error",@"bc_reader_identity",nil);
    if (original==alias || original.hazardTrackingMode!=MTLHazardTrackingModeUntracked || alias.hazardTrackingMode!=MTLHazardTrackingModeUntracked)
        return failed(@"unsupported",@"bc_untracked_aliases",nil);
    result[@"writer_hazard_mode"]=@(original.hazardTrackingMode);result[@"reader_hazard_mode"]=@(alias.hazardTrackingMode);
    result[@"source_inspection"]=@"only_owned_GPU_readback_after_producer_event";
    NSUInteger pixels=0;
    for (uint32_t format=0x41;format<=0x50;format++) {
        @autoreleasepool {
            result[@"stage"]=@"bc_linear_encoding";result[@"format_pending"]=@(format);
            if (!publish(result)) return failed(@"error",@"result_persistence",nil);
            uint8_t expected[2][8];unsigned bpp=0;uint32_t pixelFormat;int pixelBytes;
            if (!nvn_bc_unpacked(format,&pixelFormat,&pixelBytes)) return failed(@"error",@"bc_format",nil);
            MTLTextureDescriptor *descriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:(MTLPixelFormat)pixelFormat width:7 height:5 mipmapped:NO];
            descriptor.storageMode=MTLStorageModePrivate;descriptor.hazardTrackingMode=MTLHazardTrackingModeTracked;descriptor.usage=MTLTextureUsageShaderRead;
            id<MTLTexture> textures[2]={[device newTextureWithDescriptor:descriptor],[device newTextureWithDescriptor:descriptor]};
            id<MTLBuffer> observed=[device newBufferWithLength:3328 options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> command=[queue commandBuffer];
            if (!textures[0] || !textures[1] || !observed || !command) return failed(@"error",@"bc_linear_resources",nil);
            memset(observed.contents,0xCD,observed.length);
            for (unsigned variant=0;variant<2;variant++) {
                uint8_t block[16];if (!nvn_bc_vector(format,variant,block,expected[variant],&bpp)) return failed(@"error",@"bc_vector",nil);
                NSUInteger blockBytes=format==0x41 || format==0x42 || format==0x45 || format==0x46 || format==0x49 || format==0x4a?8:16;
                NSUInteger row=2*blockBytes+8,image=2*row,extent=row+2*blockBytes;
                id<MTLBuffer> seed=[device newBufferWithLength:extent options:MTLResourceStorageModeShared];
                if (!seed) return failed(@"error",@"bc_seed",nil);
                memset(seed.contents,0xEF,extent);
                for (unsigned y=0;y<2;y++) for (unsigned x=0;x<2;x++) memcpy((uint8_t *)seed.contents+y*row+x*blockBytes,block,blockBytes);
                id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
                if (!encoder) return failed(@"error",@"bc_writer_encoder",nil);
                [encoder setComputePipelineState:writer];[encoder setBuffer:seed offset:0 atIndex:0];[encoder setBuffer:original offset:4 atIndex:1];
                [encoder dispatchThreadgroups:MTLSizeMake(extent/4,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];[encoder endEncoding];
                NvnBCRegion area={.width=7,.height=5,.depth=1,.sourceRow=row,.sourceImage=image};
                if ([transfers encodeCommand:command source:alias offset:4 length:extent format:format regions:&area count:1 packaged:NULL destination:textures[variant]])
                    return failed(@"error",@"bc_linear_admission",nil);
            }
            if (transfers.allocatedBytes || transfers.pendingJobs!=2) return failed(@"error",@"bc_deferred_staging",nil);
            id<MTLBlitCommandEncoder> readback=[command blitCommandEncoder];
            if (!readback) return failed(@"error",@"bc_result_encoder",nil);
            for (unsigned variant=0;variant<2;variant++) [readback copyFromTexture:textures[variant] sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
                sourceSize:MTLSizeMake(7,5,1) toBuffer:observed destinationOffset:variant*1536 destinationBytesPerRow:256 destinationBytesPerImage:1280];
            [readback copyFromBuffer:original sourceOffset:0 toBuffer:observed destinationOffset:3072 size:4];
            [readback copyFromBuffer:original sourceOffset:4092 toBuffer:observed destinationOffset:3076 size:4];[readback endEncoding];
            dispatch_semaphore_t done=dispatch_semaphore_create(0);
            [command addCompletedHandler:^(id<MTLCommandBuffer> completed){(void)completed;(void)original.length;(void)alias.length;(void)owner.length;dispatch_semaphore_signal(done);}];
            result[@"stage"]=@"bc_linear_completion";if (!publish(result)) return failed(@"error",@"result_persistence",nil);
            [command commit];
            if (dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))) return failed(@"timeout",@"bc_linear_completion",nil);
            if (command.status!=MTLCommandBufferStatusCompleted) return failed(@"error",@"bc_linear_completion",command.error);
            const uint8_t *actual=observed.contents;
            for (unsigned variant=0;variant<2;variant++) for (unsigned y=0;y<5;y++) {
                for (unsigned x=0;x<7;x++) if (memcmp(actual+variant*1536+y*256+x*bpp,expected[variant],bpp)) return failed(@"error",@"bc_linear_pixels",nil);
                for (unsigned x=7*bpp;x<256;x++) if (actual[variant*1536+y*256+x]!=0xCD) return failed(@"error",@"bc_linear_row_guard",nil);
            }
            for (unsigned variant=0;variant<2;variant++) for (unsigned i=1280;i<1536;i++) if (actual[variant*1536+i]!=0xCD) return failed(@"error",@"bc_linear_tail_guard",nil);
            for (unsigned i=3072;i<3328;i++) if (actual[i]!=0xCD) return failed(@"error",@"bc_source_result_guards",nil);
            if (transfers.pendingJobs || transfers.allocatedBytes || transfers.reservedBytes) return failed(@"error",@"bc_linear_retirement",nil);
            pixels+=70;result[@"linear_formats_completed"]=@(format-0x40);result[@"linear_pixels_checked"]=@(pixels);
        }
    }
    @autoreleasepool {
        result[@"stage"]=@"bc_packaged_volume_encoding";if (!publish(result)) return failed(@"error",@"result_persistence",nil);
        nvn_texdesc descriptor={.target=2,.format=0x41,.width=7,.height=5,.depth=3,.levels=2};nvn_texlayout layout;nvn_tex_layout(&descriptor,&layout);
        if (!layout.size || layout.size>owner.length-4) return failed(@"error",@"bc_packaged_layout",nil);
        id<MTLBuffer> seed=[device newBufferWithLength:layout.size options:MTLResourceStorageModeShared];
        if (!seed) return failed(@"error",@"bc_packaged_seed",nil);
        memset(seed.contents,0xEF,seed.length);
        NvnBCRegion areas[2];uint8_t expected[2][8];NSUInteger outputSize=0;
        for (unsigned level=0;level<2;level++) {
            uint32_t w=MAX(7u>>level,1u),h=MAX(5u>>level,1u),z=MAX(3u>>level,1u);
            NSUInteger row=((w+3)/4)*8,image=row*((h+3)/4);uint8_t block[16];unsigned bpp;
            nvn_bc_vector(0x41,level,block,expected[level],&bpp);
            NSMutableData *linear=[NSMutableData dataWithLength:image*z];
            for (NSUInteger at=0;at<linear.length;at+=8) memcpy((uint8_t *)linear.mutableBytes+at,block,8);
            if (nvn_swizzle(&descriptor,level,0,linear.bytes,row,seed.contents)) return failed(@"error",@"bc_packaged_swizzle_fixture",nil);
            areas[level]=(NvnBCRegion){.width=w,.height=h,.depth=z,.sourceRow=row,.sourceImage=image,.level=level,.sourceLevel=level};
            outputSize+=256*h*z;
        }
        MTLTextureDescriptor *td=[MTLTextureDescriptor new];td.textureType=MTLTextureType3D;td.pixelFormat=MTLPixelFormatRGBA8Unorm;
        td.width=7;td.height=5;td.depth=3;td.mipmapLevelCount=2;td.storageMode=MTLStorageModePrivate;td.hazardTrackingMode=MTLHazardTrackingModeTracked;td.usage=MTLTextureUsageShaderRead;
        id<MTLTexture> texture=[device newTextureWithDescriptor:td];id<MTLBuffer> observed=[device newBufferWithLength:outputSize+256 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> command=[queue commandBuffer];if (!texture || !observed || !command) return failed(@"error",@"bc_packaged_resources",nil);
        memset(observed.contents,0xCD,observed.length);
        id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
        if (!encoder) return failed(@"error",@"bc_packaged_writer_encoder",nil);
        [encoder setComputePipelineState:writer];[encoder setBuffer:seed offset:0 atIndex:0];[encoder setBuffer:original offset:4 atIndex:1];
        [encoder dispatchThreadgroups:MTLSizeMake(layout.size/4,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];[encoder endEncoding];
        if ([transfers encodeCommand:command source:alias offset:4 length:layout.size format:0x41 regions:areas count:2 packaged:&descriptor destination:texture])
            return failed(@"error",@"bc_packaged_admission",nil);
        id<MTLBlitCommandEncoder> readback=[command blitCommandEncoder];if (!readback) return failed(@"error",@"bc_packaged_result_encoder",nil);
        NSUInteger offset=0;
        for (unsigned level=0;level<2;level++) {
            [readback copyFromTexture:texture sourceSlice:0 sourceLevel:level sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(areas[level].width,areas[level].height,areas[level].depth)
                toBuffer:observed destinationOffset:offset destinationBytesPerRow:256 destinationBytesPerImage:256*areas[level].height];
            offset+=256*areas[level].height*areas[level].depth;
        }
        [readback endEncoding];dispatch_semaphore_t done=dispatch_semaphore_create(0);
        [command addCompletedHandler:^(id<MTLCommandBuffer> completed){(void)completed;(void)original.length;(void)alias.length;(void)owner.length;dispatch_semaphore_signal(done);}];
        result[@"stage"]=@"bc_packaged_volume_completion";if (!publish(result)) return failed(@"error",@"result_persistence",nil);
        [command commit];if (dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))) return failed(@"timeout",@"bc_packaged_volume_completion",nil);
        if (command.status!=MTLCommandBufferStatusCompleted) return failed(@"error",@"bc_packaged_volume_completion",command.error);
        const uint8_t *actual=observed.contents;offset=0;NSUInteger pixels=0;
        for (unsigned level=0;level<2;level++) {
            for (unsigned z=0;z<areas[level].depth;z++) for (unsigned y=0;y<areas[level].height;y++) {
                for (unsigned x=0;x<areas[level].width;x++) if (memcmp(actual+offset+x*4,expected[level],4)) return failed(@"error",@"bc_packaged_pixels",nil);
                for (unsigned x=areas[level].width*4;x<256;x++) if (actual[offset+x]!=0xCD) return failed(@"error",@"bc_packaged_row_guard",nil);
                pixels+=areas[level].width;offset+=256;
            }
        }
        for (NSUInteger i=outputSize;i<observed.length;i++) if (actual[i]!=0xCD) return failed(@"error",@"bc_packaged_tail_guard",nil);
        result[@"packaged_pixels_checked"]=@(pixels);result[@"packaged_mips"]=@2;result[@"packaged_depth_slices"]=@4;
    }
    if (transfers.pendingJobs || transfers.allocatedBytes || transfers.reservedBytes || transfers.completedJobs!=33) return failed(@"error",@"bc_final_retirement",nil);
    [result removeObjectForKey:@"format_pending"];result[@"completed_jobs"]=@(transfers.completedJobs);result[@"peak_staging_bytes"]=@(transfers.peakAllocatedBytes);
    result[@"pending_jobs"]=@(transfers.pendingJobs);result[@"reserved_bytes"]=@(transfers.reservedBytes);result[@"allocated_bytes"]=@(transfers.allocatedBytes);
    result[@"status"]=@"passed";result[@"stage"]=@"bc_readback_checked";return result;
}

static NSDictionary *private_depth(id<MTLDevice> device, id<MTLCommandQueue> queue, BOOL (^publish)(NSDictionary *)) {
    NSMutableDictionary *result = [@{@"status": @"pending", @"stage": @"compile_depth_reader"} mutableCopy];
    NSDictionary *(^failed)(NSString *, NSString *, NSError *) = ^NSDictionary *(NSString *status, NSString *stage, NSError *error) {
        [result addEntriesFromDictionary:failure(status, stage, error)]; return result;
    };
    if (!publish(result)) return failed(@"error", @"result_persistence", nil);
    // Explicit level-zero depth sampling/read signatures are defined in MSL6.13.10/11/14.
    // https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct A { depth2d<float> d [[id(0)]]; depth2d_array<float> a [[id(1)]]; depthcube<float> c [[id(2)]]; device float *out [[id(3)]]; };"
        "kernel void depth_read(constant A &a [[buffer(0)]], constant uint &base [[buffer(1)]]) {"
        "constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::nearest);"
        "a.out[base]=a.d.sample(s,float2(.5f),level(0.0f)); a.out[base+1]=a.a.sample(s,float2(.5f),0u,level(0.0f));"
        "float3 dirs[6]={float3(1,0,0),float3(-1,0,0),float3(0,1,0),float3(0,-1,0),float3(0,0,1),float3(0,0,-1)};"
        "for(uint i=0;i<6;i++)a.out[base+2+i]=a.c.sample(s,dirs[i],level(0.0f));"
        "a.out[base+8]=a.d.read(uint2(0),0u); a.out[base+9]=a.a.read(uint2(0),0u,0u);"
        "for(uint i=0;i<6;i++)a.out[base+10+i]=a.c.read(uint2(0),i,0u); }";
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    if (!library) return failed(@"error", @"depth_library", error);
    id<MTLFunction> function = [library newFunctionWithName:@"depth_read"];
    if (!function) return failed(@"error", @"depth_function", nil);
    id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:function error:&error];
    if (!pipeline) return failed(@"error", @"depth_pipeline", error);
    id<MTLArgumentEncoder> arguments = [function newArgumentEncoderWithBufferIndex:0];
    if (!arguments || !nvn_sim_argument_layout(arguments.encodedLength, arguments.alignment))
        return failed(@"unsupported", @"depth_argument_layout", nil);
    NvnDepthDummies *cache = [[NvnDepthDummies alloc] initWithDevice:device];
    id<MTLBuffer> output = [device newBufferWithLength:256 options:MTLResourceStorageModeShared];
    if (!cache || !output) return failed(@"error", @"depth_allocation", nil);
    memset(output.contents, 0xCD, output.length);
    MTLTextureType types[] = {MTLTextureType2D, MTLTextureType2DArray, MTLTextureTypeCube};
    NSArray *originalTextures = nil;
    for (unsigned phase = 0; phase < 2; phase++) {
        @autoreleasepool {
            result[@"stage"] = @"depth_prepare"; result[@"phase_pending"] = @(phase);
            if (!publish(result)) return failed(@"error", @"result_persistence", nil);
            id<MTLCommandBuffer> command = [queue commandBuffer];
            if (!command || !command.retainedReferences) return failed(@"error", @"depth_retained_command", nil);
            NSMutableArray<id<MTLTexture>> *textures = [NSMutableArray array];
            for (unsigned i = 0; i < 3; i++) {
                result[@"stage"] = @"depth_prepare"; result[@"type_pending"] = @(types[i]);
                if (!publish(result)) return failed(@"error", @"result_persistence", nil);
                NvnDepthStatus status = [cache prepareType:types[i] command:command serial:phase+1];
                if (status) { result[@"type_pending"] = @(types[i]); result[@"helper_status"] = @(status); return failed(@"error", @"depth_prepare", nil); }
                id<MTLTexture> texture = [cache textureForType:types[i] serial:phase+1];
                if (!texture) return failed(@"error", @"depth_cache_lookup", nil);
                [textures addObject:texture];
                if (!phase) {
                    result[@"stage"] = @"depth_seed_clear";
                    if (!publish(result)) return failed(@"error", @"result_persistence", nil);
                    if (nvn_depth_dummy_clear(command, texture, types[i], .625)) return failed(@"error", @"depth_seed_clear", nil);
                }
            }
            [result removeObjectForKey:@"type_pending"];
            NSMutableArray *properties = [NSMutableArray array];
            for (id<MTLTexture> texture in textures) [properties addObject:@{
                @"class": NSStringFromClass(texture.class), @"type": @(texture.textureType), @"format": @(texture.pixelFormat),
                @"storage": @(texture.storageMode), @"hazard_mode": @(texture.hazardTrackingMode), @"usage": @(texture.usage),
                @"width": @(texture.width), @"height": @(texture.height), @"depth": @(texture.depth), @"array_length": @(texture.arrayLength),
                @"mip_levels": @(texture.mipmapLevelCount), @"sample_count": @(texture.sampleCount), @"same_device": @(texture.device == device)}];
            result[@"textures"] = properties;
            if (!phase) originalTextures = [textures copy];
            else for (unsigned i = 0; i < 3; i++) if (textures[i] != originalTextures[i]) return failed(@"error", @"depth_cache_reuse", nil);
            id<MTLBuffer> encoded = [device newBufferWithLength:arguments.encodedLength options:MTLResourceStorageModeShared];
            if (!encoded) return failed(@"error", @"depth_arguments", nil);
            [arguments setArgumentBuffer:encoded offset:0];
            for (NSUInteger i = 0; i < 3; i++) [arguments setTexture:textures[i] atIndex:i];
            [arguments setBuffer:output offset:0 atIndex:3];
            id<MTLComputeCommandEncoder> reader = [command computeCommandEncoder];
            if (!reader) return failed(@"error", @"depth_reader_encoder", nil);
            [reader setComputePipelineState:pipeline]; [reader setBuffer:encoded offset:0 atIndex:0];
            uint32_t base = phase*16; [reader setBytes:&base length:sizeof base atIndex:1];
            for (id<MTLTexture> texture in textures) [reader useResource:texture usage:MTLResourceUsageRead];
            [reader useResource:output usage:MTLResourceUsageWrite];
            [reader dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)]; [reader endEncoding];
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
                (void)textures.count; (void)output.length; (void)encoded.length; (void)completed; dispatch_semaphore_signal(done);
            }];
            result[@"stage"] = @"depth_gpu_completion";
            if (!publish(result)) return failed(@"error", @"result_persistence", nil);
            [command commit];
            if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC))) return failed(@"timeout", @"depth_gpu_completion", nil);
            if (command.status != MTLCommandBufferStatusCompleted) return failed(@"error", @"depth_gpu_completion", command.error);
            const float *values = output.contents; BOOL match = YES;
            for (unsigned i = 0; i < 16; i++) if (values[phase*16+i] != (phase ? 0 : .625f)) match = NO;
            result[phase ? @"zero_phase_match" : @"seed_phase_match"] = @(match);
            if (!match) return failed(@"error", @"depth_sample_readback", nil);
            result[@"completed_phases"] = @(phase+1);
        }
    }
    const uint32_t *words = output.contents; BOOL guards = YES;
    for (unsigned i = 32; i < 64; i++) if (words[i] != UINT32_C(0xcdcdcdcd)) guards = NO;
    [result removeObjectForKey:@"phase_pending"];
    result[@"type_names"] = @[@"2d", @"2d_array", @"cube"]; result[@"cube_faces"] = @6;
    result[@"format"] = @"Depth32Float"; result[@"storage"] = @"private"; result[@"tracked"] = @YES;
    result[@"usage"] = @"shader_read|render_target"; result[@"cache_objects_reused"] = @YES;
    result[@"samples_per_phase"] = @8; result[@"reads_per_phase"] = @8; result[@"total_values"] = @32;
    result[@"surrounding_bytes_unchanged"] = @(guards);
    result[@"argument_encoded_length"] = @(arguments.encodedLength); result[@"argument_alignment"] = @(arguments.alignment);
    result[@"status"] = guards ? @"passed" : @"error"; result[@"stage"] = @"depth_sample_readback"; return result;
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
        DmProfileLibraryPlan *libraryPlan = nil;
        if (selection == DM_GPU_CASE_LIBRARIES) { @autoreleasepool {
            NSError *error = nil;
            libraryPlan = [DmProfileLibraryPlan loadRoot:NSBundle.mainBundle.resourcePath
                                                 expected:dm_profile_library_expected() error:&error];
            if (!libraryPlan) {
                result[@"error"] = failure(@"error", @"profile_library_inventory", error);
                write_report(result, path, NO); return 1;
            }
        }}
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { result[@"device_status"] = @"unavailable"; write_report(result, path, NO); return 1; }
        result[@"device_status"] = @"available"; result[@"device"] = device_info(device, device);
        NSMutableDictionary *tests = [NSMutableDictionary dictionary]; result[@"tests"] = tests;
        if (selection == DM_GPU_CASE_LIBRARIES) {
            if (!begin_test(result, path, @"profile_libraries")) return 1;
            NSError *error = nil;
            NSDictionary *receipt = dm_profile_library_run(libraryPlan, device, 1, 1800, 120, 30, ^BOOL(NSDictionary *detail) {
                tests[@"profile_libraries"] = @{@"status": @"pending", @"receipt": detail};
                return write_report(result, path, NO);
            }, &error);
            BOOL passed = receipt && dm_profile_library_receipt_complete(receipt, libraryPlan, [libraryPlan scopeForDevice:device]);
            NSMutableDictionary *test = [@{@"status": passed ? @"passed" : @"error"} mutableCopy];
            if (receipt) test[@"receipt"] = receipt;
            if (error) test[@"error"] = error.localizedDescription;
            tests[@"profile_libraries"] = test;
            [result removeObjectForKey:@"pending_test"]; result[@"complete"] = @YES;
            result[@"library_compilation_only"] = @YES;
            result[@"guest_executed"] = @NO; result[@"gpu_commands_submitted"] = @NO;
            if (!write_report(result, path, NO)) return 1;
            return passed ? 0 : 1;
        }
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
        if (selection == DM_GPU_CASE_BC || selection == DM_GPU_CASE_ALL) {
            if (!begin_test(result,path,@"bc_transfers")) return 1;
            tests[@"bc_transfers"]=bc_transfers(device,queue,^BOOL(NSDictionary *detail) {
                tests[@"bc_transfers"]=detail;return write_report(result,path,NO);
            });
        }
        if (selection == DM_GPU_CASE_ARGUMENTS || selection == DM_GPU_CASE_ALL) {
            if (!begin_test(result, path, @"prepared_arguments")) return 1;
            tests[@"prepared_arguments"] = prepared_arguments(device, queue, ^BOOL(NSDictionary *detail) {
                tests[@"prepared_arguments"] = detail; return write_report(result, path, NO);
            });
        }
        if (selection == DM_GPU_CASE_DEPTH || selection == DM_GPU_CASE_ALL) {
            if (!begin_test(result, path, @"private_depth")) return 1;
            tests[@"private_depth"] = private_depth(device, queue, ^BOOL(NSDictionary *detail) {
                tests[@"private_depth"] = detail; return write_report(result, path, NO);
            });
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
