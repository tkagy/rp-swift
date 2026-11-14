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

    enum SysPLL {
        static let base: UInt32 = 0x4002_8000
    }

    enum Clock {
        static let base: UInt32 = 0x4000_8000
        static let dividerIntegerShift: UInt32 = 8
        static let resuscitationOffset: UInt32 = 0x78
    }

    enum Reset {
        static let base: UInt32 = 0x4000_C000
        static let sysPLL: UInt32 = 1 << 12
        static let uart0: UInt32 = 1 << 22
        static let uart1: UInt32 = 1 << 23
        static let ioBank0: UInt32 = 1 << 5
        static let padsBank0: UInt32 = 1 << 8
    }

    enum GPIO {
        enum IO_BANK0 {
            static let base: UInt32 = 0x4001_4000
        }

        enum PADS_BANK0 {
            static let base: UInt32 = 0x4001_C000
        }


        // This chip has no auxiliary UART routes.
        static let uartAuxFuncsel: UInt32? = nil
        static let uart0TXAuxPins: UInt32 = 0
        static let uart0RXAuxPins: UInt32 = 0
        static let uart1TXAuxPins: UInt32 = 0
        static let uart1RXAuxPins: UInt32 = 0
    }

    enum UART0 {
        static let base: UInt32 = 0x4003_4000
    }

    enum UART1 {
        static let base: UInt32 = 0x4003_8000
    }
}

#if RP2040
// Cortex-M0+ runtime support. @_cdecl entry points must be global functions.
// __aeabi_uidiv takes two unsigned 32-bit integers and returns their quotient.
// A zero denominator is handled by __aeabi_idiv0 below.
// REVISIT: use SIO later
@_cdecl("__aeabi_uidiv")
func aeabiUnsignedDivide(_ numerator: UInt32, _ denominator: UInt32) -> UInt32 {
    guard denominator != 0 else {
        return UInt32(bitPattern: aeabiIntegerDivideByZero(numerator == 0 ? 0 : -1))
    }
    var remainder = numerator
    var quotient: UInt32 = 0
    // Build the quotient from its highest bit. Check before shifting to avoid overflow.
    for shift in (0..<UInt32.bitWidth).reversed() {
        if denominator <= (remainder >> shift) {
            remainder -= denominator << shift
            quotient |= UInt32(1) << shift
        }
    }
    return quotient
}

// The ABI routes division by zero through this hook. This firmware stops on it.
@_cdecl("__aeabi_idiv0")
func aeabiIntegerDivideByZero(_ proposedResult: Int32) -> Int32 {
    preconditionFailure("Integer division by zero")
}
#endif
