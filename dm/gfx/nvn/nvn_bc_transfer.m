#import "nvn_bc_transfer.h"
#include "../tex/nvn_bcdec.h"
#include "../tex/nvn_deswizzle_gpu.h"
#include <pthread.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

static BOOL add_size(NSUInteger a, NSUInteger b, NSUInteger *out) { if (b > NSUIntegerMax-a) return NO; *out=a+b; return YES; }
static BOOL mul_size(NSUInteger a, NSUInteger b, NSUInteger *out) { if (a && b > NSUIntegerMax/a) return NO; *out=a*b; return YES; }
static BOOL align_size(NSUInteger n, NSUInteger *out) { if (n > NSUIntegerMax-255) return NO; *out=(n+255)&~(NSUInteger)255; return YES; }
NvnBCStatus nvn_bc_geometry(uint32_t format, const NvnBCRegion *r, NvnBCGeometry *out) {
    uint32_t pf; int bpp;
    if (!r || !out || !nvn_bc_unpacked(format,&pf,&bpp) || !r->width || !r->height || !r->depth ||
        r->width>16384 || r->height>16384 || r->depth>2048) return NvnBCInvalid;
    NvnBCGeometry g={0}; NSUInteger block=(format==0x41 || format==0x42 || format==0x45 || format==0x46 || format==0x49 || format==0x4a)?8:16;
    g.row=((NSUInteger)r->width+3)/4*block; g.rows=((NSUInteger)r->height+3)/4;
    if (!mul_size(g.row,g.rows,&g.image) || !mul_size(g.image,r->depth,&g.inputBytes) ||
        r->sourceRow<g.row || r->sourceRow%4 || r->sourceImage%4 || r->sourceOffset%4) return NvnBCInvalid;
    NSUInteger minimumImage, extent, n;
    if (!mul_size(r->sourceRow,g.rows,&minimumImage) || r->sourceImage<minimumImage ||
        !mul_size(r->sourceImage,r->depth-1,&extent) || !mul_size(r->sourceRow,g.rows-1,&n) ||
        !add_size(extent,n,&extent) || !add_size(extent,g.row,&g.sourceExtent) ||
        !mul_size(r->width,(NSUInteger)bpp,&n) || !align_size(n,&g.uploadRow) ||
        !mul_size(g.uploadRow,r->height,&g.uploadImage) || !mul_size(g.uploadImage,r->depth,&g.uploadBytes)) return NvnBCInvalid;
    *out=g; return NvnBCOK;
}

@interface NvnBCJob : NSObject
@property(strong) id<MTLBuffer> source, readback, upload;
@property(strong) id<MTLTexture> destination;
@property(strong) id<MTLSharedEvent> producer, done;
@property(strong) NSData *regions, *geometry;
@property NSUInteger offset, length, inputBytes, uploadBytes, charge;
@property uint32_t format;
@property BOOL packaged;
@property nvn_texdesc descriptor;
@end
@implementation NvnBCJob @end

@implementation NvnBCTransfers {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _reader, _uploader;
    MTLSharedEventListener *_listener;
    dispatch_queue_t _worker;
    pthread_mutex_t _lock;
    NSUInteger _byteBudget, _jobBudget, _pending, _reserved, _allocated, _peak, _completed;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device readbackQueue:(id<MTLCommandQueue>)reader uploadQueue:(id<MTLCommandQueue>)uploader byteBudget:(NSUInteger)bytes jobBudget:(NSUInteger)jobs {
    if (!device || !reader || !uploader || reader==uploader || reader.device!=device || uploader.device!=device || !bytes || !jobs) return nil;
    if ((self=[super init])) {
        _device=device; _reader=reader; _uploader=uploader; _byteBudget=bytes; _jobBudget=jobs;
        pthread_mutex_init(&_lock,NULL);
        _worker=dispatch_queue_create("org.d2rmobile.bc-transfer",DISPATCH_QUEUE_SERIAL);
        _listener=[[MTLSharedEventListener alloc] initWithDispatchQueue:_worker];
        if (!_listener) return nil;
    }
    return self;
}
- (void)dealloc { pthread_mutex_destroy(&_lock); }
#define STAT(name,field) - (NSUInteger)name { pthread_mutex_lock(&_lock); NSUInteger n=field; pthread_mutex_unlock(&_lock); return n; }
STAT(pendingJobs,_pending) STAT(reservedBytes,_reserved) STAT(allocatedBytes,_allocated) STAT(peakAllocatedBytes,_peak) STAT(completedJobs,_completed)
#undef STAT
- (void)fatal:(const char *)stage error:(NSError *)error {
    fprintf(stderr,"[dm] BC transfer failed at %s: %s\n",stage,error?error.description.UTF8String:"no API error");
    abort();
}
- (void)complete:(NvnBCJob *)job {
    // A command buffer with unretained references has no hidden resource graph.
    // Our explicit source ownership ends after readback; staging and destination
    // ownership end after upload, before publishing the consumer event.
    // https://developer.apple.com/documentation/metal/mtlcommandqueue/commandbufferwithunretainedreferences()
    id<MTLSharedEvent> done=job.done;
    @autoreleasepool {
        job.readback=nil; job.upload=nil; job.destination=nil; job.producer=nil; job.done=nil;
        pthread_mutex_lock(&_lock);
        _allocated-=job.charge; _reserved-=job.charge; _pending--; _completed++;
        pthread_mutex_unlock(&_lock);
    }
    done.signaledValue=1;
}
- (void)decodeAndUpload:(NvnBCJob *)job {
    @autoreleasepool {
        const NvnBCRegion *regions=job.regions.bytes; const NvnBCGeometry *g=job.geometry.bytes;
        NSUInteger count=job.regions.length/sizeof *regions;
        const uint8_t *input=job.readback.contents; uint8_t *output=job.upload.contents;
        if (!input || !output) [self fatal:"owned-staging-access" error:nil];
        memset(output,0,job.uploadBytes);
        for (NSUInteger i=0;i<count;i++) for (NSUInteger z=0;z<regions[i].depth;z++)
            if (nvn_bc_decode(job.format,input+g[i].inputOffset+z*g[i].image,g[i].row,regions[i].width,regions[i].height,
                              output+g[i].uploadOffset+z*g[i].uploadImage,g[i].uploadRow)) [self fatal:"decode" error:nil];
    }
    @autoreleasepool {
        id<MTLCommandBuffer> command=[_uploader commandBufferWithUnretainedReferences];
        id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
        if (!command || !blit) [self fatal:"upload-command" error:nil];
        const NvnBCRegion *regions=job.regions.bytes; const NvnBCGeometry *g=job.geometry.bytes;
        for (NSUInteger i=0;i<job.regions.length/sizeof *regions;i++) {
            BOOL volume=job.destination.textureType==MTLTextureType3D;
            for (NSUInteger z=0;z<(volume?1:regions[i].depth);z++) {
                MTLOrigin origin=regions[i].origin; if (volume) origin.z=regions[i].origin.z;
                [blit copyFromBuffer:job.upload sourceOffset:g[i].uploadOffset+z*g[i].uploadImage sourceBytesPerRow:g[i].uploadRow sourceBytesPerImage:g[i].uploadImage
                    sourceSize:MTLSizeMake(regions[i].width,regions[i].height,volume?regions[i].depth:1) toTexture:job.destination
                    destinationSlice:volume?0:regions[i].slice+z destinationLevel:regions[i].level destinationOrigin:origin];
            }
        }
        [blit endEncoding];
        [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            if (completed.status!=MTLCommandBufferStatusCompleted || completed.error) [self fatal:"upload-gpu" error:completed.error];
            dispatch_async(self->_worker, ^{ [self complete:job]; });
        }];
        [command commit];
    }
}
- (void)read:(NvnBCJob *)job {
    @autoreleasepool {
        job.readback=[_device newBufferWithLength:job.inputBytes options:MTLResourceStorageModeShared | MTLResourceHazardTrackingModeTracked];
        job.upload=[_device newBufferWithLength:job.uploadBytes options:MTLResourceStorageModeShared | MTLResourceHazardTrackingModeTracked];
        if (!job.readback || !job.upload) [self fatal:"deferred-staging-allocation" error:nil];
        pthread_mutex_lock(&_lock); _allocated+=job.charge; if (_allocated>_peak) _peak=_allocated; pthread_mutex_unlock(&_lock);
        id<MTLCommandBuffer> command=[_reader commandBufferWithUnretainedReferences];
        if (!command) [self fatal:"readback-command" error:nil];
        // CPU notification is not the resource visibility barrier. The reader also
        // waits on the producer event before touching the possibly untracked alias.
        [command encodeWaitForEvent:job.producer value:1];
        const NvnBCRegion *regions=job.regions.bytes; const NvnBCGeometry *g=job.geometry.bytes;
        if (job.packaged) {
            id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
            if (!encoder) [self fatal:"deswizzle-encoder" error:nil];
            for (NSUInteger i=0;i<job.regions.length/sizeof *regions;i++) {
                nvn_texdesc d=job.descriptor;
                if (nvn_deswz_gpu_encode(encoder,job.source,job.offset,&d,regions[i].sourceLevel,regions[i].sourceLayer,job.readback,g[i].inputOffset,g[i].row))
                    [self fatal:"deswizzle" error:nil];
            }
            [encoder endEncoding];
        } else {
            id<MTLBlitCommandEncoder> encoder=[command blitCommandEncoder];
            if (!encoder) [self fatal:"readback-encoder" error:nil];
            for (NSUInteger i=0;i<job.regions.length/sizeof *regions;i++) for (NSUInteger z=0;z<regions[i].depth;z++) for (NSUInteger y=0;y<g[i].rows;y++)
                [encoder copyFromBuffer:job.source sourceOffset:job.offset+regions[i].sourceOffset+z*regions[i].sourceImage+y*regions[i].sourceRow
                    toBuffer:job.readback destinationOffset:g[i].inputOffset+z*g[i].image+y*g[i].row size:g[i].row];
            [encoder endEncoding];
        }
        [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            if (completed.status!=MTLCommandBufferStatusCompleted || completed.error) [self fatal:"readback-gpu" error:completed.error];
            @autoreleasepool { job.source=nil; }
            dispatch_async(self->_worker, ^{ [self decodeAndUpload:job]; });
        }];
        [command commit];
    }
}
- (NvnBCStatus)encodeCommand:(id<MTLCommandBuffer>)command source:(id<MTLBuffer>)source offset:(NSUInteger)offset length:(NSUInteger)length
                     format:(uint32_t)format regions:(const NvnBCRegion *)regions count:(NSUInteger)count packaged:(const nvn_texdesc *)packaged destination:(id<MTLTexture>)destination {
    uint32_t pf; int bpp;
    if (!command || command.device!=_device || !command.retainedReferences || command.status>MTLCommandBufferStatusEnqueued ||
        !source || source.device!=_device || source.heap || !length || offset%4 || offset>source.length || length>source.length-offset ||
        !destination || destination.device!=_device || destination.heap || destination.storageMode!=MTLStorageModePrivate ||
        destination.hazardTrackingMode!=MTLHazardTrackingModeTracked || destination.sampleCount!=1 ||
        !nvn_bc_unpacked(format,&pf,&bpp) || destination.pixelFormat!=(MTLPixelFormat)pf ||
        !regions || !count || count>4096) return NvnBCInvalid;
    MTLTextureType type=destination.textureType;
    if (type!=MTLTextureType1D && type!=MTLTextureType1DArray && type!=MTLTextureType2D && type!=MTLTextureType2DArray &&
        type!=MTLTextureTypeCube && type!=MTLTextureTypeCubeArray && type!=MTLTextureType3D) return NvnBCUnsupported;
    nvn_texlayout layout={0};
    if (packaged) {
        if (!packaged->width || !packaged->height || !packaged->depth || packaged->width>16384 || packaged->height>16384 || packaged->depth>2048 ||
            packaged->levels>15 || packaged->pkg_block_h<0 || packaged->pkg_block_h>6 || packaged->format!=(int)format) return NvnBCInvalid;
        nvn_tex_layout(packaged,&layout);
        if (!layout.size || layout.size>length) return NvnBCInvalid;
    }
    NSMutableData *geometry=[NSMutableData dataWithLength:count*sizeof(NvnBCGeometry)];
    NvnBCGeometry *g=geometry.mutableBytes; NSUInteger input=0,upload=0;
    for (NSUInteger i=0;i<count;i++) {
        const NvnBCRegion *r=&regions[i]; NvnBCStatus status=nvn_bc_geometry(format,r,&g[i]); if (status) return status;
        if (r->level>=destination.mipmapLevelCount || r->level>=32) return NvnBCInvalid;
        NSUInteger w=MAX(destination.width>>r->level,1ul),h=MAX(destination.height>>r->level,1ul),z=MAX(destination.depth>>r->level,1ul);
        NSUInteger slices=destination.arrayLength*((type==MTLTextureTypeCube || type==MTLTextureTypeCubeArray)?6:1);
        if (r->origin.x>w || r->width>w-r->origin.x || r->origin.y>h || r->height>h-r->origin.y || r->origin.x%4 || r->origin.y%4 ||
            (r->width%4 && r->origin.x+r->width!=w) || (r->height%4 && r->origin.y+r->height!=h)) return NvnBCInvalid;
        if (type==MTLTextureType3D) { if (r->slice || r->origin.z>z || r->depth>z-r->origin.z) return NvnBCInvalid; }
        else if (r->origin.z || r->slice>slices || r->depth>slices-r->slice) return NvnBCInvalid;
        if (packaged) {
            uint32_t row,rows,depth,block; uint64_t base; unsigned th,td;
            if (r->sourceOffset || nvn_deswizzle_geom(packaged,r->sourceLevel,r->sourceLayer,&row,&rows,&depth,&base,&th,&td,&block) ||
                row!=g[i].row || rows!=g[i].rows || depth!=r->depth || th>5 || td>5 ||
                r->width!=MAX(packaged->width>>r->sourceLevel,1u) ||
                r->height!=((packaged->target==0 || packaged->target==3)?1:MAX(packaged->height>>r->sourceLevel,1u))) return NvnBCInvalid;
            // The GPU deswizzler uses the complete block-linear allocation, never a
            // guessed linear extent or a snapshot of caller-owned CPU memory.
            uint64_t last=base+nvn_bl_offset(row-1,rows-1,depth-1,row,rows,th,td);
            if (last>=layout.size) return NvnBCInvalid;
        } else if (r->sourceOffset>length || g[i].sourceExtent>length-r->sourceOffset) return NvnBCInvalid;
        g[i].inputOffset=input; g[i].uploadOffset=upload;
        if (!add_size(input,g[i].inputBytes,&input) || !add_size(upload,g[i].uploadBytes,&upload)) return NvnBCInvalid;
    }
    NSUInteger charge; if (!add_size(input,upload,&charge) || input>_device.maxBufferLength || upload>_device.maxBufferLength) return NvnBCCapacity;
    pthread_mutex_lock(&_lock);
    if (_pending==_jobBudget || charge>_byteBudget-_reserved) { pthread_mutex_unlock(&_lock); return NvnBCCapacity; }
    _pending++; _reserved+=charge; pthread_mutex_unlock(&_lock);
    NvnBCJob *job=[NvnBCJob new]; job.producer=[_device newSharedEvent]; job.done=[_device newSharedEvent];
    if (!job.producer || !job.done) {
        pthread_mutex_lock(&_lock); _pending--; _reserved-=charge; pthread_mutex_unlock(&_lock); return NvnBCAllocation;
    }
    job.source=source; job.offset=offset; job.length=length; job.destination=destination; job.format=format;
    job.regions=[NSData dataWithBytes:regions length:count*sizeof *regions]; job.geometry=geometry;
    job.inputBytes=input; job.uploadBytes=upload; job.charge=charge; job.packaged=packaged!=NULL; if (packaged) job.descriptor=*packaged;
    [job.producer notifyListener:_listener atValue:1 block:^(id<MTLSharedEvent> event,uint64_t value) { (void)event;(void)value; [self read:job]; }];
    [command encodeSignalEvent:job.producer value:1];
    [command encodeWaitForEvent:job.done value:1];
    return NvnBCOK;
}
@end
