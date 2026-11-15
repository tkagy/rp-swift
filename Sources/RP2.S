// Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
// SPDX-License-Identifier: MIT

.syntax unified
.thumb

#if RP2040

/// rp2040_boot2
//
// RP2040 ROM copies this 256-byte image to SRAM and enters with LR == 0.
// Keep boot2 to the standard 03h read path so it can start with an unknown
// SPI NOR device. The application later probes faster XIP modes from SRAM.
// Divider 4 is retained from the clock decision: it is conservative while the
// boot ROM leaves clk_sys on ROSC, and yields clk_sys / 4 after clock setup.
.equ RP2040_XIP_SSI_BASE,       0x18000000
.equ RP2040_SSI_CTRLR0,         0x00
.equ RP2040_SSI_CTRLR1,         0x04
.equ RP2040_SSI_SSIENR,         0x08
.equ RP2040_SSI_BAUDR,          0x14
.equ RP2040_SSI_SPI_CTRLR0,     0xf4
.equ RP2040_FLASH_SPI_DIVIDER,  4
.equ RP2040_SSI_CTRLR0_VALUE,   0x001f0300
.equ RP2040_SSI_SPI_CTRLR0_READ_03H, 0x03000218
.equ RP2040_FLASH_VECTOR_TABLE, 0x10000100
.equ RP2040_VTOR,               0xe000ed08
.equ RP2040_BOOT2_MAGIC_OFFSET, 248
.equ RP2040_BOOT2_PAYLOAD_BYTES, 252
.equ RP2040_XIP_PROBE_MAGIC,    0x07770777

.section .boot2,"ax",%progbits
.balign 4
.global rp2040_boot2
.type rp2040_boot2,%function
.thumb_func
rp2040_boot2:
    push {lr}
    ldr r3, =RP2040_XIP_SSI_BASE
    movs r1, #0
    str r1, [r3, #RP2040_SSI_SSIENR]
    movs r1, #RP2040_FLASH_SPI_DIVIDER
    str r1, [r3, #RP2040_SSI_BAUDR]
    ldr r1, =RP2040_SSI_CTRLR0_VALUE
    str r1, [r3, #RP2040_SSI_CTRLR0]
    ldr r1, =RP2040_SSI_SPI_CTRLR0_READ_03H
    ldr r0, =RP2040_XIP_SSI_BASE + RP2040_SSI_SPI_CTRLR0
    str r1, [r0]
    movs r1, #0
    str r1, [r3, #RP2040_SSI_CTRLR1]
    movs r1, #1
    str r1, [r3, #RP2040_SSI_SSIENR]

    // Return normally when called by software; on ROM entry, branch to the
    // vector table immediately after this boot2 image.
    pop {r0}
    cmp r0, #0
    bne .Lreturn
    ldr r0, =RP2040_FLASH_VECTOR_TABLE
    ldr r1, =RP2040_VTOR
    str r0, [r1]
    ldmia r0, {r0, r1}
    msr msp, r0
    bx r1
.Lreturn:
    bx r0

.ltorg
.org RP2040_BOOT2_MAGIC_OFFSET, 0
.global rp2040_xip_probe_magic
rp2040_xip_probe_magic:
    .word RP2040_XIP_PROBE_MAGIC
.org RP2040_BOOT2_PAYLOAD_BYTES, 0
.word 0 // Replaced with the RP2040 boot2 CRC32 by Scripts/finalize-boot2.py.
.size rp2040_boot2, .-rp2040_boot2

#endif
