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
        static let doneOffset: UInt32 = 0x08
        static let systemPLL: UInt32 = 1 << 14
        static let timer: UInt32 = 1 << 23 // TIMER0; leave TIMER1 untouched.
        static let uart0: UInt32 = 1 << 26
        static let uart1: UInt32 = 1 << 27
        static let ioBank0: UInt32 = 1 << 6
        static let padsBank0: UInt32 = 1 << 9
    }

    enum SystemInfo {
        static let base: UInt32 = 0x4000_0000
    }

    enum GPIO {
        enum IOBank0 {
            static let base: UInt32 = 0x4002_8000
        }

        enum PadsBank0 {
            static let base: UInt32 = 0x4003_8000
        }

        static let pinCount: UInt32 = 48
        static let uartFuncsel: UInt32 = 2
        static let uartAuxFuncsel: UInt32 = 11

        // QFN = Quad Flat No-lead: a package with underside contacts and no protruding leads.
        // QFN60 has 60 terminals; RP2350A exposes 30 GPIOs on the chip.
        // The terminal count is not the GPIO count or the number exposed on the board headers.
        private static let qfn60PinCount: UInt32 = 30

        // SYSINFO.PACKAGE_SEL: fixed-address package identification register.
        private enum SYSINFO {
            enum PACKAGE_SEL {
                static let reg = RP2.Register32(address: RP2350.SystemInfo.base + 0x04)
                // Bit 0: 0 = QFN80 (B), 1 = QFN60 (A).
                static let packageMask: UInt32 = 1 << 0
                static let qfn80: UInt32 = 0
            }
        }

        static func isAvailable(_ pin: UInt32) -> Bool {
            if pin < qfn60PinCount { return true }
            guard pin < pinCount else { return false }
            // GPIO30...47 are only bonded out on the B package.
            return SYSINFO.PACKAGE_SEL.reg.value & SYSINFO.PACKAGE_SEL.packageMask
                == SYSINFO.PACKAGE_SEL.qfn80
        }
    }

    enum Timer {
        // Keep only chip-specific definitions here; shared definitions live in Timer.swift.
        // RP2350 address map, Timer registers, and Tick generator registers.
        static let base: UInt32 = 0x400B_0000
        static let sourceOffset: UInt32 = 0x38
        // Dedicated TIMER0 tick generator in the TICKS block.
        static let tickControl: UInt32 = 0x4010_8018
        static let tickCycles: UInt32 = 0x4010_801C
        static let tickEnable: UInt32 = 1 << 0
        static let tickRunning: UInt32 = 1 << 1
    }

    enum UART0 {
        static let base: UInt32 = 0x4007_0000
    }

    enum UART1 {
        static let base: UInt32 = 0x4007_8000
    }
}
