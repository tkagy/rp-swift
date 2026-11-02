// Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
// SPDX-License-Identifier: MIT

/// RP2040 register layout; shared drivers refer to the Chip alias in RP2.swift.
// RP2040 datasheet: 2.2 Address Map, 2.14 Resets, 2.15 Clocks,
// 2.16 XOSC, 2.18 PLL, 2.19 GPIO, 4.2 UART, 4.6 Timer, 4.7 Watchdog.
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
        static let doneOffset: UInt32 = 0x08
        static let systemPLL: UInt32 = 1 << 12
        static let timer: UInt32 = 1 << 21
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

    enum Timer {
        static let base: UInt32 = 0x4005_4000
        static let rawHighOffset: UInt32 = 0x24
        static let rawLowOffset: UInt32 = 0x28
        static let debugPauseOffset: UInt32 = 0x2C
        // WATCHDOG.TICK supplies the shared watchdog/timer reference tick.
        static let tickControl: UInt32 = 0x4005_802C
        static let tickEnable: UInt32 = 1 << 9
        static let tickRunning: UInt32 = 1 << 10
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

// Arm RTABI32, 5.3.1: __aeabi_uidivmod receives numerator in r0 and denominator
// in r1, and returns quotient in r0 and remainder in r1.
// https://github.com/ARM-software/abi-aa/blob/main/rtabi32/rtabi32.rst
// AAPCS32, 6.4 (Result Return): a 64-bit fundamental value returns in r0/r1.
// https://github.com/ARM-software/abi-aa/blob/main/aapcs32/aapcs32.rst
// For this little-endian ARM target, a C ABI UInt64 result places its low word
// in r0 and high word in r1. Pack the results to match the AEABI register pair;
// an ordinary struct/tuple return does not establish this special convention.
// Swift does not assign registers explicitly: @_cdecl selects the C ABI here.
@_cdecl("__aeabi_uidivmod")
func aeabiUnsignedDivideModulo(_ numerator: UInt32, _ denominator: UInt32) -> UInt64 {
    // Reuse the shift/subtract division and its nonreturning divide-by-zero hook.
    // Do not use / or % here: LLVM could emit a call back to this entry point.
    let quotient = aeabiUnsignedDivide(numerator, denominator)
    // For a nonzero denominator, quotient * denominator <= numerator.
    let remainder = numerator &- (quotient &* denominator)
    return UInt64(quotient) | (UInt64(remainder) << UInt32.bitWidth)
}

// The ABI routes division by zero through this hook. This firmware stops on it.
@_cdecl("__aeabi_idiv0")
func aeabiIntegerDivideByZero(_ proposedResult: Int32) -> Int32 {
    preconditionFailure("Integer division by zero")
}
#endif
