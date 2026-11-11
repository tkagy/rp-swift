// Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
// SPDX-License-Identifier: MIT

.syntax unified
.thumb

#if defined(RP2040) == defined(RP2350)
#error "Choose exactly one assembly target: RP2040 or RP2350"
#endif

// Compiler atomic ABI for aligned 32-bit normal RAM, used by Embedded Swift's
// once-only initialization. All requested orders are conservatively implemented
// as sequentially consistent. These entries do not make Console reentrant.
// No NMI/HardFault use: those handlers cannot be masked by PRIMASK. A Swift
// initializer must also not be reentered from an IRQ while its once token is busy.
// ABI: load(ptr, order); store(ptr, value, order);
// compare_exchange(ptr, expectedPtr, desired, successOrder, failureOrder).
// The compare_exchange runtime entry has no 'weak' argument; failure updates
// *expectedPtr and returns false. It never fails spuriously.
#if RP2040
// Use the highest-index lock so application locks remain the contiguous range
// 0...30. Index 31 has no hardware-special behavior. Keep in sync with
// SIO.runtimeReservedSpinlocks; applications and SIO.initialize must not claim
// or release this runtime-owned lock. RP2350 uses CPU exclusives instead.
.equ MEMORY_ATOMIC_SIO_BASE,          0xD0000000
.equ MEMORY_ATOMIC_SPINLOCK_OFFSET,   0x100
.equ MEMORY_ATOMIC_SPINLOCK_INDEX,    31
.equ MEMORY_ATOMIC_SPINLOCK_STRIDE,   4
.equ MEMORY_ATOMIC_LOCK_ADDRESS, MEMORY_ATOMIC_SIO_BASE + MEMORY_ATOMIC_SPINLOCK_OFFSET + MEMORY_ATOMIC_SPINLOCK_INDEX * MEMORY_ATOMIC_SPINLOCK_STRIDE


// Preserve caller-owned registers and IRQ state. IRQs stay masked only for the
// short primitive, never while the Swift initializer executes. The hardware
// lock provides cross-core exclusion; PRIMASK alone would not be sufficient.
.macro memory_atomic_enter
    push {r4, r5, r6, r7}
    mov r4, r0
    mov r5, r1
    mov r6, r2
    mrs r7, primask
    cpsid i
    ldr r3, =MEMORY_ATOMIC_LOCK_ADDRESS
.Latomic_wait\@:
    ldr r2, [r3]
    cmp r2, #0
    beq .Latomic_wait\@
    dmb sy
.endm

.macro memory_atomic_leave
    dmb sy
    movs r2, #0
    str r2, [r3]
    dmb sy
    msr primask, r7
    pop {r4, r5, r6, r7}
    bx lr
.endm
#endif

// Function: __atomic_load_4. Returns the loaded word in r0.
.section .text.__atomic_load_4,"ax",%progbits
.p2align 2
.global __atomic_load_4
.type __atomic_load_4,%function
.thumb_func
__atomic_load_4:
#if RP2040
    memory_atomic_enter
    ldr r0, [r4]
    memory_atomic_leave
#elif RP2350
    dmb sy
    ldr r0, [r0]
    dmb sy
    bx lr
#endif
.size __atomic_load_4, .-__atomic_load_4
// End function: __atomic_load_4.
.ltorg

// Function: __atomic_store_4. Stores r1 to the word addressed by r0.
.section .text.__atomic_store_4,"ax",%progbits
.p2align 2
.global __atomic_store_4
.type __atomic_store_4,%function
.thumb_func
__atomic_store_4:
#if RP2040
    memory_atomic_enter
    str r5, [r4]
    memory_atomic_leave
#elif RP2350
    dmb sy
    str r1, [r0]
    dmb sy
    bx lr
#endif
.size __atomic_store_4, .-__atomic_store_4
// End function: __atomic_store_4.
.ltorg

// Function: __atomic_fetch_sub_4(pointer, value, memory_order).
// r0: address; r1: amount; r2: memory order. Return the previous word in r0.
.section .text.__atomic_fetch_sub_4,"ax",%progbits
.p2align 2
.global __atomic_fetch_sub_4
.type __atomic_fetch_sub_4,%function
.thumb_func
__atomic_fetch_sub_4:
#if RP2040
    memory_atomic_enter
    ldr r0, [r4]
    subs r1, r0, r5
    str r1, [r4]
    memory_atomic_leave
#elif RP2350
    dmb sy
1:
    ldrex r2, [r0]
    sub r3, r2, r1
    strex r12, r3, [r0]
    cmp r12, #0
    bne 1b
    mov r0, r2
    dmb sy
    bx lr
#endif
.size __atomic_fetch_sub_4, .-__atomic_fetch_sub_4
// End function: __atomic_fetch_sub_4.
.ltorg
