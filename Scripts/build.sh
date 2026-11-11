#!/usr/bin/env bash
# Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
# SPDX-License-Identifier: MIT

set -euo pipefail
PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# Build both chips by default; an explicit target selects just that chip.
CHIP=
MODE=
CHIP_SELECTED=0
for ARG in "$@"; do
    case "$ARG" in
        RP2040|RP2350)
            if [[ "$CHIP_SELECTED" == 1 ]]; then
                printf 'Choose only one target: RP2040 or RP2350\n' >&2
                exit 1
            fi
            CHIP="$ARG"
            CHIP_SELECTED=1
            ;;
        --object-only|--print-chip)
            if [[ -n "$MODE" ]]; then
                printf 'Choose only one build mode\n' >&2
                exit 1
            fi
            MODE="$ARG"
            ;;
        *) printf 'Usage: bash %s [RP2040|RP2350] [--object-only|--print-chip]\n' "${BASH_SOURCE[0]}" >&2; exit 1 ;;
    esac
done
if [[ "$CHIP_SELECTED" == 0 ]]; then
    for TARGET_CHIP in RP2040 RP2350; do
        BUILD_ARGS=("$TARGET_CHIP")
        if [[ -n "$MODE" ]]; then
            BUILD_ARGS+=("$MODE")
        fi
        bash "$PROJECT_DIR/Scripts/build.sh" "${BUILD_ARGS[@]}"
    done
    exit 0
fi
case "$CHIP" in
    # Keep the Swift ABI target and UF2 family matched to the selected chip.
    RP2040) SWIFT_TARGET=armv6m-none-none-eabi; UF2_FAMILY=rp2040 ;;
    RP2350) SWIFT_TARGET=armv8m.main-none-none-eabi; UF2_FAMILY=rp2350-arm-s ;;
esac
case "$MODE" in
    --print-chip) printf '%s\n' "$CHIP"; exit 0 ;;
    ''|--object-only) ;;
esac
BUILD_DIR="$PROJECT_DIR/.build/$CHIP"
mkdir -p "$BUILD_DIR"

# Compile both chips' firmware from the same sources with explicit chip selection.
SWIFT_OBJECT="$BUILD_DIR/RP2.o"
swiftc -target "$SWIFT_TARGET" \
    -D "$CHIP" \
    -module-cache-path "$BUILD_DIR/ModuleCache" \
    -enable-experimental-feature Embedded \
    -enable-experimental-feature Extern \
    -wmo -Osize -parse-as-library \
    -Xfrontend -function-sections \
    -Xfrontend -disable-stack-protector \
    -emit-object "$PROJECT_DIR"/Sources/*.swift \
    -o "$SWIFT_OBJECT"

MEMORY_OBJECT="$BUILD_DIR/Memory.o"
clang -target "$SWIFT_TARGET" -D "$CHIP" -c \
    "$PROJECT_DIR/Sources/Memory.S" -o "$MEMORY_OBJECT"

if [[ "$MODE" == --object-only ]]; then
    printf 'Compiled %s (%s)\n' "$SWIFT_OBJECT" "$SWIFT_TARGET"
    exit 0
fi

LINK_OBJECTS=("$SWIFT_OBJECT" "$MEMORY_OBJECT")
if [[ "$CHIP" == RP2040 ]]; then
    # Download the W25Q080 boot2 with SPI clock divisor 2 from rp-rs v0.3.0.
    # Upstream: https://github.com/rp-rs/rp2040-boot2/tree/v0.3.0
    # License: BSD-3-Clause. The binary is fetched at build time, not vendored here.
    # Pin the commit so downloads are reproducible and the verifier checks a known blob.
    BOOT2_COMMIT=b46a77eb4406c4d06837345bdad2f906d483b73f
    # Keep the downloaded blob beside the RP2040 build intermediates only while needed.
    BOOT2_DIR="$BUILD_DIR"
    BOOT2_BIN="$BOOT2_DIR/boot2_w25q080.padded.bin"
    BOOT2_URL="https://raw.githubusercontent.com/rp-rs/rp2040-boot2/$BOOT2_COMMIT/bin/boot2_w25q080.padded.bin"
    mkdir -p "$BOOT2_DIR"
    if [[ ! -f "$BOOT2_BIN" ]]; then
        # Download to a temporary file; cache it only after validation succeeds.
        BOOT2_TEMP=$(mktemp "$BOOT2_DIR/download.XXXXXX")
        trap 'rm -f -- "$BOOT2_TEMP"' EXIT
        curl --fail --location --connect-timeout 10 --max-time 60 \
            "$BOOT2_URL" -o "$BOOT2_TEMP"
        python3 "$PROJECT_DIR/Scripts/verify-boot2.py" "$BOOT2_TEMP"
        mv -- "$BOOT2_TEMP" "$BOOT2_BIN"
        trap - EXIT
    else
        python3 "$PROJECT_DIR/Scripts/verify-boot2.py" "$BOOT2_BIN"
    fi
    # Wrap the supplied binary as an ELF section for the linker; no assembly is needed.
    llvm-objcopy -I binary -O elf32-littlearm -B arm \
        --rename-section .data=.boot2,alloc,load,readonly,data,contents \
        "$BOOT2_BIN" "$BUILD_DIR/boot2.o"
    rm -f -- "$BOOT2_BIN"
    LINK_OBJECTS+=("$BUILD_DIR/boot2.o")
fi

# The linker script supplies the chip-specific memory layout and boot metadata.
ld.lld -T "$PROJECT_DIR/Configs/${CHIP,,}.ld" \
    --gc-sections --build-id=none \
    -Map="$BUILD_DIR/RP2.map" \
    "${LINK_OBJECTS[@]}" -o "$BUILD_DIR/RP2.elf"

# Convert the linked ELF to UF2 using the matching family identifier.
picotool uf2 convert "$BUILD_DIR/RP2.elf" "$BUILD_DIR/RP2.uf2" --family "$UF2_FAMILY"
printf 'Built %s\n' "$BUILD_DIR/RP2.elf" "$BUILD_DIR/RP2.uf2"
