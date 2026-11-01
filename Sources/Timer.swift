// Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
// SPDX-License-Identifier: MIT

// RP2040 datasheet: 4.6 Timer, 4.7 Watchdog, 2.14 Resets.
// https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf
// RP2350 datasheet: Timer, Tick generators, and Resets register descriptions.
// https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf
/// Microsecond hardware counter: RP2040 TIMER or RP2350 TIMER0.
/// Initialize once after Clock.initialize(). Waiting polls the counter on the CPU.
enum Timer {
    /// Number of microseconds in one second, in the same units as the counter.
    static let microsecondsPerSecond: UInt64 = 1_000_000

    enum ErrorCode: UInt32 {
        case none = 0
        case resetDidNotComplete = 1
        case tickDidNotStart = 2
        case tickDidNotStop = 3
    }

    private(set) static var status: ErrorCode = .none
    private static let pollLimit: UInt32 = 1_000_000

    private enum RESETS {
        enum RESET {
            @RP2.Register32(address: Chip.Reset.base) static var value: UInt32
        }
        enum RESET_DONE {
            @RP2.Register32(address: Chip.Reset.base + 0x08) static var value: UInt32
        }
    }

    private enum TICK {
        enum CTRL {
            @RP2.Register32(address: Chip.Timer.tickControl) static var value: UInt32
        }
        #if RP2350
        enum CYCLES {
            @RP2.Register32(address: Chip.Timer.tickCycles) static var value: UInt32
        }
        #endif
    }

    private enum COUNTER {
        enum HIGH {
            @RP2.Register32(address: Chip.Timer.base + 0x24) static var value: UInt32
        }
        enum LOW {
            @RP2.Register32(address: Chip.Timer.base + 0x28) static var value: UInt32
        }
        enum DBGPAUSE {
            @RP2.Register32(address: Chip.Timer.base + 0x2C) static var value: UInt32
        }
        #if RP2350
        enum SOURCE {
            @RP2.Register32(address: Chip.Timer.base + 0x38) static var value: UInt32
        }
        #endif
    }

    static func initialize() {
        status = .none
        // clk_ref is the 12 MHz XOSC. Twelve cycles produce one microsecond.
        let cycles = Clock.referenceFrequencyHz / UInt32(microsecondsPerSecond)
        precondition(cycles > 0 && cycles <= 0x1FF)
        precondition(Clock.referenceFrequencyHz % UInt32(microsecondsPerSecond) == 0)

        // Reset only this timer, then establish its reference before releasing it.
        RESETS.RESET.$value.setBits(Chip.Reset.timer)
        TICK.CTRL.value = 0
        guard waitForTick(running: false) else {
            status = .tickDidNotStop
            faultHandler()
        }
        #if RP2350
        TICK.CYCLES.value = cycles
        TICK.CTRL.value = Chip.Timer.tickEnable
        #else
        // RP2040 stores the cycle count and enable bit in the same register.
        // This also sets the watchdog's reference tick, without enabling its watchdog.
        TICK.CTRL.value = cycles | Chip.Timer.tickEnable
        #endif
        guard waitForTick(running: true) else {
            status = .tickDidNotStart
            faultHandler()
        }

        RESETS.RESET.$value.clearBits(Chip.Reset.timer)
        var ready = false
        for _ in 0..<pollLimit {
            if RESETS.RESET_DONE.value & Chip.Reset.timer != 0 {
                ready = true
                break
            }
        }
        guard ready else {
            status = .resetDidNotComplete
            faultHandler()
        }
        #if RP2350
        COUNTER.SOURCE.value = 0 // Count reference ticks rather than clk_sys cycles.
        #endif
        // Pause while either core is halted by a debugger; resume without catching up.
        COUNTER.DBGPAUSE.value = (1 << 1) | (1 << 2)
    }

    private static func waitForTick(running: Bool) -> Bool {
        for _ in 0..<pollLimit {
            if (TICK.CTRL.value & Chip.Timer.tickRunning != 0) == running { return true }
        }
        return false
    }

    /// Read the full counter without a shared latch, including a low-word rollover.
    static var microseconds: UInt64 {
        while true {
            let high = COUNTER.HIGH.value
            let low = COUNTER.LOW.value
            if high == COUNTER.HIGH.value {
                return (UInt64(high) << 32) | UInt64(low)
            }
        }
    }

    static func busyWait(microseconds: UInt64) {
        let deadline = self.microseconds + microseconds
        while self.microseconds < deadline {}
    }

    static func busyWait(milliseconds: UInt32) {
        busyWait(microseconds: UInt64(milliseconds) * 1_000)
    }

    static func busyWait(seconds: UInt32) {
        busyWait(microseconds: UInt64(seconds) * 1_000_000)
    }

}
