#!/usr/bin/env bash
# Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
# SPDX-License-Identifier: MIT

set -euo pipefail
PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CHIP=
CHIP_SELECTED=0
for ARG in "$@"; do
    case "$ARG" in
        RP2350)
            CHIP="$ARG"
            CHIP_SELECTED=1
            ;;
        *) printf 'Usage: bash %s [RP2350]\n' "${BASH_SOURCE[0]}" >&2; exit 1 ;;
    esac
done
if [[ "$CHIP_SELECTED" == 0 ]]; then
    for TARGET_CHIP in RP2350; do
        BUILD_ARGS=("$TARGET_CHIP")
        bash "$PROJECT_DIR/Scripts/build.sh" "${BUILD_ARGS[@]}"
    done
    exit 0
fi
case "$CHIP" in
    RP2350) SWIFT_TARGET=armv8m.main-none-none-eabi; UF2_FAMILY=rp2350-arm-s ;;
esac
BUILD_DIR="$PROJECT_DIR/.build/$CHIP"
mkdir -p "$BUILD_DIR"

SWIFT_SOURCES=()
for SOURCE in "$PROJECT_DIR"/Sources/*.swift; do
    SWIFT_SOURCES+=("$SOURCE")
done
SWIFT_OBJECT="$BUILD_DIR/RP2.o"
swiftc -target "$SWIFT_TARGET" \
    -enable-experimental-feature Embedded \
    -wmo -Osize -parse-as-library \
    -Xfrontend -function-sections \
    -emit-object "${SWIFT_SOURCES[@]}" \
    -o "$SWIFT_OBJECT"

LINK_OBJECTS=("$SWIFT_OBJECT")
ld.lld -T "$PROJECT_DIR/Configs/${CHIP,,}.ld" \
    --gc-sections --build-id=none \
    -Map="$BUILD_DIR/RP2.map" \
    "${LINK_OBJECTS[@]}" -o "$BUILD_DIR/RP2.elf"

picotool uf2 convert "$BUILD_DIR/RP2.elf" "$BUILD_DIR/RP2.uf2" --family "$UF2_FAMILY"
printf 'Built %s\n' "$BUILD_DIR/RP2.elf" "$BUILD_DIR/RP2.uf2"
