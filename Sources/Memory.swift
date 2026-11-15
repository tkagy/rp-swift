// Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
// SPDX-License-Identifier: MIT

// RAM startup, compiler-generated memory operations, and volatile access.
// Supply the memory helper calls emitted by Swift/LLVM in Swift, adding ABI entry
// points as needed instead of linking external memory-helper libraries.
// Copy/fill operate on normal RAM and XIP data. Use the volatile accessors for
// hardware registers and reads whose side effects must not be optimized away.
// Arm Run-time ABI, 5.3.4: https://github.com/ARM-software/abi-aa/blob/main/rtabi32/rtabi32.rst

enum Memory {
    // Memory.S performs one aligned 32-bit access, even if the result is discarded.
    // These operations provide neither atomic read-modify-write nor CPU barriers.
    @_extern(c, "memory_volatile_load32")
    static func volatileLoad32(_ pointer: UnsafePointer<UInt32>) -> UInt32

    @_extern(c, "memory_volatile_store32")
    static func volatileStore32(_ pointer: UnsafeMutablePointer<UInt32>, _ value: UInt32)

    // Configs/rp2040.ld and Configs/rp2350.ld define these section boundaries.
    // Load images for .data and .ramfunc are in flash; their runtime ranges
    // and .bss are in RAM.
    // End addresses are exclusive. These symbols identify addresses, not stored values.
    @_extern(c, "__data_load_start") private static var dataLoadStart: UInt32
    @_extern(c, "__data_start") private static var dataStart: UInt32
    @_extern(c, "__data_end") private static var dataEnd: UInt32
    @_extern(c, "__bss_start") private static var bssStart: UInt32
    @_extern(c, "__bss_end") private static var bssEnd: UInt32
    @_extern(c, "__ramfunc_load_start") private static var ramfuncLoadStart: UInt32
    @_extern(c, "__ramfunc_start") private static var ramfuncStart: UInt32
    @_extern(c, "__ramfunc_end") private static var ramfuncEnd: UInt32

    // Run once from RP2.reset(), before main accesses stored globals or statics.
    // The stack is already available. copy/set depend only on arguments and
    // stack storage, so they can initialize RAM without relying on its contents.
    static func initialize() {
        // Establish zero initial values for .bss.
        let bss = address(of: &bssStart)
        _ = set(UnsafeMutableRawPointer(bitPattern: bss)!, 0, address(of: &bssEnd) - bss)

        // Restore .data initial values from the flash load image.
        let data = address(of: &dataStart)
        _ = copy(
            UnsafeMutableRawPointer(bitPattern: data)!,
            UnsafeRawPointer(bitPattern: address(of: &dataLoadStart))!,
            address(of: &dataEnd) - data
        )

        // Copy RAM-resident functions before peripheral access or XIP changes.
        // Flash is still readable while their load image is copied into SRAM.
        let ramfunc = address(of: &ramfuncStart)
        _ = copy(
            UnsafeMutableRawPointer(bitPattern: ramfunc)!,
            UnsafeRawPointer(bitPattern: address(of: &ramfuncLoadStart))!,
            address(of: &ramfuncEnd) - ramfunc
        )
    }

    // Obtain a linker symbol's address without reading the value at that address.
    @inline(__always)
    static func address(of symbol: inout UInt32) -> UInt {
        withUnsafePointer(to: &symbol, UInt.init(bitPattern:))
    }

    /// Copy count bytes between nonoverlapping regions and return destination.
    @inline(never)
    static func copy(_ destination: UnsafeMutableRawPointer, _ source: UnsafeRawPointer, _ count: UInt) -> UnsafeMutableRawPointer {
        var index: UInt = 0
        // Use words only when both addresses have the same offset modulo four.
        // Copy leading bytes until both are word-aligned, as Cortex-M0+ requires.
        if (UInt(bitPattern: destination) ^ UInt(bitPattern: source)) & 3 == 0 {
            while index < count && (UInt(bitPattern: destination) &+ index) & 3 != 0 {
                copyByte(destination.advanced(by: Int(index)), source.advanced(by: Int(index)))
                index &+= 1
            }
            while count - index >= 4 {
                copyWord(destination.advanced(by: Int(index)), source.advanced(by: Int(index)))
                index &+= 4
            }
        }
        while index < count {
            copyByte(destination.advanced(by: Int(index)), source.advanced(by: Int(index)))
            index &+= 1
        }
        return destination
    }

    /// Fill count bytes starting at destination with the same byte value.
    /// RAM startup calls this with value = 0 to clear the entire .bss section.
    /// Return the original destination pointer, matching C memset's return value.
    @inline(never)
    static func set(_ destination: UnsafeMutableRawPointer, _ value: Int32, _ count: UInt) -> UnsafeMutableRawPointer {
        // Number of bytes written so far; destination itself does not change.
        var index: UInt = 0

        // Use only the lowest 8 bits of value, as memset does.
        // For example, 0x123 becomes the byte 0x23.
        let byte = UInt8(truncatingIfNeeded: value)

        // Repeat that byte four times so one 32-bit store fills four bytes.
        // For example, byte = 0xAB produces word = 0xABABABAB.
        // Clearing RAM uses byte = 0, so word is also zero.
        let word = UInt32(byte) * 0x01010101

        // 1. Write individual bytes until the address is a multiple of four.
        // Cortex-M0+ requires this alignment before we can store a UInt32.
        // Stop early if we have already filled all count bytes.
        while index < count && (UInt(bitPattern: destination) &+ index) & 3 != 0 {
            setByte(destination.advanced(by: Int(index)), byte)
            index &+= 1
        }

        // 2. Fill four bytes per store while at least four bytes remain.
        while count - index >= 4 {
            setWord(destination.advanced(by: Int(index)), word)
            index &+= 4
        }

        // 3. Fill any remaining bytes individually (at most three).
        while index < count {
            setByte(destination.advanced(by: Int(index)), byte)
            index &+= 1
        }

        // Return where the fill started, not the address after the last byte.
        return destination
    }

    // Keep individual loads/stores out of line so LLVM cannot turn the optimized
    // copy/set loops into calls back to memcpy/memset. Word accesses are aligned
    // by the callers; byte accesses handle leading, trailing, or unaligned data.
    @inline(never)
    private static func copyByte(_ destination: UnsafeMutableRawPointer, _ source: UnsafeRawPointer) {
        destination.storeBytes(of: source.load(as: UInt8.self), as: UInt8.self)
    }

    @inline(never)
    private static func copyWord(_ destination: UnsafeMutableRawPointer, _ source: UnsafeRawPointer) {
        destination.storeBytes(of: source.load(as: UInt32.self), as: UInt32.self)
    }

    @inline(never)
    private static func setByte(_ destination: UnsafeMutableRawPointer, _ value: UInt8) {
        destination.storeBytes(of: value, as: UInt8.self)
    }

    @inline(never)
    private static func setWord(_ destination: UnsafeMutableRawPointer, _ value: UInt32) {
        destination.storeBytes(of: value, as: UInt32.self)
    }
}

// Export only the compiler ABI entry points required by the current firmware.
// Add other names when generated code actually needs them. @_cdecl requires globals.
// The linker aliases __aeabi_memcpy and __aeabi_memcpy4 to memcpy; their arguments
// match and Arm ABI callers ignore the return value.
@_cdecl("memcpy")
func memoryCopy(_ destination: UnsafeMutableRawPointer, _ source: UnsafeRawPointer, _ count: UInt) -> UnsafeMutableRawPointer {
    Memory.copy(destination, source, count)
}

// __aeabi_memclr4 aliases this adapter, which supplies the zero fill value.
@_cdecl("__aeabi_memclr")
func aeabiMemclr(_ destination: UnsafeMutableRawPointer, _ count: UInt) {
    _ = Memory.set(destination, 0, count)
}
