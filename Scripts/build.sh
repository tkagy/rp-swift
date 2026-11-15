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

# Compile shared drivers with only the selected chip's implementation.
SWIFT_SOURCES=()
for SOURCE in "$PROJECT_DIR"/Sources/*.swift; do
    case "${SOURCE##*/}" in
        RP2040.swift|RP2350.swift)
            if [[ "${SOURCE##*/}" != "$CHIP.swift" ]]; then continue; fi
            ;;
    esac
    SWIFT_SOURCES+=("$SOURCE")
done
SWIFT_OBJECT="$BUILD_DIR/RP2.o"
swiftc -target "$SWIFT_TARGET" \
    -D "$CHIP" \
    -module-cache-path "$BUILD_DIR/ModuleCache" \
    -enable-experimental-feature Embedded \
    -enable-experimental-feature Extern \
    -wmo -Osize -parse-as-library \
    -Xfrontend -function-sections \
    -Xfrontend -disable-stack-protector \
    -emit-object "${SWIFT_SOURCES[@]}" \
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
    # Assemble the self-written boot2, generate its checksum, then patch the
    # section before linking it at the start of flash.
    BOOT2_OBJECT="$BUILD_DIR/boot2.o"
    BOOT2_RAW="$BUILD_DIR/boot2.raw.bin"
    BOOT2_BIN="$BUILD_DIR/boot2.bin"
    clang -target "$SWIFT_TARGET" -D "$CHIP" -c \
        "$PROJECT_DIR/Sources/RP2.S" -o "$BOOT2_OBJECT"
    llvm-objcopy --dump-section ".boot2=$BOOT2_RAW" "$BOOT2_OBJECT"
    python3 "$PROJECT_DIR/Scripts/finalize-boot2.py" "$BOOT2_RAW" "$BOOT2_BIN"
    llvm-objcopy --update-section ".boot2=$BOOT2_BIN" "$BOOT2_OBJECT"
    rm -f -- "$BOOT2_RAW" "$BOOT2_BIN"
    LINK_OBJECTS+=("$BOOT2_OBJECT")
fi

# The linker script supplies the chip-specific memory layout and boot metadata.
ld.lld -T "$PROJECT_DIR/Configs/${CHIP,,}.ld" \
    --gc-sections --build-id=none \
    -Map="$BUILD_DIR/RP2.map" \
    "${LINK_OBJECTS[@]}" -o "$BUILD_DIR/RP2.elf"

# Convert the linked ELF to UF2 using the matching family identifier.
picotool uf2 convert "$BUILD_DIR/RP2.elf" "$BUILD_DIR/RP2.uf2" --family "$UF2_FAMILY"
printf 'Built %s\n' "$BUILD_DIR/RP2.elf" "$BUILD_DIR/RP2.uf2"
