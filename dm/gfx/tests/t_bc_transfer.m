#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdatomic.h>
#include "../nvn/nvn_bc_transfer.h"
#include "../tex/nvn_bcdec.h"

static _Atomic unsigned sourceDrops;
@interface BCBuffer : NSObject
@property(weak) id device;
@property NSUInteger length;
@property MTLStorageMode storageMode;
@property(strong) id heap;
@property BOOL source;
@property void *bytes;
@end
@implementation BCBuffer
- (void *)contents NS_RETURNS_INNER_POINTER { assert(!self.source); return self.bytes; }
- (void)dealloc { if (_source) atomic_fetch_add(&sourceDrops,1); free(_bytes); }
@end
@interface BCEvent : NSObject
@property(nonatomic) uint64_t signaledValue;
@property(strong) NSCondition *condition;
@property(strong) MTLSharedEventListener *listener;
@property(copy) MTLSharedEventNotificationBlock notification;
@end
@implementation BCEvent
- (instancetype)init { if ((self=[super init])) _condition=[NSCondition new]; return self; }
- (void)setSignaledValue:(uint64_t)value {
    [_condition lock]; _signaledValue=value; [_condition broadcast];
    MTLSharedEventNotificationBlock notification=self.notification; self.notification=nil;
    [_condition unlock];
    if (notification) dispatch_async(self.listener.dispatchQueue, ^{ notification((id)self,value); });
}
- (void)notifyListener:(MTLSharedEventListener *)listener atValue:(uint64_t)value block:(MTLSharedEventNotificationBlock)block {
    assert(value==1); self.listener=listener; self.notification=block;
}
- (void)wait { [_condition lock]; while (!_signaledValue) [_condition wait]; [_condition unlock]; }
@end
@interface BCTexture : NSObject
@property(weak) id device;
@property(strong) id heap;
@property MTLStorageMode storageMode;
@property MTLHazardTrackingMode hazardTrackingMode;
@property MTLPixelFormat pixelFormat;
@property MTLTextureType textureType;
@property NSUInteger width,height,depth,arrayLength,mipmapLevelCount,sampleCount;
@property(strong) NSMutableData *pixels;
@end
@implementation BCTexture @end
static NSUInteger pixel_offset(BCTexture *t,NSUInteger level,NSUInteger slice,MTLOrigin origin) {
    NSUInteger base=0,slices=t.arrayLength*((t.textureType==MTLTextureTypeCube || t.textureType==MTLTextureTypeCubeArray)?6:1);
    for(NSUInteger l=0;l<level;l++) base+=MAX(t.width>>l,1ul)*MAX(t.height>>l,1ul)*MAX(t.depth>>l,1ul)*slices*4;
    return base+((slice*MAX(t.depth>>level,1ul)+origin.z)*MAX(t.height>>level,1ul)*MAX(t.width>>level,1ul)+origin.y*MAX(t.width>>level,1ul)+origin.x)*4;
}
@class BCQueue;
@interface BCCommand : NSObject
@property(weak) id device;
@property BOOL retainedReferences;
@property MTLCommandBufferStatus status;
@property(strong) NSError *error;
@property(strong) NSMutableArray<dispatch_block_t> *operations;
@property(strong) NSMutableArray<MTLCommandBufferHandler> *handlers;
@property(strong) BCQueue *queue;
@end
@interface BCBlit : NSObject
@property(weak) BCCommand *command;
@end
@interface BCQueue : NSObject
@property(weak) id device;
@property dispatch_queue_t worker;
@property NSUInteger commits;
@property BOOL failGPU;
@end
@implementation BCQueue
- (instancetype)init { if ((self=[super init])) _worker=dispatch_queue_create("mock.bc.queue",DISPATCH_QUEUE_SERIAL); return self; }
- (id)commandBufferWithUnretainedReferences {
    BCCommand *command=[BCCommand new]; command.device=self.device; command.queue=self;
    command.operations=[NSMutableArray array]; command.handlers=[NSMutableArray array]; return command;
}
@end
@implementation BCCommand
- (void)encodeSignalEvent:(id)event value:(uint64_t)value { [self.operations addObject:^{ [(BCEvent *)event setSignaledValue:value]; }]; }
- (void)encodeWaitForEvent:(id)event value:(uint64_t)value { assert(value==1); [self.operations addObject:^{ [(BCEvent *)event wait]; }]; }
- (id)blitCommandEncoder { BCBlit *encoder=[BCBlit new]; encoder.command=self; return encoder; }
- (id)computeCommandEncoder { return [self blitCommandEncoder]; }
- (void)addCompletedHandler:(MTLCommandBufferHandler)handler { [self.handlers addObject:handler]; }
- (void)commit {
    self.status=MTLCommandBufferStatusCommitted; self.queue.commits++;
    dispatch_async(self.queue.worker, ^{
        @autoreleasepool {
            for (dispatch_block_t operation in self.operations) operation();
            [self.operations removeAllObjects]; self.status=self.queue.failGPU?MTLCommandBufferStatusError:MTLCommandBufferStatusCompleted;
            for (MTLCommandBufferHandler handler in self.handlers) handler((id)self);
            [self.handlers removeAllObjects];
        }
    });
}
@end
@implementation BCBlit
- (void)copyFromBuffer:(BCBuffer *)source sourceOffset:(NSUInteger)offset toBuffer:(BCBuffer *)destination destinationOffset:(NSUInteger)output size:(NSUInteger)size {
    assert(offset<=source.length && size<=source.length-offset && output<=destination.length && size<=destination.length-output);
    __unsafe_unretained BCBuffer *s=source,*d=destination;
    [self.command.operations addObject:^{ memcpy((uint8_t *)d.bytes+output,(uint8_t *)s.bytes+offset,size); }];
}
- (void)copyFromBuffer:(BCBuffer *)source sourceOffset:(NSUInteger)offset sourceBytesPerRow:(NSUInteger)row sourceBytesPerImage:(NSUInteger)image sourceSize:(MTLSize)size
             toTexture:(BCTexture *)destination destinationSlice:(NSUInteger)slice destinationLevel:(NSUInteger)level destinationOrigin:(MTLOrigin)origin {
    assert(image==row*size.height);
    __unsafe_unretained BCBuffer *s=source; __unsafe_unretained BCTexture *d=destination;
    [self.command.operations addObject:^{
        for(NSUInteger z=0;z<size.depth;z++) for(NSUInteger y=0;y<size.height;y++) {
            MTLOrigin at=MTLOriginMake(origin.x,origin.y+y,origin.z+z);
            NSUInteger target=pixel_offset(d,level,slice,at);assert(target+size.width*4<=d.pixels.length);
            memcpy((uint8_t *)d.pixels.mutableBytes+target,(uint8_t *)s.bytes+offset+z*image+y*row,size.width*4);
        }
    }];
}
- (void)endEncoding {}
@end
@interface BCDevice : NSObject
@property NSUInteger maxBufferLength,allocations;
@property BOOL failEvent;
@end
@implementation BCDevice
- (id)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options {
    assert(!(options&MTLResourceStorageModePrivate)); self.allocations++;
    BCBuffer *buffer=[BCBuffer new]; buffer.device=self; buffer.length=length; buffer.bytes=calloc(1,length); return buffer;
}
- (id)newSharedEvent { return self.failEvent?nil:[BCEvent new]; }
@end
// This suite does not initialize a Metal device or compile a GPU kernel.
int nvn_deswz_gpu_encode(id<MTLComputeCommandEncoder> e,id<MTLBuffer> s,uint64_t off,const nvn_texdesc *d,unsigned l,unsigned y,id<MTLBuffer> o,uint64_t oo,size_t row) {
    BCBlit *encoder=(id)e;__unsafe_unretained BCBuffer *source=(id)s,*output=(id)o;nvn_texdesc descriptor=*d;
    [encoder.command.operations addObject:^{ assert(!nvn_deswizzle(&descriptor,l,y,(uint8_t *)source.bytes+off,(uint8_t *)output.bytes+oo,row)); }];return 0;
}
static BCTexture *texture(BCDevice *device) {
    BCTexture *t=[BCTexture new]; t.device=device; t.textureType=MTLTextureType2D; t.pixelFormat=MTLPixelFormatRGBA8Unorm;
    t.width=7;t.height=5;t.depth=t.arrayLength=t.mipmapLevelCount=t.sampleCount=1;
    t.storageMode=MTLStorageModePrivate; t.hazardTrackingMode=MTLHazardTrackingModeTracked;
    t.pixels=[NSMutableData dataWithLength:7*5*4]; return t;
}
int main(int argc,const char *argv[]) {
    assert(argc==1 || (argc==2 && (!strcmp(argv[1],"--fail-read") || !strcmp(argv[1],"--fail-upload"))));
    @autoreleasepool {
        NvnBCRegion region={.width=7,.height=5,.depth=1,.sourceRow=24,.sourceImage=48}; NvnBCGeometry g;
        assert(!nvn_bc_geometry(0x41,&region,&g) && g.row==16 && g.rows==2 && g.sourceExtent==40 && g.inputBytes==32 && g.uploadRow==256 && g.uploadBytes==1280);
        NvnBCRegion bad=region; bad.sourceRow=15; assert(nvn_bc_geometry(0x41,&bad,&g)==NvnBCInvalid);
        bad=region;bad.sourceImage=40;assert(nvn_bc_geometry(0x41,&bad,&g)==NvnBCInvalid);
        bad=region;bad.sourceOffset=1;assert(nvn_bc_geometry(0x41,&bad,&g)==NvnBCInvalid);
        bad=region;bad.width=0;assert(nvn_bc_geometry(0x41,&bad,&g)==NvnBCInvalid);
        bad=region;bad.depth=2049;assert(nvn_bc_geometry(0x41,&bad,&g)==NvnBCInvalid);
        bad=region;bad.sourceRow=NSUIntegerMax-3;assert(nvn_bc_geometry(0x41,&bad,&g)==NvnBCInvalid);
        assert(nvn_bc_geometry(0,&region,&g)==NvnBCInvalid);
        BCDevice *device=[BCDevice new];device.maxBufferLength=1<<20;
        BCQueue *main=[BCQueue new],*reader=[BCQueue new],*uploader=[BCQueue new];main.device=reader.device=uploader.device=device;
        if (argc==2) { reader.failGPU=!strcmp(argv[1],"--fail-read");uploader.failGPU=!strcmp(argv[1],"--fail-upload"); }
        assert(![[NvnBCTransfers alloc] initWithDevice:(id)device readbackQueue:(id)reader uploadQueue:(id)reader byteBudget:4096 jobBudget:2]);
        NvnBCTransfers *transfers=[[NvnBCTransfers alloc] initWithDevice:(id)device readbackQueue:(id)reader uploadQueue:(id)uploader byteBudget:2624 jobBudget:2]; assert(transfers);
        BCCommand *command=[main commandBufferWithUnretainedReferences];command.retainedReferences=YES;
        BCTexture *first=texture(device),*second=texture(device);
        __weak BCBuffer *weakSource;
        @autoreleasepool {
            BCBuffer *source=[device newBufferWithLength:48 options:0]; source.source=YES;weakSource=source;
            assert(![transfers encodeCommand:(id)command source:(id)source offset:0 length:40 format:0x41 regions:&region count:1 packaged:NULL destination:(id)first]);
            assert(![transfers encodeCommand:(id)command source:(id)source offset:0 length:40 format:0x41 regions:&region count:1 packaged:NULL destination:(id)second]);
            assert(transfers.pendingJobs==2 && transfers.reservedBytes==2624 && transfers.allocatedBytes==0 && device.allocations==1);
            assert([transfers encodeCommand:(id)command source:(id)source offset:0 length:40 format:0x41 regions:&region count:1 packaged:NULL destination:(id)second]==NvnBCCapacity);
            // Mutation AFTER admission models an execution-time producer. The
            // adapter must not inspect source.contents or capture old block bytes.
            uint8_t *bytes=source.bytes;
            for (unsigned y=0;y<2;y++) for(unsigned x=0;x<2;x++) { uint8_t *block=bytes+y*24+x*8; block[0]=0;block[1]=0xf8; }
            source=nil;
        }
        assert(weakSource && !atomic_load(&sourceDrops));
        dispatch_semaphore_t completed=dispatch_semaphore_create(0);
        [command addCompletedHandler:^(id<MTLCommandBuffer> cb) { (void)cb;
            assert(!weakSource && atomic_load(&sourceDrops)==1 && transfers.pendingJobs==0 && transfers.reservedBytes==0 && transfers.allocatedBytes==0);
            dispatch_semaphore_signal(completed);
        }];
        [command commit]; assert(!dispatch_semaphore_wait(completed,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)));
        assert(transfers.completedJobs==2 && transfers.peakAllocatedBytes==1312 && reader.commits==2 && uploader.commits==2);
        for (BCTexture *t in @[first,second]) { const uint8_t *p=t.pixels.bytes; for(unsigned i=0;i<35;i++) assert(p[i*4]==255 && !p[i*4+1] && !p[i*4+2] && p[i*4+3]==255); }
        BCCommand *next=[main commandBufferWithUnretainedReferences]; next.retainedReferences=YES;
        BCBuffer *source=[device newBufferWithLength:48 options:0];source.source=YES;
        NSUInteger operations=next.operations.count;
        assert([transfers encodeCommand:(id)next source:(id)source offset:0 length:39 format:0x41 regions:&region count:1 packaged:NULL destination:(id)first]==NvnBCInvalid);
        first.pixelFormat=MTLPixelFormatRGBA8Unorm_sRGB;
        assert([transfers encodeCommand:(id)next source:(id)source offset:0 length:40 format:0x41 regions:&region count:1 packaged:NULL destination:(id)first]==NvnBCInvalid);
        first.pixelFormat=MTLPixelFormatRGBA8Unorm;source.heap=[NSObject new];
        assert([transfers encodeCommand:(id)next source:(id)source offset:0 length:40 format:0x41 regions:&region count:1 packaged:NULL destination:(id)first]==NvnBCInvalid);source.heap=nil;
        next.retainedReferences=NO;
        assert([transfers encodeCommand:(id)next source:(id)source offset:0 length:40 format:0x41 regions:&region count:1 packaged:NULL destination:(id)first]==NvnBCInvalid);next.retainedReferences=YES;
        device.failEvent=YES;
        assert([transfers encodeCommand:(id)next source:(id)source offset:0 length:40 format:0x41 regions:&region count:1 packaged:NULL destination:(id)first]==NvnBCAllocation);
        assert(next.operations.count==operations && !transfers.reservedBytes && !transfers.pendingJobs);
        device.failEvent=NO;
        NvnBCTransfers *packaged=[[NvnBCTransfers alloc] initWithDevice:(id)device readbackQueue:(id)reader uploadQueue:(id)uploader byteBudget:65536 jobBudget:2];
        for(unsigned kind=0;kind<3;kind++) {
            nvn_texdesc desc={.target=kind==0?2:kind==1?4:8,.format=0x41,.width=7,.height=5,.depth=kind==0?3:kind==1?2:1,.levels=2};
            nvn_texlayout layout;nvn_tex_layout(&desc,&layout);assert(layout.size);
            BCTexture *target=texture(device);target.textureType=kind==0?MTLTextureType3D:kind==1?MTLTextureType2DArray:MTLTextureTypeCube;
            target.depth=kind==0?3:1;target.arrayLength=kind==1?2:1;target.mipmapLevelCount=2;
            target.pixels=[NSMutableData dataWithLength:4096];
            BCBuffer *raw=[device newBufferWithLength:layout.size+4 options:0];raw.source=YES;
            NvnBCRegion regions[12];NSUInteger count=0;
            for(unsigned level=0;level<2;level++) for(unsigned layer=0;layer<layout.layers;layer++) {
                unsigned w=MAX(7u>>level,1u),h=MAX(5u>>level,1u),depth=kind==0?MAX(3u>>level,1u):1;
                NSUInteger row=((w+3)/4)*8,image=row*((h+3)/4);uint8_t block[8]={0};
                uint16_t color=(level+layer)%2?0x07e0:0xf800;memcpy(block,&color,2);
                NSMutableData *linear=[NSMutableData dataWithLength:image*depth];
                for(NSUInteger at=0;at<linear.length;at+=8)memcpy((uint8_t *)linear.mutableBytes+at,block,8);
                assert(!nvn_swizzle(&desc,level,layer,linear.bytes,row,(uint8_t *)raw.bytes+4));
                regions[count++]=(NvnBCRegion){.width=w,.height=h,.depth=depth,.sourceRow=row,.sourceImage=image,.level=level,.slice=kind==0?0:layer,.sourceLevel=level,.sourceLayer=layer};
            }
            BCCommand *c=[main commandBufferWithUnretainedReferences];c.retainedReferences=YES;
            NvnBCRegion invalid=regions[0];invalid.width--;
            assert([packaged encodeCommand:(id)c source:(id)raw offset:4 length:layout.size format:0x41 regions:&invalid count:1 packaged:&desc destination:(id)target]==NvnBCInvalid);
            assert(![packaged encodeCommand:(id)c source:(id)raw offset:4 length:layout.size format:0x41 regions:regions count:count packaged:&desc destination:(id)target]);
            dispatch_semaphore_t done=dispatch_semaphore_create(0);[c addCompletedHandler:^(id<MTLCommandBuffer> cb){(void)cb;dispatch_semaphore_signal(done);}];
            [c commit];assert(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)));
            assert(!packaged.pendingJobs && !packaged.reservedBytes && !packaged.allocatedBytes);
            for(NSUInteger i=0;i<count;i++)for(unsigned z=0;z<regions[i].depth;z++)for(unsigned y=0;y<regions[i].height;y++)for(unsigned x=0;x<regions[i].width;x++) {
                NSUInteger at=pixel_offset(target,regions[i].level,regions[i].slice,MTLOriginMake(x,y,z));const uint8_t *pixel=(const uint8_t *)target.pixels.bytes+at;
                unsigned green=(regions[i].level+regions[i].slice)%2;assert(pixel[0]==(green?0:255) && pixel[1]==(green?255:0) && !pixel[2] && pixel[3]==255);
            }
        }
        puts("BC transfer production orchestration passed: deferred staging, two independent queues, owned source, full spans, budgets and retirement (CPU mock only)");
    }
}
