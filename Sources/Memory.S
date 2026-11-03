// Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
// SPDX-License-Identifier: MIT

// Memory-operation loops, compiler ABI adapters, and SRAM diagnostics for Memory.swift.
// RP2.S owns reset, stack protection, startup status, and the fault entry.
// This file owns stack painting and its peak-usage diagnostic state.
// No external runtime is linked. Scripts/build.sh produces asm-Memory.o.
// C ABI: r0-r2 carry arguments, r0 returns the result, and bx lr returns to caller.
// All primitives and diagnostic accessors are register-only, without stack frames.
// Function/End function comments delimit functions; .L labels are branch targets.
// Swift-like comments are pseudocode, not additional executable code.

.syntax unified
.thumb
#if defined(RP2040) == defined(RP2350)
#error "Choose exactly one assembly target: RP2040 or RP2350"
#endif
// Stack paint pattern is shared by the startup painter and peak-usage scan here.
.equ MEMORY_STACK_PAINT_WORD,          0xA5A5A5A5
.equ MEMORY_STACK_PAINT_WORD_BYTES,    4

// -----------------------------------------------------------------------------
// Function: rp2_stack_paint() [No Stack Frames]
// Paint unused boot-stack words below the current MSP; startup only.
// Private ABI: clobbers r0-r3/flags; preserves r4-r11/SP/LR.
.section .text.rp2_stack_paint,"ax",%progbits
.p2align 2
.global rp2_stack_paint
.type rp2_stack_paint,%function
.thumb_func
rp2_stack_paint:
    ldr r0, =STACK_BOTTOM
    mrs r1, msp
    ldr r3, =rp2_stack_paint_end
    str r1, [r3]
    ldr r2, =MEMORY_STACK_PAINT_WORD
.Lstack_paint_words:
    cmp r0, r1
    bhs .Lstack_paint_done
    str r2, [r0]
    adds r0, #MEMORY_STACK_PAINT_WORD_BYTES
    b .Lstack_paint_words
.Lstack_paint_done:
    bx lr
.size rp2_stack_paint, .-rp2_stack_paint
// End function: rp2_stack_paint.

.section .bss.rp2_stack_paint,"aw",%nobits
.p2align 2
.global rp2_stack_paint_end
.hidden rp2_stack_paint_end
.type rp2_stack_paint_end,%object
rp2_stack_paint_end:
    .space 4
.size rp2_stack_paint_end, .-rp2_stack_paint_end

// =============================================================================
// SWIFT SRAM DIAGNOSTICS -- C ABI entry points used by Memory.SRAM
// =============================================================================

// -----------------------------------------------------------------------------
// Function: rp2_sram_total_bytes() [No Stack Frames]
// ABI: no arguments; returns a linker-derived byte count in r0.
// Stack: None: register-only leaf.
.section .text.rp2_sram_total_bytes,"ax",%progbits
.p2align 2
.global rp2_sram_total_bytes
.type rp2_sram_total_bytes,%function
.thumb_func
rp2_sram_total_bytes:
    // return SRAM_BYTES
    ldr r0, =SRAM_BYTES
    bx lr
.size rp2_sram_total_bytes, .-rp2_sram_total_bytes
// End function: rp2_sram_total_bytes.
.ltorg

// -----------------------------------------------------------------------------
// Function: rp2_sram_static_bytes() [No Stack Frames]
// ABI: no arguments; returns a linker-derived byte count in r0.
// Stack: None: register-only leaf.
.section .text.rp2_sram_static_bytes,"ax",%progbits
.p2align 2
.global rp2_sram_static_bytes
.type rp2_sram_static_bytes,%function
.thumb_func
rp2_sram_static_bytes:
    // return __bss_end - SRAM_BASE
    ldr r0, =__bss_end
    ldr r1, =SRAM_BASE
    subs r0, r0, r1
    bx lr
.size rp2_sram_static_bytes, .-rp2_sram_static_bytes
// End function: rp2_sram_static_bytes.
.ltorg

// -----------------------------------------------------------------------------
// Function: rp2_sram_stack_reserved_bytes() [No Stack Frames]
// ABI: no arguments; returns a linker-derived byte count in r0.
// Stack: None: register-only leaf.
.section .text.rp2_sram_stack_reserved_bytes,"ax",%progbits
.p2align 2
.global rp2_sram_stack_reserved_bytes
.type rp2_sram_stack_reserved_bytes,%function
.thumb_func
rp2_sram_stack_reserved_bytes:
    // return STACK_TOP - STACK_BOTTOM
    ldr r0, =STACK_TOP
    ldr r1, =STACK_BOTTOM
    subs r0, r0, r1
    bx lr
.size rp2_sram_stack_reserved_bytes, .-rp2_sram_stack_reserved_bytes
// End function: rp2_sram_stack_reserved_bytes.
.ltorg

// -----------------------------------------------------------------------------
// Function: rp2_sram_reserved_bytes() [No Stack Frames]
// ABI: no arguments; returns a linker-derived byte count in r0.
// Stack: None: register-only leaf.
.section .text.rp2_sram_reserved_bytes,"ax",%progbits
.p2align 2
.global rp2_sram_reserved_bytes
.type rp2_sram_reserved_bytes,%function
.thumb_func
rp2_sram_reserved_bytes:
    // return STACK_TOP - STACK_GUARD_BOTTOM
    ldr r0, =STACK_TOP
    ldr r1, =STACK_GUARD_BOTTOM
    subs r0, r0, r1
    bx lr
.size rp2_sram_reserved_bytes, .-rp2_sram_reserved_bytes
// End function: rp2_sram_reserved_bytes.
.ltorg

// -----------------------------------------------------------------------------
// Function: rp2_stack_peak_used_bytes() [No Stack Frames]
// Stack: No active frame; reads painted stack memory without changing it.
// Estimate the deepest overwritten word since painting; do not modify the paint.
// Registers only, no IRQ masking. A concurrent interrupt can deepen usage after
// its word has been scanned; a later query observes that write. The scan is O(n)
// in the untouched stack size. Call from the boot core using its original MSP.
.section .text.rp2_stack_peak_used_bytes,"ax",%progbits
.p2align 2
.global rp2_stack_peak_used_bytes
.type rp2_stack_peak_used_bytes,%function
.thumb_func
rp2_stack_peak_used_bytes:
    // var address = STACK_BOTTOM; let end = paintEnd
    ldr r0, =STACK_BOTTOM
    ldr r1, =rp2_stack_paint_end
    ldr r1, [r1]
    ldr r2, =MEMORY_STACK_PAINT_WORD
    // while address < end && load32(address) == paintWord { address += 4 }
.Lstack_scan:
    cmp r0, r1
    bhs .Lstack_scan_done
    ldr r3, [r0]
    cmp r3, r2
    bne .Lstack_scan_done
    adds r0, #MEMORY_STACK_PAINT_WORD_BYTES
    b .Lstack_scan
.Lstack_scan_done:
    // return STACK_TOP - address
    ldr r1, =STACK_TOP
    subs r0, r1, r0
    bx lr
.size rp2_stack_peak_used_bytes, .-rp2_stack_peak_used_bytes
// End function: rp2_stack_peak_used_bytes.
.ltorg

// =============================================================================
// MEMORY PRIMITIVES -- C ABI for Swift, compiler-generated calls, and startup
// =============================================================================

// Word-copy alignment constants shared by the memory-operation loops.
.equ MEMORY_BYTE_BITS,        8
.equ MEMORY_WORD_BYTES,       4
.equ MEMORY_BLOCK_WORDS,      4
.equ MEMORY_BLOCK_BYTES,      (MEMORY_BLOCK_WORDS * MEMORY_WORD_BYTES)
.equ MEMORY_MID_BLOCK_WORDS,   8
.equ MEMORY_MID_BLOCK_BYTES,   (MEMORY_MID_BLOCK_WORDS * MEMORY_WORD_BYTES)
.equ MEMORY_LARGE_BLOCK_WORDS, 16
.equ MEMORY_LARGE_BLOCK_BYTES, (MEMORY_LARGE_BLOCK_WORDS * MEMORY_WORD_BYTES)
.equ MEMORY_ALIGNMENT_MASK,   (MEMORY_WORD_BYTES - 1)
.equ MEMORY_ALIGNMENT_SHIFT,  30 // Shift the two low address bits into the high bits.

// -----------------------------------------------------------------------------
// Function: memcpy() [No Stack Frames]
// Stack: None: no stack frame or nested calls.
// Memory.copy(dst, src, count): nonoverlapping ranges. r0=dst, r1=src, r2=count.
// Return the original dst. Use r0-r3/r12/flags only; no stack accesses.
// Share this section with memmove so it can reuse the forward loop.
.section .text.rp2_memory_transfer,"ax",%progbits
.global memcpy
.type memcpy,%function
.thumb_func
memcpy:
    // let originalDestination = dst
    // if dst == src { return originalDestination }
    mov r12, r0                 // Preserve the required C return value.
    cmp r0, r1
    beq .Lcopy_return           // Identical pointers need no work.
.Lcopy_forward:
    // guard count != 0 else { return originalDestination }
    // if (dst ^ src) & 3 != 0 { copyRemainingBytes(); return originalDestination } // The pointers cannot be aligned together.
    cmp r2, #0
    beq .Lcopy_return
    mov r3, r0
    eors r3, r1
    lsls r3, r3, #MEMORY_ALIGNMENT_SHIFT
    bne .Lcopy_bytes            // Low two bits differ: cannot align both together.
    // while dst % 4 != 0 { copyByte(); dst += 1; src += 1; count -= 1 }
    // Return early if count reaches zero.
.Lcopy_align:
    movs r3, #MEMORY_ALIGNMENT_MASK
    tst r0, r3
    beq .Lcopy_aligned
    ldrb r3, [r1]               // Copy a leading byte without unaligned word access.
    strb r3, [r0]
    adds r0, #1
    adds r1, #1
    subs r2, #1
    beq .Lcopy_return
    b .Lcopy_align
.Lcopy_aligned:
    // while count >= 64 { copyWordsForward(16); dst += 64; src += 64; count -= 64 }
    // .irp expands these word accesses at assembly time; it makes no calls.
    cmp r2, #MEMORY_LARGE_BLOCK_BYTES
    blo .Lcopy_mid_check
.Lcopy_large_blocks:
    .irp word, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
    ldr r3, [r1, #(\word * MEMORY_WORD_BYTES)]
    str r3, [r0, #(\word * MEMORY_WORD_BYTES)]
    .endr
    adds r0, #MEMORY_LARGE_BLOCK_BYTES
    adds r1, #MEMORY_LARGE_BLOCK_BYTES
    subs r2, #MEMORY_LARGE_BLOCK_BYTES
    cmp r2, #MEMORY_LARGE_BLOCK_BYTES
    bhs .Lcopy_large_blocks

    // The bulk loop leaves count < 64, so one 32-byte block is sufficient.
    // if count >= 32 { copyWordsForward(8); dst += 32; src += 32; count -= 32 }
.Lcopy_mid_check:
    cmp r2, #MEMORY_MID_BLOCK_BYTES
    blo .Lcopy_small_check
    .irp word, 0,1,2,3,4,5,6,7
    ldr r3, [r1, #(\word * MEMORY_WORD_BYTES)]
    str r3, [r0, #(\word * MEMORY_WORD_BYTES)]
    .endr
    adds r0, #MEMORY_MID_BLOCK_BYTES
    adds r1, #MEMORY_MID_BLOCK_BYTES
    subs r2, #MEMORY_MID_BLOCK_BYTES

    // Now count < 32: handle at most one 16-byte block before the word/byte tail.
.Lcopy_small_check:
    cmp r2, #MEMORY_BLOCK_BYTES
    blo .Lcopy_words
.Lcopy_blocks:
    ldr r3, [r1]
    str r3, [r0]
    ldr r3, [r1, #MEMORY_WORD_BYTES]
    str r3, [r0, #MEMORY_WORD_BYTES]
    ldr r3, [r1, #(2 * MEMORY_WORD_BYTES)]
    str r3, [r0, #(2 * MEMORY_WORD_BYTES)]
    ldr r3, [r1, #(3 * MEMORY_WORD_BYTES)]
    str r3, [r0, #(3 * MEMORY_WORD_BYTES)]
    adds r0, #MEMORY_BLOCK_BYTES
    adds r1, #MEMORY_BLOCK_BYTES
    subs r2, #MEMORY_BLOCK_BYTES

    // Copy the remaining zero to three words, then zero to three bytes.
    // while count >= 4 { store32(dst, load32(src)); dst += 4; src += 4; count -= 4 }
.Lcopy_words:
    cmp r2, #MEMORY_WORD_BYTES
    blo .Lcopy_bytes            // Unsigned count check: never read past the tail.
    ldr r3, [r1]
    str r3, [r0]
    adds r0, #MEMORY_WORD_BYTES
    adds r1, #MEMORY_WORD_BYTES
    subs r2, #MEMORY_WORD_BYTES
    b .Lcopy_words
    // while count > 0 { copyByte(); dst += 1; src += 1; count -= 1 }
.Lcopy_bytes:
    cmp r2, #0
    beq .Lcopy_return
.Lcopy_byte_loop:
    ldrb r3, [r1]
    strb r3, [r0]
    adds r0, #1
    adds r1, #1
    subs r2, #1
    bne .Lcopy_byte_loop
.Lcopy_return:
    mov r0, r12
    bx lr
.size memcpy, .-memcpy
// End function: memcpy.

// -----------------------------------------------------------------------------
// Function: memmove() [No Stack Frames]
// Stack: None: shares the forward-copy path with memcpy without another call.
// Memory.move(dst, src, count): overlap allowed; arguments/result/registers match memcpy.
.global memmove
.type memmove,%function
.thumb_func
memmove:
    // let originalDestination = dst
    // if count == 0 || dst == src { return originalDestination }
    // if dst < src || dst - src >= count { return copyForward(dst, src, count) }
    mov r12, r0
    cmp r2, #0
    beq .Lmove_return_early
    cmp r0, r1
    beq .Lmove_return_early
    blo .Lmove_forward          // A lower destination is safe to copy forward.
    subs r3, r0, r1             // Ordered subtraction avoids source + count overflow.
    cmp r3, r2
    bhs .Lmove_forward          // Gap >= length: the ranges are disjoint.
    b .Lmove_backward
.Lmove_return_early:
    bx lr                       // r0 still holds the original destination.
.Lmove_forward:
    // The shared copy loop can exceed Cortex-M0+ conditional-branch reach.
    b .Lcopy_forward
.Lmove_backward:
    // The overlapping destination is higher; copy backward to preserve unread data.
    // dst += count; src += count
    adds r0, r0, r2
    adds r1, r1, r2
    // if (dst ^ src) & 3 != 0 { copyRemainingBytesBackward(); return originalDestination }
    mov r3, r0
    eors r3, r1
    lsls r3, r3, #MEMORY_ALIGNMENT_SHIFT
    bne .Lmove_bytes            // Different alignment requires byte accesses.
    // while dst % 4 != 0 { dst -= 1; src -= 1; copyByte(); count -= 1 }
    // Return if count reaches zero.
.Lmove_align:
    movs r3, #MEMORY_ALIGNMENT_MASK
    tst r0, r3
    beq .Lmove_aligned
    subs r0, #1                 // Align the ends by copying trailing bytes first.
    subs r1, #1
    ldrb r3, [r1]
    strb r3, [r0]
    subs r2, #1
    beq .Lmove_return
    b .Lmove_align
.Lmove_aligned:
    // while count >= 64 { dst -= 64; src -= 64; copyWordsBackward(from: 60, through: 0); count -= 64 }
    // .irp expands these word accesses at assembly time; it makes no calls.
    cmp r2, #MEMORY_LARGE_BLOCK_BYTES
    blo .Lmove_mid_check
.Lmove_large_blocks:
    subs r0, #MEMORY_LARGE_BLOCK_BYTES
    subs r1, #MEMORY_LARGE_BLOCK_BYTES
    .irp word, 15,14,13,12,11,10,9,8,7,6,5,4,3,2,1,0
    ldr r3, [r1, #(\word * MEMORY_WORD_BYTES)]
    str r3, [r0, #(\word * MEMORY_WORD_BYTES)]
    .endr
    subs r2, #MEMORY_LARGE_BLOCK_BYTES
    cmp r2, #MEMORY_LARGE_BLOCK_BYTES
    bhs .Lmove_large_blocks

    // The bulk loop leaves count < 64, so one 32-byte block is sufficient.
    // if count >= 32 { dst -= 32; src -= 32; copyWordsBackward(8); count -= 32 }
.Lmove_mid_check:
    cmp r2, #MEMORY_MID_BLOCK_BYTES
    blo .Lmove_small_check
    subs r0, #MEMORY_MID_BLOCK_BYTES
    subs r1, #MEMORY_MID_BLOCK_BYTES
    .irp word, 7,6,5,4,3,2,1,0
    ldr r3, [r1, #(\word * MEMORY_WORD_BYTES)]
    str r3, [r0, #(\word * MEMORY_WORD_BYTES)]
    .endr
    subs r2, #MEMORY_MID_BLOCK_BYTES

    // Now count < 32: handle at most one 16-byte block before the word/byte tail.
.Lmove_small_check:
    cmp r2, #MEMORY_BLOCK_BYTES
    blo .Lmove_words
.Lmove_blocks:
    subs r0, #MEMORY_BLOCK_BYTES
    subs r1, #MEMORY_BLOCK_BYTES
    ldr r3, [r1, #(3 * MEMORY_WORD_BYTES)]
    str r3, [r0, #(3 * MEMORY_WORD_BYTES)]
    ldr r3, [r1, #(2 * MEMORY_WORD_BYTES)]
    str r3, [r0, #(2 * MEMORY_WORD_BYTES)]
    ldr r3, [r1, #MEMORY_WORD_BYTES]
    str r3, [r0, #MEMORY_WORD_BYTES]
    ldr r3, [r1]
    str r3, [r0]
    subs r2, #MEMORY_BLOCK_BYTES

    // Copy remaining words backward, then handle the byte prefix.
    // while count >= 4 { dst -= 4; src -= 4; store32(dst, load32(src)); count -= 4 }
.Lmove_words:
    cmp r2, #MEMORY_WORD_BYTES
    blo .Lmove_bytes
    subs r0, #MEMORY_WORD_BYTES
    subs r1, #MEMORY_WORD_BYTES
    ldr r3, [r1]                // Read all four bytes before the overlapping store.
    str r3, [r0]
    subs r2, #MEMORY_WORD_BYTES
    b .Lmove_words
    // while count > 0 { dst -= 1; src -= 1; copyByte(); count -= 1 }
.Lmove_bytes:
    cmp r2, #0
    beq .Lmove_return
.Lmove_byte_loop:
    subs r0, #1
    subs r1, #1
    ldrb r3, [r1]
    strb r3, [r0]
    subs r2, #1
    bne .Lmove_byte_loop
.Lmove_return:
    mov r0, r12
    bx lr
.size memmove, .-memmove
// End function: memmove.

// -----------------------------------------------------------------------------
// Function: memset() [No Stack Frames]
// Stack: None: no stack frame or nested calls.
// Memory.set(dst, value, count): r0=dst, r1=value, r2=count; return the original dst.
// Use r0-r3/r12/flags only; share this section with the Arm ABI adapters.
.section .text.rp2_memory_fill,"ax",%progbits
.global memset
.type memset,%function
.thumb_func
memset:
    // let originalDestination = dst
    // guard count != 0 else { return originalDestination }
    mov r12, r0
    cmp r2, #0
    beq .Lset_return
    // let byte = UInt8(truncatingIfNeeded: value); var word = UInt32(byte)
    // word |= word << 8; word |= word << 16 // Example: 0xA5 -> 0xA5A5A5A5
    uxtb r1, r1
    lsls r3, r1, #MEMORY_BYTE_BITS
    orrs r1, r3
    lsls r3, r1, #(2 * MEMORY_BYTE_BITS)
    orrs r1, r3                 // Replicate the byte into every byte of the word.
    // while dst % 4 != 0 { store8(dst, byte); dst += 1; count -= 1 }
    // Return if count reaches zero.
.Lset_align:
    movs r3, #MEMORY_ALIGNMENT_MASK
    tst r0, r3
    beq .Lset_aligned
    strb r1, [r0]
    adds r0, #1
    subs r2, #1
    beq .Lset_return
    b .Lset_align
.Lset_aligned:
    // while count >= 64 { fillWords(16); dst += 64; count -= 64 }
    // .irp expands these word accesses at assembly time; it makes no calls.
    cmp r2, #MEMORY_LARGE_BLOCK_BYTES
    blo .Lset_mid_check
.Lset_large_blocks:
    .irp word, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
    str r1, [r0, #(\word * MEMORY_WORD_BYTES)]
    .endr
    adds r0, #MEMORY_LARGE_BLOCK_BYTES
    subs r2, #MEMORY_LARGE_BLOCK_BYTES
    cmp r2, #MEMORY_LARGE_BLOCK_BYTES
    bhs .Lset_large_blocks

    // The bulk loop leaves count < 64, so one 32-byte block is sufficient.
    // if count >= 32 { fillWords(8); dst += 32; count -= 32 }
.Lset_mid_check:
    cmp r2, #MEMORY_MID_BLOCK_BYTES
    blo .Lset_small_check
    .irp word, 0,1,2,3,4,5,6,7
    str r1, [r0, #(\word * MEMORY_WORD_BYTES)]
    .endr
    adds r0, #MEMORY_MID_BLOCK_BYTES
    subs r2, #MEMORY_MID_BLOCK_BYTES

    // Now count < 32: handle at most one 16-byte block before the word/byte tail.
.Lset_small_check:
    cmp r2, #MEMORY_BLOCK_BYTES
    blo .Lset_words
.Lset_blocks:
    str r1, [r0]
    str r1, [r0, #MEMORY_WORD_BYTES]
    str r1, [r0, #(2 * MEMORY_WORD_BYTES)]
    str r1, [r0, #(3 * MEMORY_WORD_BYTES)]
    adds r0, #MEMORY_BLOCK_BYTES
    subs r2, #MEMORY_BLOCK_BYTES

    // Fill remaining words, then the byte tail.
    // while count >= 4 { store32(dst, word); dst += 4; count -= 4 }
.Lset_words:
    cmp r2, #MEMORY_WORD_BYTES
    blo .Lset_bytes
    str r1, [r0]
    adds r0, #MEMORY_WORD_BYTES
    subs r2, #MEMORY_WORD_BYTES
    b .Lset_words
    // while count > 0 { store8(dst, byte); dst += 1; count -= 1 }
.Lset_bytes:
    cmp r2, #0
    beq .Lset_return
.Lset_byte_loop:
    strb r1, [r0]
    adds r0, #1
    subs r2, #1
    bne .Lset_byte_loop
.Lset_return:
    mov r0, r12
    bx lr
.size memset, .-memset
// End function: memset.

// =============================================================================
// ARM ABI ADAPTERS -- compiler entry points; different argument order
// =============================================================================

// -----------------------------------------------------------------------------
// Function: __aeabi_memclr() [No Stack Frames]
// Reorder Arm ABI arguments and tail-branch to memset; LR retains the original caller.
// Stack: None: tail-branches to stack-free memset.
.global __aeabi_memclr
.type __aeabi_memclr,%function
.thumb_func
__aeabi_memclr:
    // memset(dst, 0, count)
    mov r2, r1                  // C memset expects count as its third argument.
    movs r1, #0                 // Its second argument is the fill value.
    b memset                    // Tail branch: memset returns to the original caller.
.size __aeabi_memclr, .-__aeabi_memclr
// End function: __aeabi_memclr.

// -----------------------------------------------------------------------------
// Function: __aeabi_memset() [No Stack Frames]
// Reorder Arm ABI arguments and tail-branch to memset; LR retains the original caller.
// Stack: None: tail-branches to stack-free memset.
.global __aeabi_memset
.type __aeabi_memset,%function
.thumb_func
__aeabi_memset:
    // memset(dst, value, count)
    mov r3, r1                  // Keep the count while swapping the last arguments.
    mov r1, r2                  // C memset's second argument is the fill value.
    mov r2, r3                  // Its third argument is the byte count.
    b memset                    // Reuse alignment handling and the complete fill loop.
.size __aeabi_memset, .-__aeabi_memset
// End function: __aeabi_memset.

// Object-file metadata declaring that this file does not need an executable stack.
// It does not allocate stack memory or configure the hardware stack protection.
.section .note.GNU-stack,"",%progbits
