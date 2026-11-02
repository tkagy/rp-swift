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
ENTRY(rp2_reset)

/* Resolve only the memory helper names used by the current firmware.
   memcpy/memmove share the Arm ABI argument order; their return values are ignored.
   memclr4 shares the zero-fill adapter. Add further aliases only when needed. */
PROVIDE(__aeabi_memcpy = memcpy);
PROVIDE(__aeabi_memcpy4 = memcpy);
PROVIDE(__aeabi_memmove = memmove);
PROVIDE(__aeabi_memmove4 = memmove);
PROVIDE(__aeabi_memclr4 = __aeabi_memclr);

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

/* Project policy: reserve the top 4 KiB of SRAM for the stack; this is not a chip requirement. */
STACK_RESERVED_BYTES = 4K;

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
        LONG(STACK_TOP) /* Slot 0: initial MSP; the stack grows down from the top of SRAM. */
        LONG(rp2_reset) /* Slot 1: reset handler address, including the function symbol's Thumb bit. */
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
       Store their initial bytes in flash; resetHandler copies them to RAM.
       .bss contains zero-initialized variables; resetHandler fills this range with zero.
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
    ASSERT(__bss_end <= STACK_TOP - STACK_RESERVED_BYTES,
           "RAM globals overlap the reserved 4 KiB stack")

    /* Check boot2 size here. Tests/Scripts/verify-boot2.py checks its CRC and clock divisor. */
    ASSERT(SIZEOF(.boot2) == BOOT2_BYTES,
           "RP2040 needs a 256-byte .boot2 including its CRC")
    ASSERT(SIZEOF(.vectors) == (16 + 26) * 4, "Unexpected RP2040 vector table size")
}
