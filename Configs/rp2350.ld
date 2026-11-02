/* Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
 * SPDX-License-Identifier: MIT
 */

/* RP2350 Arm Secure firmware configuration.
   RP2350 Datasheet (section numbers from the 2025-07-29 edition):
   https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf
     2.2.2 XIP / 2.2.3 SRAM: memory addresses
     3.7.1 Features: 52 external IRQs on Cortex-M33
     5.1.12 Flash image boot: block search within the first 4 KiB
     5.9.1: metadata block structure
     5.9.3.1: IMAGE_DEF image_type_flags
     5.9.5.1: minimal 20-byte Arm IMAGE_DEF
   Compare RP2040 Datasheet 2.8.1.3, which uses boot2 rather than IMAGE_DEF:
   https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf */

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
PROVIDE(__aeabi_memclr4 = __aeabi_memclr);

/* Addresses are chip specifications. The flash region size is a project configuration. */
FLASH_BASE = 0x10000000; /* XIP: start of the CPU address window for external flash */
SRAM_BASE = 0x20000000;  /* Start of the contiguous SRAM address range */
FLASH_BYTES = 4M;
SRAM_BYTES = 520K;       /* 512 KiB main SRAM plus two 4 KiB scratch banks */

/* Sections 5.9.1 / 5.9.5.1: fixed markers identifying the start and end of a metadata block. */
PICOBIN_BLOCK_MARKER_START = 0xFFFFDED3;
PICOBIN_BLOCK_MARKER_END = 0xAB123579;
PICOBIN_ITEM_IMAGE_TYPE = 0x42; /* IMAGE_TYPE item tag; one-byte size field */
PICOBIN_ITEM_LAST = 0xFF;       /* End-of-items tag; two-byte size field */

/* Section 5.9.3.1: 16-bit image_type_flags = 0x1021.
   [ 3: 0] = 1: executable image
   [ 5: 4] = 2: Arm Secure
   [10: 8] = 0: Arm CPU
   [14:12] = 1: RP2350
   All remaining bits (reserved and TBYB) are zero.
   Secure describes CPU execution state, not whether the image is signed. */
PICOBIN_IMAGE_TYPE_RP2350_ARM_SECURE = (1 << 12) | (0 << 8) | (2 << 4) | 1;
BOOTROM_SEARCH_BYTES = 4K; /* Initial flash range searched for a block loop */

MEMORY {
    FLASH (rx) : ORIGIN = FLASH_BASE, LENGTH = FLASH_BYTES
    RAM (rwx) : ORIGIN = SRAM_BASE, LENGTH = SRAM_BYTES
}
STACK_TOP = ORIGIN(RAM) + LENGTH(RAM); /* 0x20082000: just past SRAM, aligned to 8 bytes */

/* Project policy: reserve the top 4 KiB of SRAM for the stack; this is not a chip requirement. */
STACK_RESERVED_BYTES = 4K;

SECTIONS {
    /* Section 5.9.5.1: without a VECTOR_TABLE item, ROM uses the image start.
       16 Cortex-M33 core slots + 52 external IRQs = 68 words = 272 bytes. */
    .vectors ORIGIN(FLASH) : {
        LONG(STACK_TOP) /* Slot 0: initial MSP; the stack grows down from the top of SRAM. */
        LONG(rp2_reset) /* Slot 1: reset handler address, including the function symbol's Thumb bit. */
        /* Route unused exceptions and reserved slots to the default fault handler. */
        LONG(rp2_fault) /* Slot  2: NMI */
        LONG(rp2_fault) /* Slot  3: HardFault */
        LONG(rp2_fault) /* Slot  4: MemManage */
        LONG(rp2_fault) /* Slot  5: BusFault */
        LONG(rp2_fault) /* Slot  6: UsageFault */
        LONG(rp2_fault) /* Slot  7: SecureFault */
        LONG(rp2_fault) /* Slot  8: Reserved */
        LONG(rp2_fault) /* Slot  9: Reserved */
        LONG(rp2_fault) /* Slot 10: Reserved */
        LONG(rp2_fault) /* Slot 11: SVCall */
        LONG(rp2_fault) /* Slot 12: DebugMonitor */
        LONG(rp2_fault) /* Slot 13: Reserved */
        LONG(rp2_fault) /* Slot 14: PendSV */
        LONG(rp2_fault) /* Slot 15: SysTick */
        /* External IRQs begin at slot 16. All currently use the default handler. */
        LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) /* IRQ 0..3 */
        LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) /* IRQ 4..7 */
        LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) /* IRQ 8..11 */
        LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) /* IRQ 12..15 */
        LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) /* IRQ 16..19 */
        LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) /* IRQ 20..23 */
        LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) /* IRQ 24..27 */
        LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) /* IRQ 28..31 */
        LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) /* IRQ 32..35 */
        LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) /* IRQ 36..39 */
        LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) /* IRQ 40..43 */
        LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) /* IRQ 44..47 */
        LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) LONG(rp2_fault) /* IRQ 48..51 */
    } > FLASH

    /* Minimal Arm IMAGE_DEF from section 5.9.5.1: five words (20 bytes).
       This is data consumed by ROM, not executable boot code.
       It follows the vectors at address 0x10000110. */
    .picobin : {
        LONG(PICOBIN_BLOCK_MARKER_START)

        /* Little-endian bytes 42 01 21 10 form the word 0x10210142.
           [ 7: 0]: item tag 0x42
           [15: 8]: item length, one word including this header
           [31:16]: image_type_flags = 0x1021 */
        LONG((PICOBIN_IMAGE_TYPE_RP2350_ARM_SECURE << 16) |
             (1 << 8) | PICOBIN_ITEM_IMAGE_TYPE)

        /* Little-endian bytes FF 01 00 00 form the word 0x000001FF.
           [ 7: 0]: end-of-items tag 0xFF
           [23: 8]: preceding item words: one (IMAGE_TYPE only)
           [31:24]: zero padding. Exclude the start marker and this end item from the count. */
        LONG((1 << 8) | PICOBIN_ITEM_LAST)

        LONG(0) /* Next-block relative offset 0: a single-block loop pointing to itself */
        LONG(PICOBIN_BLOCK_MARKER_END)
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

    /* Four bytes per word: detect missing core exception or external IRQ entries. */
    ASSERT(SIZEOF(.vectors) == (16 + 52) * 4, "Unexpected RP2350 vector table size")
    ASSERT(SIZEOF(.picobin) == 5 * 4, "Minimum IMAGE_DEF must be 20 bytes")
    /* ROM searches the first 4 KiB for a loop start. Keep this entire block within that range. */
    ASSERT(ADDR(.picobin) + SIZEOF(.picobin) <= ORIGIN(FLASH) + BOOTROM_SEARCH_BYTES,
           "RP2350 boot block must be in the first 4 KiB")
}
