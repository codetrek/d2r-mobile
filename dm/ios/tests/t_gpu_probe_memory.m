#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdarg.h>
#include "../Sources/dm_gpu_probe.m"

void plog(const char *format, ...) { (void)format; }

int main(void) {
    @autoreleasepool {
        for (int kind = BackingMalloc; kind <= BackingShared; kind++) {
            NSMutableDictionary *detail = [NSMutableDictionary dictionary];
            DmGpuMemory *owner = allocate_memory((enum Backing)kind, detail);
            assert(owner && owner.length == 0x4000);
            assert([detail[@"region"][@"query_code"] intValue] == KERN_SUCCESS);
            assert([detail[@"region"][@"page_aligned"] boolValue]);
            assert(((uint32_t *)owner.pointer)[0] == 1 && ((uint32_t *)owner.pointer)[63] == 64);
        }
        NSMutableDictionary *leftDetail = [NSMutableDictionary dictionary], *rightDetail = [NSMutableDictionary dictionary];
        DmGpuMemory *left = allocate_memory(BackingShared, leftDetail), *right = allocate_memory(BackingVM, rightDetail);
        assert(left && right);
        vm_address_t target = (vm_address_t)right.pointer;
        vm_prot_t current = 0, maximum = 0;
        kern_return_t code = vm_remap(mach_task_self(), &target, right.length, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
                                      mach_task_self(), (vm_address_t)left.pointer, FALSE, &current, &maximum, VM_INHERIT_NONE);
        assert(code == KERN_SUCCESS && target == (vm_address_t)right.pointer);
        assert((current & (VM_PROT_READ | VM_PROT_WRITE)) == (VM_PROT_READ | VM_PROT_WRITE));
        ((uint32_t *)right.pointer)[0] = 0x17283940;
        assert(((uint32_t *)left.pointer)[0] == 0x17283940);
        __weak DmGpuMemory *weak;
        void (^completion)(void);
        @autoreleasepool {
            DmGpuMemory *kept = allocate_memory(BackingVM, [NSMutableDictionary dictionary]);
            weak = kept;
            completion = ^{ (void)kept.length; };
            kept = nil;
            assert(weak);
        }
        completion(); assert(weak); completion = nil; assert(!weak);
        puts("PASS gpu_probe_memory: malloc/VM/shared allocations, exact owned VM alias and completion lifetime; no Metal device or dispatch called");
    }
}
