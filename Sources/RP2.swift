// Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
// SPDX-License-Identifier: MIT

#if RP2040 && RP2350
#error("Choose exactly one target: RP2040 or RP2350")
#elseif RP2040
typealias Chip = RP2040
#elseif RP2350
typealias Chip = RP2350
#else
#error("Pass -D RP2040 or -D RP2350 when building")
#endif

/// Common firmware entry point for RP-series chips.
// RP2.S initializes RAM/protection and calls Memory.S to paint the stack before rp2_start.
// No Swift code runs before those steps; @main is not required.
// This firmware reserves no heap region and performs no heap allocations.
// Use static storage and stack values instead of dynamically allocated strings.

enum RP2 {
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

    // Return the type directly, without lazy static storage before RAM is initialized.
    static var memory: Memory.Type { Memory.self }
    static var clock: Clock.Type { Clock.self }
    static var timer: Timer.Type { Timer.self }
    static var console: Console.Type { Console.self }

    // Entered only after assembly startup initializes RAM and protects the stack.
    // The peripheral clock must be ready before either UART is initialized.
    static func initialize() -> Never {
        clock.initialize()
        timer.initialize()
        console.initialize(name: Chip.name)
        console.add(UART(.uart0).initialize(tx: 0, rx: 1, baudRate: 115_200))
        main()
    }

    // Main loop
    static func main() -> Never {
        while true { console.poll() }
    }

}

// The assembly reset entry branches here only after RAM and stack setup succeed.
// This C-ABI entry never returns to startup code.
@_cdecl("rp2_start")
func firmwareStart() -> Never {
    RP2.initialize()
}

// Hardware faults enter RP2.S directly through the vector table, without a
// Swift prologue. Explicit software failures use this normal-call adapter.
@_extern(c, "rp2_fault")
private func stopOnFault()

func faultHandler() -> Never {
    stopOnFault()
    // The assembly entry never returns; express that guarantee to Swift callers.
    while true {}
}
