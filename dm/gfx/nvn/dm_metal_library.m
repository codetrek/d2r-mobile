#import "dm_metal_library.h"
#import <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <mach-o/loader.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <math.h>
#include <string.h>

static NSError *library_error(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:@"d2r.metal-library" code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

NSString *dm_metal_sha256(NSData *data) {
    CC_SHA256_CTX context; CC_SHA256_Init(&context);
    const uint8_t *bytes = data.bytes;
    for (NSUInteger offset = 0; offset < data.length;) {
        CC_LONG count = (CC_LONG)MIN(data.length - offset, (NSUInteger)UINT32_MAX);
        CC_SHA256_Update(&context, bytes + offset, count); offset += count;
    }
    unsigned char result[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(result, &context);
    NSMutableString *hex = [NSMutableString stringWithCapacity:64];
    for (unsigned i = 0; i < sizeof result; i++) [hex appendFormat:@"%02x", result[i]];
    return hex;
}

NSDictionary *dm_metal_library_contract(void) {
    Dl_info info = {0}; NSString *image = nil;
    if (dladdr((const void *)dm_metal_library_contract, &info) && info.dli_fbase) {
        const struct mach_header_64 *header = info.dli_fbase;
        if (header->magic == MH_MAGIC_64) {
            const struct load_command *command = (const void *)(header + 1);
            for (uint32_t i = 0; i < header->ncmds; i++) {
                if (command->cmd == LC_UUID && command->cmdsize == sizeof(struct uuid_command)) {
                    image = [[NSUUID alloc] initWithUUIDBytes:((const struct uuid_command *)command)->uuid].UUIDString;
                    break;
                }
                command = (const void *)((const uint8_t *)command + command->cmdsize);
            }
        }
    }
#ifdef DM_METAL_LIBRARY_CONTRACT_SHA256
    id source = @DM_METAL_LIBRARY_CONTRACT_SHA256;
#else
    id source = NSNull.null;
#endif
    return @{@"schema": @"d2r.metal-library-compile.v1", @"source_encoding": @"UTF-8",
             @"source_api": @"newLibraryWithSource:options:error:", @"options": @"nil-default",
             @"binary_api": @"newLibraryWithData:error:dispatch-data-mmap", @"function_api": @"newFunctionWithName:",
             @"clang": @__clang_version__, @"source_sha256": source, @"loaded_image_uuid": image ? image : NSNull.null};
}

@interface DmLibraryTicket : NSObject
@property(strong) NSLock *lock;
@property(strong) id object;
@property(strong) NSError *error;
@property BOOL abandoned;
@property NSTimeInterval deadline;
@property(strong) dispatch_semaphore_t semaphore;
@end
@implementation DmLibraryTicket
- (instancetype)init {
    if ((self = [super init])) { _lock = [NSLock new]; _semaphore = dispatch_semaphore_create(0); }
    return self;
}
@end

static NSError *deadline_error(void) {
    return library_error(4, @"Metal library operation exceeded its declared deadline");
}
static BOOL in_time(NSTimeInterval deadline, NSError **error) {
    if (deadline == 0 || NSProcessInfo.processInfo.systemUptime < deadline) return YES;
    if (error) *error = deadline_error(); return NO;
}
static void complete(DmLibraryTicket *ticket, id object, NSError *error) {
    [ticket.lock lock];
    if (!ticket.abandoned) {
        if (!in_time(ticket.deadline, NULL)) {
            ticket.abandoned = YES; ticket.error = deadline_error();
        } else { ticket.object = object; ticket.error = error; }
    }
    [ticket.lock unlock]; dispatch_semaphore_signal(ticket.semaphore);
}
static id await(DmLibraryTicket *ticket, NSError **error) {
    double remaining = ticket.deadline - NSProcessInfo.processInfo.systemUptime;
    long waited = remaining <= 0 ? 1 : dispatch_semaphore_wait(ticket.semaphore,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)));
    [ticket.lock lock];
    if (waited || !in_time(ticket.deadline, NULL)) {
        ticket.abandoned = YES; ticket.object = nil; ticket.error = deadline_error();
    }
    id object = ticket.object; NSError *failure = ticket.error;
    [ticket.lock unlock];
    if (!object && error) *error = failure ? failure : library_error(5, @"Metal returned no object and no error");
    return object;
}

id<MTLLibrary> dm_metal_library_load(id<MTLDevice> device, NSString *path, DmMetalLibraryPolicy policy,
                                    NSTimeInterval timeout, BOOL *compiledSource, NSError **error) {
    double entered = NSProcessInfo.processInfo.systemUptime;
    if (!isfinite(timeout) || timeout < 0 || timeout > 3600) {
        if (compiledSource) *compiledSource = NO;
        if (error) *error = library_error(1, @"Invalid Metal library timeout"); return nil;
    }
    return dm_metal_library_load_until(device, path, policy, timeout == 0 ? 0 : entered + timeout, compiledSource, error);
}

id<MTLLibrary> dm_metal_library_load_until(id<MTLDevice> device, NSString *path, DmMetalLibraryPolicy policy,
                                          NSTimeInterval deadline, BOOL *compiledSource, NSError **error) {
    if (compiledSource) *compiledSource = NO;
    if (!device || !path.length || !isfinite(deadline) || deadline < 0 ||
        deadline > NSProcessInfo.processInfo.systemUptime + 3600 ||
        !policy || (policy & ~(DmMetalLibrarySource | DmMetalLibraryBinary))) {
        if (error) *error = library_error(1, @"Invalid Metal library load contract"); return nil;
    }
    if (!in_time(deadline, error)) return nil;
    int fd = open(path.fileSystemRepresentation, O_RDONLY); struct stat status;
    if (fd < 0 || fstat(fd, &status) || status.st_size <= 0) {
        int code = errno; if (fd >= 0) close(fd);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: @"Cannot read Metal library file"}];
        return nil;
    }
    size_t length = (size_t)status.st_size;
    void *mapped = mmap(NULL, length, PROT_READ, MAP_PRIVATE, fd, 0); int code = errno; close(fd);
    if (mapped == MAP_FAILED) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil]; return nil;
    }
    if (!in_time(deadline, error)) { munmap(mapped, length); return nil; }
    BOOL binary = length >= 4 && !memcmp(mapped, "MTLB", 4);
    if (!(policy & (binary ? DmMetalLibraryBinary : DmMetalLibrarySource))) {
        munmap(mapped, length); if (error) *error = library_error(2, @"Library bytes violate the selected source/binary contract"); return nil;
    }
    dispatch_data_t data = nil; NSString *source = nil;
    if (binary) {
        data = dispatch_data_create(mapped, length, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ munmap(mapped, length); });
    } else {
        source = [[NSString alloc] initWithBytes:mapped length:length encoding:NSUTF8StringEncoding];
        munmap(mapped, length);
        if (!source) { if (error) *error = library_error(3, @"Metal source is not valid UTF-8"); return nil; }
    }
    if (!in_time(deadline, error)) return nil;
    if (compiledSource) *compiledSource = !binary;
    if (deadline == 0) return binary ? [device newLibraryWithData:data error:error] : [device newLibraryWithSource:source options:nil error:error];
    DmLibraryTicket *ticket = [DmLibraryTicket new]; ticket.deadline = deadline;
    if (!in_time(deadline, error)) return nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ @autoreleasepool {
        NSError *failure = nil; id<MTLLibrary> library = nil;
        if (in_time(deadline, &failure))
            library = binary ? [device newLibraryWithData:data error:&failure] : [device newLibraryWithSource:source options:nil error:&failure];
        complete(ticket, library, failure);
    }});
    return await(ticket, error);
}

id<MTLFunction> dm_metal_library_function(id<MTLLibrary> library, NSString *entry,
                                         MTLFunctionType expected, NSTimeInterval timeout, NSError **error) {
    double entered = NSProcessInfo.processInfo.systemUptime;
    if (!isfinite(timeout) || timeout <= 0 || timeout > 3600) {
        if (error) *error = library_error(1, @"Invalid named function timeout"); return nil;
    }
    return dm_metal_library_function_until(library, entry, expected, entered + timeout, error);
}
id<MTLFunction> dm_metal_library_function_until(id<MTLLibrary> library, NSString *entry,
                                               MTLFunctionType expected, NSTimeInterval deadline, NSError **error) {
    if (!library || !entry.length || !isfinite(deadline) || deadline <= 0 || deadline > NSProcessInfo.processInfo.systemUptime + 3600) {
        if (error) *error = library_error(1, @"Invalid named function contract"); return nil;
    }
    if (!in_time(deadline, error)) return nil;
    DmLibraryTicket *ticket = [DmLibraryTicket new]; ticket.deadline = deadline;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ @autoreleasepool {
        NSError *failure = nil; id<MTLFunction> function = nil;
        if (in_time(deadline, &failure)) {
            function = [library newFunctionWithName:entry];
            if (!function || function.functionType != expected) failure = library_error(6, @"Named function is missing or has a different Metal entry kind");
        }
        complete(ticket, failure ? nil : function, failure);
    }});
    return await(ticket, error);
}
