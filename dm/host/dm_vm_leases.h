#pragma once
#include <mach/mach.h>
#include <stdint.h>
#include <stdatomic.h>

enum { DM_VM_POOL_LEASE_LIMIT = 4096 };
typedef struct { uint64_t base, length, id; } dm_vm_pool_lease;
typedef struct { dm_vm_pool_lease rows[DM_VM_POOL_LEASE_LIMIT]; unsigned count; uint64_t next; } dm_vm_pool_leases;

static inline kern_return_t dm_vm_lease_acquire(dm_vm_pool_leases *leases, uint64_t base, uint64_t length, uint64_t *id) {
    if (!length || length > UINT64_MAX - base) return KERN_INVALID_ARGUMENT;
    if (!leases->next || leases->next == UINT64_MAX || leases->count == DM_VM_POOL_LEASE_LIMIT) return KERN_RESOURCE_SHORTAGE;
    *id = leases->next++;
    leases->rows[leases->count++] = (dm_vm_pool_lease){base, length, *id};
    return KERN_SUCCESS;
}

static inline kern_return_t dm_vm_lease_release(dm_vm_pool_leases *leases, uint64_t id) {
    for (unsigned i = 0; i < leases->count; i++) if (leases->rows[i].id == id) {
        leases->rows[i] = leases->rows[--leases->count]; return KERN_SUCCESS;
    }
    return KERN_INVALID_ARGUMENT;
}

static inline kern_return_t dm_vm_lease_can_discard(const dm_vm_pool_leases *leases, uint64_t base, uint64_t length) {
    if (!length || length > UINT64_MAX - base) return KERN_INVALID_ARGUMENT;
    for (unsigned i = 0; i < leases->count; i++) {
        const dm_vm_pool_lease *lease = &leases->rows[i];
        if (base < lease->base + lease->length && lease->base < base + length) return KERN_PROTECTION_FAILURE;
    }
    return KERN_SUCCESS;
}

static inline void dm_vm_lease_retire(_Atomic uint64_t *lease, void (*release)(uint64_t)) {
    uint64_t id = atomic_exchange(lease, 0);
    if (id) release(id);
}
