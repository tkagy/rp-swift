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
// RP2.S initializes RAM/protection and calls Memory.S to paint the stack before rp2_core0_start.
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

    typealias memory = Memory
    typealias clock = Clock
    typealias timer = Timer
    typealias sio = SIO
    typealias console = Console

    enum Core0 {
        // Entered only after assembly startup initializes RAM and protects the stack.
        // The peripheral clock must be ready before either UART is initialized.
        static func initialize() {
            sio.initialize()
            clock.initialize()
            timer.initialize()
            console.initialize(name: Chip.name)
            console.add(UART(.uart0).initialize(tx: 0, rx: 1, baudRate: 115_200))
            Core1.launch()
        }

        // Main loop
        static func main() -> Never {
            while true { console.poll() }
        }
    }

    enum Core1 {
        private static let syncWord: UInt32 = 0
        private static let launchWord: UInt32 = 1
        // Our own notification that core 1 has reached Swift after stack protection.
        // This value is not part of the Boot ROM launch protocol.
        private static let readyWord: UInt32 = 0xC001_C001
        private static let startupTimeout: UInt64 = Timer.microsecondsPerSecond
        private static var started = false

        // Linker-defined addresses and Arm SEV are supplied by our RP2.S helpers.
        @_extern(c, "rp2_core1_vector_table")
        private static func vectorTableAddress() -> UInt32
        @_extern(c, "rp2_core1_stack_top")
        private static func stackTopAddress() -> UInt32
        @_extern(c, "rp2_core1_entry_address")
        private static func entryAddress() -> UInt32
        @_extern(c, "rp2_send_event")
        private static func sendEvent()

        /// Called once on core 0 to start core 1, which waits in the Boot ROM after reset.
        //    RP2040 datasheet section 2.8.2
        //    RP2350 section 5.3
        static func launch() {
            precondition(sio.core == .core0, "Start core 1 from core 0")
            precondition(!started, "Core 1 is already started")
            precondition(timer.isInitialized, "Initialize the timer before starting core 1")

            let vectorTable = vectorTableAddress()
            let stackTop = stackTopAddress()
            let entry = entryAddress()
            let deadline = timer.microseconds &+ startupTimeout
            memory.barrier()

            while !(
                exchangeBootWord(syncWord, until: deadline)
                    && exchangeBootWord(syncWord, until: deadline)
                    && exchangeBootWord(launchWord, until: deadline)
                    && exchangeBootWord(vectorTable, until: deadline)
                    && exchangeBootWord(stackTop, until: deadline)
                    && exchangeBootWord(entry, until: deadline)
            ) {}

            precondition(readBootWord(until: deadline) == readyWord,
                         "Unexpected core 1 startup acknowledgement")
            memory.barrier()
            started = true
        }

        /// - Before sending 0, discard pending replies and wake core 1.
        /// - Send one launch value through the FIFO and wake core 1.
        /// - Wait for the reply; return whether it matches the value sent.
        /// - Stop if the startup deadline expires.
        private static func exchangeBootWord(_ word: UInt32, until deadline: UInt64) -> Bool {
            precondition(!timer.hasReached(deadline: deadline), "Core 1 startup timed out")
            if word == syncWord {
                // Before sending 0, the datasheets require discarding pending replies
                // and issuing SEV: core 1 may be asleep waiting for FIFO space.
                _ = sio.FIFO.drain(maxWords: sio.FIFO.depth)
                sendEvent()
            }
            while !sio.FIFO.write(word) {
                precondition(!timer.hasReached(deadline: deadline), "Core 1 FIFO write timed out")
            }
            sendEvent()
            return readBootWord(until: deadline) == word
        }

        /// Wait for one value from core 1, using the deadline shared by the entire launch.
        private static func readBootWord(until deadline: UInt64) -> UInt32 {
            while !timer.hasReached(deadline: deadline) {
                if let word = sio.FIFO.read() { return word }
            }
            preconditionFailure("Core 1 FIFO read timed out")
        }

        /// Entered on core 1 after its own stack protection is installed.
        /// Shared startup runs only on core 0; ordinary core 1 IRQs remain masked.
        static func initialize() {
            precondition(sio.core == .core1, "Initialize Core1 on core 1")
            memory.barrier()
            let notified = sio.FIFO.write(readyWord)
            precondition(notified, "Core 1 startup acknowledgement failed")
            sendEvent()
        }

        static func main() -> Never {
            while true {}
        }
    }

}

// The assembly reset entry branches here only after RAM and stack setup succeed.
// This C-ABI entry never returns to startup code.
@_cdecl("rp2_core0_start")
func firmwareCore0Start() -> Never {
    RP2.Core0.initialize()
    RP2.Core0.main()
}

// The separate assembly entry does not clear shared RAM or repeat core 0 startup.
@_cdecl("rp2_core1_start")
func firmwareCore1Start() -> Never {
    RP2.Core1.initialize()
    RP2.Core1.main()
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
