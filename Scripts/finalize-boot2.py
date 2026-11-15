#!/usr/bin/env python3
# Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
# SPDX-License-Identifier: MIT

"""Fill the CRC word in an assembled RP2040 boot2 section."""
from pathlib import Path
import struct
import sys

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
image = bytearray(source.read_bytes())
probe_magic_offset = 248
probe_magic = 0x07770777

if len(image) != 256:
    raise SystemExit("boot2 section must be exactly 256 bytes")
if image[probe_magic_offset:252] != struct.pack("<I", probe_magic):
    raise SystemExit("boot2 XIP probe magic must be at offset 248")
if image[252:] != b"\0\0\0\0":
    raise SystemExit("boot2 CRC placeholder must be four zero bytes")

# RP2040 datasheet 2.8.1.3.1: CRC-32, non-reflected, init 0xffffffff,
# polynomial 0x04c11db7, and no final XOR. Store the result little-endian.
crc = 0xFFFFFFFF
for byte in image[:252]:
    crc ^= byte << 24
    for _ in range(8):
        crc = ((crc << 1) ^ (0x04C11DB7 if crc & 0x80000000 else 0)) & 0xFFFFFFFF
struct.pack_into("<I", image, 252, crc)
destination.write_bytes(image)
print(f"boot2: 256 bytes, CRC32={crc:08x}, standard READ /4; XIP probe magic at 248")
