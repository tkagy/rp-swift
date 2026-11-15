<!--
Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
SPDX-License-Identifier: MIT
-->

# Firmware for RP2040 / RP2350

Firmware for RP2040 (Arm Cortex-M0+) and RP2350 (Arm Cortex-M33),
written primarily in Embedded Swift.

## Design Concepts

- Organize each chip's peripherals and registers using enums and structs.
- Use Embedded Swift and direct register access for firmware logic.
- Use assembly for startup, volatile memory access, and RP2040 atomic operations
  that require explicit CPU instructions.

## Requirements

- `Swift` 6
    + Requires Embedded Swift and `Extern` support.
    + Compiles Swift sources for the target microcontroller, including references to assembly symbols.
- `clang`
    + Requires Arm target support.
    + Assembles startup and memory access code.
- `ld.lld`
    + Requires Arm target support.
    + Links object files using the chip's memory layout to produce the ELF firmware image.
- `picotool`
    + Requires `uf2 convert` support.
    + Converts the ELF image to UF2 for USB flashing.
- `llvm-objcopy` (only for RP2040)
    + Extracts and updates binary sections in object files.
- `Python` 3 (only for RP2040)
    + Uses the standard library only.
    + Finalizes startup data and calculates its checksum.
- `OpenOCD` (only for SWD flashing)
    + Requires support for the target chip and your debug probe.
    + Writes the ELF image to flash through SWD.

## How to Build

Run the build script from this directory:

```sh
bash Scripts/build.sh           # Both chips
bash Scripts/build.sh RP2040    # RP2040 only
bash Scripts/build.sh RP2350    # RP2350 only
```

## Build Outputs

Outputs are placed in `.build/RP2040/` or `.build/RP2350/`:

- `RP2.elf`
    + Firmware image with addresses and symbols, used for SWD flashing and debugging.
- `RP2.uf2`
    + Firmware image for USB flashing in `BOOTSEL` mode.
- `RP2.map`
    + Linker report showing the addresses and sizes of functions and data.
    + Used to inspect memory placement and usage; not needed for flashing.

## How to Run

### USB (`BOOTSEL`) for deployment

1. Enter `BOOTSEL` mode after connecting your board to your host computer.
2. Copy `RP2.uf2` matching your board's chip to the board's USB drive.
3. Wait for the board to automatically reboot and run the firmware.

### SWD (`OpenOCD`) for development

Connect the powered board's `SWDIO`, `SWCLK`, `RUN`, and `GND` pins
to a debug probe, such as a Raspberry Pi.

```sh
# RP2040 (Arm Cortex-M0+)
openocd -f $CFG_DIR/rp-swd-rp2040.cfg -f target/rp2040.cfg \
    -c "program .build/RP2040/RP2.elf verify reset exit"

# RP2350 (Arm Cortex-M33)
openocd -f $CFG_DIR/rp-swd-rp2350.cfg -f target/rp2350.cfg \
    -c "program .build/RP2350/RP2.elf verify reset exit"
```

## License

Licensed under the [MIT License](LICENSE).
