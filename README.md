<!--
Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
SPDX-License-Identifier: MIT
-->

# Firmware for RP2040 / RP2350

Bare-metal firmware written in Embedded Swift, with a UART command console.

## Design Concepts

- Keep chip-specific addresses and definitions in each chip's source file.
- Access hardware registers directly from Swift.
- Use fixed-size storage without heap allocation.

## Requirements

| Tool | Purpose | Target |
| --- | --- | --- |
| Bash | Run the build script | Both |
| Swift 6.x with Embedded Swift support | Compile the firmware | Both |
| `clang` with Arm support | Assemble startup and memory operations | Both |
| `ld.lld` | Link the firmware into an ELF file | Both |
| `picotool` | Convert ELF to UF2 | Both |
| `curl` | Download boot2 when it is not cached | RP2040 |
| `llvm-objcopy` | Convert the boot2 binary into a linker input | RP2040 |
| Python 3.x, standard library only | Validate boot2 before linking | RP2040 |

RP2040 uses a boot2 binary from
[rp-rs/rp2040-boot2 v0.3.0](https://github.com/rp-rs/rp2040-boot2/tree/v0.3.0)
under the BSD-3-Clause license. The build script downloads a pinned version and
caches it in `.build/RP2040/`. Boot2 initializes flash access before Swift starts.

## How to Build

Run the build script from this directory:

```sh
bash Scripts/build.sh           # Both chips
bash Scripts/build.sh RP2040    # RP2040 only
bash Scripts/build.sh RP2350    # RP2350 only
```

## Build Outputs

Each target writes its output to `.build/RP2040/` or `.build/RP2350/`:

| File | Contents |
| --- | --- |
| `RP2.elf` | Linked firmware with symbols |
| `RP2.uf2` | Firmware in UF2 format |
| `RP2.map` | Section and symbol placement |

## Assembly Sources

`RP2.S` initializes RAM, validates/protects the stack, and handles faults.
`Memory.S` supplies memory operations and SRAM diagnostics, including stack
painting. The build links both assembly objects with the Swift object.

## Startup

```text
Boot ROM / boot2
    |
    v
rp2_reset (RP2.S)
    | Mask ordinary interrupts; preserve the previous mask
    | Copy .data initial values from flash to SRAM
    | Clear .bss, including startup diagnostics
    | Call rp2_stack_initialize: validate MSP and enable hardware protection
    |   RP2040: configure the MPU guard
    |   RP2350: set MSPLIM
    |   Failure: record the error and stop in rp2_fault
    | Call Memory.S rp2_stack_paint: paint unused stack words below MSP
    | Restore the previous interrupt mask
    v
rp2_start (RP2.swift: first Swift function)
    |
    v
RP2.initialize(): clock -> timer -> console -> UART
    |
    v
RP2.main()
```

## Build-time SRAM Report

After linking, `Scripts/build.sh` reports SRAM allocation in bytes for each chip.
The report reads symbols from the linked ELF using `llvm-nm`. The same allocation
information is available from `Memory.SRAM` at run time. Object-only builds do not
link or print this report.

| Field | Meaning |
| --- | --- |
| Total | Linker `SRAM_BYTES`: RP2040 264 KiB; RP2350 520 KiB |
| Static | `__bss_end - SRAM_BASE`, including `.data`, `.bss`, and alignment |
| Stack/guard | Entire stack reservation plus any MPU guard |
| Allocated | Static plus Stack/guard |
| Remaining | Total minus Allocated; room for static storage to grow |

Allocated includes unused reserved stack bytes. Remaining excludes the entire
stack/guard reservation and is not allocator-managed memory; there is no heap.
This report does not measure current or peak stack usage.

## SRAM Allocation Policy

Code and read-only constants remain in flash. SRAM holds global data below the
stack; the space between them is unused and has no heap allocator.

| Region | Use | Size policy |
| --- | --- | --- |
| `.data` | Global data with initial values stored in flash | Determined by the compiler and linker |
| `.bss` | Global data cleared to zero at startup | Determined by the compiler and linker |
| Unallocated space | Room for global data to grow | Remaining SRAM below the stack and any guard region |
| Stack | Local values, saved registers, and temporary storage | Reserve 8 KiB on both chips |
| MPU guard (RP2040 only) | Deny accesses immediately below the stack | Reserve another 4 KiB |

Global fixed-size buffers count toward `.data` or `.bss`; the linker places them
below the reserved stack regions shown in the diagrams.

```text
RP2040: 264 KiB total (270,336 bytes)

0x20042000 +----------------------------------+ STACK_TOP / SRAM end
           | Stack reservation                |
           | 8,192 bytes (8 KiB)               |
           | Grows downward: v                |
0x20040000 +----------------------------------+ STACK_BOTTOM
           | MPU guard: no access             |
           | 4,096 bytes (4 KiB)               |
0x2003F000 +----------------------------------+ STACK_GUARD_BOTTOM
           | Unused SRAM                      |
           |                                  |
           +----------------------------------+ __bss_end <= STACK_GUARD_BOTTOM
           | .bss: zero-initialized globals   |
           +----------------------------------+ __bss_start = __data_end
           | .data: initialized globals       |
0x20000000 +----------------------------------+ __data_start / SRAM start

RP2350: 520 KiB total (532,480 bytes)

0x20082000 +----------------------------------+ STACK_TOP / SRAM end
           | Stack reservation                |
           | 8,192 bytes (8 KiB)               |
           | Grows downward: v                |
0x20080000 +----------------------------------+ STACK_BOTTOM / MSPLIM
           | Unused SRAM                      |
           |                                  |
           +----------------------------------+ __bss_end <= STACK_BOTTOM
           | .bss: zero-initialized globals   |
           +----------------------------------+ __bss_start = __data_end
           | .data: initialized globals       |
0x20000000 +----------------------------------+ __data_start / SRAM start
```

The linker enforces the `.bss` limits shown in the diagram. RP2040 protects a 4 KiB
region below its 8 KiB stack with the MPU. RP2350 uses `MSPLIM` at the bottom of
its 8 KiB stack. Startup faults stop in `rp2_fault` before normal Swift code runs.

## Console

Connect UART0 on GP0/TX and GP1/RX to a 3.3 V UART adapter with shared GND.
Use 115200 baud, 8N1, with local echo and flow control disabled.
The prompt includes the chip name. Press Enter to show it again.

| Input | Action |
| --- | --- |
| `help` | List commands |
| `reset` | Restart the firmware |
| `bootsel` | Enter USB boot mode |
| Tab | Complete a command or list matching commands |
| Up or Ctrl+P | Recall an older command from the shared five-entry history |
| Down or Ctrl+N | Recall a newer command; past the newest entry, restore unfinished input |

Editing a recalled command makes it independent of history. Console I/O is
serviced by repeated calls to `Console.poll()` in the main loop.

## License

Licensed under the [MIT License](LICENSE).
