// Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
// SPDX-License-Identifier: MIT

// RP2040 datasheet 2.3.1, including the register list in 2.3.1.7:
// https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf
// RP2350 datasheet 3.1, register list 3.1.11, errata RP2350-E1/E2:
// https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf
enum SIO {
    private typealias register = RP2.Register32
    private typealias spec = Chip.SIO
    private static let sioBase: UInt32 = 0xD000_0000

    private static let CPUID = register(address: sioBase + 0x00)
    private static let GPIO_IN = register(address: sioBase + 0x04)
    private static let GPIO_HI_IN = register(address: sioBase + 0x08)
    private static let GPIO_OUT = register(address: sioBase + 0x10)
    private static let GPIO_OUT_SET = register(address: sioBase + spec.outputSetOffset)
    private static let GPIO_OUT_CLR = register(address: sioBase + spec.outputClearOffset)
    private static let GPIO_OUT_XOR = register(address: sioBase + spec.outputXorOffset)
    private static let GPIO_OE = register(address: sioBase + spec.outputEnableOffset)
    private static let GPIO_OE_SET = register(address: sioBase + spec.outputEnableSetOffset)
    private static let GPIO_OE_CLR = register(address: sioBase + spec.outputEnableClearOffset)
    private static let GPIO_OE_XOR = register(address: sioBase + spec.outputEnableXorOffset)
    private static let GPIO_HI_OUT = register(address: sioBase + spec.highOutputOffset)
    private static let GPIO_HI_OUT_SET = register(address: sioBase + spec.highOutputSetOffset)
    private static let GPIO_HI_OUT_CLR = register(address: sioBase + spec.highOutputClearOffset)
    private static let GPIO_HI_OUT_XOR = register(address: sioBase + spec.highOutputXorOffset)
    private static let GPIO_HI_OE = register(address: sioBase + spec.highOutputEnableOffset)
    private static let GPIO_HI_OE_SET = register(address: sioBase + spec.highOutputEnableSetOffset)
    private static let GPIO_HI_OE_CLR = register(address: sioBase + spec.highOutputEnableClearOffset)
    private static let GPIO_HI_OE_XOR = register(address: sioBase + 0x4C)
    private static let SPINLOCK_ST = register(address: sioBase + 0x5C)

    private static var isInitialized = false

    enum Core: UInt32 { case core0 = 0, core1 }

    /// SIO.CPUID identifies the executing core, unlike the Arm CPU-part register.
    /// Hardware returns 0 or 1. Read on each access; a shared static let would
    /// cache the identity of the core that first accessed it.
    static var core: Core {
        CPUID.value == Core.core0.rawValue ? .core0 : .core1
    }

    /// Call once on core 0, before either core or any IRQ uses SIO.
    /// Releases only errata-safe spinlocks and discards this core's incoming FIFO.
    /// The peer must not send data during initialization. GPIO, interpolators,
    /// and the peer's incoming FIFO are left to their respective users.
    static func initialize() {
        precondition(core == .core0, "Initialize SIO on core 0")
        precondition(!isInitialized, "SIO is already initialized")

        for index in UInt32(0)..<Spinlock.count {
            if spec.usableSpinlocks & (UInt32(1) << index) != 0 {
                spinlock(index).unlock()
            }
        }
        _ = FIFO.drain(maxWords: FIFO.depth)
        FIFO.clearErrors()
        Memory.barrier()
        isInitialized = true
    }

    /// Bank 0 GPIO0...29 (RP2040) or GPIO0...31 (RP2350).
    /// Select FUNCSEL = 5 in IO_BANK0 and configure pads separately. Masks refer
    /// to physical pin numbers; callers must respect board/package availability.
    /// SET/CLR/XOR writes avoid read-modify-write races between cores.
    enum GPIO {
        private static let bank = GPIOBank(high: false, mask: spec.gpioMask)

        static var input: UInt32 { bank.input }
        static var output: UInt32 { bank.output }
        static var outputEnabled: UInt32 { bank.outputEnabled }

        static func set(_ mask: UInt32) { bank.set(mask) }
        static func clear(_ mask: UInt32) { bank.clear(mask) }
        static func toggle(_ mask: UInt32) { bank.toggle(mask) }
        static func enableOutput(_ mask: UInt32) { bank.enableOutput(mask) }
        static func disableOutput(_ mask: UInt32) { bank.disableOutput(mask) }
        static func toggleOutputEnable(_ mask: UInt32) { bank.toggleOutputEnable(mask) }

#if RP2350
        /// GPIO32...47, exposed on the B package only. Bit 0 means GPIO32.
        /// USB and QSPI bits in GPIO_HI are excluded from this interface.
        enum High {
            private static let bank = GPIOBank(high: true, mask: spec.highGPIOMask)

            static var input: UInt32 { bank.input }
            static var output: UInt32 { bank.output }
            static var outputEnabled: UInt32 { bank.outputEnabled }

            static func set(_ mask: UInt32) { bank.set(mask) }
            static func clear(_ mask: UInt32) { bank.clear(mask) }
            static func toggle(_ mask: UInt32) { bank.toggle(mask) }
            static func enableOutput(_ mask: UInt32) { bank.enableOutput(mask) }
            static func disableOutput(_ mask: UInt32) { bank.disableOutput(mask) }
            static func toggleOutputEnable(_ mask: UInt32) { bank.toggleOutputEnable(mask) }
        }
#endif

        /// Normalized QSPI mask on either chip: SCLK, SS, SD0...SD3 in bits 0...5.
        /// Select SIO in IO_QSPI separately. Do not change active flash pins while
        /// executing from XIP, including code, interrupt handlers, or data reads.
        enum QSPI {
            private static let pinMask: UInt32 = (1 << 6) - 1
            private static let bank = GPIOBank(high: true, mask: pinMask << spec.qspiShift)

            private static func shifted(_ mask: UInt32) -> UInt32 {
                mask << spec.qspiShift
            }

            static var input: UInt32 { bank.input >> spec.qspiShift }
            static var output: UInt32 { bank.output >> spec.qspiShift }
            static var outputEnabled: UInt32 { bank.outputEnabled >> spec.qspiShift }

            static func set(_ mask: UInt32) { bank.set(shifted(mask)) }
            static func clear(_ mask: UInt32) { bank.clear(shifted(mask)) }
            static func toggle(_ mask: UInt32) { bank.toggle(shifted(mask)) }
            static func enableOutput(_ mask: UInt32) { bank.enableOutput(shifted(mask)) }
            static func disableOutput(_ mask: UInt32) { bank.disableOutput(shifted(mask)) }
            static func toggleOutputEnable(_ mask: UInt32) { bank.toggleOutputEnable(shifted(mask)) }
        }
    }

    /// One incoming and one outgoing FIFO per core. Use one producer/consumer
    /// per side; main/IRQ users on the same core require caller serialization.
    /// A word transfer alone needs no DMB. Publishing shared RAM requires an
    /// explicit memory-ordering protocol; these methods do not provide one.
    enum FIFO {
        private static let validMask: UInt32 = 1 << 0
        private static let readyMask: UInt32 = 1 << 1
        private static let writeOverflowMask: UInt32 = 1 << 2
        private static let readUnderflowMask: UInt32 = 1 << 3

        private static let ST = register(address: SIO.sioBase + 0x50)
        private static let WR = register(address: SIO.sioBase + 0x54)
        private static let RD = register(address: SIO.sioBase + 0x58)

        static let depth: UInt32 = SIO.spec.fifoDepth

        /// One ST register sample. A snapshot does not reserve FIFO capacity.
        struct Status {
            private let value: UInt32

            var canRead: Bool { value & FIFO.validMask != 0 }
            var canWrite: Bool { value & FIFO.readyMask != 0 }
            var writeOverflow: Bool { value & FIFO.writeOverflowMask != 0 }
            var readUnderflow: Bool { value & FIFO.readUnderflowMask != 0 }

            fileprivate init(_ value: UInt32) {
                self.value = value
            }
        }

        /// Reads ST exactly once; inspecting the returned fields does no MMIO.
        static var status: Status { Status(ST.value) }
        static var canRead: Bool { ST.value & validMask != 0 }
        static var canWrite: Bool { ST.value & readyMask != 0 }
        static var writeOverflow: Bool { ST.value & writeOverflowMask != 0 }
        static var readUnderflow: Bool { ST.value & readUnderflowMask != 0 }

        static func write(_ word: UInt32) -> Bool {
            guard canWrite else { return false }
            WR.value = word
            return true
        }

        static func read() -> UInt32? {
            guard canRead else { return nil }
            return RD.value
        }

        /// Error flags are write-one-to-clear; does not consume queued data.
        static func clearErrors() { ST.value = FIFO.writeOverflowMask | FIFO.readUnderflowMask }

        /// Discards at most maxWords incoming words, stopping early if empty.
        /// Returns the number discarded. A zero limit performs no register reads.
        static func drain(maxWords: UInt32) -> UInt32 {
            var discarded: UInt32 = 0
            while discarded < maxWords {
                guard read() != nil else { break }
                discarded += 1
            }
            return discarded
        }
    }

    static func divide(_ numerator: UInt32, by denominator: UInt32) -> UInt32 {
        divmod(numerator, by: denominator).quotient
    }

    static func remainder(_ numerator: UInt32, by denominator: UInt32) -> UInt32 {
        divmod(numerator, by: denominator).remainder
    }

    static func divmod(
        _ numerator: UInt32,
        by denominator: UInt32
    ) -> (quotient: UInt32, remainder: UInt32) {
        precondition(denominator != 0, "Division by zero")
#if RP2040
        return Divider.calculate(numerator, denominator, signed: false)
#else
        // Cortex-M33 has CPU division; RP2350 has no SIO divider
        return (numerator / denominator, numerator % denominator)
#endif
    }

    static func divide(_ numerator: Int32, by denominator: Int32) -> Int32 {
        divmod(numerator, by: denominator).quotient
    }

    static func remainder(_ numerator: Int32, by denominator: Int32) -> Int32 {
        divmod(numerator, by: denominator).remainder
    }

    static func divmod(
        _ numerator: Int32,
        by denominator: Int32
    ) -> (quotient: Int32, remainder: Int32) {
        precondition(denominator != 0, "Division by zero")
        precondition(numerator != Int32.min || denominator != -1, "Division overflow")
#if RP2040
        let result = Divider.calculate(
            UInt32(bitPattern: numerator),
            UInt32(bitPattern: denominator),
            signed: true
        )
        return (Int32(bitPattern: result.quotient), Int32(bitPattern: result.remainder))
#else
        return (numerator / denominator, numerator % denominator)
#endif
    }

    static let interpolator0 = Interpolator(index: 0)
    static let interpolator1 = Interpolator(index: 1)

    /// Handles with the same index refer to the same core-local hardware.
    /// PEEK reads a result; every POP also updates both accumulators. Serialize
    /// main/IRQ use on the same core; configuration is not saved automatically.
    struct Interpolator {
        enum Lane { case lane0, lane1 }

        private static let baseOffset: UInt32 = 0x80
        private static let stride: UInt32 = 0x40

        private static let positionMask: UInt32 = 0x1F
        private static let maskLSBShift: UInt32 = 5
        private static let maskMSBShift: UInt32 = 10
        private static let signedMask: UInt32 = 1 << 15
        private static let crossInputMask: UInt32 = 1 << 16
        private static let crossResultMask: UInt32 = 1 << 17
        private static let addRawMask: UInt32 = 1 << 18
        private static let forceMSBShift: UInt32 = 19
        private static let forceMSBMask: UInt32 = 0x03
        private static let blendMask: UInt32 = 1 << 21
        private static let clampMask: UInt32 = 1 << 22
        private static let base1Shift: UInt32 = 16
        private static let addMask: UInt32 = 0x00FF_FFFF

        let index: UInt32
        private let ACCUM0: register
        private let ACCUM1: register
        private let BASE0: register
        private let BASE1: register
        private let BASE2: register
        private let POP_LANE0: register
        private let POP_LANE1: register
        private let POP_FULL: register
        private let PEEK_LANE0: register
        private let PEEK_LANE1: register
        private let PEEK_FULL: register
        private let CTRL_LANE0: register
        private let CTRL_LANE1: register
        private let ACCUM0_ADD: register
        private let ACCUM1_ADD: register
        private let BASE_1AND0: register

        /// Prepare register handles only; this does not access hardware.
        fileprivate init(index: UInt32) {
            self.index = index
            let interpolatorBase = SIO.sioBase + Self.baseOffset + index * Self.stride
            ACCUM0 = register(address: interpolatorBase + 0x00)
            ACCUM1 = register(address: interpolatorBase + 0x04)
            BASE0 = register(address: interpolatorBase + 0x08)
            BASE1 = register(address: interpolatorBase + 0x0C)
            BASE2 = register(address: interpolatorBase + 0x10)
            POP_LANE0 = register(address: interpolatorBase + 0x14)
            POP_LANE1 = register(address: interpolatorBase + 0x18)
            POP_FULL = register(address: interpolatorBase + 0x1C)
            PEEK_LANE0 = register(address: interpolatorBase + 0x20)
            PEEK_LANE1 = register(address: interpolatorBase + 0x24)
            PEEK_FULL = register(address: interpolatorBase + 0x28)
            CTRL_LANE0 = register(address: interpolatorBase + 0x2C)
            CTRL_LANE1 = register(address: interpolatorBase + 0x30)
            ACCUM0_ADD = register(address: interpolatorBase + 0x34)
            ACCUM1_ADD = register(address: interpolatorBase + 0x38)
            BASE_1AND0 = register(address: interpolatorBase + 0x3C)
        }

        struct Configuration {
            enum Mode { case normal, blend, clamp }
            /// Encodings of the two-bit FORCE_MSB field.
            enum ForceMSB: UInt32 { case none = 0, bit0, bit1, both }

            /// The only stored value; encode once and derive settings on demand.
            fileprivate let registerValue: UInt32

            var shift: UInt32 { registerValue & Interpolator.positionMask }
            var maskLSB: UInt32 {
                (registerValue >> Interpolator.maskLSBShift) & Interpolator.positionMask
            }

            var maskMSB: UInt32 {
                (registerValue >> Interpolator.maskMSBShift) & Interpolator.positionMask
            }

            var signed: Bool { registerValue & Interpolator.signedMask != 0 }
            var crossInput: Bool { registerValue & Interpolator.crossInputMask != 0 }
            var crossResult: Bool { registerValue & Interpolator.crossResultMask != 0 }
            var addRaw: Bool { registerValue & Interpolator.addRawMask != 0 }
            var forceMSB: ForceMSB {
                switch (registerValue >> Interpolator.forceMSBShift) & Interpolator.forceMSBMask {
                case ForceMSB.none.rawValue: return .none
                case ForceMSB.bit0.rawValue: return .bit0
                case ForceMSB.bit1.rawValue: return .bit1
                default: return .both
                }
            }

            var mode: Mode {
                if registerValue & Interpolator.blendMask != 0 { return .blend }
                if registerValue & Interpolator.clampMask != 0 { return .clamp }
                return .normal
            }

            init(
                shift: UInt32 = 0,
                maskLSB: UInt32 = 0,
                maskMSB: UInt32 = UInt32(UInt32.bitWidth - 1),
                signed: Bool = false,
                crossInput: Bool = false,
                crossResult: Bool = false,
                addRaw: Bool = false,
                forceMSB: ForceMSB = .none,
                mode: Mode = .normal
            ) {
                precondition(shift < UInt32.bitWidth)
                precondition(maskLSB <= maskMSB && maskMSB < UInt32.bitWidth)
                var value = shift | (maskLSB << Interpolator.maskLSBShift)
                    | (maskMSB << Interpolator.maskMSBShift)
                    | (forceMSB.rawValue << Interpolator.forceMSBShift)
                if signed { value |= Interpolator.signedMask }
                if crossInput { value |= Interpolator.crossInputMask }
                if crossResult { value |= Interpolator.crossResultMask }
                if addRaw { value |= Interpolator.addRawMask }
                switch mode {
                case .normal: break
                case .blend: value |= Interpolator.blendMask
                case .clamp: value |= Interpolator.clampMask
                }
                self.registerValue = value
            }
        }

        /// RP2040 shifts right; RP2350 rotates right before masking. RP2350-E1:
        /// OVERF flags may be spuriously set by rotated bits; check bounds yourself.
        /// BLEND is only valid on interpolator 0 lane 0; CLAMP on 1 lane 0.
        func configure(lane: Lane, configuration: Configuration = Configuration()) {
            switch configuration.mode {
            case .normal: break
            case .blend:
                precondition(index == 0 && lane == .lane0, "BLEND requires interpolator 0 lane 0")
            case .clamp:
                precondition(index == 1 && lane == .lane0, "CLAMP requires interpolator 1 lane 0")
            }
            (lane == .lane0 ? CTRL_LANE0 : CTRL_LANE1).value = configuration.registerValue
        }

        func peek(lane: Lane) -> UInt32 {
            (lane == .lane0 ? PEEK_LANE0 : PEEK_LANE1).value
        }

        func pop(lane: Lane) -> UInt32 {
            (lane == .lane0 ? POP_LANE0 : POP_LANE1).value
        }

        var peekFull: UInt32 { PEEK_FULL.value }

        /// Read the full result and update both accumulators.
        func popFull() -> UInt32 { POP_FULL.value }

        /// Read or replace one full 32-bit accumulator value.
        func accumulator(lane: Lane) -> UInt32 {
            (lane == .lane0 ? ACCUM0 : ACCUM1).value
        }

        func setAccumulator(_ value: UInt32, lane: Lane) {
            (lane == .lane0 ? ACCUM0 : ACCUM1).value = value
        }

        /// Read or replace BASE0/BASE1. Lane values may be signed by its control bit.
        func base(lane: Lane) -> UInt32 {
            (lane == .lane0 ? BASE0 : BASE1).value
        }

        func setBase(_ value: UInt32, lane: Lane) {
            (lane == .lane0 ? BASE0 : BASE1).value = value
        }

        /// BASE2 is independent of the paired BASE0/BASE1 write register.
        var base2: UInt32 { BASE2.value }
        func setBase2(_ value: UInt32) { BASE2.value = value }

        /// Atomically add an unsigned 24-bit value to the selected accumulator.
        func add(_ value: UInt32, lane: Lane) {
            precondition(value <= Interpolator.addMask)
            (lane == .lane0 ? ACCUM0_ADD : ACCUM1_ADD).value = value
        }

        /// In normal mode, each half uses its lane's SIGNED flag for sign extension.
        /// In BLEND mode, lane 1's SIGNED flag controls sign extension of both halves.
        func setBases(_ base0: UInt16, _ base1: UInt16) {
            BASE_1AND0.value = UInt32(base0) | (UInt32(base1) << Interpolator.base1Shift)
        }
    }

    /// All 32 locks on RP2040. RP2350-E2 restricts this API to safe lock numbers:
    /// 5...7, 10...11, 18...31. There is no implicit allocation or CAS reservation.
    static func spinlock(_ index: UInt32) -> Spinlock {
        precondition(index < Spinlock.count)
        precondition(spec.usableSpinlocks & (UInt32(1) << index) != 0,
                     "Spinlock is affected by RP2350-E2")
        return Spinlock(index: index)
    }

    /// Read attempts acquisition; any write releases. Only the successful owner
    /// may unlock. Never wait in an interrupt for a lock held by interrupted code.
    /// tryLock/unlock are raw operations without memory barriers. withLock and
    /// tryWithLock provide acquire/release ordering without changing IRQ state.
    /// Shared storage must use compiler/language-safe access under the same lock.
    struct Spinlock {
        static let count: UInt32 = 32
        private static let baseOffset: UInt32 = 0x100
        private static let stride: UInt32 = 4

        let index: UInt32
        private let LOCK: register

        fileprivate init(index: UInt32) {
            self.index = index
            LOCK = register(address: SIO.sioBase + Self.baseOffset + index * Self.stride)
        }

        /// A snapshot only; this does not claim ownership.
        var isLocked: Bool {
            SIO.SPINLOCK_ST.value & (UInt32(1) << index) != 0
        }

        func tryLock() -> Bool {
            LOCK.value != 0
        }

        func unlock() {
            LOCK.value = 0
        }

        /// Waits for ownership, executes body, then releases the lock.
        /// IRQ state is unchanged. Do not use from NMI/IRQ handlers or recursively
        /// acquire this lock; waiting has no timeout and requires peer progress.
        /// Keep body short and do not wait for work that needs this lock.
        /// All accesses to protected shared RAM must use this same ordered API
        /// and escaped pointer-backed storage. This does not make ordinary Swift
        /// globals or overlapping inout accesses safe for concurrent use.
        func withLock<Result>(_ body: () -> Result) -> Result {
            while !tryLock() {}
            Memory.barrier()
            defer {
                Memory.barrier()
                unlock()
            }
            return body()
        }

        /// Attempts ownership once; nil means body was not called.
        /// A successful result is wrapped in .some, even if Result is optional.
        /// Uses the same memory ordering and storage rules as withLock.
        /// IRQ state is unchanged; neither this API nor body may release a lock
        /// held by interrupted code. NMI/IRQ use requires a separate IRQ policy.
        func tryWithLock<Result>(_ body: () -> Result) -> Result? {
            guard tryLock() else { return nil }
            Memory.barrier()
            defer {
                Memory.barrier()
                unlock()
            }
            return .some(body())
        }
    }

    private struct GPIOBank {
        let high: Bool
        let mask: UInt32

        var input: UInt32 { (high ? SIO.GPIO_HI_IN : SIO.GPIO_IN).value & mask }
        var output: UInt32 { (high ? SIO.GPIO_HI_OUT : SIO.GPIO_OUT).value & mask }
        var outputEnabled: UInt32 {
            (high ? SIO.GPIO_HI_OE : SIO.GPIO_OE).value & mask
        }

        func set(_ bits: UInt32) {
            (high ? SIO.GPIO_HI_OUT_SET : SIO.GPIO_OUT_SET).value = bits & mask
        }

        func clear(_ bits: UInt32) {
            (high ? SIO.GPIO_HI_OUT_CLR : SIO.GPIO_OUT_CLR).value = bits & mask
        }

        func toggle(_ bits: UInt32) {
            (high ? SIO.GPIO_HI_OUT_XOR : SIO.GPIO_OUT_XOR).value = bits & mask
        }

        func enableOutput(_ bits: UInt32) {
            (high ? SIO.GPIO_HI_OE_SET : SIO.GPIO_OE_SET).value = bits & mask
        }

        func disableOutput(_ bits: UInt32) {
            (high ? SIO.GPIO_HI_OE_CLR : SIO.GPIO_OE_CLR).value = bits & mask
        }

        func toggleOutputEnable(_ bits: UInt32) {
            (high ? SIO.GPIO_HI_OE_XOR : SIO.GPIO_OE_XOR).value = bits & mask
        }
    }

#if RP2040
    /// Save operands, results, and DIRTY on every call. Nested IRQ/NMI calls are
    /// supported only when every interrupt divider user follows this convention.
    /// This preserves completed results, not the timing of an interrupted divide.
    private enum Divider {
        private static let readyMask: UInt32 = 1 << 0
        private static let dirtyMask: UInt32 = 1 << 1

        private static let UDIVIDEND = register(address: SIO.sioBase + 0x60)
        private static let UDIVISOR = register(address: SIO.sioBase + 0x64)
        private static let SDIVIDEND = register(address: SIO.sioBase + 0x68)
        private static let SDIVISOR = register(address: SIO.sioBase + 0x6C)
        private static let QUOTIENT = register(address: SIO.sioBase + 0x70)
        private static let REMAINDER = register(address: SIO.sioBase + 0x74)
        private static let CSR = register(address: SIO.sioBase + 0x78)

        static func calculate(
            _ numerator: UInt32,
            _ denominator: UInt32,
            signed: Bool
        ) -> (quotient: UInt32, remainder: UInt32) {
            var status = CSR.value
            while status & readyMask == 0 { status = CSR.value }
            let wasDirty = status & dirtyMask != 0
            let savedDividend = UDIVIDEND.value
            let savedDivisor = UDIVISOR.value
            let savedRemainder = REMAINDER.value
            let savedQuotient = QUOTIENT.value // Read last: clears DIRTY.
            if signed {
                SDIVIDEND.value = numerator
                SDIVISOR.value = denominator
            } else {
                UDIVIDEND.value = numerator
                UDIVISOR.value = denominator
            }
            while CSR.value & readyMask == 0 {}
            let remainder = REMAINDER.value
            let quotient = QUOTIENT.value
            UDIVIDEND.value = savedDividend
            UDIVISOR.value = savedDivisor
            // Result writes stop recalculation and set READY/DIRTY. Exact bits
            // preserve signed results even though operands use unsigned aliases.
            REMAINDER.value = savedRemainder
            QUOTIENT.value = savedQuotient
            if !wasDirty { _ = QUOTIENT.value }
            return (quotient, remainder)
        }
    }
#endif
}
