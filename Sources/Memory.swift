// Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
// SPDX-License-Identifier: MIT

// Swift memory operations and SRAM diagnostics backed by assembly.
// Memory.copy/move/set bind directly to the C-ABI entries in Memory.S.
// Memory.S supplies all loops and compiler ABI adapters; no external library is linked.
// Sources may be RAM or XIP flash; destinations must be writable RAM. These
// operations do not provide the access guarantees required by peripheral
// registers.
// Arm Run-time ABI, 5.3.4:
// https://github.com/ARM-software/abi-aa/blob/main/rtabi32/rtabi32.rst

/// Memory operations accept byte counts and return the original destination.
/// A zero count performs no source or destination memory access.
enum Memory {
    /// Linker allocation and boot-core main-stack diagnostics, in bytes.
    /// Call after startup on the privileged boot core with the original MSP.
    enum SRAM {
        /// SRAM capacity from the selected chip's linker configuration.
        @_extern(c, "rp2_sram_total_bytes")
        static func totalBytes() -> UInt
        /// .data, .bss, and alignment from SRAM base through .bss end.
        @_extern(c, "rp2_sram_static_bytes")
        static func staticBytes() -> UInt
        /// Entire main-stack reservation, including its currently unused part.
        @_extern(c, "rp2_sram_stack_reserved_bytes")
        static func stackReservedBytes() -> UInt
        /// Entire stack reservation plus any MPU guard.
        @_extern(c, "rp2_sram_reserved_bytes")
        static func reservedBytes() -> UInt
        /// Static storage plus the entire stack/guard reservation.
        static func allocatedBytes() -> UInt { staticBytes() + reservedBytes() }
        /// Room for static storage to grow; no heap allocator is provided.
        static func remainingBytes() -> UInt { totalBytes() - allocatedBytes() }
        /// Estimated peak written main-stack extent since startup, rounded to
        /// four bytes. Untouched allocations and writes equal to the paint pattern
        /// can be missed. Includes measurement/interrupt frames that overwrite paint.
        /// This is not an exact maximum or a guarantee of sufficient stack space.
        @_extern(c, "rp2_stack_peak_used_bytes")
        static func stackPeakUsedBytes() -> UInt
    }

    /// Copy count bytes between nonoverlapping regions and return destination.
    /// Assembly handles alignment and trailing bytes internally.
    @_extern(c, "memcpy")
    static func copy(
        _ dst: UnsafeMutableRawPointer,
        _ src: UnsafeRawPointer,
        _ count: UInt
    ) -> UnsafeMutableRawPointer

    /// Move count bytes, allowing overlapping regions, and return destination.
    /// Assembly selects the safe direction and handles alignment internally.
    @_extern(c, "memmove")
    static func move(
        _ dst: UnsafeMutableRawPointer,
        _ src: UnsafeRawPointer,
        _ count: UInt
    ) -> UnsafeMutableRawPointer

    /// Fill count bytes with the low byte of value, and return destination.
    @_extern(c, "memset")
    static func set(
        _ dst: UnsafeMutableRawPointer,
        _ value: Int32,
        _ count: UInt
    ) -> UnsafeMutableRawPointer
}
