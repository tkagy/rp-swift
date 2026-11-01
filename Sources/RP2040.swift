// Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
// SPDX-License-Identifier: MIT

/// RP2040 register layout; shared drivers refer to the Chip alias in RP2.swift.
// RP2040 datasheet: 2.2 Address Map, 2.14 Resets, 2.15 Clocks,
// 2.16 XOSC, 2.18 PLL, 2.19 GPIO, 4.2 UART.
// https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf
// Compare RP2350: 2.2 Address map, 7.5 Resets, 8.1 Clocks,
// 8.2 XOSC, 8.6 PLL, 9 GPIO, 12.1 UART.
// https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf
enum RP2040 {
    enum XOSC {
        static let base: UInt32 = 0x4002_4000
    }

    enum SystemPLL {
        static let base: UInt32 = 0x4002_8000
        static let referenceDivider: UInt32 = 1
        static let feedbackDivider: UInt32 = 125
        static let postDivider1: UInt32 = 6
        static let postDivider2: UInt32 = 2
    }

    enum Clock {
        static let base: UInt32 = 0x4000_8000
        static let dividerIntegerShift: UInt32 = 8
        static let resuscitationOffset: UInt32 = 0x78
    }

    enum Reset {
        static let base: UInt32 = 0x4000_C000
        static let systemPLL: UInt32 = 1 << 12
        static let uart0: UInt32 = 1 << 22
        static let uart1: UInt32 = 1 << 23
        static let ioBank0: UInt32 = 1 << 5
        static let padsBank0: UInt32 = 1 << 8
    }

    enum GPIO {
        enum IOBank0 {
            static let base: UInt32 = 0x4001_4000
        }

        enum PadsBank0 {
            static let base: UInt32 = 0x4001_C000
        }

        static let pinCount: UInt32 = 30
        static let uartFuncsel: UInt32 = 2

        static func isAvailable(_ pin: UInt32) -> Bool {
            pin < pinCount
        }
    }

    enum UART0 {
        static let base: UInt32 = 0x4003_4000
    }

    enum UART1 {
        static let base: UInt32 = 0x4003_8000
    }
}
