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
        case sysClockDidNotSwitchToReference = 2
        case referenceClockDidNotSelectCrystal = 3
        case pllResetDidNotComplete = 4
        case pllDidNotLock = 5
        case sysClockDidNotSwitchToPLL = 6
        case peripheralClockDidNotStop = 7
    }

    struct SysFreqConfig {
        let fbDivInt: UInt32
        let postDiv1: UInt32
        let postDiv2: UInt32
        let clkSysDivInt: UInt32

        private init(fbDivInt: UInt32, postDiv1: UInt32, postDiv2: UInt32, clkSysDivInt: UInt32) {
            self.fbDivInt = fbDivInt
            self.postDiv1 = postDiv1
            self.postDiv2 = postDiv2
            self.clkSysDivInt = clkSysDivInt
        }

        static var MHz48: Self { Self(fbDivInt: 96, postDiv1: 6, postDiv2: 4, clkSysDivInt: 1) }
        static var MHz60: Self { Self(fbDivInt: 120, postDiv1: 6, postDiv2: 4, clkSysDivInt: 1) }
        static var MHz72: Self { Self(fbDivInt: 120, postDiv1: 5, postDiv2: 4, clkSysDivInt: 1) }
        static var MHz96: Self { Self(fbDivInt: 96, postDiv1: 6, postDiv2: 2, clkSysDivInt: 1) }
        static var MHz100: Self { Self(fbDivInt: 100, postDiv1: 6, postDiv2: 2, clkSysDivInt: 1) }
        static var MHz120: Self { Self(fbDivInt: 120, postDiv1: 6, postDiv2: 2, clkSysDivInt: 1) }
        static var MHz125: Self { Self(fbDivInt: 125, postDiv1: 6, postDiv2: 2, clkSysDivInt: 1) }
        static var MHz132: Self { Self(fbDivInt: 110, postDiv1: 5, postDiv2: 2, clkSysDivInt: 1) }
        static var MHz133: Self { Self(fbDivInt: 133, postDiv1: 6, postDiv2: 2, clkSysDivInt: 1) }
#if RP2350
        static var MHz150: Self { Self(fbDivInt: 125, postDiv1: 5, postDiv2: 2, clkSysDivInt: 1) }
#endif
    }

    // The RP2040 and RP2350 reference designs use a 12 MHz crystal:
    // RP2040 datasheet 2.15.2.2; RP2350 datasheet 8.1.2.3.
    static let peripheralFreqMHz: UInt32 = 12

    // .none means no error; other cases identify a failure in this module.
    private(set) static var status: ErrorCode = .none

    // Initialization failures are fatal; retain the cause for debugger inspection.
    static func initialize(config: SysFreqConfig) {
        status = .none
        CLOCKS.CLK_SYS_RESUS_CTRL.reg.value = 0

        status = initializeCrystal()
        guard status == .none else { faultHandler() }

        status = initializeReferenceClock()
        guard status == .none else { faultHandler() }

        status = stopPeripheralClock()
        guard status == .none else { faultHandler() }

        status = initializeSysPLL(config: config)
        guard status == .none else { faultHandler() }

        CLOCKS.CLK_SYS_DIV.reg.value = config.clkSysDivInt
            << Chip.Clock.dividerIntegerShift

        status = switchSysClockToPLL()
        guard status == .none else { faultHandler() }

        initializePeripheralClock()
    }

    private static func initializeCrystal() -> ErrorCode {
        // Board-specific crystal stabilization allowance.
        configureCrystalStartupDelay(ms: 7)
        XOSC.CTRL.reg.value = XOSC.CTRL.ENABLE | XOSC.CTRL.FREQ_RANGE
        guard waitFor(XOSC.STATUS.reg,
            mask: XOSC.STATUS.STABLE, value: XOSC.STATUS.STABLE
        ) else { return .crystalDidNotStabilize }
        return .none
    }

    // RP2040 2.16.3 "Startup Delay"; RP2350 8.2.4 "Startup delay".
    // STARTUP counts groups of 256 crystal cycles; round up the requested delay.
    @inline(__always)
    private static func configureCrystalStartupDelay(ms: UInt32) {
        let msPerSec: UInt64 = 1_000
        let hzPerMhz: UInt64 = 1_000_000
        let cycles = UInt64(peripheralFreqMHz) * UInt64(ms) * hzPerMhz / msPerSec
        let cyclesPerCount = XOSC.STARTUP.cyclesPerCount
        let startupDelayCount = (cycles + cyclesPerCount - 1) / cyclesPerCount
        precondition(startupDelayCount <= XOSC.STARTUP.maxDelayCount, "XOSC delay out of range")
        XOSC.STARTUP.reg.value = UInt32(startupDelayCount)
    }

    private static func initializeReferenceClock() -> ErrorCode {
        // Glitchless mux sequencing: detach SYS from AUX before changing PLLs.
        // RP2040 2.15.3.2; RP2350 8.1.3.2, "Multiplexers".
        CLOCKS.CLK_SYS_CTRL.reg.clearBits(CLOCKS.CLK_SYS_CTRL.SRC_AUX)
        guard waitFor(CLOCKS.CLK_SYS_SELECTED.reg, mask: UInt32.max,
            value: CLOCKS.CLK_SYS_SELECTED.SELECTED_REF
        ) else { return .sysClockDidNotSwitchToReference }
        CLOCKS.CLK_REF_DIV.reg.value = CLOCKS.divideByOne
        CLOCKS.CLK_REF_CTRL.reg.value =
            (CLOCKS.CLK_REF_CTRL.reg.value & ~CLOCKS.CLK_REF_CTRL.SRC_MASK)
                | CLOCKS.CLK_REF_CTRL.SRC_XOSC
        guard waitFor(CLOCKS.CLK_REF_SELECTED.reg,
            mask: UInt32.max, value: CLOCKS.CLK_REF_SELECTED.SELECTED_XOSC
        ) else { return .referenceClockDidNotSelectCrystal }
        CLOCKS.CLK_SYS_DIV.reg.value = CLOCKS.divideByOne
        return .none
    }

    private static func stopPeripheralClock() -> ErrorCode {
        CLOCKS.CLK_PERI_CTRL.reg.clearBits(CLOCKS.CLK_PERI_CTRL.ENABLE)
        return waitForPeripheralClockToStop() ? .none : .peripheralClockDidNotStop
    }

    private static func waitForPeripheralClockToStop() -> Bool {
#if RP2350
        // RP2350 exposes CTRL_ENABLED. The datasheet recommends polling it
        // until it matches CTRL_ENABLE after disabling the generator.
        return waitFor(CLOCKS.CLK_PERI_CTRL.reg,
            mask: CLOCKS.CLK_PERI_CTRL.ENABLED, value: 0)
#endif
#if RP2040
        // RP2040 datasheet 2.15.3.1: CLK_PERI supports up to 133 MHz.
        // Section 2.15.3.2 requires 2 source cycles; wait 4 as a 2x margin.
        // SYS runs from the 12 MHz crystal; round up for a partial source cycle.
        let maxClkPeriFreqMHz: UInt64 = 133
        let peripheralClockStopWaitCycles: UInt64 = 4
        let scaledWaitCycles = maxClkPeriFreqMHz * peripheralClockStopWaitCycles
        let readCount =
            (scaledWaitCycles + UInt64(peripheralFreqMHz) - 1) / UInt64(peripheralFreqMHz)
        for _ in 0..<readCount {
            _ = CLOCKS.CLK_PERI_CTRL.reg.value
        }
        return true
#endif
    }

    private static func initializePeripheralClock() {
#if RP2350
        CLOCKS.CLK_PERI_DIV.reg.value = CLOCKS.divideByOne
#endif
        CLOCKS.CLK_PERI_CTRL.reg.value = CLOCKS.CLK_PERI_CTRL.AUXSRC_XOSC // Still stopped.
        CLOCKS.CLK_PERI_CTRL.reg.value =
            CLOCKS.CLK_PERI_CTRL.ENABLE | CLOCKS.CLK_PERI_CTRL.AUXSRC_XOSC
    }

    // RP2040 2.18 PLL; RP2350 8.6 PLL. Register offsets/field layout are shared.
    // initialize() has already switched SYS to the stable crystal via REF.
    private static func initializeSysPLL(config: SysFreqConfig) -> ErrorCode {
        guard RP2.RESETS.reset(Chip.Reset.sysPLL) else {
            return .pllResetDidNotComplete
        }
        PLL_SYS.CS.reg.value = PLL_SYS.refDiv
        PLL_SYS.FBDIV_INT.reg.value = config.fbDivInt
        PLL_SYS.PWR.reg.clearBits(PLL_SYS.PWR.PD | PLL_SYS.PWR.VCOPD)
        guard waitFor(PLL_SYS.CS.reg,
            mask: PLL_SYS.CS.LOCK, value: PLL_SYS.CS.LOCK
        ) else { return .pllDidNotLock }
        PLL_SYS.PRIM.reg.value = (config.postDiv1 << PLL_SYS.PRIM.POSTDIV1_SHIFT)
                | (config.postDiv2 << PLL_SYS.PRIM.POSTDIV2_SHIFT)
        PLL_SYS.PWR.reg.clearBits(PLL_SYS.PWR.POSTDIVPD)
        return .none
    }

    // Call only after SYS uses REF and the system PLL is configured and locked.
    private static func switchSysClockToPLL() -> ErrorCode {
        // AUXSRC = PLL_SYS while SYS uses REF.
        CLOCKS.CLK_SYS_CTRL.reg.clearBits(CLOCKS.CLK_SYS_CTRL.AUXSRC_MASK)
        CLOCKS.CLK_SYS_CTRL.reg.setBits(CLOCKS.CLK_SYS_CTRL.SRC_AUX)
        guard waitFor(CLOCKS.CLK_SYS_SELECTED.reg,
            mask: UInt32.max, value: CLOCKS.CLK_SYS_SELECTED.SELECTED_PLL_SYS
        ) else { return .sysClockDidNotSwitchToPLL }
        return .none
    }

    private static func waitFor(
        _ register: RP2.Register32,
        mask: UInt32,
        value: UInt32
    ) -> Bool {
        // Bound register reads; this is an iteration limit, not an elapsed-time timeout.
        let maxPollCount: UInt32 = 1_000_000
        for _ in 0..<maxPollCount {
            if (register.value & mask) == value { return true }
        }
        return false
    }

    // Each hardware register groups its handle with its bit definitions.
    private enum CLOCKS {
        static let divideByOne: UInt32 = 1 << Chip.Clock.dividerIntegerShift

        // Selects the source of the reference clock (CLK_REF).
        enum CLK_REF_CTRL {
            static let reg = RP2.Register32(address: Chip.Clock.base + 0x30)
            static let SRC_MASK: UInt32 = 0b11 // SRC field mask.
            static let SRC_XOSC: UInt32 = 0b10 // Select XOSC for CLK_REF.
        }

        enum CLK_REF_DIV {
            static let reg = RP2.Register32(address: Chip.Clock.base + 0x34)
        }

        enum CLK_REF_SELECTED {
            static let reg = RP2.Register32(address: Chip.Clock.base + 0x38)
            static let SELECTED_XOSC: UInt32 = 0b100 // Confirm XOSC is selected for CLK_REF.
        }

        enum CLK_SYS_CTRL {
            static let reg = RP2.Register32(address: Chip.Clock.base + 0x3C)
            static let SRC_AUX: UInt32 = 0b1 // Select the auxiliary source for CLK_SYS.
            static let AUXSRC_MASK: UInt32 = 0b111 << 5 // AUXSRC field mask; zero selects PLL_SYS.
        }

        enum CLK_SYS_DIV {
            static let reg = RP2.Register32(address: Chip.Clock.base + 0x40)
        }

        enum CLK_SYS_SELECTED {
            static let reg = RP2.Register32(address: Chip.Clock.base + 0x44)
            static let SELECTED_REF: UInt32 = 0b1 // Confirm CLK_REF is selected for CLK_SYS.
            static let SELECTED_PLL_SYS: UInt32 = 0b10 // Confirm AUX is selected; AUXSRC is PLL_SYS.
        }

        enum CLK_PERI_CTRL {
            static let reg = RP2.Register32(address: Chip.Clock.base + 0x48)
            static let ENABLE: UInt32 = 1 << 11 // Peripheral clock enable.
#if RP2350
            static let ENABLED: UInt32 = 1 << 28 // Clock generator is enabled.
#endif
            static let AUXSRC_XOSC: UInt32 = 0b100 << 5 // Select XOSC for CLK_PERI.
        }

#if RP2350
        enum CLK_PERI_DIV {
            static let reg = RP2.Register32(address: Chip.Clock.base + 0x4C)
        }
#endif

        enum CLK_SYS_RESUS_CTRL {
            static let reg = RP2.Register32(address: Chip.Clock.base + Chip.Clock.resuscitationOffset)
        }
    }

    private enum XOSC {
        enum CTRL {
            static let reg = RP2.Register32(address: Chip.XOSC.base + 0x00)
            static let ENABLE: UInt32 = 0xFAB << 12 // Enable the crystal oscillator.
            static let FREQ_RANGE: UInt32 = 0xAA0 // 1–15 MHz crystal range; board uses 12 MHz.
        }

        enum STATUS {
            static let reg = RP2.Register32(address: Chip.XOSC.base + 0x04)
            static let STABLE: UInt32 = 1 << 31 // Crystal oscillator is stable.
        }

        enum STARTUP {
            static let reg = RP2.Register32(address: Chip.XOSC.base + 0x0C)
            static let cyclesPerCount: UInt64 = 256
            static let maxDelayCount: UInt64 = 0x3FFF
        }
    }

    private enum PLL_SYS {
        static let refDiv: UInt32 = 1

        enum CS {
            static let reg = RP2.Register32(address: Chip.SysPLL.base + 0x00)
            static let LOCK: UInt32 = 1 << 31 // PLL is locked.
        }

        enum PWR {
            static let reg = RP2.Register32(address: Chip.SysPLL.base + 0x04)
            static let PD: UInt32 = 1 << 0 // PLL power-down.
            static let VCOPD: UInt32 = 1 << 5 // VCO power-down.
            static let POSTDIVPD: UInt32 = 1 << 3 // Post-divider power-down.
        }

        enum FBDIV_INT {
            static let reg = RP2.Register32(address: Chip.SysPLL.base + 0x08)
        }

        enum PRIM {
            static let reg = RP2.Register32(address: Chip.SysPLL.base + 0x0C)
            static let POSTDIV1_SHIFT: UInt32 = 16
            static let POSTDIV2_SHIFT: UInt32 = 12
        }
    }
}
