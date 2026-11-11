// Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
// SPDX-License-Identifier: MIT

/// RP2350 (Arm Secure) register layout; selection lives in RP2.swift.
// RP2350 datasheet: 2.2 Address map, 7.5 Resets, 8.1 Clocks,
// 8.2 XOSC, 8.6 PLL, 9 GPIO, 12.1 UART.
// https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf
// Compare RP2040: 2.2 Address Map, 2.14 Resets, 2.15 Clocks,
// 2.16 XOSC, 2.18 PLL, 2.19 GPIO, 4.2 UART.
// https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf
enum RP2350 {
    enum XOSC {
        static let base: UInt32 = 0x4004_8000
    }

    enum SystemPLL {
        static let base: UInt32 = 0x4005_0000
        static let referenceDivider: UInt32 = 1
        static let feedbackDivider: UInt32 = 125
        static let postDivider1: UInt32 = 5
        static let postDivider2: UInt32 = 2
    }

    enum Clock {
        static let base: UInt32 = 0x4001_0000
        static let dividerIntegerShift: UInt32 = 16
        static let resuscitationOffset: UInt32 = 0x84
    }

    enum Reset {
        static let base: UInt32 = 0x4002_0000
        static let systemPLL: UInt32 = 1 << 14
        static let uart0: UInt32 = 1 << 26
        static let uart1: UInt32 = 1 << 27
        static let ioBank0: UInt32 = 1 << 6
        static let padsBank0: UInt32 = 1 << 9
    }

    enum SystemInfo {
        static let base: UInt32 = 0x4000_0000
    }

    enum GPIO {
        // RP2350A (QFN60), GPIO0...29. Common pin information is in GPIO.swift.
        enum IO_BANK0 {
            static let base: UInt32 = 0x4002_8000
        }

        enum PADS_BANK0 {
            static let base: UInt32 = 0x4003_8000
        }


        // RP2350A Table 3: additional UART routes, encoded as GPIO-number masks.
        static let uartAuxFuncsel: UInt32? = 11
        static let uart0TXAuxPins: UInt32 = (1 << 2) | (1 << 14) | (1 << 18)
        static let uart0RXAuxPins: UInt32 = (1 << 3) | (1 << 15) | (1 << 19)
        static let uart1TXAuxPins: UInt32 = (1 << 6) | (1 << 10) | (1 << 22) | (1 << 26)
        static let uart1RXAuxPins: UInt32 = (1 << 7) | (1 << 11) | (1 << 23) | (1 << 27)
        // TBD: PIO and other RP2350-specific peripheral functions.
    }

    enum UART0 {
        static let base: UInt32 = 0x4007_0000
    }

    enum UART1 {
        static let base: UInt32 = 0x4007_8000
    }
}
