// Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
// SPDX-License-Identifier: MIT

#if RP2040 && RP2350
    #error("Choose exactly one target: RP2040 or RP2350")
#elseif RP2040
    typealias Chip = RP2040
#elseif RP2350
    typealias Chip = RP2350
#elseif !RP2040 && !RP2350
    #error("Pass -D RP2040 or -D RP2350 when building")
#endif

/// Common firmware entry point for RP-series chips.
// @main is not required because resetHandler invokes main through reset().
enum RP2 {
    // Select the CPU clock used during startup.
#if RP2040
    static var sysFreqConfig: Clock.SysFreqConfig { .MHz125 }
#endif
#if RP2350
    static var sysFreqConfig: Clock.SysFreqConfig { .MHz150 }
#endif

    /// A 32-bit hardware register at a fixed address.
    // RP2040 datasheet, 2.2 "Address Map"; 2.1.2 "Atomic Register Access".
    // https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf
    // RP2350 datasheet, 2.2 "Address map"; 2.1.3 "Atomic register access".
    // https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf
    // The immutable handle can be shared; it refers to hardware, not Swift-owned memory.
    // Sendable does not serialize register operations or replace peripheral ownership.
    struct Register32: @unchecked Sendable {
        // RP2040 2.1.2 / RP2350 2.1.3: atomic SET/CLEAR alias address offsets.
        // Writing a mask to base+0x2000 sets those bits in the original register;
        // writing to base+0x3000 clears them. These are address offsets, not masks.
        private enum AtomicAlias {
            static let setOffset: UInt32 = 0x2000
            static let clearOffset: UInt32 = 0x3000
        }

        let address: UInt32
        private let pointer: UnsafeMutablePointer<UInt32>

        // Access hardware on every read or write. Keep these accessors out of
        // optimized callers; ordinary Swift pointer accesses are not volatile.
        // Pointer construction stays in the optimized initializer, keeping the actual
        // non-elidable load/store short enough for time-sensitive peripheral polling.
        // These accessors do not provide locking or shared-memory synchronization.
        var value: UInt32 {
            @inline(never)
            @_optimize(none)
            get {
                return pointer.pointee
            }
            @inline(never)
            @_optimize(none)
            nonmutating set {
                // Write to the hardware address without changing this Register32 value.
                pointer.pointee = newValue
            }
        }

        init(address: UInt32) {
            self.address = address
            pointer = UnsafeMutablePointer<UInt32>(bitPattern: UInt(address))!
        }

        // Atomic aliases for RP peripheral registers that support SET/CLEAR writes.
        // RP2040 datasheet 2.1.2; RP2350 datasheet 2.1.3 (URLs above).
        func setBits(_ mask: UInt32) {
            Register32(address: address + AtomicAlias.setOffset).value = mask
        }

        func clearBits(_ mask: UInt32) {
            Register32(address: address + AtomicAlias.clearOffset).value = mask
        }
    }

    // Shared peripheral reset control. Chip.Reset supplies addresses and reset masks.
    // RESET (0x00) and RESET_DONE (0x08) have the same offsets on both chips.
    // Calls that change reset state must be serialized by the caller.
    enum RESETS {
        private static let RESET = Register32(address: Chip.Reset.base)
        private static let RESET_DONE = Register32(address: Chip.Reset.base + 0x08)
        private static let maxPollCount: UInt32 = 1_000_000

        // Release without disturbing the configuration of peripherals already running.
        static func release(_ mask: UInt32) -> Bool {
            if RESET.value & mask == 0, RESET_DONE.value & mask == mask { return true }
            RESET.clearBits(mask)
            for _ in 0..<maxPollCount {
                if RESET_DONE.value & mask == mask { return true }
            }
            return false
        }

        // Reset the selected peripherals, then release and wait for completion.
        static func reset(_ mask: UInt32) -> Bool {
            RESET.setBits(mask)
            return release(mask)
        }
    }

    // Return the type directly, without lazy static storage before RAM is initialized.
    static var memory: Memory.Type { Memory.self }
    static var clock: Clock.Type { Clock.self }

    // Create these explicitly during initialize(), after RAM and clocks are ready.
    // nil is a constant initial value and requires no lazy initializer or atomic helpers.
    // Use open(tx:rx:baudRate:) to configure pins only for a UART the application uses.
    static var uart0: UART! = nil

    // Run once at startup: RAM must be ready before stored peripheral state is used,
    // and the peripheral clock must be ready before either UART is initialized.
    static func initialize() -> Never {
        memory.initialize()
        clock.initialize(config: sysFreqConfig)
        uart0 = UART(.uart0)
        uart0.open(tx: 0, rx: 1, baudRate: 115_200)
        if uart0.status != .none { faultHandler() }
        main()
    }

    static func main() -> Never {
        uart0.write("Disable local echo, then type:\r\n")
        while true {
            if case let .byte(byte) = uart0.read() {
                uart0.write(byte: byte)
            }
        }
    }

    // The vector table supplies the initial stack pointer: boot2 on RP2040,
    // boot ROM on RP2350. Initialize .bss/.data before main uses stored Swift state.
    // RP2040 datasheet: 2.8 Bootrom; RP2350 datasheet: 5 Bootrom.
    // https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf
    // https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf
    static func reset() -> Never {
        initialize()
    }

    static func fault() -> Never {
        while true {}
    }
}

@_cdecl("rp2_reset")
func resetHandler() -> Never {
    RP2.reset()
}

@_cdecl("rp2_fault")
func faultHandler() -> Never {
    RP2.fault()
}
