// Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
// SPDX-License-Identifier: MIT

// RP2040 datasheet: 2.15 Clocks, 2.16 XOSC, 2.18 PLL.
// https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf
// RP2350 datasheet: 8.1 Clocks, 8.2 XOSC, 8.6 PLL.
// https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf
// 12 MHz crystal -> CLK_REF; PLL_SYS -> 125 MHz (RP2040) or 150 MHz (RP2350);
// XOSC -> 12 MHz CLK_PERI for UART.
enum Clock {
    enum ErrorCode: UInt32 {
        case none = 0
        case crystalDidNotStabilize = 1
        case systemClockDidNotSwitchToReference = 2
        case referenceClockDidNotSelectCrystal = 3
        case pllResetDidNotComplete = 4
        case pllDidNotLock = 5
        case systemClockDidNotSwitchToPLL = 6
    }

    // The supported RP2040 and RP2350 hardware configurations use a 12 MHz crystal.
    static let referenceFrequencyHz: UInt32 = 12_000_000
    static let peripheralFrequencyHz = referenceFrequencyHz
    static let systemFrequencyHz = referenceFrequencyHz
        * Chip.SystemPLL.feedbackDivider
        / Chip.SystemPLL.referenceDivider
        / Chip.SystemPLL.postDivider1
        / Chip.SystemPLL.postDivider2

    private static let maxPollCount: UInt32 = 1_000_000
    // Board-specific crystal stabilization allowance.
    private static let crystalStartupDelayMilliseconds: UInt32 = 7
    private static let millisecondsPerSecond: UInt64 = 1_000
    // Read count used to allow peripheral-clock disable to propagate.
    // This is an iteration count, not a fixed duration or a hardware-defined minimum.
    private static let clockSettleWaitReadCount: UInt32 = 32

    // .none means no error; other cases identify a failure in this module.
    private(set) static var status: ErrorCode = .none

    // Each hardware register groups its handle with its bit definitions.
    private enum CLOCKS {
        // Selects the source of the reference clock (CLK_REF).
        enum CLK_REF_CTRL {
            static let reg = RP2.Register32(address: Chip.Clock.base + 0x30)
            static let sourceMask: UInt32 = 0b11
            static let sourceXosc: UInt32 = 0b10
        }

        enum CLK_REF_DIV {
            static let reg = RP2.Register32(address: Chip.Clock.base + 0x34)
            static let one: UInt32 = 1
        }

        enum CLK_REF_SELECTED {
            static let reg = RP2.Register32(address: Chip.Clock.base + 0x38)
            static let xosc: UInt32 = 0b100
        }

        enum CLK_SYS_CTRL {
            static let reg = RP2.Register32(address: Chip.Clock.base + 0x3C)
            static let sourceAuxiliary: UInt32 = 0b1
            static let auxiliarySourceMask: UInt32 = 0b111 << 5
        }

        enum CLK_SYS_DIV {
            static let reg = RP2.Register32(address: Chip.Clock.base + 0x40)
            static let one: UInt32 = 1
        }

        enum CLK_SYS_SELECTED {
            static let reg = RP2.Register32(address: Chip.Clock.base + 0x44)
            static let reference: UInt32 = 0b1
            static let pll: UInt32 = 0b10
        }

        enum CLK_PERI_CTRL {
            static let reg = RP2.Register32(address: Chip.Clock.base + 0x48)
            static let enable: UInt32 = 1 << 11
            static let sourceXosc: UInt32 = 0b100 << 5
        }

        #if RP2350
        enum CLK_PERI_DIV {
            static let reg = RP2.Register32(address: Chip.Clock.base + 0x4C)
            static let one: UInt32 = 1
        }
        #endif

        enum CLK_SYS_RESUS_CTRL {
            static let reg = RP2.Register32(address: Chip.Clock.base + Chip.Clock.resuscitationOffset)
        }
    }

    private enum XOSC {
        enum CTRL {
            static let reg = RP2.Register32(address: Chip.XOSC.base + 0x00)
            static let enableValue: UInt32 = (0xFAB << 12) | 0xAA0
        }

        enum STATUS {
            static let reg = RP2.Register32(address: Chip.XOSC.base + 0x04)
            static let stable: UInt32 = 1 << 31
        }

        enum STARTUP {
            static let reg = RP2.Register32(address: Chip.XOSC.base + 0x0C)
            static let cyclesPerCount: UInt64 = 256
            static let maxDelayCount: UInt64 = 0x3FFF
        }
    }

    private enum PLL_SYS {
        enum CS {
            static let reg = RP2.Register32(address: Chip.SystemPLL.base + 0x00)
            static let locked: UInt32 = 1 << 31
        }

        enum PWR {
            static let reg = RP2.Register32(address: Chip.SystemPLL.base + 0x04)
            static let powerDown: UInt32 = 1 << 0
            static let vcoPowerDown: UInt32 = 1 << 5
            static let postDividerPowerDown: UInt32 = 1 << 3
        }

        enum FBDIV_INT {
            static let reg = RP2.Register32(address: Chip.SystemPLL.base + 0x08)
        }

        enum PRIM {
            static let reg = RP2.Register32(address: Chip.SystemPLL.base + 0x0C)
            static let divider1Shift: UInt32 = 16
            static let divider2Shift: UInt32 = 12
        }
    }

    private enum RESETS {
        enum RESET {
            static let reg = RP2.Register32(address: Chip.Reset.base + 0x00)
        }

        enum RESET_DONE {
            static let reg = RP2.Register32(address: Chip.Reset.base + 0x08)
        }
    }

    // Initialization failures are fatal; retain the cause for debugger inspection.
    static func initialize() {
        status = .none
        if let error = initializeClocks() {
            status = error
            faultHandler()
        }
    }

    private static func initializeClocks() -> ErrorCode? {
        CLOCKS.CLK_SYS_RESUS_CTRL.reg.value = 0
        configureCrystalStartupDelay(milliseconds: crystalStartupDelayMilliseconds)
        XOSC.CTRL.reg.value = XOSC.CTRL.enableValue
        guard waitFor(
            XOSC.STATUS.reg.value,
            mask: XOSC.STATUS.stable,
            value: XOSC.STATUS.stable
        ) else { return .crystalDidNotStabilize }

        // Glitchless mux sequencing: detach SYS from AUX before changing PLLs.
        // RP2040 2.15.3.2; RP2350 8.1.3.2, "Multiplexers".
        CLOCKS.CLK_SYS_CTRL.reg.clearBits(CLOCKS.CLK_SYS_CTRL.sourceAuxiliary)
        guard waitFor(
            CLOCKS.CLK_SYS_SELECTED.reg.value,
            mask: UInt32.max,
            value: CLOCKS.CLK_SYS_SELECTED.reference
        ) else { return .systemClockDidNotSwitchToReference }
        CLOCKS.CLK_REF_DIV.reg.value = CLOCKS.CLK_REF_DIV.one << Chip.Clock.dividerIntegerShift
        CLOCKS.CLK_REF_CTRL.reg.value =
            (CLOCKS.CLK_REF_CTRL.reg.value & ~CLOCKS.CLK_REF_CTRL.sourceMask)
                | CLOCKS.CLK_REF_CTRL.sourceXosc
        guard waitFor(
            CLOCKS.CLK_REF_SELECTED.reg.value,
            mask: UInt32.max,
            value: CLOCKS.CLK_REF_SELECTED.xosc
        ) else { return .referenceClockDidNotSelectCrystal }
        CLOCKS.CLK_SYS_DIV.reg.value = CLOCKS.CLK_SYS_DIV.one << Chip.Clock.dividerIntegerShift

        // Stop the peripheral clock and allow propagation before switching its mux.
        // RP2040 2.15.3.2; RP2350 8.1.3.2 (same mux switching requirement).
        CLOCKS.CLK_PERI_CTRL.reg.clearBits(CLOCKS.CLK_PERI_CTRL.enable)
        for _ in 0..<clockSettleWaitReadCount {
            _ = CLOCKS.CLK_PERI_CTRL.reg.value
        }

        if let error = initializeSystemPLL() { return error }

        #if RP2350
        CLOCKS.CLK_PERI_DIV.reg.value = CLOCKS.CLK_PERI_DIV.one << Chip.Clock.dividerIntegerShift
        #endif
        CLOCKS.CLK_PERI_CTRL.reg.value = CLOCKS.CLK_PERI_CTRL.sourceXosc // Still stopped.
        CLOCKS.CLK_PERI_CTRL.reg.value =
            CLOCKS.CLK_PERI_CTRL.enable | CLOCKS.CLK_PERI_CTRL.sourceXosc
        return nil
    }

    // RP2040 2.16.3 "Startup Delay"; RP2350 8.2.4 "Startup delay".
    // STARTUP counts groups of 256 crystal cycles. Seven ms is a board choice.
    @inline(__always)
    private static func configureCrystalStartupDelay(milliseconds: UInt32) {
        let cycles = UInt64(referenceFrequencyHz) * UInt64(milliseconds) / millisecondsPerSecond
        let cyclesPerCount = XOSC.STARTUP.cyclesPerCount
        let delay = (cycles + cyclesPerCount - 1) / cyclesPerCount
        precondition(delay <= XOSC.STARTUP.maxDelayCount, "Crystal startup delay exceeds the register range")
        XOSC.STARTUP.reg.value = UInt32(delay)
    }

    // RP2040 2.18 PLL; RP2350 8.6 PLL. Register offsets/field layout are shared.
    // initialize() has already switched SYS to the stable crystal via REF.
    private static func initializeSystemPLL() -> ErrorCode? {
        let reset = Chip.Reset.systemPLL
        RESETS.RESET.reg.setBits(reset)
        RESETS.RESET.reg.clearBits(reset)
        guard waitFor(
            RESETS.RESET_DONE.reg.value,
            mask: reset,
            value: reset
        ) else { return .pllResetDidNotComplete }
        PLL_SYS.CS.reg.value = Chip.SystemPLL.referenceDivider
        let feedbackDivider = Chip.SystemPLL.feedbackDivider
        let postDivider1 = Chip.SystemPLL.postDivider1
        let postDivider2 = Chip.SystemPLL.postDivider2
        PLL_SYS.FBDIV_INT.reg.value = feedbackDivider
        PLL_SYS.PWR.reg.clearBits(
            PLL_SYS.PWR.powerDown | PLL_SYS.PWR.vcoPowerDown
        )
        guard waitFor(
            PLL_SYS.CS.reg.value,
            mask: PLL_SYS.CS.locked,
            value: PLL_SYS.CS.locked
        ) else { return .pllDidNotLock }
        // Both chips use a 1500 MHz VCO: 1500 / 6 / 2 = 125 MHz
        // on RP2040; 1500 / 5 / 2 = 150 MHz on RP2350.
        PLL_SYS.PRIM.reg.value =
            (postDivider1 << PLL_SYS.PRIM.divider1Shift)
                | (postDivider2 << PLL_SYS.PRIM.divider2Shift)
        PLL_SYS.PWR.reg.clearBits(PLL_SYS.PWR.postDividerPowerDown)
        // AUXSRC = PLL_SYS while SYS uses REF.
        CLOCKS.CLK_SYS_CTRL.reg.clearBits(CLOCKS.CLK_SYS_CTRL.auxiliarySourceMask)
        CLOCKS.CLK_SYS_CTRL.reg.setBits(CLOCKS.CLK_SYS_CTRL.sourceAuxiliary)
        guard waitFor(
            CLOCKS.CLK_SYS_SELECTED.reg.value,
            mask: UInt32.max,
            value: CLOCKS.CLK_SYS_SELECTED.pll
        ) else { return .systemClockDidNotSwitchToPLL }
        return nil
    }

    // This is a bounded poll count, not a time in milliseconds.
    private static func waitFor(_ read: @autoclosure () -> UInt32, mask: UInt32, value: UInt32) -> Bool {
        for _ in 0..<maxPollCount {
            if read() & mask == value { return true }
        }
        return false
    }
}
