// Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
// SPDX-License-Identifier: MIT

/// RP2040 register layout; shared drivers refer to the Chip alias in RP2.swift.
// RP2040 datasheet: 2.2 Address Map, 2.14 Resets, 2.15 Clocks,
// 2.16 XOSC, 2.18 PLL, 2.19 GPIO, 4.2 UART.
// https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf
// Compare RP2350: 2.2 Address map, 7.5 Resets, 8.1 Clocks,
// 8.2 XOSC, 8.6 PLL, 9 GPIO, 12.1 UART.
// https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf
enum RP2040 {
    enum ErrorCode: Equatable {
        case none
        case xipReadVerificationFailed
        case continuousReadVerificationFailed
    }

    enum XOSC {
        static let base: UInt32 = 0x4002_4000
    }

    enum SysPLL {
        static let base: UInt32 = 0x4002_8000
    }

    enum Clock {
        static let base: UInt32 = 0x4000_8000
        static let dividerIntegerShift: UInt32 = 8
        static let resuscitationOffset: UInt32 = 0x78
    }

    enum Reset {
        static let base: UInt32 = 0x4000_C000
        static let sysPLL: UInt32 = 1 << 12
        static let uart0: UInt32 = 1 << 22
        static let uart1: UInt32 = 1 << 23
        static let ioBank0: UInt32 = 1 << 5
        static let padsBank0: UInt32 = 1 << 8
    }

    enum GPIO {
        enum IO_BANK0 {
            static let base: UInt32 = 0x4001_4000
        }

        enum PADS_BANK0 {
            static let base: UInt32 = 0x4001_C000
        }

        // This chip has no auxiliary UART routes.
        static let uartAuxFuncsel: UInt32? = nil
        static let uart0TXAuxPins: UInt32 = 0
        static let uart0RXAuxPins: UInt32 = 0
        static let uart1TXAuxPins: UInt32 = 0
        static let uart1RXAuxPins: UInt32 = 0
    }

    enum UART0 {
        static let base: UInt32 = 0x4003_4000
    }

    enum UART1 {
        static let base: UInt32 = 0x4003_8000
    }

    // RP2040 XIP serial-flash controller. Addresses and encodings are from
    // RP2040 datasheet sections 2.6.3 and 4.10.
    enum SSI {
        typealias RegPtrRW = UnsafeMutablePointer<UInt32>
        typealias RegPtrRO = UnsafePointer<UInt32>

        @_extern(c, "rp2040_xip_probe_magic")
        private static var rp2040_xip_probe_magic: UInt32

        fileprivate static var xipProbeMagicAddress: UInt32 {
            UInt32(truncatingIfNeeded: Memory.address(of: &rp2040_xip_probe_magic))
        }

        static let base: UInt32 = 0x1800_0000
        static let flashClockDivider: UInt32 = 4
        static let ctrlr0Standard: UInt32 = 0x001f_0300
        static let ctrlr0Dual: UInt32 = 0x003f_0300 // SPI_FRF = 01b.
        static let ctrlr0Quad: UInt32 = 0x005f_0300 // SPI_FRF = 10b.
        static let opcodeDualIO: UInt32 = 0xbb
        static let opcodeQuadIO: UInt32 = 0xeb
        static let continuousReadMode: UInt32 = 0xa0 // M[5:4] = 10b.
        static let commandReadMode: UInt32 = 0xff // M[5:4] != 10b: require a command on the next access.
        static let commandShift: UInt32 = 24
        static let waitCyclesShift: UInt32 = 11
        static let dualDummyCycles: UInt32 = 0
        static let quadDummyCycles: UInt32 = 4
        static let spiCtrlr0StandardRead: UInt32 = 0x0300_0218
        static let spiCtrlr0ModeEntry: UInt32 = 0x221 // INST_L = 8, ADDR_L = 32, TRANS_TYPE = 1.
        static let spiCtrlr0ContinuousRead: UInt32 = 0x22 // INST_L = 0, ADDR_L = 32, TRANS_TYPE = 2.
        // 0x13... bypasses the cache without allocating or replacing cache lines.
        static let xipUncachedAliasOffset: UInt32 = 0x0300_0000

        enum Register {
            static let ctrlr0: UInt32 = 0x00
            static let ctrlr1: UInt32 = 0x04
            static let enable: UInt32 = 0x08
            static let slaveEnable: UInt32 = 0x10
            static let baudRate: UInt32 = 0x14
            static let status: UInt32 = 0x28
            static let data: UInt32 = 0x60
            static let spiCtrlr0: UInt32 = 0xf4
        }

        // Exclude single-SPI Fast Read (0Bh): it requires eight dummy clocks
        // (P25Q16H datasheet, section 10.11), but SSI WAIT_CYCLES applies to
        // enhanced (Dual/Quad) SPI reads, not standard single-SPI reads.
        // Setting WAIT_CYCLES=8 therefore cannot supply the dummy clocks for XIP.
        // RP2040 datasheet, section 4.10.10.4.2:
        // https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf
        enum Preset {
            case quadIO
            case dualIO
            case standardRead
        }

        struct ModeConfig {
            let control: UInt32
            let command: UInt32
            let spiControl: UInt32
            let continuousControl: UInt32
        }

        // Construct in Flash before entering the SRAM configuration routine.
        struct Config {
            let preset: Preset
            let continuousMode = SSI.continuousReadMode
            let commandMode = SSI.commandReadMode
            let quad: ModeConfig
            let dual: ModeConfig
            // command=0 delegates command generation to the XIP hardware.
            let standard = ModeConfig(
                control: SSI.ctrlr0Standard,
                command: 0,
                spiControl: SSI.spiCtrlr0StandardRead,
                continuousControl: 0
            )
            let divider = SSI.flashClockDivider
            let enable = RegPtrRW(bitPattern: UInt(SSI.base + Register.enable))!
            let baudRate = RegPtrRW(bitPattern: UInt(SSI.base + Register.baudRate))!
            let ctrlr0 = RegPtrRW(bitPattern: UInt(SSI.base + Register.ctrlr0))!
            let ctrlr1 = RegPtrRW(bitPattern: UInt(SSI.base + Register.ctrlr1))!
            let slave = RegPtrRW(bitPattern: UInt(SSI.base + Register.slaveEnable))!
            let spiControl = RegPtrRW(bitPattern: UInt(SSI.base + Register.spiCtrlr0))!
            let data = RegPtrRW(bitPattern: UInt(SSI.base + Register.data))!
            let status = RegPtrRO(bitPattern: UInt(SSI.base + Register.status))!
            let verificationAddress: RegPtrRO
            let commandAddress: UInt32
            let expectedValue: UInt32
            let expectedSerialValue: UInt32
            let busy: UInt32 = 1 << 0
            let receiveNotEmpty: UInt32 = 1 << 3
            let maxPollCount: UInt32 = 100_000

            init(preset: Preset = .quadIO) {
                self.preset = preset
                let continuation = (SSI.continuousReadMode << SSI.commandShift)
                    | SSI.spiCtrlr0ContinuousRead
                let quadWait = SSI.quadDummyCycles << SSI.waitCyclesShift
                let dualWait = SSI.dualDummyCycles << SSI.waitCyclesShift
                quad = ModeConfig(
                    control: SSI.ctrlr0Quad,
                    command: SSI.opcodeQuadIO,
                    spiControl: quadWait | SSI.spiCtrlr0ModeEntry,
                    continuousControl: quadWait | continuation
                )
                dual = ModeConfig(
                    control: SSI.ctrlr0Dual,
                    command: SSI.opcodeDualIO,
                    spiControl: dualWait | SSI.spiCtrlr0ModeEntry,
                    continuousControl: dualWait | continuation
                )
                let probeAddress = SSI.xipProbeMagicAddress
                verificationAddress = RegPtrRO(
                    bitPattern: UInt(probeAddress + SSI.xipUncachedAliasOffset)
                )!
                let flashAddressMask: UInt32 = 0x00ff_ffff
                let modeByteShift: UInt32 = 8
                commandAddress = (probeAddress & flashAddressMask) << modeByteShift
                // Read the baseline through uncached XIP while Standard Read is active.
                expectedValue = Memory.volatileLoad32(verificationAddress)
                // RP2040 datasheet 4.10.3:
                // XIP swaps bytes for the CPU; FIFO reads retain wire byte order.
                expectedSerialValue = expectedValue.byteSwapped
            }

            // Configure the read mode and compare Flash data with the expected value.
            @_silgen_name("rp2040_ssi_verify_read_mode")
            @inline(never)
            // Size optimization fetched MMIO function addresses from the Flash GOT.
            // Keep direct SRAM calls while SSI changes can make Flash unreadable.
            @_optimize(none)
            fileprivate func verifyReadMode(_ mode: ModeConfig, modeByte: UInt32) -> Bool {
                Memory.volatileStore32(enable, 0)
                Memory.volatileStore32(baudRate, divider)
                Memory.volatileStore32(ctrlr0, mode.control)
                Memory.volatileStore32(ctrlr1, 0) // Receive one 32-bit frame.
                Memory.volatileStore32(slave, 0)
                Memory.volatileStore32(spiControl, mode.spiControl)
                Memory.volatileStore32(enable, 1)

                guard mode.command != 0 else {
                    // Standard Read (03h) sends a command on each XIP access.
                    Memory.volatileStore32(slave, 1)
                    let value = Memory.volatileLoad32(verificationAddress)
                    return value == expectedValue
                }

                // Queue the complete command/address before selecting Flash.
                Memory.volatileStore32(data, mode.command)
                Memory.volatileStore32(data, commandAddress | modeByte)
                Memory.volatileStore32(slave, 1)
                let completionMask = busy | receiveNotEmpty
                var poll: UInt32 = 0
                while poll < maxPollCount {
                    let flags = Memory.volatileLoad32(status)
                    if flags & completionMask == receiveNotEmpty {
                        let value = Memory.volatileLoad32(data)
                        return value == expectedSerialValue
                    }
                    poll &+= 1
                }
                return false
            }
        }

        // Boot2 starts the flash in standard 03h read mode.
        private static var xipMode: Preset = .standardRead

        static func getXIPmode() -> Preset { return xipMode }

        // Startup only: RAM must be initialized, with interrupts and Core 1 inactive.
        // The caller must handle errors in SRAM; failed probes leave Flash unverified.
        @_silgen_name("rp2040_ssi_config")
        @inline(never)
        // Observed with optimization: -Osize adds Flash GOT reads, and speed
        // optimization creates a specialized body outside the named SRAM section.
        // Keep this entire control path in the section selected by the linker.
        @_optimize(none)
        static func setXIPmode(config: Config) -> RP2040.ErrorCode {
            var candidate = config.preset
            while true {
                let selected: ModeConfig
                let next: Preset?
                switch candidate {
                case .quadIO: (selected, next) = (config.quad, .dualIO)
                case .dualIO: (selected, next) = (config.dual, .standardRead)
                case .standardRead: (selected, next) = (config.standard, nil)
                }

                guard config.verifyReadMode(selected, modeByte: config.commandMode) else {
                    guard let next else { return .xipReadVerificationFailed }
                    candidate = next
                    continue
                }

                if selected.continuousControl != 0 {
                    guard config.verifyReadMode(selected, modeByte: config.continuousMode) else {
                        return .continuousReadVerificationFailed
                    }
                    // Verify the actual command-free XIP path before returning.
                    Memory.volatileStore32(config.enable, 0)
                    Memory.volatileStore32(config.spiControl, selected.continuousControl)
                    Memory.volatileStore32(config.enable, 1)
                    let value = Memory.volatileLoad32(config.verificationAddress)
                    guard value == config.expectedValue else {
                        return .continuousReadVerificationFailed
                    }
                }
                xipMode = candidate
                return .none
            }
        }
    }
}

// Cortex-M0+ runtime support. @_cdecl entry points must be global functions.
// __aeabi_uidiv takes two unsigned 32-bit integers and returns their quotient.
// A zero denominator is handled by __aeabi_idiv0 below.
// REVISIT: use SIO later
@_cdecl("__aeabi_uidiv")
func aeabiUnsignedDivide(_ numerator: UInt32, _ denominator: UInt32) -> UInt32 {
    guard denominator != 0 else {
        return UInt32(bitPattern: aeabiIntegerDivideByZero(numerator == 0 ? 0 : -1))
    }
    var remainder = numerator
    var quotient: UInt32 = 0
    // Build the quotient from its highest bit. Check before shifting to avoid overflow.
    for shift in (0..<UInt32.bitWidth).reversed() {
        if denominator <= (remainder >> shift) {
            remainder -= denominator << shift
            quotient |= UInt32(1) << shift
        }
    }
    return quotient
}

// The ABI routes division by zero through this hook. This firmware stops on it.
@_cdecl("__aeabi_idiv0")
func aeabiIntegerDivideByZero(_ proposedResult: Int32) -> Int32 {
    preconditionFailure("Integer division by zero")
}
