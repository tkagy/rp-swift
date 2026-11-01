/* Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
 * SPDX-License-Identifier: MIT
 */

/* RP2350 Arm Secure firmware configuration.
   RP2350 Datasheet (section numbers from the 2025-07-29 edition):
   https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf
     2.2.2 XIP / 2.2.3 SRAM: memory addresses
     5.1.12 Flash image boot: block search within the first 4 KiB
     5.9.1: metadata block structure
     5.9.3.1: IMAGE_DEF image_type_flags
     5.9.5.1: minimal 20-byte Arm IMAGE_DEF
   Compare RP2040 Datasheet 2.8.1.3, which uses boot2 rather than IMAGE_DEF:
   https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf */

ENTRY(rp2_reset)

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

SECTIONS {
    /* Section 5.9.5.1: ROM reads the initial stack pointer and reset vector here. */
    .vectors ORIGIN(FLASH) : {
        LONG(STACK_TOP) /* Slot 0: initial MSP; the stack grows down from the top of SRAM. */
        LONG(rp2_reset) /* Slot 1: reset handler address, including the function symbol's Thumb bit. */
    } > FLASH

    /* Minimal Arm IMAGE_DEF from section 5.9.5.1: five words (20 bytes).
       This is data consumed by ROM, not executable boot code.
       It follows the two-word vector table at address 0x10000008. */
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

    /* No stack unwinding is used by this firmware, so discard generated unwind entries. */
    /DISCARD/ : {
        *(.ARM.exidx*)
        *(.comment) *(.note*) *(.swift_modhash) *(.swift1_autolink_entries)
    }

    ASSERT(SIZEOF(.vectors) == 2 * 4, "Vector table must contain the stack pointer and reset vector")
    ASSERT(SIZEOF(.picobin) == 5 * 4, "Minimum IMAGE_DEF must be 20 bytes")
    /* ROM searches the first 4 KiB for a loop start. Keep this entire block within that range. */
    ASSERT(ADDR(.picobin) + SIZEOF(.picobin) <= ORIGIN(FLASH) + BOOTROM_SEARCH_BYTES,
           "RP2350 boot block must be in the first 4 KiB")
}
