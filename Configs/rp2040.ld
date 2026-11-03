/* Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
 * SPDX-License-Identifier: MIT
 */

/* RP2040 firmware configuration with a 2 MiB flash region.
   RP2040 Datasheet (section numbers from the 2025-02-20 edition):
   https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf
     2.6.2 SRAM / 2.6.3 Flash: memory addresses and SRAM size
     2.3.2 Interrupts / 2.4 Cortex-M0+: interrupts and vector table
     2.8.1.2 Flash Boot Sequence: ROM copies the first flash page into SRAM
     2.8.1.3 Flash Second Stage: boot2 responsibilities
     2.8.1.3.1 Checksum: 252-byte payload plus 4-byte CRC32
   Compare RP2350 Datasheet 5.9.5.1, which uses IMAGE_DEF rather than boot2:
   https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf */

/* Linker-script syntax (separate from the hardware datasheet):
   ENTRY: ELF entry symbol; the vector table separately specifies the reset address.
   LONG: emit a 32-bit value, little-endian for this Arm build.
   *(.text .text.*): collect matching sections from input objects.
   > FLASH / > RAM: run-time placement. AT> FLASH: storage for initial values.
   KEEP: retain with --gc-sections. NOLOAD: omit initial bytes from the file.
   ALIGN(4): align to four bytes. ASSERT: fail the link if a condition is false.
   K / M: 1024 / 1024*1024 bytes. */
ENTRY(rp2_core0_entry)

/* Memory.S provides the C primitives and Arm fill/clear adapters.
   Copy/move helpers share the C argument order; return values are ignored.
   Arm memset reverses count/value, so its aligned names must use the adapter. */
PROVIDE(__aeabi_memcpy = memcpy);
PROVIDE(__aeabi_memcpy4 = memcpy);
PROVIDE(__aeabi_memcpy8 = memcpy);
PROVIDE(__aeabi_memmove = memmove);
PROVIDE(__aeabi_memmove4 = memmove);
PROVIDE(__aeabi_memmove8 = memmove);
PROVIDE(__aeabi_memclr4 = __aeabi_memclr);
PROVIDE(__aeabi_memclr8 = __aeabi_memclr);
PROVIDE(__aeabi_memset4 = __aeabi_memset);
PROVIDE(__aeabi_memset8 = __aeabi_memset);

/* Addresses and SRAM size are RP2040 specifications. The flash region size is a project configuration. */
FLASH_BASE = 0x10000000; /* XIP: start of the CPU address window for external flash */
SRAM_BASE = 0x20000000;  /* Start of the contiguous SRAM address range */
FLASH_BYTES = 2M;
SRAM_BYTES = 264K;      /* Four 64 KiB banks plus two 4 KiB banks */
BOOT2_BYTES = 256;      /* Section 2.8.1.3.1: 252 bytes of code/padding followed by a 4-byte CRC32 */

MEMORY {
    FLASH (rx) : ORIGIN = FLASH_BASE, LENGTH = FLASH_BYTES
    RAM (rwx) : ORIGIN = SRAM_BASE, LENGTH = SRAM_BYTES
}
STACK_TOP = ORIGIN(RAM) + LENGTH(RAM); /* 0x20042000: just past SRAM, aligned to 8 bytes */

/* The top 8 KiB is stack space. The 4 KiB immediately below is an MPU guard.
   rp2_core0_entry installs the guard after RAM initialization and before Swift. */
STACK_RESERVED_BYTES = 8K;
STACK_BOTTOM = STACK_TOP - STACK_RESERVED_BYTES;
STACK_GUARD_BYTES = 4K;
STACK_GUARD_BOTTOM = STACK_BOTTOM - STACK_GUARD_BYTES;
/* Cortex-M0+ MPU SIZE = log2(region bytes) - 1. ASSERT below requires a power of
   two, so LOG2CEIL is exact. Compute this at link time, not during startup. */
STACK_GUARD_MPU_SIZE = LOG2CEIL(STACK_GUARD_BYTES) - 1;

/* Core 1 has an independent 8 KiB stack and a 4 KiB MPU guard matching core 0's.
   Keep both core 1 regions below core 0's guard; only core 1 protects this guard. */
CORE1_STACK_TOP = STACK_GUARD_BOTTOM;
CORE1_STACK_RESERVED_BYTES = 8K;
CORE1_STACK_BOTTOM = CORE1_STACK_TOP - CORE1_STACK_RESERVED_BYTES;
CORE1_STACK_GUARD_BYTES = STACK_GUARD_BYTES;
CORE1_STACK_GUARD_BOTTOM = CORE1_STACK_BOTTOM - CORE1_STACK_GUARD_BYTES;

SECTIONS {
    /* The first 256 bytes are loaded by ROM. KEEP prevents garbage collection.
       build.sh supplies a downloaded boot2 blob after checking its CRC. */
    .boot2 ORIGIN(FLASH) : {
        KEEP(*(.boot2 .boot2.*))
    } > FLASH

    /* Firmware convention: place vectors at 0x10000100, immediately after boot2.
       boot2 sets VTOR and MSP, then branches to the reset handler.
       16 Cortex-M0+ core slots + 26 external IRQs = 42 words = 168 bytes. */
    .vectors (ORIGIN(FLASH) + BOOT2_BYTES) : {
        __vector_table = .;
        LONG(STACK_TOP) /* Slot 0: initial MSP; the stack grows down from the top of SRAM. */
        LONG(rp2_core0_entry) /* Slot 1: reset handler address, including the function symbol's Thumb bit. */
        /* Route unused exceptions and reserved slots to the default fault handler. */
        LONG(rp2_fault) /* Slot  2: NMI */
        LONG(rp2_fault) /* Slot  3: HardFault */
        LONG(rp2_fault) /* Slot  4: Reserved (not implemented on Cortex-M0+) */
        LONG(rp2_fault) /* Slot  5: Reserved (not implemented on Cortex-M0+) */
        LONG(rp2_fault) /* Slot  6: Reserved (not implemented on Cortex-M0+) */
        LONG(rp2_fault) /* Slot  7: Reserved (not implemented on Cortex-M0+) */
        LONG(rp2_fault) /* Slot  8: Reserved (not implemented on Cortex-M0+) */
        LONG(rp2_fault) /* Slot  9: Reserved (not implemented on Cortex-M0+) */
        LONG(rp2_fault) /* Slot 10: Reserved (not implemented on Cortex-M0+) */
        LONG(rp2_fault) /* Slot 11: SVCall */
        LONG(rp2_fault) /* Slot 12: Reserved (not implemented on Cortex-M0+) */
        LONG(rp2_fault) /* Slot 13: Reserved (not implemented on Cortex-M0+) */
        LONG(rp2_fault) /* Slot 14: PendSV */
        LONG(rp2_fault) /* Slot 15: SysTick */
        /* External IRQs begin at slot 16. All currently use the default handler. */
        LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) /* IRQ 0..3 */
        LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) /* IRQ 4..7 */
        LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) /* IRQ 8..11 */
        LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) /* IRQ 12..15 */
        LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) /* IRQ 16..19 */
        LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) /* IRQ 20..23 */
        LONG(rp2_fault) LONG(rp2_fault) /* IRQ 24..25 */
    } > FLASH

    /* Place executable code and read-only constants in flash. */
    .text : ALIGN(4) {
        *(.text .text.*)
        *(.rodata .rodata.*)
        . = ALIGN(4);
    } > FLASH

    /* ARM EHABI unwind index; separate from RP-specific boot metadata. */
    .ARM.exidx : { *(.ARM.exidx*) } > FLASH

    /* The Global Offset Table (GOT) contains addresses used by Swift to find
       external symbols. Static linking fixes these addresses, so keep the table
       in flash where startup can read it before RAM has been initialized. */
    .got : ALIGN(4) { *(.got .got.*) } > FLASH

    /* .data stores initial values for RAM variables, such as count = 123.
       Store their initial bytes in flash; rp2_core0_entry copies them to RAM.
       .bss contains zero-initialized variables; rp2_core0_entry fills this range with zero.
       Align each boundary to four bytes so startup can copy or clear one UInt32 at a time.
       The boundary symbols name addresses; they do not allocate additional RAM variables. */
    .data : ALIGN(4) {
        __data_start = .;
        *(.data .data.*) *(.sdata .sdata.*)
        . = ALIGN(4);
        __data_end = .;
    } > RAM AT> FLASH
    __data_load_start = LOADADDR(.data); /* Flash address of the initial .data bytes */

    .bss (NOLOAD) : ALIGN(4) {
        __bss_start = .;
        *(.bss .bss.*) *(.sbss .sbss.*) *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > RAM

    /* Discard unused notes, Swift module hashes, and autolink directives. */
    /DISCARD/ : { *(.comment) *(.note*) *(.swift_modhash) *(.swift1_autolink_entries) }
    /* Keep initialized globals below the reserved stack area.
       Startup must not clear or overwrite the stack it is already using. */
    ASSERT(__bss_end <= CORE1_STACK_GUARD_BOTTOM,
           "RAM globals overlap the core 1 stack guard")
    /* Fixed layout checks belong here; reset checks only the actual boot MSP
       and protection hardware. Reject bad layouts before producing firmware. */
    ASSERT(STACK_BOTTOM < STACK_TOP, "Stack reservation must not be empty")
    ASSERT(STACK_GUARD_BOTTOM >= ORIGIN(RAM) && STACK_GUARD_BOTTOM <= STACK_BOTTOM,
           "Stack guard must lie in SRAM below the stack")
    ASSERT((STACK_TOP & 7) == 0 && (STACK_BOTTOM & 7) == 0,
           "Stack bounds must be 8-byte aligned")
    ASSERT(STACK_GUARD_BYTES >= 256 && (STACK_GUARD_BYTES & (STACK_GUARD_BYTES - 1)) == 0,
           "MPU guard size must be a power of two and at least 256 bytes")
    ASSERT((STACK_GUARD_BOTTOM & (STACK_GUARD_BYTES - 1)) == 0,
           "MPU guard must be aligned to its size")
    ASSERT(CORE1_STACK_BOTTOM < CORE1_STACK_TOP && CORE1_STACK_TOP <= STACK_GUARD_BOTTOM,
           "Core stacks must be separate and nonempty")
    ASSERT(CORE1_STACK_GUARD_BOTTOM >= ORIGIN(RAM), "Core 1 stack guard must lie in SRAM")
    ASSERT((CORE1_STACK_TOP & 7) == 0 && (CORE1_STACK_BOTTOM & 7) == 0,
           "Core 1 stack bounds must be 8-byte aligned")
    ASSERT((CORE1_STACK_GUARD_BOTTOM & (CORE1_STACK_GUARD_BYTES - 1)) == 0,
           "Core 1 MPU guard must be aligned to its size")

    /* Check boot2 size here. Tests/Scripts/verify-boot2.py checks its CRC and clock divisor. */
    ASSERT(SIZEOF(.boot2) == BOOT2_BYTES,
           "RP2040 needs a 256-byte .boot2 including its CRC")
    ASSERT(SIZEOF(.vectors) == (16 + 26) * 4, "Unexpected RP2040 vector table size")
}
