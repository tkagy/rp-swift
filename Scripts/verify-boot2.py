#!/usr/bin/env python3
# Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
# SPDX-License-Identifier: MIT

"""Check the supplied RP2040 W25Q080 boot2 before linking it into firmware."""
from pathlib import Path
import struct
import sys

blob = Path(sys.argv[1]).read_bytes()
if len(blob) != 256:
    raise SystemExit("boot2 must contain 252 payload bytes and a 4-byte CRC")

# RP2040 datasheet 2.8.1.3.1: CRC-32/MPEG-2, no reflection or final XOR.
# https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf
crc = 0xFFFFFFFF
for byte in blob[:252]:
    crc ^= byte << 24
    for _ in range(8):
        crc = ((crc << 1) ^ (0x04C11DB7 if crc & 0x80000000 else 0)) & 0xFFFFFFFF
if crc != struct.unpack_from("<I", blob, 252)[0]:
    raise SystemExit("boot2 CRC32 does not match its payload")

# In the pinned W25Q080 blob: movs r1, #2; str r1, [r3, #0x14].
# r3 is SSI_BASE and offset 0x14 is SSI_BAUDR: confirm the requested divisor 2.
if bytes.fromhex("02 21 59 61") not in blob[:252]:
    raise SystemExit("Expected the supplied W25Q080 boot2 with SPI clock divisor 2")
print(f"boot2: 256 bytes, CRC32={crc:08x}, SPI clock divisor 2")
