#import "dm_profile_libraries.h"
#import "../../gfx/nvn/dm_metal_library.h"
#include <math.h>

static BOOL rejected(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"d2r.profile-libraries" code:1
                                      userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}
static BOOL text(NSString *value, NSString *pattern) {
    return [value isKindOfClass:NSString.class] &&
        [value rangeOfString:pattern options:NSRegularExpressionSearch].location != NSNotFound;
}
static NSData *regular(NSString *path, NSError **error) {
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:error];
    if (!attributes) return nil;
    if (![attributes[NSFileType] isEqual:NSFileTypeRegular]) { rejected(error, @"Profile input is not a regular file"); return nil; }
    return [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:error];
}
static NSDictionary *file_identity(NSData *data) { return @{@"size": @(data.length), @"sha256": dm_metal_sha256(data)}; }
static BOOL bound(NSString *path, NSDictionary *identity, NSError **error) {
    if (![identity isKindOfClass:NSDictionary.class] || identity.count != 2 ||
        ![identity[@"size"] isKindOfClass:NSNumber.class] || !text(identity[@"sha256"], @"^[0-9a-f]{64}$"))
        return rejected(error, @"Malformed profile file identity");
    NSData *data = regular(path, error);
    return data && ([file_identity(data) isEqual:identity] || rejected(error, @"Profile file identity changed"));
}
NSDictionary *dm_profile_library_json(NSData *data, NSError **error) {
    if (!data) return nil;
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (value && ![value isKindOfClass:NSDictionary.class]) { rejected(error, @"Profile JSON root is not an object"); return nil; }
    if (!value) return nil;
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!json) { rejected(error, @"Profile JSON must be UTF-8"); return nil; }
    NSMutableArray *stack = [NSMutableArray array];
    for (NSUInteger index = 0; index < json.length; index++) {
        unichar character = [json characterAtIndex:index];
        if (character == '{' || character == '[') {
            [stack addObject:[@{@"object": @(character == '{'), @"key": @(character == '{'), @"keys": [NSMutableSet set]} mutableCopy]];
        } else if (character == '}' || character == ']') [stack removeLastObject];
        else if (character == ',' && [stack.lastObject[@"object"] boolValue]) stack.lastObject[@"key"] = @YES;
        else if (character == '"') {
            NSUInteger end = index + 1;
            for (; end < json.length; end++) {
                unichar current = [json characterAtIndex:end];
                if (current == '\\') end++;
                else if (current == '"') break;
            }
            NSMutableDictionary *frame = stack.lastObject;
            if ([frame[@"object"] boolValue] && [frame[@"key"] boolValue]) {
                NSString *token = [json substringWithRange:NSMakeRange(index, end - index + 1)];
                NSData *keyData = [[@"[" stringByAppendingString:[token stringByAppendingString:@"]"]] dataUsingEncoding:NSUTF8StringEncoding];
                NSArray *decoded = [NSJSONSerialization JSONObjectWithData:keyData options:0 error:error];
                if (!decoded || [frame[@"keys"] containsObject:decoded[0]]) { rejected(error, @"Duplicate profile JSON field"); return nil; }
                [frame[@"keys"] addObject:decoded[0]]; frame[@"key"] = @NO;
            }
            index = end;
        }
    }
    return value;
}
static BOOL fields(NSDictionary *value, NSArray *names) {
    return [value isKindOfClass:NSDictionary.class] && [[NSSet setWithArray:value.allKeys] isEqual:[NSSet setWithArray:names]];
}

static NSDictionary *library_item(NSString *key, NSString *chain, NSDictionary *profile, NSString *root,
                                  NSMutableDictionary *files, double inventoryDeadline,
                                  uint64_t *sourceBytes, NSError **error) {
    if (NSProcessInfo.processInfo.systemUptime >= inventoryDeadline) { rejected(error, @"Inventory validation deadline exceeded"); return nil; }
    if (!text(key, @"^[0-9a-f]{16}$") || [key isEqual:@"0000000000000000"]) { rejected(error, @"Malformed base key"); return nil; }
    NSString *base = [key stringByAppendingString:@"_b"];
    NSString *reflectionName = [NSString stringWithFormat:@"b-%@/%@.json", chain, base];
    NSString *sourceName = [NSString stringWithFormat:@"b-%@/%@.metallib", chain, base];
    NSDictionary *reflectionIdentity = profile[@"artifacts"][reflectionName];
    NSDictionary *sourceIdentity = profile[@"artifacts"][sourceName];
    if (![sourceIdentity isKindOfClass:NSDictionary.class] || ![sourceIdentity[@"size"] isKindOfClass:NSNumber.class] ||
        [sourceIdentity[@"size"] unsignedLongLongValue] > (64u << 20) ||
        (*sourceBytes += [sourceIdentity[@"size"] unsignedLongLongValue]) > (UINT64_C(2) << 30)) {
        rejected(error, @"Source corpus byte budget exceeded"); return nil;
    }
    NSString *reflectionPath = [@"msl/" stringByAppendingString:reflectionName];
    NSString *sourcePath = [@"msl/" stringByAppendingString:sourceName];
    if (!bound([root stringByAppendingPathComponent:reflectionPath], reflectionIdentity, error) ||
        !bound([root stringByAppendingPathComponent:sourcePath], sourceIdentity, error)) return nil;
    NSData *raw = regular([root stringByAppendingPathComponent:sourcePath], error);
    if (!raw || raw.length < 4 || raw.length > (64u << 20) || !memcmp(raw.bytes, "MTLB", 4)) {
        rejected(error, @"Derived profile requires bounded source MSL bytes"); return nil;
    }
    NSDictionary *reflection = dm_profile_library_json(regular([root stringByAppendingPathComponent:reflectionPath], error), error);
    NSDictionary *kinds = @{@"vs": @"vertex", @"ps": @"fragment", @"cs": @"kernel", @"hs": @"kernel", @"ds": @"vertex"};
    NSString *stage = reflection[@"stage"];
    NSString *kind = [stage isKindOfClass:NSString.class] ? kinds[stage] : nil;
    if (!kind || ![reflection[@"key"] isEqual:base] || ![reflection[@"chain"] isEqual:chain] ||
        ![reflection[@"msl_entry_kind"] isEqual:kind] || !text(reflection[@"entry"], @"^[A-Za-z_][A-Za-z0-9_]*$") || reflection[@"fetch"]) {
        rejected(error, @"Reflection key/stage/entry relationship is invalid"); return nil;
    }
    files[reflectionPath] = reflectionIdentity; files[sourcePath] = sourceIdentity;
    return @{@"key": key, @"stage": stage, @"entry_kind": kind, @"entry": reflection[@"entry"],
                       @"source": sourcePath, @"source_identity": sourceIdentity,
                       @"reflection": reflectionPath, @"reflection_identity": reflectionIdentity};
}

@interface DmProfileLibraryPlan ()
@property(readwrite, strong) NSString *root;
@property(readwrite, strong) NSArray *items;
@property(readwrite, strong) NSDictionary *identity;
@property(strong) NSDictionary *files;
@property(strong) NSString *chainDirectory;
- (BOOL)verifyUntil:(double)deadline error:(NSError **)error;
@end
@implementation DmProfileLibraryPlan
+ (instancetype)loadRoot:(NSString *)root expected:(NSDictionary *)expected error:(NSError **)error {
    double inventoryDeadline = NSProcessInfo.processInfo.systemUptime + 120;
    if (![root isKindOfClass:NSString.class] || !root.length ||
        !fields(expected, @[@"profile", @"chain", @"metadata_sha256", @"metadata_id", @"compiler_source_sha256"]) ||
        ![expected[@"profile"] isEqual:@"ios-simulator-native-arguments-sampler-alias-v1"] ||
        !text(expected[@"chain"], @"^[0-9a-f]{12}$") ||
        !text(expected[@"metadata_sha256"], @"^[0-9a-f]{64}$") ||
        !text(expected[@"metadata_id"], @"^[0-9a-f]{64}$") ||
        !text(expected[@"compiler_source_sha256"], @"^[0-9a-f]{64}$") ||
        ![expected[@"compiler_source_sha256"] isEqual:dm_metal_library_contract()[@"source_sha256"]]) {
        rejected(error, @"Explicit descriptor and compiler source identities are required"); return nil;
    }
    root = root.stringByResolvingSymlinksInPath;
    NSData *metadataData = regular([root stringByAppendingPathComponent:@"dm/simulator-metadata-profile.json"], error);
    NSData *profileData = regular([root stringByAppendingPathComponent:@"dm/simulator-shader-profile.json"], error);
    if (!metadataData || !profileData) return nil;
    if (![dm_metal_sha256(metadataData) isEqual:expected[@"metadata_sha256"]]) { rejected(error, @"Pinned metadata descriptor mismatch"); return nil; }
    NSDictionary *metadata = dm_profile_library_json(metadataData, error), *profile = dm_profile_library_json(profileData, error);
    if (!metadata || !profile) return nil;
    if (!fields(metadata, @[@"schema", @"profile", @"compiled", @"executed", @"renderer_qualified", @"provenance", @"provenance_id", @"artifacts", @"ledger", @"summary", @"native_execution", @"c1_execution"]) ||
        !fields(profile, @[@"profile", @"chain", @"keys", @"variants", @"compiled", @"artifacts", @"provenance", @"corpus", @"metadata_requirements", @"renderer_qualified"]) ||
        ![metadata[@"provenance"] isKindOfClass:NSDictionary.class] ||
        ![metadata[@"provenance"][@"inputs"] isKindOfClass:NSDictionary.class] ||
        ![profile[@"provenance"] isKindOfClass:NSDictionary.class] ||
        ![profile[@"provenance"][@"input"] isKindOfClass:NSDictionary.class] ||
        ![profile[@"artifacts"] isKindOfClass:NSDictionary.class] ||
        ![metadata[@"schema"] isEqual:@"d2r.simulator-profile-metadata.v1"] ||
        ![metadata[@"profile"] isEqual:expected[@"profile"]] || ![profile[@"profile"] isEqual:expected[@"profile"]] ||
        ![metadata[@"provenance_id"] isEqual:expected[@"metadata_id"]] ||
        ![profile[@"chain"] isEqual:expected[@"chain"]] ||
        ![metadata[@"provenance"][@"derived_chain"] isEqual:expected[@"chain"]] ||
        ![profile[@"compiled"] isEqual:@NO] || ![profile[@"renderer_qualified"] isEqual:@NO] ||
        ![profile[@"variants"] isEqual:@0] || ![metadata[@"compiled"] isEqual:@NO] ||
        ![metadata[@"executed"] isEqual:@NO] || ![metadata[@"renderer_qualified"] isEqual:@NO] ||
        ![file_identity(profileData) isEqual:metadata[@"provenance"][@"inputs"][@"shader_profile"]]) {
        rejected(error, @"Descriptor profile/chain/source-only relationship is invalid"); return nil;
    }
    NSArray *keys = profile[@"provenance"][@"input"][@"keys"];
    if ([keys isKindOfClass:NSArray.class]) for (id key in keys)
        if (!text(key, @"^[0-9a-f]{16}$")) { rejected(error, @"Malformed base-key inventory"); return nil; }
    if (![keys isKindOfClass:NSArray.class] || !keys.count || keys.count > 32768 ||
        ![profile[@"keys"] isEqual:@(keys.count)] ||
        ![metadata[@"provenance"][@"shader_keys"] isEqual:@(keys.count)] ||
        [NSSet setWithArray:keys].count != keys.count ||
        ![keys isEqual:[keys sortedArrayUsingSelector:@selector(compare:)]]) {
        rejected(error, @"Invalid complete base-key inventory"); return nil;
    }
    DmProfileLibraryPlan *plan = [self new]; plan.root = root;
    plan.chainDirectory = [@"msl/b-" stringByAppendingString:expected[@"chain"]];
    NSMutableDictionary *files = [NSMutableDictionary dictionary];
    files[@"dm/simulator-metadata-profile.json"] = file_identity(metadataData);
    files[@"dm/simulator-shader-profile.json"] = file_identity(profileData);
    if (!fields(metadata[@"artifacts"], @[@"shader_map.tsv", @"c1_full.tsv", @"pso_manifest.tsv"])) {
        rejected(error, @"Invalid metadata artifact set"); return nil;
    }
    for (NSString *name in metadata[@"artifacts"]) files[[@"dm/" stringByAppendingString:name]] = metadata[@"artifacts"][name];
    NSMutableArray *items = [NSMutableArray array];
    uint64_t sourceBytes = 0;
    for (NSString *key in keys) {
        NSError *rowError = nil; NSDictionary *item = nil;
        @autoreleasepool {
            item = library_item(key, expected[@"chain"], profile, root, files, inventoryDeadline, &sourceBytes, &rowError);
        }
        if (!item) { if (error) *error = rowError; return nil; }
        [items addObject:item];
    }
    plan.items = [items copy]; plan.files = [files copy];
    plan.identity = @{@"profile": expected[@"profile"], @"chain": expected[@"chain"],
                      @"metadata_sha256": expected[@"metadata_sha256"], @"metadata_id": expected[@"metadata_id"],
                      @"profile_sha256": dm_metal_sha256(profileData), @"compiler_source_sha256": expected[@"compiler_source_sha256"]};
    return [plan verifyUntil:inventoryDeadline error:error] ? plan : nil;
}
- (BOOL)verify:(NSError **)error {
    return [self verifyUntil:NSProcessInfo.processInfo.systemUptime + 120 error:error];
}
- (BOOL)verifyUntil:(double)deadline error:(NSError **)error {
    for (NSString *directory in @[@"msl", self.chainDirectory]) {
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:[self.root stringByAppendingPathComponent:directory] error:error];
        if (![attributes[NSFileType] isEqual:NSFileTypeDirectory]) return rejected(error, @"Shader inventory directory is missing or a symlink");
    }
    NSArray *roots = [NSFileManager.defaultManager contentsOfDirectoryAtPath:[self.root stringByAppendingPathComponent:@"msl"] error:error];
    if (!roots || ![[NSSet setWithArray:roots] isEqual:[NSSet setWithObject:self.chainDirectory.lastPathComponent]])
        return rejected(error, @"Unexpected shader chain inventory");
    NSArray *actual = [NSFileManager.defaultManager contentsOfDirectoryAtPath:[self.root stringByAppendingPathComponent:self.chainDirectory] error:error];
    NSMutableSet *expected = [NSMutableSet set];
    for (NSString *name in self.files) if ([name hasPrefix:@"msl/"]) [expected addObject:name.lastPathComponent];
    if (!actual || ![[NSSet setWithArray:actual] isEqual:expected]) return rejected(error, @"Unexpected/missing/BF shader artifact");
    for (NSString *name in self.files) {
        if (NSProcessInfo.processInfo.systemUptime >= deadline) return rejected(error, @"Inventory verification deadline exceeded");
        if (!bound([self.root stringByAppendingPathComponent:name], self.files[name], error)) return NO;
    }
    return NSProcessInfo.processInfo.systemUptime < deadline || rejected(error, @"Inventory verification deadline exceeded");
}
- (BOOL)verifyItem:(NSDictionary *)item error:(NSError **)error {
    return bound([self.root stringByAppendingPathComponent:item[@"source"]], item[@"source_identity"], error) &&
           bound([self.root stringByAppendingPathComponent:item[@"reflection"]], item[@"reflection_identity"], error);
}
- (NSDictionary *)scopeForDevice:(id<MTLDevice>)device {
    return @{@"profile": self.identity, @"os_build": NSProcessInfo.processInfo.operatingSystemVersionString,
             @"device": @{@"name": device.name, @"class": NSStringFromClass([device class]), @"registry_id": @(device.registryID),
                           @"argument_buffers_tier": @(device.argumentBuffersSupport)},
             @"compiler_contract": dm_metal_library_contract()};
}
@end

NSDictionary *dm_profile_library_expected(void) {
#if defined(DM_SIMULATOR_SOURCE_PROFILE) && defined(DM_METAL_LIBRARY_CONTRACT_SHA256)
    return @{@"profile": @DM_SIMULATOR_SOURCE_PROFILE, @"chain": @DM_SIMULATOR_SHADER_CHAIN,
             @"metadata_sha256": @DM_SIMULATOR_METADATA_SHA256, @"metadata_id": @DM_SIMULATOR_METADATA_ID,
             @"compiler_source_sha256": @DM_METAL_LIBRARY_CONTRACT_SHA256};
#else
    return nil;
#endif
}

BOOL dm_profile_library_receipt_complete(NSDictionary *receipt, DmProfileLibraryPlan *plan, NSDictionary *scope) {
    if (![receipt isKindOfClass:NSDictionary.class] || !plan || !scope) return NO;
    NSArray *names = @[@"schema", @"scope", @"library_compilation_only", @"renderer_qualified", @"native_layout_qualified", @"pso_qualified",
        @"tessellation_rendering_qualified", @"complete", @"expected", @"succeeded", @"failed", @"unattempted", @"limits",
        @"expected_count", @"succeeded_count", @"failed_count", @"unattempted_count", @"expected_inventory_sha256"];
    NSData *inventory = [NSJSONSerialization dataWithJSONObject:plan.items options:NSJSONWritingSortedKeys error:nil];
    NSDictionary *limits = receipt[@"limits"];
    if (!fields(limits, @[@"max_threads", @"active_worker_limit", @"batch_keys", @"whole_seconds", @"batch_seconds", @"key_seconds"])) return NO;
    for (NSString *name in limits) if (![limits[name] isKindOfClass:NSNumber.class] || !isfinite([limits[name] doubleValue])) return NO;
    if ([limits[@"max_threads"] unsignedIntegerValue] < 1 || [limits[@"max_threads"] unsignedIntegerValue] > 6 ||
        ![limits[@"active_worker_limit"] isEqual:@1] || ![limits[@"batch_keys"] isEqual:@64] ||
        [limits[@"whole_seconds"] doubleValue] <= 0 || [limits[@"whole_seconds"] doubleValue] > 3600 ||
        [limits[@"batch_seconds"] doubleValue] <= 0 || [limits[@"batch_seconds"] doubleValue] > [limits[@"whole_seconds"] doubleValue] ||
        [limits[@"key_seconds"] doubleValue] <= 0 || [limits[@"key_seconds"] doubleValue] > [limits[@"batch_seconds"] doubleValue]) return NO;
    if (!fields(receipt, names) || ![receipt[@"schema"] isEqual:@"d2r.profile-library-compilation.v1"] ||
        ![receipt[@"scope"] isEqual:scope] || ![receipt[@"complete"] isEqual:@YES] ||
        ![receipt[@"library_compilation_only"] isEqual:@YES] || ![receipt[@"renderer_qualified"] isEqual:@NO] ||
        ![receipt[@"native_layout_qualified"] isEqual:@NO] || ![receipt[@"pso_qualified"] isEqual:@NO] ||
        ![receipt[@"tessellation_rendering_qualified"] isEqual:@NO] ||
        ![receipt[@"expected_count"] isEqual:@(plan.items.count)] || ![receipt[@"succeeded_count"] isEqual:@(plan.items.count)] ||
        ![receipt[@"failed_count"] isEqual:@0] || ![receipt[@"unattempted_count"] isEqual:@0] ||
        ![receipt[@"expected_inventory_sha256"] isEqual:dm_metal_sha256(inventory)] ||
        ![receipt[@"expected"] isEqual:plan.items] || ![receipt[@"failed"] isEqual:@[]] || ![receipt[@"unattempted"] isEqual:@[]]) return NO;
    NSArray *succeeded = receipt[@"succeeded"];
    return [succeeded isKindOfClass:NSArray.class] && [succeeded isEqual:plan.items];
}

static NSDictionary *progress_receipt(NSDictionary *report) {
    NSMutableDictionary *progress = [report mutableCopy];
    for (NSString *name in @[@"expected", @"succeeded", @"unattempted"]) {
        progress[[name stringByAppendingString:@"_count"]] = @([report[name] count]);
        [progress removeObjectForKey:name];
    }
    return progress;
}

static BOOL before_deadline(double deadline, NSError **error) {
    return NSProcessInfo.processInfo.systemUptime < deadline || rejected(error, @"Batch/key/whole library deadline exceeded");
}
static NSDictionary *item_failure(NSDictionary *item, NSError *error) {
    return @{@"item": item, @"error_domain": error.domain, @"error_code": @(error.code), @"description": error.localizedDescription};
}
static void update_progress(NSMutableDictionary *report, NSArray *success, NSArray *failed, NSArray *items, NSUInteger next) {
    report[@"succeeded"] = [success copy]; report[@"failed"] = [failed copy];
    report[@"succeeded_count"] = @(success.count); report[@"failed_count"] = @(failed.count);
    report[@"unattempted"] = [items subarrayWithRange:NSMakeRange(next, items.count - next)];
    report[@"unattempted_count"] = @(items.count - next);
}

NSDictionary *dm_profile_library_run(DmProfileLibraryPlan *plan, id<MTLDevice> device, NSUInteger threads,
                                     NSTimeInterval wholeSeconds, NSTimeInterval batchSeconds, NSTimeInterval keySeconds,
                                     BOOL (^checkpoint)(NSDictionary *), NSError **error) {
    double entered = NSProcessInfo.processInfo.systemUptime;
    if (!plan || !device || !checkpoint || !threads || threads > 6 || !isfinite(wholeSeconds) || wholeSeconds <= 0 || wholeSeconds > 3600 ||
        !isfinite(batchSeconds) || batchSeconds <= 0 || batchSeconds > wholeSeconds ||
        !isfinite(keySeconds) || keySeconds <= 0 || keySeconds > batchSeconds) {
        rejected(error, @"Invalid bounded profile compilation request"); return nil;
    }
    double wholeDeadline = entered + wholeSeconds;
    if (![plan verifyUntil:MIN(wholeDeadline, NSProcessInfo.processInfo.systemUptime + 120) error:error] ||
        !before_deadline(wholeDeadline, error)) return nil;
    NSMutableDictionary *report = [@{@"schema": @"d2r.profile-library-compilation.v1", @"scope": [plan scopeForDevice:device],
        @"library_compilation_only": @YES, @"renderer_qualified": @NO, @"native_layout_qualified": @NO,
        @"pso_qualified": @NO, @"tessellation_rendering_qualified": @NO, @"complete": @NO,
        @"expected": plan.items, @"succeeded": @[], @"failed": @[], @"unattempted": plan.items,
        @"expected_count": @(plan.items.count), @"succeeded_count": @0, @"failed_count": @0, @"unattempted_count": @(plan.items.count),
        @"limits": @{@"max_threads": @(threads), @"active_worker_limit": @1, @"batch_keys": @64, @"whole_seconds": @(wholeSeconds),
                      @"batch_seconds": @(batchSeconds), @"key_seconds": @(keySeconds)}} mutableCopy];
    NSData *inventory = [NSJSONSerialization dataWithJSONObject:plan.items options:NSJSONWritingSortedKeys error:error];
    if (!inventory) return nil;
    report[@"expected_inventory_sha256"] = dm_metal_sha256(inventory);
    if (!before_deadline(wholeDeadline, error)) return nil;
    if (!checkpoint([report copy])) { rejected(error, @"Cannot persist expected library inventory"); return nil; }
    if (!before_deadline(wholeDeadline, error)) return nil;
    NSMutableArray *success = [NSMutableArray array], *failed = [NSMutableArray array];
    BOOL stopped = NO, persistenceFailed = NO; NSError *persistenceError = nil;
    double completionDeadline = wholeDeadline;
    for (NSUInteger offset = 0; offset < plan.items.count && !stopped; offset += 64) {
        NSUInteger end = MIN(offset + 64, plan.items.count);
        double batchDeadline = MIN(wholeDeadline, NSProcessInfo.processInfo.systemUptime + batchSeconds);
        for (NSUInteger index = offset; index < end; index++) { @autoreleasepool {
            double keyDeadline = MIN(batchDeadline, NSProcessInfo.processInfo.systemUptime + keySeconds);
            completionDeadline = keyDeadline;
            NSDictionary *item = plan.items[index]; NSError *failure = nil; BOOL source = NO;
            report[@"pending"] = item; report[@"pending_phase"] = @"library";
            update_progress(report, success, failed, plan.items, index);
            if (!checkpoint(progress_receipt(report))) { rejected(&persistenceError, @"Cannot persist pending library checkpoint"); persistenceFailed = YES; break; }
            id<MTLLibrary> library = before_deadline(keyDeadline, &failure) && [plan verifyItem:item error:&failure] &&
                before_deadline(keyDeadline, &failure) ?
                dm_metal_library_load_until(device, [plan.root stringByAppendingPathComponent:item[@"source"]],
                                            DmMetalLibrarySource, keyDeadline, &source, &failure) : nil;
            MTLFunctionType kind = [item[@"entry_kind"] isEqual:@"vertex"] ? MTLFunctionTypeVertex :
                [item[@"entry_kind"] isEqual:@"fragment"] ? MTLFunctionTypeFragment : MTLFunctionTypeKernel;
            id<MTLFunction> function = nil;
            if (library && before_deadline(keyDeadline, &failure)) {
                report[@"pending_phase"] = @"named-function";
                if (!checkpoint(progress_receipt(report))) { rejected(&persistenceError, @"Cannot persist named-function checkpoint"); persistenceFailed = YES; break; }
                if (before_deadline(keyDeadline, &failure))
                    function = dm_metal_library_function_until(library, item[@"entry"], kind, keyDeadline, &failure);
            }
            BOOL accepted = function && before_deadline(keyDeadline, &failure) && [plan verifyItem:item error:&failure] &&
                before_deadline(keyDeadline, &failure);
            // Checkpoints are provisional. A slow persistence callback must finish
            // within the same key deadline before its result can become a success.
            report[@"pending_phase"] = accepted ? @"verified" : @"failed";
            if (!accepted) {
                if (!failure) rejected(&failure, @"Library operation returned no result");
                [failed addObject:item_failure(item, failure)];
                update_progress(report, success, failed, plan.items, index + 1);
            }
            if (!checkpoint(progress_receipt(report))) { rejected(&persistenceError, @"Cannot persist library result checkpoint"); persistenceFailed = YES; break; }
            if (accepted && !before_deadline(keyDeadline, &failure)) {
                accepted = NO; [failed addObject:item_failure(item, failure)];
            }
            if (accepted) [success addObject:item]; else stopped = YES;
            update_progress(report, success, failed, plan.items, index + 1);
            [report removeObjectForKey:@"pending"]; [report removeObjectForKey:@"pending_phase"];
            if (stopped) break;
        }}
        if (persistenceFailed) { if (error) *error = persistenceError; return nil; }
    }
    // Completion is returned only after the final provisional checkpoint, input
    // hashes and the last key/batch/whole boundary all succeed. Failure receipts
    // may still be persisted within the whole-run budget.
    double finalDeadline = failed.count ? wholeDeadline : completionDeadline;
    if (!before_deadline(finalDeadline, error)) return nil;
    if (!checkpoint([report copy])) { rejected(error, @"Cannot persist final library checkpoint"); return nil; }
    if (!before_deadline(finalDeadline, error)) return nil;
    BOOL inputs = [plan verifyUntil:MIN(finalDeadline, NSProcessInfo.processInfo.systemUptime + 120) error:error];
    if (!before_deadline(finalDeadline, error)) return nil;
    report[@"complete"] = @(inputs && !failed.count && success.count == plan.items.count);
    return report;
}
