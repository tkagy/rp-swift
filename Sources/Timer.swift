// Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
// SPDX-License-Identifier: MIT

// RP2040 datasheet: 4.6 Timer, 4.7 Watchdog, 2.14 Resets.
// https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf
// RP2350 datasheet: Timer, Tick generators, and Resets register descriptions.
// https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf
/// Microsecond hardware counter: RP2040 TIMER or RP2350 TIMER0.
/// Initialize once after Clock.initialize(). Waiting polls the counter on the CPU.
/// All waits use a counter with one-microsecond resolution. Counter phase can
/// shorten a relative wait by less than one microsecond; polling overhead and
/// interrupts can delay return. Waits do not guarantee an exact GPIO pulse width.
enum Timer {
    enum ErrorCode: UInt32 {
        case none = 0
        case resetDidNotComplete = 1
        case tickDidNotStart = 2
        case tickDidNotStop = 3
        case invalidReferenceFrequency = 4
        case notInitialized = 5
        case alreadyInitialized = 6
    }

    /// Last register sample from an initialization poll that exhausted its limit.
    struct FailureSnapshot {
        let address: UInt32
        let value: UInt32
    }

    /// Time conversion constants use the same UInt64 units as the counter.
    static let microsecondsPerSecond: UInt64 = 1_000_000
    private static let microsecondsPerMillisecond: UInt64 = 1_000

    /// Largest supported deadline distance in microseconds, in either direction.
    /// Exactly half the UInt64 counter range is ambiguous and is not supported.
    static let maximumDeadlineDistance: UInt64 = UInt64(Int64.max)

    private(set) static var status: ErrorCode = .none
    /// Successful driver initialization; this does not monitor hardware clock state.
    private(set) static var isInitialized: Bool = false
    /// Nil unless initialization polling failed; captured without an extra MMIO read.
    private(set) static var failureSnapshot: FailureSnapshot? = nil
    private static let maxPollCount: UInt32 = 1_000_000

    private enum RESETS {
        enum RESET {
            static let reg = RP2.Register32(address: Chip.Reset.base)
        }
        enum RESET_DONE {
            static let reg = RP2.Register32(address: Chip.Reset.base + Chip.Reset.doneOffset)
        }
    }

    private enum TICK {
        // Both chips use a nine-bit cycle count for the tick generator.
        static let maxCycles: UInt32 = 0x1FF

        enum CTRL {
            static let reg = RP2.Register32(address: Chip.Timer.tickControl)
        }
        #if RP2350
        enum CYCLES {
            static let reg = RP2.Register32(address: Chip.Timer.tickCycles)
        }
        #endif
    }

    // Register offsets shared by RP2040 TIMER and RP2350 TIMER0.
    private enum COUNTER {
        enum TIMERAWH {
            static let reg = RP2.Register32(address: Chip.Timer.base + 0x24)
        }
        enum TIMERAWL {
            static let reg = RP2.Register32(address: Chip.Timer.base + 0x28)
        }
        enum DBGPAUSE {
            static let reg = RP2.Register32(address: Chip.Timer.base + 0x2C)
            static let core0: UInt32 = 1 << 1
            static let core1: UInt32 = 1 << 2
        }
        #if RP2350
        enum SOURCE {
            static let reg = RP2.Register32(address: Chip.Timer.base + Chip.Timer.sourceOffset)
            static let referenceTicks: UInt32 = 0
        }
        #endif
    }

    /// Call once during startup, before other cores or interrupts use this timer.
    /// On RP2040, call before starting the watchdog: setup stops and reconfigures
    /// their shared tick generator. This function does not start the watchdog.
    /// By default, pause the counter while either core is halted by a debugger.
    /// Pass false to keep counting during debugger halts.
    static func initialize(pauseOnDebug: Bool = true) {
        guard !isInitialized else { fail(.alreadyInitialized) }
        status = .none
        failureSnapshot = nil
        // clk_ref is the 12 MHz XOSC. Twelve cycles produce one microsecond.
        let cycles = Clock.referenceFrequencyHz / UInt32(microsecondsPerSecond)
        guard cycles > 0 && cycles <= TICK.maxCycles,
              Clock.referenceFrequencyHz % UInt32(microsecondsPerSecond) == 0 else {
            fail(.invalidReferenceFrequency)
        }

        // Reset only this timer, then establish its reference before releasing it.
        RESETS.RESET.reg.setBits(Chip.Reset.timer)
        configureTick(cycles: cycles)
        RESETS.RESET.reg.clearBits(Chip.Reset.timer)
        guard waitForResetRelease() else { fail(.resetDidNotComplete) }
        #if RP2350
        COUNTER.SOURCE.reg.value = COUNTER.SOURCE.referenceTicks
        #endif
        COUNTER.DBGPAUSE.reg.value = pauseOnDebug
            ? (COUNTER.DBGPAUSE.core0 | COUNTER.DBGPAUSE.core1)
            : 0
        isInitialized = true
    }

    /// Read the full counter without a shared latch, including a low-word rollover.
    /// Reading before initialization records an error and calls faultHandler().
    static var microseconds: UInt64 {
        guard isInitialized else { fail(.notInitialized) }
        while true {
            let high = COUNTER.TIMERAWH.reg.value
            let low = COUNTER.TIMERAWL.reg.value
            if high == COUNTER.TIMERAWH.reg.value {
                return (UInt64(high) << UInt32.bitWidth) | UInt64(low)
            }
        }
    }

    /// Wait for elapsed counter ticks, including a UInt64 counter wrap.
    /// The timer must be initialized and running; a zero duration returns immediately.
    /// Counter phase can shorten the wait by less than one microsecond.
    /// Polling overhead and interrupts can delay return beyond the requested duration.
    static func busyWait(microseconds: UInt64) {
        guard microseconds > 0 else { return }
        let start = self.microseconds
        // Wrapping subtraction measures elapsed time without an overflowing deadline.
        while self.microseconds &- start < microseconds {}
    }

    /// Relative wait with the same resolution and timing limits as busyWait(microseconds:).
    static func busyWait(milliseconds: UInt32) {
        busyWait(microseconds: UInt64(milliseconds) * microsecondsPerMillisecond)
    }

    /// Relative wait with the same resolution and timing limits as busyWait(microseconds:).
    static func busyWait(seconds: UInt32) {
        busyWait(microseconds: UInt64(seconds) * microsecondsPerSecond)
    }

    /// Check an absolute Timer.microseconds deadline without waiting for it.
    /// Returns true when the deadline is reached or already past, including wrap.
    /// The deadline must be at most maximumDeadlineDistance away in either direction.
    /// Exactly half the UInt64 counter range cannot distinguish past from future.
    /// Requires initialization. The result reflects the sampled counter value.
    static func hasReached(deadline: UInt64) -> Bool {
        hasReached(deadline: deadline, at: self.microseconds)
    }

    /// Compare a deadline with a supplied sample from the same Timer counter.
    /// This overload only compares values; it does not read hardware or require
    /// initialization. Reuse one sample to evaluate multiple deadlines consistently.
    /// The deadline must be at most maximumDeadlineDistance from the sample in
    /// either direction; exactly half the UInt64 counter range is unsupported.
    static func hasReached(deadline: UInt64, at microseconds: UInt64) -> Bool {
        let remaining = deadline &- microseconds
        // The upper half of a wrapping difference represents a past deadline.
        return remaining == 0 || remaining > maximumDeadlineDistance
    }

    /// Wait until an absolute Timer.microseconds value, including counter wrap.
    /// Returns immediately if the deadline is reached or already past.
    /// The deadline must be at most maximumDeadlineDistance away in either direction.
    /// Exactly half the UInt64 counter range cannot distinguish past from future.
    /// Requires initialization even when the deadline has already passed.
    /// Counter resolution is one microsecond; polling overhead and interrupts
    /// can delay return after the deadline is reached.
    static func busyWait(until deadline: UInt64) {
        while !hasReached(deadline: deadline) {}
    }

    // MARK: - Initialization helpers

    private static func configureTick(cycles: UInt32) {
        TICK.CTRL.reg.value = 0
        guard waitForTick(running: false) else { fail(.tickDidNotStop) }
        #if RP2350
        TICK.CYCLES.reg.value = cycles
        TICK.CTRL.reg.value = Chip.Timer.tickEnable
        #else
        // RP2040 shares this reference tick with the watchdog. Do not change its
        // period while the watchdog is active; this does not enable the watchdog.
        TICK.CTRL.reg.value = cycles | Chip.Timer.tickEnable
        #endif
        guard waitForTick(running: true) else { fail(.tickDidNotStart) }
    }

    private static func waitForTick(running: Bool) -> Bool {
        waitForRegister(TICK.CTRL.reg, mask: Chip.Timer.tickRunning,
                        expected: running ? Chip.Timer.tickRunning : 0)
    }

    private static func waitForResetRelease() -> Bool {
        waitForRegister(RESETS.RESET_DONE.reg, mask: Chip.Reset.timer,
                        expected: Chip.Reset.timer)
    }

    /// Poll a masked register value; expected must contain only bits within mask.
    private static func waitForRegister(
        _ register: RP2.Register32, mask: UInt32, expected: UInt32
    ) -> Bool {
        var lastValue: UInt32 = 0
        for _ in 0..<maxPollCount {
            lastValue = register.value
            if lastValue & mask == expected { return true }
        }
        failureSnapshot = FailureSnapshot(address: register.address, value: lastValue)
        return false
    }

    private static func fail(_ error: ErrorCode) -> Never {
        status = error
        faultHandler()
    }
}
