#pragma once
#include <mach/mach.h>
#include <stdint.h>
#include <sys/mman.h>
#include <errno.h>
#include "dm_vm_leases.h"

typedef struct {
    vm_address_t base;
    vm_size_t length;
    vm_address_t region_base;
    vm_size_t region_length;
    vm_prot_t protection, maximum_protection;
    int shared;
} dm_vm_pool_region;

// The reservation keeps one VM allocation as the owner. Opening subranges and
// wrapping their pages does not replace neighboring live allocations.
static inline kern_return_t dm_vm_reserve(vm_size_t length, void **memory) {
    if (!length || !vm_page_size || length % vm_page_size) return KERN_INVALID_ARGUMENT;
    vm_address_t address = 0;
    kern_return_t code = vm_allocate(mach_task_self(), &address, length, VM_FLAGS_ANYWHERE);
    if (code != KERN_SUCCESS) return code;
    code = vm_protect(mach_task_self(), address, length, FALSE, VM_PROT_NONE);
    if (code != KERN_SUCCESS) {
        vm_deallocate(mach_task_self(), address, length);
        return code;
    }
    *memory = (void *)address;
    return KERN_SUCCESS;
}

static inline kern_return_t dm_vm_span_pages(const void *memory, uint64_t length, vm_address_t *base, vm_size_t *rounded) {
    uintptr_t page = vm_page_size, lo = (uintptr_t)memory;
    if (!page || (page & (page - 1)) || !memory || !length || length > UINTPTR_MAX - lo)
        return KERN_INVALID_ARGUMENT;
    uintptr_t hi = lo + length;
    if (hi > UINTPTR_MAX - (page - 1)) return KERN_INVALID_ARGUMENT;
    *base = lo & ~(page - 1);
    *rounded = ((hi + page - 1) & ~(page - 1)) - *base;
    return KERN_SUCCESS;
}

// Apple requires no-copy buffers to use aligned pages inside one VM region:
// https://developer.apple.com/documentation/metal/mtldevice/makebuffer(bytesnocopy:length:options:deallocator:)
static inline kern_return_t dm_vm_pool_check(const void *memory, uint64_t length, dm_vm_pool_region *out) {
    vm_address_t base; vm_size_t rounded;
    kern_return_t code = dm_vm_span_pages(memory, length, &base, &rounded);
    if (code != KERN_SUCCESS) return code;
    vm_address_t region = base; vm_size_t extent = 0;
    vm_region_basic_info_data_64_t info = {0};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    code = vm_region_64(mach_task_self(), &region, &extent, VM_REGION_BASIC_INFO_64,
                                      (vm_region_info_t)&info, &count, &object);
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    if (code != KERN_SUCCESS) return code;
    if (region > base || base - region > extent || rounded > extent - (base - region))
        return KERN_INVALID_ADDRESS;
    vm_prot_t access = VM_PROT_READ | VM_PROT_WRITE;
    if ((info.protection & access) != access) return KERN_PROTECTION_FAILURE;
    *out = (dm_vm_pool_region){base, rounded, region, extent, info.protection, info.max_protection, info.shared};
    return KERN_SUCCESS;
}

// The owner serializes this operation with lease acquisition. Failure precedes
// both MADV_FREE and protection changes, so a live pool cannot lose its pages.
static inline int dm_vm_change(const dm_vm_pool_leases *leases, void *memory, size_t length, int protection, int discard) {
    if (discard || protection == PROT_NONE) {
        vm_address_t base; vm_size_t rounded;
        kern_return_t code = dm_vm_span_pages(memory, length, &base, &rounded);
        if (code == KERN_SUCCESS) code = dm_vm_lease_can_discard(leases, base, rounded);
        if (code != KERN_SUCCESS) { errno = code == KERN_INVALID_ARGUMENT ? EINVAL : EBUSY; return -1; }
    }
    if (discard && madvise(memory, length, MADV_FREE)) return -1;
    return mprotect(memory, length, protection);
}

kern_return_t dm_guest_vm_pool_acquire(const void *memory, uint64_t length, dm_vm_pool_region *region, uint64_t *lease);
void dm_guest_vm_pool_release(uint64_t lease);
