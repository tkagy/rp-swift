// Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
// SPDX-License-Identifier: MIT

// Assembly startup and terminal fault entry for RP2.swift.
// Reset initializes RAM through Memory.S primitives, validates/protects the boot
// stack, calls Memory.S to paint unused words, and enters rp2_start. No external runtime is linked.
// Build: Scripts/build.sh produces asm-RP2.o, separate from Swift's RP2.o.
// Reset and its assembly helpers create no active stack frames. The reset entry
// is not a returning C function; helpers document their private register ABI.
// Hardware may already have attempted exception stacking before rp2_fault runs;
// the terminal handler itself makes no stack accesses or nested calls.
// Function/End function comments delimit functions; .L labels are branch targets.
// Swift-like comments are pseudocode, not additional executable code.

// Use UAL (Unified Assembly Language) syntax for instruction spelling and operands.
// UAL is an assembly-language syntax shared by Arm and Thumb code; selecting it
// does not select a CPU, switch instruction state, or enable additional instructions.
// GNU-compatible directive reference: .syntax and .thumb.
// https://sourceware.org/binutils/docs/as/ARM-Directives.html
.syntax unified

// Assemble subsequent instructions as Thumb code, which can use 16-bit and 32-bit
// encodings where supported by the selected CPU. Cortex-M0+ (RP2040) and Cortex-M33
// (the Arm target of RP2350) execute Thumb code and do not support A32 Arm state.
// This is their execution model, not a setting that makes all instructions portable.
// build.sh also passes -mthumb and selects -mcpu=cortex-m0plus or -mcpu=cortex-m33;
// the CPU selection determines which instructions and special registers are valid.
// Shared functions below use operations supported by both CPUs. MSPLIM access is
// restricted to #if RP2350 because it is unavailable on Cortex-M0+.
// Arm Cortex-M0+ Generic User Guide: instruction set (Armv6-M Thumb).
// https://documentation-service.arm.com/static/5f04aadfdbdee951c1cdc957
// Arm Cortex-M33 Generic User Guide: Thumb execution state and stack limit registers.
// https://documentation-service.arm.com/static/66be2153882fec713ef49e49
.thumb

#if defined(RP2040) == defined(RP2350)
#error "Choose exactly one assembly target: RP2040 or RP2350"
#endif
#if RP2040
// Cortex-M0+ MPU definitions for RP2040 assembly startup. No initialization code.
// RP2040 datasheet 2.4.6 and 2.4.8: MPU register descriptions.
// https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf
.equ RP2040_MPU_BASE,                  0xE000ED90
.equ RP2040_MPU_TYPE_OFFSET,           0x00
.equ RP2040_MPU_CTRL_OFFSET,           0x04
.equ RP2040_MPU_RNR_OFFSET,            0x08
.equ RP2040_MPU_RBAR_OFFSET,           0x0C
.equ RP2040_MPU_RASR_OFFSET,           0x10
.equ RP2040_MPU_REGION_COUNT_SHIFT,    8
.equ RP2040_MPU_CTRL_ENABLE,           (1 << 0)
.equ RP2040_MPU_CTRL_PRIVDEFENA,       (1 << 2)
.equ RP2040_MPU_RASR_ENABLE,           (1 << 0)
.equ RP2040_MPU_RASR_SIZE_SHIFT,       1
.equ RP2040_MPU_RASR_EXECUTE_NEVER,    (1 << 28)
// AP=0: no data access. All subregions stay enabled (SRD=0).
.equ RP2040_MPU_MINIMUM_SIZE_ENCODING, 7
.equ RP2040_MPU_MINIMUM_REGION_BYTES,  (1 << (RP2040_MPU_MINIMUM_SIZE_ENCODING + 1))
#endif

// Startup diagnostic codes for debugger inspection; Swift does not expose them.
.equ MEMORY_STACK_STATUS_NONE,         0
.equ MEMORY_STACK_STATUS_LAYOUT,       1
.equ MEMORY_STACK_STATUS_SETUP,        2
.equ MEMORY_STACK_STATUS_IN_USE,       3
.equ MEMORY_STACK_STATUS_UNAVAILABLE,  4
.equ MEMORY_STACK_ALIGNMENT,           8
.equ MEMORY_STACK_ALIGNMENT_MASK,      (MEMORY_STACK_ALIGNMENT - 1)
.equ MEMORY_STACK_MPU_REGION,          0

// =============================================================================
// STARTUP ONLY -- reset entry and private helpers; not Swift/C APIs
// =============================================================================

// -----------------------------------------------------------------------------
// Function: rp2_reset()  [No Stack Frames]
// --> Init globals
// --> Protect/Paint the stack
// --> Jump to rp2_start()
.section .text.rp2_reset,"ax",%progbits
.p2align 2
.global rp2_reset
.type rp2_reset,%function
.thumb_func
rp2_reset:
 // let savedMask = readPRIMASK(); disableInterrupts()
    mrs r8, primask
    cpsid i

 // Memory.copy(dataStart, dataLoadStart, dataEnd - dataStart)
    ldr r0, =__data_start
    ldr r1, =__data_load_start
    ldr r2, =__data_end
    subs r2, r2, r0
    bl memcpy

 // Memory.set(bssStart, 0, bssEnd - bssStart)
    ldr r0, =__bss_start
    ldr r2, =__bss_end
    subs r2, r2, r0
    movs r1, #0
    bl memset

 // let status = initializeStack()
 // guard status == .none else { fail(status) }
    bl rp2_stack_initialize
    cmp r0, #MEMORY_STACK_STATUS_NONE
    bne .Lreset_failure

 // paintStack(); stackProtected = true
    bl rp2_stack_paint
    ldr r0, =rp2_stack_protected_value
    movs r1, #1
    str r1, [r0]
 // publishMemoryWrites(); writePRIMASK(savedMask); startSwift()
    dsb
    msr primask, r8
    bl rp2_start                // BL uses LR; Swift may create protected stack frames.
    movs r0, #MEMORY_STACK_STATUS_SETUP // A returning Swift entry is also a setup failure.
.Lreset_failure:
 // startupStatus = status; fault(reason: status)
    ldr r1, =rp2_stack_status_value
    str r0, [r1]
    mov r2, r0                  // Preserve the error for debugger inspection.
    b rp2_fault
.size rp2_reset, .-rp2_reset
// End function: rp2_reset.
.ltorg

// -----------------------------------------------------------------------------
// Function: rp2_stack_initialize() [No Stack Frames]
// --> Validate the boot MSP
// --> Tail-branch to chip protection; return its status directly to reset
// Private ABI: r0=status, clobbers r0-r7/flags; preserves r8-r11/SP/LR.
.section .text.rp2_stack_initialize,"ax",%progbits
.p2align 2
.type rp2_stack_initialize,%function
.thumb_func
rp2_stack_initialize:
 // let bottom = STACK_BOTTOM; let sp = readMSP()
 // guard bottom <= sp && sp <= STACK_TOP && sp % 8 == 0 else { return .invalidMSP }
    ldr r4, =STACK_BOTTOM
    mrs r0, msp
    cmp r0, r4
    blo .Lstack_init_invalid_msp
    ldr r1, =STACK_TOP
    cmp r0, r1
    bhi .Lstack_init_invalid_msp
    movs r1, #MEMORY_STACK_ALIGNMENT_MASK
    tst r0, r1
    bne .Lstack_init_invalid_msp

 // return protectStack() // B preserves LR; no return-address save is needed.
#if RP2040
    b rp2040_stack_protect
#elif RP2350
    b rp2350_stack_protect
#endif
.Lstack_init_invalid_msp:
    movs r0, #MEMORY_STACK_STATUS_LAYOUT
    bx lr
.size rp2_stack_initialize, .-rp2_stack_initialize
// End function: rp2_stack_initialize.
.ltorg

#if RP2040
// -----------------------------------------------------------------------------
// Function: rp2040_stack_protect() [No Stack Frames]
// --> Check that the MPU and all its regions are disabled
// --> Tail-branch to guard setup; return its status directly to reset
// Private ABI: r0=status, clobbers r0-r7/flags; preserves r8-r11/SP/LR.
.section .text.rp2040_stack_protect,"ax",%progbits
.p2align 2
.type rp2040_stack_protect,%function
.thumb_func
rp2040_stack_protect:
 // let mpu = MPU(base: RP2040_MPU_BASE)                  // r3
 // let regionCount = (mpu.type >> regionCountShift) & 0xFF // r2
 // guard regionCount > 0 else { return .unavailable }
    ldr r3, =RP2040_MPU_BASE
    ldr r2, [r3, #RP2040_MPU_TYPE_OFFSET]
    lsrs r2, r2, #RP2040_MPU_REGION_COUNT_SHIFT
    uxtb r2, r2
    cmp r2, #MEMORY_STACK_MPU_REGION
    bls .Lrp2040_protect_mpu_unavailable

 // guard mpu.control == 0 else { return .inUse }
    ldr r0, [r3, #RP2040_MPU_CTRL_OFFSET]
    cmp r0, #0
    bne .Lrp2040_protect_mpu_in_use

 // for region in 0..<regionCount {
 //     mpu.select(region)
 //     guard !mpu.regionEnabled else { return .inUse }
 // }
    movs r0, #0
    movs r7, #RP2040_MPU_RASR_ENABLE
.Lrp2040_protect_check_regions:
    str r0, [r3, #RP2040_MPU_RNR_OFFSET]
    ldr r1, [r3, #RP2040_MPU_RASR_OFFSET]
    tst r1, r7
    bne .Lrp2040_protect_mpu_in_use
    adds r0, #1
    cmp r0, r2
    blo .Lrp2040_protect_check_regions

 // return enableStackGuard() // B keeps reset's return address in LR.
    b rp2040_stack_guard_enable
.Lrp2040_protect_mpu_unavailable:
    movs r0, #MEMORY_STACK_STATUS_UNAVAILABLE
    bx lr
.Lrp2040_protect_mpu_in_use:
    movs r0, #MEMORY_STACK_STATUS_IN_USE
    bx lr
.size rp2040_stack_protect, .-rp2040_stack_protect
// End function: rp2040_stack_protect.
.ltorg

// -----------------------------------------------------------------------------
// Function: rp2040_stack_guard_enable() [No Stack Frames]
// --> Enable the linker-defined guard in MPU region 0
// --> Tail-branch to readback verification
// Called only after the MPU/region checks. Linker constants supply base and SIZE.
// Private ABI: r0=status, clobbers r0-r7/flags; preserves r8-r11/SP/LR.
.section .text.rp2040_stack_guard_enable,"ax",%progbits
.p2align 2
.type rp2040_stack_guard_enable,%function
.thumb_func
rp2040_stack_guard_enable:
 // let mpu = MPU(base: RP2040_MPU_BASE); let guardBottom = STACK_GUARD_BOTTOM
 // let attributes = executeNever | enabled | (STACK_GUARD_MPU_SIZE << sizeShift)
    ldr r3, =RP2040_MPU_BASE
    ldr r5, =STACK_GUARD_BOTTOM
    ldr r7, =STACK_GUARD_MPU_SIZE
    lsls r7, r7, #RP2040_MPU_RASR_SIZE_SHIFT
    ldr r0, =(RP2040_MPU_RASR_EXECUTE_NEVER | RP2040_MPU_RASR_ENABLE)
    orrs r7, r0

 // mpu.select(0); mpu.regionBase = guardBottom; mpu.regionAttributes = attributes
    movs r0, #MEMORY_STACK_MPU_REGION
    str r0, [r3, #RP2040_MPU_RNR_OFFSET]
    str r5, [r3, #RP2040_MPU_RBAR_OFFSET]
    str r7, [r3, #RP2040_MPU_RASR_OFFSET]
    dsb
    isb

 // mpu.control = enabled | privilegedDefaultMap; return verifyStackGuard()
 // AP=0 denies data access; HardFault/NMI bypass the MPU to reach the fault loop.
    movs r2, #(RP2040_MPU_CTRL_ENABLE | RP2040_MPU_CTRL_PRIVDEFENA)
    str r2, [r3, #RP2040_MPU_CTRL_OFFSET]
    dsb
    isb
    b rp2040_stack_guard_verify
.size rp2040_stack_guard_enable, .-rp2040_stack_guard_enable
// End function: rp2040_stack_guard_enable.
.ltorg

// -----------------------------------------------------------------------------
// Function: rp2040_stack_guard_verify() [No Stack Frames]
// --> Check control, guard base, and region attributes against the requested values
// Private ABI: r3=MPU, r2=control, r5=base, r7=attributes from guard_enable.
// Returns status in r0; clobbers r0/flags only; preserves r1-r11/SP/LR.
.section .text.rp2040_stack_guard_verify,"ax",%progbits
.p2align 2
.type rp2040_stack_guard_verify,%function
.thumb_func
rp2040_stack_guard_verify:
 // guard mpu.control == control && mpu.regionBase == base
 //     && mpu.regionAttributes == attributes else { return .setupFailed }
    ldr r0, [r3, #RP2040_MPU_CTRL_OFFSET]
    cmp r0, r2
    bne .Lrp2040_guard_failed
    ldr r0, [r3, #RP2040_MPU_RBAR_OFFSET]
    cmp r0, r5
    bne .Lrp2040_guard_failed
    ldr r0, [r3, #RP2040_MPU_RASR_OFFSET]
    cmp r0, r7
    bne .Lrp2040_guard_failed
 // return .none
    movs r0, #MEMORY_STACK_STATUS_NONE
    bx lr
.Lrp2040_guard_failed:
    movs r0, #MEMORY_STACK_STATUS_SETUP
    bx lr
.size rp2040_stack_guard_verify, .-rp2040_stack_guard_verify
// End function: rp2040_stack_guard_verify.
.ltorg

#elif RP2350

// -----------------------------------------------------------------------------
// Function: rp2350_stack_protect() [No Stack Frames]
// --> Set Secure MSPLIM and verify readback
// Private ABI: r0=status, clobbers r0-r1/flags; preserves r2-r11/SP/LR.
.section .text.rp2350_stack_protect,"ax",%progbits
.p2align 2
.type rp2350_stack_protect,%function
.thumb_func
rp2350_stack_protect:
 // writeMSPLIM(STACK_BOTTOM)
 // guard readMSPLIM() == STACK_BOTTOM else { return .setupFailed }
    ldr r1, =STACK_BOTTOM
    msr msplim, r1
    isb
    mrs r0, msplim
    cmp r0, r1
    bne .Lrp2350_protect_failed
 // return .none
    movs r0, #MEMORY_STACK_STATUS_NONE
    bx lr
.Lrp2350_protect_failed:
    movs r0, #MEMORY_STACK_STATUS_SETUP
    bx lr
.size rp2350_stack_protect, .-rp2350_stack_protect
// End function: rp2350_stack_protect.
.ltorg

#endif

.ltorg

// =============================================================================
// FAULT ENTRY -- exception vectors and the Swift stopOnFault() binding
// =============================================================================

// -----------------------------------------------------------------------------
// Function: rp2_fault() [No Stack Frames]
// Stack: None in this handler; hardware may already have stacked an exception frame.
// Terminal faultHandler path: no stack accesses, Swift/UART calls, or return.
// Debugger: r0=MSP after exception stacking, r1=exception number, r2=startup error only.
.section .text.rp2_fault,"ax",%progbits
.global rp2_fault
.type rp2_fault,%function
.thumb_func
rp2_fault:
    // disableInterrupts(); let sp = readMSP(); let exception = readIPSR()
    cpsid i                     // Mask ordinary interrupts; NMI and HardFault are not masked.
    mrs r0, msp                 // Keep the current main-stack address for inspection.
    mrs r1, ipsr                // Keep the active exception number for inspection.
    // while true {} // Stop with register values preserved.
.Lfault_stop:
    b .Lfault_stop              // Stay here until a debugger or reset intervenes.
.size rp2_fault, .-rp2_fault
// End function: rp2_fault.

// =============================================================================
// DATA -- startup diagnostics and paint state; no executable functions
// =============================================================================

// Startup diagnostics live in .bss and are cleared before protection setup.
// These are real storage objects, not linker-address aliases. Only startup writes
// them; both remain debugger-visible without a Swift diagnostic API.
.section .bss.rp2_stack_state,"aw",%nobits
.p2align 2
.global rp2_stack_status_value
// Data: rp2_stack_status_value (UInt32 storage, not a function).
.type rp2_stack_status_value,%object
rp2_stack_status_value:
    .space 4
.size rp2_stack_status_value, .-rp2_stack_status_value
.global rp2_stack_protected_value
// Data: rp2_stack_protected_value (UInt32 storage, not a function).
.type rp2_stack_protected_value,%object
rp2_stack_protected_value:
    .space 4
.size rp2_stack_protected_value, .-rp2_stack_protected_value

// Object-file metadata declaring that this file does not need an executable stack.
// It does not allocate stack memory or configure the hardware stack protection.
.section .note.GNU-stack,"",%progbits
