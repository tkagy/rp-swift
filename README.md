<!--
Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
SPDX-License-Identifier: MIT
-->

# Firmware for RP2350

This firmware is written in Swift.

## Requirements

- Embedded Swift 6.x
- `ld.lld`
    + Creates an ELF firmware image from compiled code.
- `picotool`
    + Converts ELF firmware images to UF2.

## How to Build

Run the build script from this directory:

```sh
Scripts/build.sh RP2350
```

## Build Outputs

- `.build/RP2350/RP2.elf`
- `.build/RP2350/RP2.uf2`

## License

Licensed under the [MIT License](LICENSE).
