#ifdef DM_SHELL
#import <Metal/Metal.h>
#import <UIKit/UIKit.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include "dm_profile_libraries.h"
#include "../../gfx/nvn/dm_metal_library.h"

static void pl(NSString *s) { fprintf(stderr, "[dm] %s\n", s.UTF8String); }
static int lg(void) { NSString *l = NSLocale.preferredLanguages.firstObject; return [l hasPrefix:@"zh"] ? 1 : [l hasPrefix:@"es"] ? 2 : 0; }
#define L3(zh, en, es) (lg() == 1 ? (zh) : lg() == 2 ? (es) : (en))

@interface DmLibraryProgress : NSObject
@property(strong) UIView *view;
@property(strong) UILabel *label;
@property(strong) UIProgressView *bar;
@end
@implementation DmLibraryProgress @end

static DmLibraryProgress *progress_view(void) {
    UIWindow *win = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) if ([s isKindOfClass:UIWindowScene.class]) for (UIWindow *w in ((UIWindowScene *)s).windows) if (!win || w.isKeyWindow) win = w;
    UIView *host = win.rootViewController.view ?: win; if (!host) { pl(@"【红】着色器准备：没有窗口可放进度页，跳过（进游戏后会边玩边编，第一次进新场景会顿）"); return nil; }
    UIView *v = [[UIView alloc] initWithFrame:host.bounds]; v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight; v.backgroundColor = UIColor.blackColor;
    UILabel *title = [UILabel new], *sub = [UILabel new], *note = [UILabel new]; UIProgressView *bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    for (UILabel *l in @[title, sub, note]) { l.textColor = [UIColor colorWithWhite:0.85 alpha:1]; l.textAlignment = NSTextAlignmentCenter; l.numberOfLines = 0; l.translatesAutoresizingMaskIntoConstraints = NO; [v addSubview:l]; }
    title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold]; sub.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightRegular]; note.font = [UIFont systemFontOfSize:13]; note.textColor = [UIColor colorWithWhite:0.6 alpha:1];
    bar.translatesAutoresizingMaskIntoConstraints = NO; bar.progressTintColor = [UIColor colorWithRed:0.78 green:0.36 blue:0.16 alpha:1]; [v addSubview:bar];
    title.text = L3(@"首次启动：正在准备着色器", @"First launch: preparing shaders", @"Primer inicio: preparando los shaders");
    [NSLayoutConstraint activateConstraints:@[
        [title.centerXAnchor constraintEqualToAnchor:v.centerXAnchor], [title.bottomAnchor constraintEqualToAnchor:bar.topAnchor constant:-22],
        [bar.centerXAnchor constraintEqualToAnchor:v.centerXAnchor], [bar.centerYAnchor constraintEqualToAnchor:v.centerYAnchor], [bar.widthAnchor constraintEqualToAnchor:v.widthAnchor multiplier:0.5],
        [sub.centerXAnchor constraintEqualToAnchor:v.centerXAnchor], [sub.topAnchor constraintEqualToAnchor:bar.bottomAnchor constant:14],
        [note.centerXAnchor constraintEqualToAnchor:v.centerXAnchor], [note.topAnchor constraintEqualToAnchor:sub.bottomAnchor constant:22], [note.widthAnchor constraintLessThanOrEqualToAnchor:v.widthAnchor multiplier:0.8]]];
    note.text = L3(@"准备过程可能需要几分钟。", @"Preparation may take a few minutes.", @"La preparación puede tardar unos minutos.");
    [host addSubview:v];
    UIApplication.sharedApplication.idleTimerDisabled = YES;   // 这几分钟别自动锁屏 | do not auto-lock the screen during these few minutes
    DmLibraryProgress *progress = [DmLibraryProgress new];
    progress.view = v; progress.label = sub; progress.bar = bar;
    return progress;
}
static void progress_status(DmLibraryProgress *progress, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        progress.label.text = message; UIApplication.sharedApplication.idleTimerDisabled = NO;
    });
}
static NSString *receipt_path(NSDictionary *scope, NSString *kind) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:scope options:NSJSONWritingSortedKeys error:&error];
    if (!data) { pl(error.localizedDescription); return nil; }
    NSString *cache = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return [cache stringByAppendingPathComponent:[NSString stringWithFormat:@"dm_library_%@_%@.json", kind, dm_metal_sha256(data)]];
}
static BOOL persist(NSDictionary *receipt, NSString *path, NSError **error) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:receipt options:NSJSONWritingSortedKeys error:error];
    return data && [data writeToFile:path options:NSDataWritingAtomic error:error];
}
static NSDictionary *read_receipt(NSString *path, NSError **error) {
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (!data) return nil;
    return dm_profile_library_json(data, error);
}

static int profile_preparation(void) {
    DmLibraryProgress *progress = progress_view();
    if (!progress) { pl(@"No window for strict profile preparation"); return 1; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ @autoreleasepool {
        NSError *error = nil; DmProfileLibraryPlan *plan = nil;
        @autoreleasepool {
            plan = [DmProfileLibraryPlan loadRoot:NSBundle.mainBundle.resourcePath expected:dm_profile_library_expected() error:&error];
        }
        if (!plan) {
            pl(error.localizedDescription);
            progress_status(progress, L3(@"资源检查失败，无法继续。", @"Resource verification failed.", @"La verificación falló."));
            return;
        }
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { progress_status(progress, @"Metal device unavailable"); return; }
        NSDictionary *scope = [plan scopeForDevice:device];
        NSString *marker = receipt_path(scope, @"profile");
        if (!marker) { progress_status(progress, @"Cannot identify library preparation"); return; }
        if ([NSFileManager.defaultManager fileExistsAtPath:marker]) {
            NSDictionary *previous = read_receipt(marker, &error);
            if (!dm_profile_library_receipt_complete(previous, plan, scope) || ![plan verify:&error]) {
                pl(error ? error.localizedDescription : @"Invalid library-only completion receipt");
                progress_status(progress, @"Library completion receipt is invalid"); return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{ progress.bar.progress = 1; });
            progress_status(progress, L3(@"着色器库已准备；图形验证尚未完成。", @"Libraries prepared; renderer validation remains pending.", @"Bibliotecas listas; falta validar el renderizador."));
            return;
        }
        NSError *failure = nil;
        NSDictionary *receipt = dm_profile_library_run(plan, device, 1, 1800, 120, 30, ^BOOL(NSDictionary *detail) {
            dispatch_async(dispatch_get_main_queue(), ^{
                progress.bar.progress = [detail[@"succeeded_count"] floatValue] / (float)plan.items.count;
                progress.label.text = [NSString stringWithFormat:@"%@ / %lu", detail[@"succeeded_count"], (unsigned long)plan.items.count];
            });
            NSError *writeError = nil;
            BOOL written = persist(detail, [marker stringByAppendingString:@".partial"], &writeError);
            if (!written) pl(writeError.localizedDescription);
            return written;
        }, &failure);
        BOOL complete = receipt && dm_profile_library_receipt_complete(receipt, plan, scope);
        if (complete) complete = persist(receipt, marker, &failure);
        if (!complete) {
            if (failure) pl(failure.localizedDescription);
            progress_status(progress, L3(@"着色器准备失败，无法继续。", @"Library preparation failed.", @"La preparación falló."));
        } else progress_status(progress, L3(@"着色器库已准备；图形验证尚未完成。", @"Libraries prepared; renderer validation remains pending.", @"Bibliotecas listas; falta validar el renderizador."));
    }});
    // Library completion cannot admit the original application: native argument
    // and PSO preparation have independent, still-unqualified contracts.
    return 1;
}

static int legacy_preparation(void (^done)(void)) {
    NSString *msl = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"msl"];
    NSArray *directories = [NSFileManager.defaultManager contentsOfDirectoryAtPath:msl error:nil];
    NSString *directory = nil;
    for (NSString *name in directories) if ([name hasPrefix:@"b-"]) { directory = [msl stringByAppendingPathComponent:name]; break; }
    if (!directory) return 0;
    NSMutableArray *sources = [NSMutableArray array];
    NSError *error = nil;
    NSArray *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:&error];
    if (!names) { DmLibraryProgress *page = progress_view(); progress_status(page, error.localizedDescription); return 1; }
    for (NSString *name in [names sortedArrayUsingSelector:@selector(compare:)]) {
        if (![name hasSuffix:@".metallib"]) continue;
        NSString *path = [directory stringByAppendingPathComponent:name];
        FILE *file = fopen(path.fileSystemRepresentation, "rb");
        if (!file) { DmLibraryProgress *page = progress_view(); progress_status(page, @"Cannot inspect shader library"); return 1; }
        char header[4] = {0}; size_t length = fread(header, 1, sizeof header, file); BOOL unreadable = ferror(file); fclose(file);
        if (unreadable) { DmLibraryProgress *page = progress_view(); progress_status(page, @"Cannot read shader library"); return 1; }
        if (length == 4 && !memcmp(header, "MTLB", 4)) continue;
        [sources addObject:path];
    }
    if (!sources.count) return 0;
    DmLibraryProgress *progress = progress_view(); if (!progress) return 1;
    const char *override = getenv("DM_SHADER_PREP_THREADS");
    if (override && (strlen(override) != 1 || override[0] < '1' || override[0] > '6')) {
        progress_status(progress, @"DM_SHADER_PREP_THREADS must be 1 through 6"); return 1;
    }
    NSUInteger threads = override ? (NSUInteger)(override[0] - '0') : (NSUInteger)MAX(2, MIN(6, (NSInteger)NSProcessInfo.processInfo.activeProcessorCount - 2));
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ @autoreleasepool {
        NSMutableArray *expected = [NSMutableArray array];
        for (NSString *path in sources) { @autoreleasepool {
            NSError *failure = nil;
            NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:&failure];
            if (!data) { pl(failure.localizedDescription); progress_status(progress, @"Cannot identify shader source"); return; }
            [expected addObject:@{@"file": path.lastPathComponent, @"size": @(data.length), @"sha256": dm_metal_sha256(data)}];
        }}
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { progress_status(progress, @"Metal device unavailable"); return; }
        NSDictionary *scope = @{@"chain": directory.lastPathComponent, @"expected": expected,
            @"os_build": NSProcessInfo.processInfo.operatingSystemVersionString,
            @"device": @{@"name": device.name, @"registry_id": @(device.registryID)},
            @"compiler_contract": dm_metal_library_contract()};
        NSString *marker = receipt_path(scope, @"legacy"); if (!marker) return;
        if ([NSFileManager.defaultManager fileExistsAtPath:marker]) {
            NSError *failure = nil; NSDictionary *previous = read_receipt(marker, &failure);
            if (![previous[@"schema"] isEqual:@"d2r.legacy-library-compilation.v1"] ||
                ![previous[@"scope"] isEqual:scope] || ![previous[@"expected"] isEqual:expected] ||
                ![previous[@"succeeded"] isEqual:expected] || ![previous[@"failed"] isEqual:@[]] ||
                ![previous[@"unattempted"] isEqual:@[]] || ![previous[@"complete"] isEqual:@YES] ||
                ![previous[@"library_compilation_only"] isEqual:@YES] || ![previous[@"renderer_qualified"] isEqual:@NO]) {
                progress_status(progress, @"Library completion receipt is invalid"); return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{ [progress.view removeFromSuperview]; UIApplication.sharedApplication.idleTimerDisabled = NO; done(); });
            return;
        }
        NSMutableArray *succeeded = [NSMutableArray array], *failed = [NSMutableArray array];
        NSUInteger attempted = 0; double deadline = NSProcessInfo.processInfo.systemUptime + 1800;
        for (NSUInteger offset = 0; offset < sources.count && !failed.count; offset += threads) {
            if (NSProcessInfo.processInfo.systemUptime >= deadline) {
                [failed addObject:@{@"error": @"Whole preparation deadline exceeded"}]; break;
            }
            NSUInteger count = MIN(threads, sources.count - offset);
            dispatch_group_t group = dispatch_group_create(); NSLock *lock = [NSLock new];
            NSMutableDictionary *batch = [@{@"closed": @NO, @"outcomes": [NSMutableDictionary dictionary]} mutableCopy];
            for (NSUInteger local = 0; local < count; local++) {
                NSUInteger index = offset + local;
                dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ @autoreleasepool {
                    NSError *failure = nil; BOOL source = NO;
                    id<MTLLibrary> library = dm_metal_library_load(device, sources[index], DmMetalLibrarySource, 30, &source, &failure);
                    NSData *current = [NSData dataWithContentsOfFile:sources[index] options:NSDataReadingMappedIfSafe error:&failure];
                    NSDictionary *identity = current ? @{@"file": [sources[index] lastPathComponent], @"size": @(current.length), @"sha256": dm_metal_sha256(current)} : nil;
                    NSDictionary *outcome = library && [identity isEqual:expected[index]] ? @{@"item": identity, @"passed": @YES} :
                        @{@"item": expected[index], @"passed": @NO, @"error": failure ? failure.localizedDescription : @"Source changed or library missing"};
                    [lock lock]; if (![batch[@"closed"] boolValue]) batch[@"outcomes"][@(local)] = outcome; [lock unlock];
                }});
            }
            double left = MIN(35, deadline - NSProcessInfo.processInfo.systemUptime);
            long waited = left <= 0 ? 1 : dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(left * NSEC_PER_SEC)));
            [lock lock]; batch[@"closed"] = @YES; NSDictionary *outcomes = [batch[@"outcomes"] copy]; [lock unlock];
            for (NSUInteger local = 0; local < count; local++) {
                NSDictionary *outcome = outcomes[@(local)];
                if (!outcome || waited) [failed addObject:@{@"item": expected[offset + local], @"error": @"Bounded worker did not complete"}];
                else if ([outcome[@"passed"] boolValue]) [succeeded addObject:outcome[@"item"]];
                else [failed addObject:outcome];
            }
            attempted = offset + count;
            NSDictionary *partial = @{@"scope": scope, @"library_compilation_only": @YES, @"complete": @NO,
                @"expected": expected, @"succeeded": [succeeded copy], @"failed": [failed copy],
                @"unattempted": [expected subarrayWithRange:NSMakeRange(attempted, expected.count - attempted)]};
            NSError *writeError = nil;
            BOOL checkpoint = offset == 0 || attempted % 128 < threads || failed.count || attempted == sources.count;
            if (checkpoint && !persist(partial, [marker stringByAppendingString:@".partial"], &writeError)) {
                [failed addObject:@{@"error": writeError.localizedDescription}]; break;
            }
            dispatch_async(dispatch_get_main_queue(), ^{ progress.bar.progress = (float)attempted / sources.count; });
        }
        NSDictionary *receipt = @{@"schema": @"d2r.legacy-library-compilation.v1", @"scope": scope,
            @"expected": expected, @"succeeded": [succeeded copy], @"failed": [failed copy],
            @"unattempted": [expected subarrayWithRange:NSMakeRange(attempted, expected.count - attempted)],
            @"complete": @(!failed.count && succeeded.count == expected.count),
            @"library_compilation_only": @YES, @"renderer_qualified": @NO};
        NSError *failure = nil;
        if (!failed.count && succeeded.count == expected.count && persist(receipt, marker, &failure)) {
            dispatch_async(dispatch_get_main_queue(), ^{ [progress.view removeFromSuperview]; UIApplication.sharedApplication.idleTimerDisabled = NO; done(); });
        } else progress_status(progress, L3(@"着色器准备失败，无法继续。", @"Library preparation failed.", @"La preparación falló."));
    }});
    return 1;
}

int dm_shader_prep_begin(void (^done)(void)) {
#ifdef DM_SIMULATOR_SOURCE_PROFILE
    (void)done;
    return profile_preparation();
#else
    return legacy_preparation(done);
#endif
}
#endif
