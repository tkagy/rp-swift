<!--
Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
SPDX-License-Identifier: MIT
-->

# Firmware for RP2040 / RP2350

This firmware is written in Swift.

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
        * Downloads boot2 during the build.
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

## License

Licensed under the [MIT License](LICENSE).
