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
    RP2040) SWIFT_TARGET=armv6m-none-none-eabi; ARM_CPU=cortex-m0plus; UF2_FAMILY=rp2040 ;;
    RP2350) SWIFT_TARGET=armv8m.main-none-none-eabi; ARM_CPU=cortex-m33; UF2_FAMILY=rp2350-arm-s ;;
esac
case "$MODE" in
    --print-chip) printf '%s\n' "$CHIP"; exit 0 ;;
    ''|--object-only) ;;
esac
BUILD_DIR="$PROJECT_DIR/.build/$CHIP"

# Compile both chips' firmware from the same sources with explicit chip selection.
SWIFT_OBJECT="$BUILD_DIR/RP2.o"
# Include driver directories without depending on shell globstar settings.
SWIFT_SOURCES=()
while IFS= read -r -d '' SWIFT_SOURCE; do
    SWIFT_SOURCES+=("$SWIFT_SOURCE")
done < <(find "$PROJECT_DIR/Sources" -type f -name '*.swift' -print0 | sort -z)
SWIFT_DEFINES=()
if [[ -n "${PRIVATE_TEST-}" ]]; then
    SWIFT_DEFINES+=(-D PRIVATE_TEST)
fi
swiftc -target "$SWIFT_TARGET" \
    -D "$CHIP" \
    "${SWIFT_DEFINES[@]}" \
    -module-cache-path "$BUILD_DIR/ModuleCache" \
    -enable-experimental-feature Embedded \
    -enable-experimental-feature Extern \
    -wmo -Osize -parse-as-library \
    -Xfrontend -function-sections \
    -Xfrontend -disable-stack-protector \
    -emit-object "${SWIFT_SOURCES[@]}" \
    -o "$SWIFT_OBJECT"

if [[ "$MODE" == --object-only ]]; then
    printf 'Compiled %s (%s)\n' "$SWIFT_OBJECT" "$SWIFT_TARGET"
    exit 0
fi

LINK_OBJECTS=("$SWIFT_OBJECT")
# Assemble startup/fault handling separately from memory primitives/diagnostics.
# --object-only emits only the Swift object. The asm- prefix distinguishes
# assembly outputs from Swift's RP2.o.
for ASSEMBLY_NAME in RP2 Memory; do
    ASSEMBLY_OBJECT="$BUILD_DIR/asm-$ASSEMBLY_NAME.o"
    clang -target arm-none-eabi -mcpu="$ARM_CPU" -mthumb -D "$CHIP" \
        -c "$PROJECT_DIR/Sources/$ASSEMBLY_NAME.S" -o "$ASSEMBLY_OBJECT"
    LINK_OBJECTS+=("$ASSEMBLY_OBJECT")
done
if [[ "$CHIP" == RP2040 ]]; then
    # Download the W25Q080 boot2 with SPI clock divisor 2 from rp-rs v0.3.0.
    # Upstream: https://github.com/rp-rs/rp2040-boot2/tree/v0.3.0
    # License: BSD-3-Clause. The binary is fetched at build time, not vendored here.
    # Pin the commit so downloads are reproducible and the verifier checks a known blob.
    BOOT2_COMMIT=b46a77eb4406c4d06837345bdad2f906d483b73f
    # Retain the downloaded blob beside the RP2040 build intermediates for reuse.
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
    LINK_OBJECTS+=("$BUILD_DIR/boot2.o")
fi

# The linker script supplies the chip-specific memory layout and boot metadata.
ld.lld -T "$PROJECT_DIR/Configs/${CHIP,,}.ld" \
    --gc-sections --build-id=none \
    -Map="$BUILD_DIR/RP2.map" \
    "${LINK_OBJECTS[@]}" -o "$BUILD_DIR/RP2.elf"

# Report the selected linker's SRAM allocation, not instantaneous stack usage.
# Read symbol values from the linked ELF rather than duplicating chip capacities.
SRAM_SYMBOL_TABLE=$(llvm-nm --defined-only --format=posix "$BUILD_DIR/RP2.elf")
declare -A SRAM_SYMBOLS=()
while read -r SYMBOL_NAME SYMBOL_TYPE SYMBOL_VALUE SYMBOL_REST; do
    case "$SYMBOL_NAME" in
        SRAM_BASE|SRAM_BYTES|__bss_end|STACK_TOP|CORE1_STACK_GUARD_BOTTOM)
            SRAM_SYMBOLS["$SYMBOL_NAME"]=$((16#$SYMBOL_VALUE))
            ;;
    esac
done <<< "$SRAM_SYMBOL_TABLE"
for SYMBOL_NAME in SRAM_BASE SRAM_BYTES __bss_end STACK_TOP CORE1_STACK_GUARD_BOTTOM; do
    if [[ -z "${SRAM_SYMBOLS[$SYMBOL_NAME]+present}" ]]; then
        printf 'Missing SRAM layout symbol: %s\n' "$SYMBOL_NAME" >&2
        exit 1
    fi
done
SRAM_TOTAL_BYTES=${SRAM_SYMBOLS[SRAM_BYTES]}
SRAM_STATIC_BYTES=$(( ${SRAM_SYMBOLS[__bss_end]} - ${SRAM_SYMBOLS[SRAM_BASE]} ))
SRAM_RESERVED_BYTES=$(( ${SRAM_SYMBOLS[STACK_TOP]} - ${SRAM_SYMBOLS[CORE1_STACK_GUARD_BOTTOM]} ))
SRAM_ALLOCATED_BYTES=$((SRAM_STATIC_BYTES + SRAM_RESERVED_BYTES))
SRAM_REMAINING_BYTES=$((SRAM_TOTAL_BYTES - SRAM_ALLOCATED_BYTES))
printf 'SRAM allocation (%s, bytes):\n' "$CHIP"
printf '  Total:       %d\n' "$SRAM_TOTAL_BYTES"
printf '  Static:      %d\n' "$SRAM_STATIC_BYTES"
printf '  Stack/guard: %d\n' "$SRAM_RESERVED_BYTES"
printf '  Allocated:   %d\n' "$SRAM_ALLOCATED_BYTES"
printf '  Remaining:   %d\n' "$SRAM_REMAINING_BYTES"

# Convert the linked ELF to UF2 using the matching family identifier.
picotool uf2 convert "$BUILD_DIR/RP2.elf" "$BUILD_DIR/RP2.uf2" --family "$UF2_FAMILY"
printf 'Built %s\n' "$BUILD_DIR/RP2.elf" "$BUILD_DIR/RP2.uf2"
