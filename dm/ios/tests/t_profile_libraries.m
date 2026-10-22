#import <Foundation/Foundation.h>
#import "../Sources/dm_profile_libraries.h"
#import "../../gfx/nvn/dm_metal_library.h"
#include "../Sources/dm_shader_prep_gate.h"
#include <assert.h>
#include <stdatomic.h>
#include <unistd.h>
#include <sys/mman.h>

static _Atomic int liveLibraries, liveFunctions, functionCalls, delayNextMmap;
void *dm_owned_mmap(void *address, size_t length, int protection, int flags, int descriptor, off_t offset) {
    if (atomic_exchange(&delayNextMmap, 0)) usleep(600000);
    return mmap(address, length, protection, flags, descriptor, offset);
}
@interface FakeFunction : NSObject
@property MTLFunctionType functionType;
@property(strong) id owner;
@end
@implementation FakeFunction
- (instancetype)init { if ((self = [super init])) atomic_fetch_add(&liveFunctions, 1); return self; }
- (void)dealloc { atomic_fetch_sub(&liveFunctions, 1); }
@end
@interface FakeLibrary : NSObject
@property MTLFunctionType kind;
@property BOOL missing;
@property(strong) dispatch_data_t binary;
@property(strong) dispatch_semaphore_t functionGate;
@end
@implementation FakeLibrary
- (instancetype)init { if ((self = [super init])) atomic_fetch_add(&liveLibraries, 1); return self; }
- (void)dealloc { atomic_fetch_sub(&liveLibraries, 1); }
- (id<MTLFunction>)newFunctionWithName:(NSString *)name {
    atomic_fetch_add(&functionCalls, 1);
    if (self.functionGate) dispatch_semaphore_wait(self.functionGate, DISPATCH_TIME_FOREVER);
    if (self.missing || ![name isEqual:@"main0"]) return nil;
    FakeFunction *function = [FakeFunction new]; function.functionType = self.kind; function.owner = self;
    return (id<MTLFunction>)function;
}
@end
@interface FakeDevice : NSObject
@property NSUInteger sourceCalls;
@property NSUInteger binaryCalls;
@property BOOL fail;
@property BOOL missing;
@property(strong) dispatch_semaphore_t gate;
@property BOOL wrongKind;
@end
@implementation FakeDevice
- (NSString *)name { return @"Owned CPU compiler recorder"; }
- (uint64_t)registryID { return 42; }
- (MTLArgumentBuffersTier)argumentBuffersSupport { return MTLArgumentBuffersTier1; }
- (id<MTLLibrary>)newLibraryWithSource:(NSString *)source options:(MTLCompileOptions *)options error:(NSError **)error {
    assert(options == nil); self.sourceCalls++;
    dispatch_semaphore_t gate = self.gate;
    if (gate) dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER);
    if (self.fail) {
        if (error) *error = [NSError errorWithDomain:@"owned.compiler" code:7 userInfo:nil];
        return nil;
    }
    FakeLibrary *library = [FakeLibrary new]; library.missing = self.missing;
    library.kind = [source hasPrefix:@"vertex"] ? MTLFunctionTypeVertex :
                   [source hasPrefix:@"fragment"] ? MTLFunctionTypeFragment : MTLFunctionTypeKernel;
    if (self.wrongKind) library.kind = MTLFunctionTypeKernel;
    return (id<MTLLibrary>)library;
}
- (id<MTLLibrary>)newLibraryWithData:(dispatch_data_t)data error:(NSError **)error {
    (void)error; self.binaryCalls++;
    FakeLibrary *library = [FakeLibrary new]; library.binary = data; return (id<MTLLibrary>)library;
}
@end

@interface SlowVerificationPlan : DmProfileLibraryPlan
@property NSUInteger lastKeyChecks;
@property NSUInteger slowItemCheck;
@property NSUInteger fullChecks;
@property NSUInteger slowFullCheck;
@end
@interface DmProfileLibraryPlan (OwnedDeadlineWitness)
- (BOOL)verifyUntil:(double)deadline error:(NSError **)error;
@end
@implementation SlowVerificationPlan
- (BOOL)verifyItem:(NSDictionary *)item error:(NSError **)error {
    BOOL result = [super verifyItem:item error:error];
    if ([item[@"key"] isEqual:self.items.lastObject[@"key"]] && ++self.lastKeyChecks == self.slowItemCheck) usleep(600000);
    return result;
}
- (BOOL)verifyUntil:(double)deadline error:(NSError **)error {
    BOOL result = [super verifyUntil:deadline error:error];
    if (++self.fullChecks == self.slowFullCheck) usleep(600000);
    return result;
}
@end

static NSData *json(id object) {
    NSError *error = nil; NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:&error];
    assert(data && !error); return data;
}
static void write_owned(NSString *path, NSData *data) {
    NSError *error = nil;
    assert([NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                                withIntermediateDirectories:YES attributes:nil error:&error]);
    assert([data writeToFile:path options:0 error:&error]); assert(!error);
}
static NSDictionary *identity(NSData *data) { return @{@"size": @(data.length), @"sha256": dm_metal_sha256(data)}; }
static NSDictionary *fixture(NSString *root) {
    NSString *chain = @"0123456789ab";
    NSArray *stages = @[@"vs", @"ps", @"cs", @"hs", @"ds"];
    NSDictionary *kinds = @{@"vs": @"vertex", @"ps": @"fragment", @"cs": @"kernel", @"hs": @"kernel", @"ds": @"vertex"};
    NSMutableArray *keys = [NSMutableArray array]; NSMutableDictionary *artifacts = [NSMutableDictionary dictionary];
    for (NSUInteger index = 0; index < stages.count; index++) {
        NSString *key = [NSString stringWithFormat:@"%016lx", (unsigned long)index + 1]; [keys addObject:key];
        NSString *stage = stages[index], *base = [key stringByAppendingString:@"_b"];
        NSData *reflection = json(@{@"key": base, @"chain": chain, @"stage": stage, @"msl_entry_kind": kinds[stage], @"entry": @"main0"});
        NSData *source = [[NSString stringWithFormat:@"%@ float4 main0() { return float4(1); }\n", kinds[stage]] dataUsingEncoding:NSUTF8StringEncoding];
        for (NSString *suffix in @[@"json", @"metallib"]) {
            NSString *name = [NSString stringWithFormat:@"b-%@/%@.%@", chain, base, suffix];
            NSData *data = [suffix isEqual:@"json"] ? reflection : source;
            artifacts[name] = identity(data); write_owned([root stringByAppendingPathComponent:[@"msl/" stringByAppendingString:name]], data);
        }
    }
    NSString *profileName = @"ios-simulator-native-arguments-sampler-alias-v1";
    NSData *profile = json(@{@"profile": profileName, @"chain": chain, @"keys": @5, @"variants": @0, @"compiled": @NO,
                            @"renderer_qualified": @NO, @"artifacts": artifacts, @"provenance": @{@"input": @{@"keys": keys}},
                            @"corpus": @{}, @"metadata_requirements": @[]});
    write_owned([root stringByAppendingPathComponent:@"dm/simulator-shader-profile.json"], profile);
    NSMutableDictionary *metaArtifacts = [NSMutableDictionary dictionary];
    for (NSString *name in @[@"shader_map.tsv", @"c1_full.tsv", @"pso_manifest.tsv"]) {
        NSData *data = [@"owned fixture\n" dataUsingEncoding:NSUTF8StringEncoding]; metaArtifacts[name] = identity(data);
        write_owned([root stringByAppendingPathComponent:[@"dm/" stringByAppendingString:name]], data);
    }
    NSString *metadataID = [@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0];
    NSData *metadata = json(@{@"schema": @"d2r.simulator-profile-metadata.v1", @"profile": profileName,
        @"compiled": @NO, @"executed": @NO, @"renderer_qualified": @NO, @"provenance_id": metadataID,
        @"provenance": @{@"derived_chain": chain, @"shader_keys": @5, @"inputs": @{@"shader_profile": identity(profile)}},
        @"artifacts": metaArtifacts, @"ledger": @[], @"summary": @{}, @"native_execution": @{}, @"c1_execution": @{}});
    write_owned([root stringByAppendingPathComponent:@"dm/simulator-metadata-profile.json"], metadata);
    return @{@"profile": profileName, @"chain": chain, @"metadata_sha256": dm_metal_sha256(metadata),
             @"metadata_id": metadataID, @"compiler_source_sha256": dm_metal_library_contract()[@"source_sha256"]};
}

int main(int argc, char **argv) { @autoreleasepool {
    assert(argc == 2); NSString *root = @(argv[1]);
    DmShaderPrepState gate = DmPrepIdle;
    assert(dm_shader_prep_enter(&gate) == DmPrepStart);
    assert(dm_shader_prep_enter(&gate) == DmPrepWait);
    assert(dm_shader_prep_enter(&gate) == DmPrepWait);
    dm_shader_prep_ready(&gate); assert(dm_shader_prep_enter(&gate) == DmPrepPass);
    NSDictionary *expected = fixture(root); NSError *error = nil;
    DmProfileLibraryPlan *plan = [DmProfileLibraryPlan loadRoot:root expected:expected error:&error];
    assert(plan && !error && plan.items.count == 5);
    assert([plan.items[3][@"stage"] isEqual:@"hs"] && [plan.items[3][@"entry_kind"] isEqual:@"kernel"]);
    assert([plan.items[4][@"stage"] isEqual:@"ds"] && [plan.items[4][@"entry_kind"] isEqual:@"vertex"]);
    FakeDevice *device = [FakeDevice new]; NSMutableArray *checkpoints = [NSMutableArray array];
    NSDictionary *receipt = dm_profile_library_run(plan, (id<MTLDevice>)device, 1, 10, 5, 1,
        ^BOOL(NSDictionary *detail) { [checkpoints addObject:detail]; return YES; }, &error);
    assert(receipt && !error && device.sourceCalls == 5 && device.binaryCalls == 0);
    NSDictionary *scope = [plan scopeForDevice:(id<MTLDevice>)device];
    assert(dm_profile_library_receipt_complete(receipt, plan, scope));
    assert(checkpoints.count == 17 && [checkpoints[1][@"pending_phase"] isEqual:@"library"] &&
           [checkpoints[2][@"pending_phase"] isEqual:@"named-function"]);
    for (NSDictionary *point in checkpoints) assert(![point[@"complete"] boolValue]);
    assert(!checkpoints[1][@"expected"] && [checkpoints[1][@"expected_count"] isEqual:@5]);
    assert(!dm_profile_library_receipt_complete((id)@"ok", plan, scope));
    for (NSString *field in @[@"renderer_qualified", @"native_layout_qualified", @"pso_qualified", @"tessellation_rendering_qualified"]) {
        NSMutableDictionary *bad = [receipt mutableCopy]; bad[field] = @YES;
        assert(!dm_profile_library_receipt_complete(bad, plan, scope));
    }
    NSMutableDictionary *bad = [receipt mutableCopy]; bad[@"future"] = @1;
    assert(!dm_profile_library_receipt_complete(bad, plan, scope));
    bad = [receipt mutableCopy]; bad[@"succeeded"] = @[];
    assert(!dm_profile_library_receipt_complete(bad, plan, scope));
    bad = [receipt mutableCopy]; bad[@"expected_inventory_sha256"] = @"wrong";
    assert(!dm_profile_library_receipt_complete(bad, plan, scope));
    for (NSString *phase in @[@"library", @"named-function", @"verified"]) {
        __block BOOL delayed = NO; error = nil;
        NSUInteger callsBefore = device.sourceCalls; int functionsBefore = atomic_load(&functionCalls);
        double started = NSProcessInfo.processInfo.systemUptime;
        receipt = dm_profile_library_run(plan, (id<MTLDevice>)device, 1, 10, .5, .5, ^BOOL(NSDictionary *detail) {
            assert(![detail[@"complete"] boolValue]);
            if (!delayed && [detail[@"pending_phase"] isEqual:phase] &&
                [detail[@"pending"][@"key"] isEqual:plan.items.lastObject[@"key"]]) {
                delayed = YES; usleep(600000);
            }
            return YES;
        }, &error);
        assert(delayed && NSProcessInfo.processInfo.systemUptime - started > .6 && receipt && !error);
        assert(!dm_profile_library_receipt_complete(receipt, plan, scope));
        assert(![receipt[@"complete"] boolValue] && [receipt[@"succeeded"] count] == 4 && [receipt[@"failed"] count] == 1);
        assert(device.sourceCalls - callsBefore == ([phase isEqual:@"library"] ? 4 : 5));
        assert(atomic_load(&functionCalls) - functionsBefore == ([phase isEqual:@"verified"] ? 5 : 4));
    }
    for (NSUInteger check = 1; check <= 2; check++) {
        error = nil;
        SlowVerificationPlan *slow = [SlowVerificationPlan loadRoot:root expected:expected error:&error];
        assert(slow && !error); slow.slowItemCheck = check;
        NSUInteger callsBefore = device.sourceCalls;
        receipt = dm_profile_library_run(slow, (id<MTLDevice>)device, 1, 10, .5, .5,
            ^BOOL(NSDictionary *detail) { assert(![detail[@"complete"] boolValue]); return YES; }, &error);
        assert(receipt && !error && ![receipt[@"complete"] boolValue] && [receipt[@"succeeded"] count] == 4 && [receipt[@"failed"] count] == 1);
        assert(device.sourceCalls - callsBefore == (check == 1 ? 4 : 5));
    }
    // Final input hashing and persistence have whole-run budgets; checkpoints
    // cannot publish an accepted completion while either is still pending.
    error = nil;
    SlowVerificationPlan *slowFinal = [SlowVerificationPlan loadRoot:root expected:expected error:&error];
    assert(slowFinal && !error); slowFinal.slowFullCheck = 3;
    assert(!dm_profile_library_run(slowFinal, (id<MTLDevice>)device, 1, 10, .5, .5,
        ^BOOL(NSDictionary *detail) { assert(![detail[@"complete"] boolValue]); return YES; }, &error) && error);
    for (NSUInteger final = 0; final < 2; final++) {
        __block NSUInteger points = 0; error = nil;
        NSUInteger callsBefore = device.sourceCalls;
        receipt = dm_profile_library_run(plan, (id<MTLDevice>)device, 1, final ? 10 : .5, .5, .5, ^BOOL(NSDictionary *detail) {
            assert(![detail[@"complete"] boolValue]); points++;
            if ((!final && points == 1) || (final && detail[@"expected"] && [detail[@"succeeded_count"] isEqual:@5])) usleep(600000);
            return YES;
        }, &error);
        assert(!receipt && error && device.sourceCalls - callsBefore == (final ? 5 : 0));
    }
    device.fail = YES; error = nil;
    receipt = dm_profile_library_run(plan, (id<MTLDevice>)device, 1, 10, 5, 1, ^BOOL(NSDictionary *detail) { (void)detail; return YES; }, &error);
    assert(receipt && ![receipt[@"complete"] boolValue] && [receipt[@"failed"] count] == 1 && [receipt[@"unattempted"] count] == 4);
    device.fail = NO; device.missing = YES; error = nil;
    receipt = dm_profile_library_run(plan, (id<MTLDevice>)device, 1, 10, 5, 1, ^BOOL(NSDictionary *detail) { (void)detail; return YES; }, &error);
    assert(receipt && ![receipt[@"complete"] boolValue] && [receipt[@"failed"] count] == 1);
    device.missing = NO; device.wrongKind = YES; error = nil;
    receipt = dm_profile_library_run(plan, (id<MTLDevice>)device, 1, 10, 5, 1, ^BOOL(NSDictionary *detail) { (void)detail; return YES; }, &error);
    assert(receipt && ![receipt[@"complete"] boolValue] && [receipt[@"failed"] count] == 1);
    device.wrongKind = NO; error = nil;
    assert(!dm_profile_library_run(plan, (id<MTLDevice>)device, 7, 10, 5, 1, ^BOOL(NSDictionary *detail) { (void)detail; return YES; }, &error));
    error = nil;
    assert(!dm_profile_library_run(plan, (id<MTLDevice>)device, 1, 10, 5, 1, ^BOOL(NSDictionary *detail) { (void)detail; return NO; }, &error));
    __block NSUInteger checkpointCount = 0; error = nil;
    assert(!dm_profile_library_run(plan, (id<MTLDevice>)device, 1, 10, 5, 1, ^BOOL(NSDictionary *detail) {
        (void)detail; return ++checkpointCount < 2;
    }, &error));
    assert(error && [error.localizedDescription containsString:@"pending"]);
    for (NSString *raw in @[@"{\"a\":1,\"a\":2}", @"{\"a\":{\"x\":1,\"x\":2}}", @"{\"a\":1,\"\\u0061\":2}", @"not-json"]) {
        error = nil;
        assert(!dm_profile_library_json([raw dataUsingEncoding:NSUTF8StringEncoding], &error) && error);
    }
    error = nil;
    assert(dm_profile_library_json([@"{\"objects\":[{\"a\":1},{\"a\":2}],\"text\":\"{escaped}\\\"\"}" dataUsingEncoding:NSUTF8StringEncoding], &error));
    NSString *binary = [root stringByAppendingPathComponent:@"owned-binary.metallib"];
    write_owned(binary, [@"MTLB-owned" dataUsingEncoding:NSUTF8StringEncoding]); BOOL compiled = NO; error = nil;
    assert(!dm_metal_library_load((id<MTLDevice>)device, binary, DmMetalLibrarySource, 1, &compiled, &error));
    error = nil; assert(dm_metal_library_load((id<MTLDevice>)device, binary, DmMetalLibraryBinary, 0, &compiled, &error));
    assert(device.binaryCalls == 1 && !compiled);
    NSString *invalid = [root stringByAppendingPathComponent:@"invalid-utf8.metallib"];
    const unsigned char invalidBytes[] = {0xff, 0xff};
    write_owned(invalid, [NSData dataWithBytes:invalidBytes length:sizeof invalidBytes]); error = nil;
    assert(!dm_metal_library_load((id<MTLDevice>)device, invalid, DmMetalLibrarySource, 1, &compiled, &error));
    assert(error.code == 3);
    NSString *source = [plan.root stringByAppendingPathComponent:plan.items[0][@"source"]];
    NSUInteger sourceCallsBefore = device.sourceCalls; double readStarted = NSProcessInfo.processInfo.systemUptime;
    atomic_store(&delayNextMmap, 1); error = nil;
    assert(!dm_metal_library_load((id<MTLDevice>)device, source, DmMetalLibrarySource, .5, &compiled, &error));
    assert(error.code == 4 && !compiled && device.sourceCalls == sourceCallsBefore && NSProcessInfo.processInfo.systemUptime - readStarted > .6);
    atomic_store(&delayNextMmap, 1); error = nil; readStarted = NSProcessInfo.processInfo.systemUptime;
    assert(dm_metal_library_load((id<MTLDevice>)device, source, DmMetalLibrarySource, 0, &compiled, &error));
    assert(!error && compiled && device.sourceCalls == sourceCallsBefore + 1 && NSProcessInfo.processInfo.systemUptime - readStarted > .6);
    error = nil;
    assert(!dm_metal_library_load_until((id<MTLDevice>)device, source, DmMetalLibrarySource,
                                       NSProcessInfo.processInfo.systemUptime - .1, &compiled, &error));
    assert(error.code == 4 && device.sourceCalls == sourceCallsBefore + 1);
    error = nil; atomic_store(&delayNextMmap, 1); NSUInteger binaryCallsBefore = device.binaryCalls;
    assert(!dm_metal_library_load((id<MTLDevice>)device, binary, DmMetalLibraryBinary, .5, &compiled, &error));
    assert(error.code == 4 && device.binaryCalls == binaryCallsBefore);
    @autoreleasepool {
        FakeLibrary *late = [FakeLibrary new]; late.kind = MTLFunctionTypeVertex; late.functionGate = dispatch_semaphore_create(0);
        error = nil;
        assert(!dm_metal_library_function((id<MTLLibrary>)late, @"main0", MTLFunctionTypeVertex, .01, &error));
        assert(error.code == 4);
        dispatch_semaphore_signal(late.functionGate);
    }
    device.gate = dispatch_semaphore_create(0); error = nil;
    assert(!dm_metal_library_load((id<MTLDevice>)device, source, DmMetalLibrarySource, 0.01, &compiled, &error));
    assert([error.domain isEqual:@"d2r.metal-library"] && error.code == 4);
    dispatch_semaphore_signal(device.gate); device.gate = nil;
    NSString *extra = [[root stringByAppendingPathComponent:@"msl/b-0123456789ab"] stringByAppendingPathComponent:@"unbound_bf.metallib"];
    write_owned(extra, [@"extra" dataUsingEncoding:NSUTF8StringEncoding]); error = nil;
    assert(![plan verify:&error]); assert([NSFileManager.defaultManager removeItemAtPath:extra error:NULL]);
    NSData *original = [NSData dataWithContentsOfFile:source]; write_owned(source, [@"changed" dataUsingEncoding:NSUTF8StringEncoding]); error = nil;
    assert(![plan verifyItem:plan.items[0] error:&error]);
    assert(![DmProfileLibraryPlan loadRoot:root expected:expected error:&error]); write_owned(source, original);
    NSMutableDictionary *wrong = [expected mutableCopy]; wrong[@"metadata_sha256"] = [@"b" stringByPaddingToLength:64 withString:@"b" startingAtIndex:0];
    assert(![DmProfileLibraryPlan loadRoot:root expected:wrong error:&error]);
    puts("PASS profile libraries: owned CPU compiler/function mocks, exact descriptor inventory, HS/DS kinds, partial/full receipts, errors/absolute entry-to-receipt deadlines/slow checkpoints+pre/posthash+mmap/late ticket lifetimes, BF/drift; no Metal device or GPU call");
}
    for (unsigned attempt = 0; attempt < 1000 && (atomic_load(&liveLibraries) || atomic_load(&liveFunctions)); attempt++) usleep(1000);
    assert(!atomic_load(&liveLibraries) && !atomic_load(&liveFunctions));
    return 0;
}
