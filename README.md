<!--
Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
SPDX-License-Identifier: MIT
-->

# Firmware for RP2040 / RP2350

This firmware is written in Swift and provides a UART command console.

## Design Concepts

- Organize each chip's peripherals and registers using enums and structs.
- Use Embedded Swift and direct register access for firmware logic.

## Requirements

- Embedded Swift 6.x
- `ld.lld`
    + Creates an ELF firmware image from compiled code.
- `picotool`
    + Converts ELF firmware images to UF2.

---

- Additional requirements for RP2040
    + boot2
        * Initializes flash access before the Swift firmware starts.
        * [rp-rs/rp2040-boot2 v0.3.0](https://github.com/rp-rs/rp2040-boot2/tree/v0.3.0), BSD-3-Clause
    + `curl`
        * Downloads boot2 only when it is missing from `.build/RP2040/`
    + `llvm-objcopy`
        * Wraps the boot2 binary in a linkable object file.
    + Python 3.x with the following standard library modules:
        * `pathlib`
        * `struct`
        * `sys`

## How to Build

Run the build script from this directory:

```sh
Scripts/build.sh           # Both chips
Scripts/build.sh RP2040    # RP2040 only
Scripts/build.sh RP2350    # RP2350 only
```

## Build Outputs

- `.build/RP2350/RP2.elf`
- `.build/RP2350/RP2.uf2`
- `.build/RP2040/RP2.elf`
- `.build/RP2040/RP2.uf2`

## Console

Connect UART0 on GP0/TX and GP1/RX to a 3.3 V UART adapter with shared GND.
Use 115200 baud, 8N1, with local echo and flow control disabled.
Press Enter for the chip-named prompt and enter `help` to list commands.
Press Tab to complete a command; Tab on an empty line lists the candidates.
Up/Down or Ctrl+P/Ctrl+N recall the five most recent submitted commands.
Down or Ctrl+N past the newest entry restores the text you were typing.
`bootsel` enters USB boot mode; `reset` restarts the firmware.

## License

Licensed under the [MIT License](LICENSE).
