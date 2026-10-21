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
        void *reserved = NULL; size_t page = vm_page_size;
        assert(dm_vm_reserve(8 * page, &reserved) == KERN_SUCCESS);
        DmGpuMemory *reservedOwner = [DmGpuMemory new];
        reservedOwner.pointer = reserved; reservedOwner.length = 8 * page; reservedOwner.backing = BackingVM;
        uint8_t *opened = (uint8_t *)reserved + page;
        assert(!dm_vm_change(&g_probe_leases, opened, 4 * page, PROT_READ | PROT_WRITE, 0));
        memset(opened, 0xCD, 4 * page);
        dm_vm_pool_region region;
        assert(dm_vm_pool_check(opened + 4096, page, &region) == KERN_SUCCESS);
        assert(region.base == (vm_address_t)opened && region.length == 2 * page);
        assert(dm_vm_pool_check(reserved, page, &region) == KERN_PROTECTION_FAILURE);
        assert(dm_vm_pool_check(opened, 0, &region) == KERN_INVALID_ARGUMENT);
        assert(dm_vm_pool_check((void *)UINTPTR_MAX, 1, &region) == KERN_INVALID_ARGUMENT);
        assert(dm_vm_pool_check(opened + 4096, page, &region) == KERN_SUCCESS);
        uint64_t lease;
        assert(dm_vm_lease_acquire(&g_probe_leases, region.base, region.length, &lease) == KERN_SUCCESS);
        reservedOwner->pool_lease = lease;
        assert(dm_vm_change(&g_probe_leases, opened, page, PROT_NONE, 1) == -1 && errno == EBUSY);
        assert(opened[0] == 0xCD && dm_vm_pool_check(opened, page, &region) == KERN_SUCCESS);
        // This CPU case creates no Metal buffer. Actual no-copy deallocator
        // ownership is checked by the separately launched protected-pool case.
        dm_vm_lease_retire(&reservedOwner->pool_lease, probe_lease_release);
        dm_vm_lease_retire(&reservedOwner->pool_lease, probe_lease_release);
        assert(g_probe_leases.count == 0);
        assert(!dm_vm_change(&g_probe_leases, opened, page, PROT_NONE, 1));
        assert(dm_vm_pool_check(opened, page, &region) == KERN_PROTECTION_FAILURE);
        assert(dm_vm_pool_check(opened, 2 * page, &region) != KERN_SUCCESS);
        assert(dm_vm_lease_release(&g_probe_leases, lease) == KERN_INVALID_ARGUMENT);
        assert(dm_vm_lease_acquire(&g_probe_leases, UINT64_MAX, 1, &lease) == KERN_INVALID_ARGUMENT);
        dm_vm_pool_leases bounded = {.next = 1}; uint64_t firstLease, secondLease;
        assert(dm_vm_lease_acquire(&bounded, 0x10000, 0x2000, &firstLease) == KERN_SUCCESS);
        assert(dm_vm_lease_acquire(&bounded, 0x11000, 0x2000, &secondLease) == KERN_SUCCESS);
        assert(dm_vm_lease_release(&bounded, firstLease) == KERN_SUCCESS);
        assert(dm_vm_lease_can_discard(&bounded, 0x11000, 0x1000) == KERN_PROTECTION_FAILURE);
        assert(dm_vm_lease_release(&bounded, secondLease) == KERN_SUCCESS);
        assert(dm_vm_lease_can_discard(&bounded, 0x11000, 0x1000) == KERN_SUCCESS);
        for (unsigned i = 0; i < DM_VM_POOL_LEASE_LIMIT; i++)
            assert(dm_vm_lease_acquire(&bounded, 0x10000 + 0x1000ull * i, 0x1000, &lease) == KERN_SUCCESS);
        assert(dm_vm_lease_acquire(&bounded, 0x10000, 0x1000, &lease) == KERN_RESOURCE_SHORTAGE);
        bounded = (dm_vm_pool_leases){.next = UINT64_MAX};
        assert(dm_vm_lease_acquire(&bounded, 0x10000, 0x1000, &lease) == KERN_RESOURCE_SHORTAGE);
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
        puts("PASS gpu_probe_memory: malloc/VM/shared, protected reservations/slices, lease-blocked discard and post-retirement unmap, owned alias/completion lifetime; no Metal device or dispatch called");
    }
}
