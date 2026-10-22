#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

@interface DmProfileLibraryPlan : NSObject
@property(readonly, strong) NSString *root;
@property(readonly, strong) NSArray<NSDictionary *> *items;
@property(readonly, strong) NSDictionary *identity;
+ (instancetype)loadRoot:(NSString *)root expected:(NSDictionary *)expected error:(NSError **)error;
- (BOOL)verify:(NSError **)error;
- (BOOL)verifyItem:(NSDictionary *)item error:(NSError **)error;
- (NSDictionary *)scopeForDevice:(id<MTLDevice>)device;
@end

NSDictionary *dm_profile_library_expected(void);
NSDictionary *dm_profile_library_json(NSData *data, NSError **error);
NSDictionary *dm_profile_library_run(DmProfileLibraryPlan *plan, id<MTLDevice> device,
                                     NSUInteger threads, NSTimeInterval wholeSeconds,
                                     NSTimeInterval batchSeconds, NSTimeInterval keySeconds,
                                     BOOL (^checkpoint)(NSDictionary *receipt), NSError **error);
BOOL dm_profile_library_receipt_complete(NSDictionary *receipt, DmProfileLibraryPlan *plan,
                                         NSDictionary *scope);
