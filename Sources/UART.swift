// Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
// SPDX-License-Identifier: MIT

/// UART0 or UART1 with explicit, pin-map-validated TX/RX GPIOs and baud rate, 8N1.
/// Call Clock.initialize() before initialize().
// RP2040 datasheet: 4.2.8 UART registers; 2.19.6.1 IO - User Bank;
// 2.19.6.3 Pad Control - User Bank; 2.14 Subsystem Resets; 1.4.3 GPIO Functions.
// https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf
// RP2350 datasheet: 12.1.8 UART registers; 9.11.1 IO - User Bank;
// 9.11.3 Pad Control - User Bank; 7.5.3 Reset registers; 1.2.3 GPIO functions.
// https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf
struct UART {
    private typealias register = RP2.Register32

    enum ErrorCode: UInt32 {
        case none = 0
        case resetDidNotComplete = 1
        case invalidPins = 2
        case invalidBaudRate = 3
    }

    enum Port {
        case uart0
        case uart1

        // Pin maps from RP2040 Table 2 / RP2350 Table 3.
        // Lists include RP2350B GPIOs; funcsel(for:) checks chip/package availability.
        struct Signal {
            // Fixed-size lists stored inline, without heap allocation.
            let gpio: InlineArray<6, UInt32>
            let gpioAux: InlineArray<6, UInt32>

            func funcsel(for pin: UInt32) -> UInt32? {
                guard Chip.GPIO.isAvailable(pin) else { return nil }
                for index in gpio.indices {
                    if gpio[index] == pin { return Chip.GPIO.uartFuncsel }
                }
                #if RP2350
                for index in gpioAux.indices {
                    if gpioAux[index] == pin { return Chip.GPIO.uartAuxFuncsel }
                }
                #endif
                return nil
            }
        }

        struct Config {
            let base: UInt32
            let resetMask: UInt32
            let tx: Signal
            let rx: Signal
        }
    }

    private static let maxPollCount: UInt32 = 1_000_000

    private(set) var status: ErrorCode = .none
    // No active pin or baud-rate configuration is retained until initialization succeeds.
    private(set) var transmitPin: UInt32? = nil
    private(set) var receivePin: UInt32? = nil
    // Preserve each pin's pre-UART state across reinitialization.
    private var transmitPinState: PinState? = nil
    private var receivePinState: PinState? = nil
    // Requested baud rate; the hardware divider may introduce rounding error.
    private(set) var baudRate: UInt32? = nil
    private let config: Port.Config
    private let regs: Registers

    private struct PinState {
        let pin: UInt32
        let control: UInt32
        let pad: UInt32
    }

    // Shared reset-register handles; the selected port supplies the UART reset bit.
    // Base addresses and reset bit positions come from the selected Chip.
    // RP2040  2.14: base 0x4000C000; UART0 bit 22, UART1 bit 23, IO_BANK0 bit 5, PADS_BANK0 bit 8.
    // RP2350 7.5.3: base 0x40020000; UART0 bit 26, UART1 bit 27, IO_BANK0 bit 6, PADS_BANK0 bit 9.
    // RESET offset 0x00 and RESET_DONE offset 0x08 are common to both chips.
    private enum ResetRegisters {
        static let reset = register(address: Chip.Reset.base)
        static let resetDone = register(address: Chip.Reset.base + 0x08)
    }

    // RP2040 2.19.6.1 IO - User Bank
    // RP2350 9.11.1 IO - User Bank
    //  Bases: RP2040 0x40014000; RP2350 0x40028000 (selected by Chip.GPIO.IOBank0.base).
    //  Both chips place GPIO n's CTRL at offset n*8+4.
    private enum IO_BANK0 {
        static func control(_ pin: UInt32) -> register {
            .init(address: Chip.GPIO.IOBank0.base + pin * 8 + 4)
        }
    }

    // RP2040 2.19.6.3 Pad Control - User Bank
    // RP2350 9.11.3 Pad Control - User Bank.
    //  Bases: RP2040 0x4001C000; RP2350 0x40038000 (selected by Chip.GPIO.PadsBank0.base).
    //  GPIO n's pad control is at offset 4+n*4 on both chips.
    private enum PADS_BANK0 {
        // RP2040 2.19.6.3 PADS_BANK0.GPIO0/GPIO1:
        // RP2350 9.11.3   PADS_BANK0.GPIO0/GPIO1:
        // shared fields IE bit 6, DRIVE[5:4]=1 (4 mA), SCHMITT bit 1.
        private static let inputEnabled: UInt32 = 1 << 6
        private static let drive4mA: UInt32 = 1 << 4
        private static let pullDown: UInt32 = 1 << 2
        private static let pullUp: UInt32 = 1 << 3
        private static let schmittEnabled: UInt32 = 1 << 1
        // TX=0x56; RX=0x5A with pull-up for idle high.
        // OD/SLEWFAST remain clear. Writing the complete value also clears
        // RP2350 9.11.3 ISO bit 8 (pad isolation); RP2040 has no ISO bit.
        static let transmit = inputEnabled | drive4mA | pullDown | schmittEnabled
        static let receive = inputEnabled | drive4mA | pullUp | schmittEnabled

        static func gpio(_ pin: UInt32) -> register {
            .init(address: Chip.GPIO.PadsBank0.base + 4 + pin * 4)
        }
    }

    // RP2040  4.2.8: UART offsets/fields are shared.
    // RP2350 12.1.8: UART offsets/fields are shared.
    // The selected port supplies the chip-specific UART base address.
    private enum UARTFR {
        static let busy: UInt32 = 1 << 3
        static let receiveEmpty: UInt32 = 1 << 4
        static let transmitFull: UInt32 = 1 << 5
    }

    private enum UARTLCR_H {
        static let fifoEnabled: UInt32 = 1 << 4
        static let eightDataBits: UInt32 = 3 << 5
    }

    private enum UARTCR {
        static let enabled: UInt32 = 1 << 0
        static let transmitEnabled: UInt32 = 1 << 8
        static let receiveEnabled: UInt32 = 1 << 9
    }

    private enum UARTICR {
        static let allInterrupts: UInt32 = (1 << 11) - 1
    }

    private static let receiveErrorMask: UInt32 = 0xF << 8

    // Each UART instance retains handles for its selected port.
    private struct Registers {
        let UARTDR: register
        let UARTFR: register
        let UARTIBRD: register
        let UARTFBRD: register
        let UARTLCR_H: register
        let UARTCR: register
        let UARTIMSC: register
        let UARTICR: register

        init(base: UInt32) {
            // Constructing handles does not access MMIO.
            self.UARTDR = .init(address: base + 0x00)
            self.UARTFR = .init(address: base + 0x18)
            self.UARTIBRD = .init(address: base + 0x24)
            self.UARTFBRD = .init(address: base + 0x28)
            self.UARTLCR_H = .init(address: base + 0x2C)
            self.UARTCR = .init(address: base + 0x30)
            self.UARTIMSC = .init(address: base + 0x38)
            self.UARTICR = .init(address: base + 0x44)
        }
    }

    private func savedPinState(for pin: UInt32) -> PinState? {
        if let state = transmitPinState, state.pin == pin { return state }
        if let state = receivePinState, state.pin == pin { return state }
        return nil
    }

    private func capturePinState(_ pin: UInt32) -> PinState {
        PinState(
            pin: pin,
            control: IO_BANK0.control(pin).value,
            pad: PADS_BANK0.gpio(pin).value
        )
    }

    private func restorePinState(_ state: PinState) {
        IO_BANK0.control(state.pin).value = state.control
        PADS_BANK0.gpio(state.pin).value = state.pad
    }

    // Construct register handles only; this does not configure hardware or GPIOs.
    init(_ port: Port) {
        let config: Port.Config
        switch port {
        case .uart0:
            config = .init(
                base: Chip.UART0.base,
                resetMask: Chip.Reset.uart0,
                tx: .init(gpio: [0, 12, 16, 28, 32, 44], gpioAux: [2, 14, 18, 30, 34, 46]),
                rx: .init(gpio: [1, 13, 17, 29, 33, 45], gpioAux: [3, 15, 19, 31, 35, 47])
            )
        case .uart1:
            config = .init(
                base: Chip.UART1.base,
                resetMask: Chip.Reset.uart1,
                tx: .init(gpio: [4, 8, 20, 24, 36, 40], gpioAux: [6, 10, 22, 26, 38, 42]),
                rx: .init(gpio: [5, 9, 21, 25, 37, 41], gpioAux: [7, 11, 23, 27, 39, 43])
            )
        }
        self.config = config
        regs = Registers(base: config.base)
    }

    /// Return a UART initialized with the selected TX/RX pins and baud rate. Store the
    /// returned handle to retain its status and configuration. Reinitializing it
    /// restores pins no longer used to their states from before the first initialization.
    func initialize(tx: UInt32, rx: UInt32, baudRate: UInt32) -> Self {
        var uart = self
        uart.setup(tx: tx, rx: rx, baudRate: baudRate)
        return uart
    }

    enum ReadResult: Equatable {
        case byte(UInt8)
        case empty
        case error(UInt32)
    }

    /// Check RX once without waiting; distinguish an empty FIFO from UART error flags.
    func tryReadByte() -> ReadResult {
        // RP2040 4.2.8 / RP2350 12.1.8: UARTFR.RXFE and UARTDR share this layout.
        guard regs.UARTFR.value & UARTFR.receiveEmpty == 0 else { return .empty }
        let received = regs.UARTDR.value
        let errors = received & Self.receiveErrorMask
        guard errors == 0 else { return .error(errors) }
        return .byte(UInt8(truncatingIfNeeded: received))
    }

    /// Wait until a byte or receive error is available. Use tryReadByte to avoid waiting.
    func read() -> ReadResult {
        while true {
            let result = tryReadByte()
            if result != .empty { return result }
        }
    }

    /// Wait without a timeout for the FIFO and shift register to finish transmitting (BUSY=0).
    // RP2040 4.2.8 / RP2350 12.1.8: UARTFR.BUSY includes the final stop bit.
    func flush() {
        while isTransmitting {}
    }

    /// True while the FIFO or shift register is still transmitting.
    var isTransmitting: Bool {
        regs.UARTFR.value & UARTFR.busy != 0
    }

    /// Enqueue one byte immediately if FIFO space is available.
    /// Return false without writing when the FIFO is full.
    @discardableResult
    func tryWrite(byte: UInt8) -> Bool {
        guard regs.UARTFR.value & UARTFR.transmitFull == 0 else { return false }
        regs.UARTDR.value = UInt32(byte)
        return true
    }

    /// Enqueue a byte, waiting without a timeout for FIFO space. Use tryWrite to avoid waiting.
    // RP2040 4.2.8 / RP2350 12.1.8: UARTFR.TXFF and UARTDR.DATA are shared.
    func write(byte: UInt8) {
        while !tryWrite(byte: byte) {}
    }

    func write(_ text: StaticString) {
        for index in 0..<text.utf8CodeUnitCount {
            write(byte: text.utf8Start[index])
        }
    }

    // Invalid pins and baud rates are rejected before any registers are written.
    private mutating func setup(tx: UInt32, rx: UInt32, baudRate: UInt32) {
        guard let transmitFuncsel = config.tx.funcsel(for: tx),
              let receiveFuncsel = config.rx.funcsel(for: rx) else {
            status = .invalidPins
            return
        }
        // RP2040 4.2.3.1 / RP2350 12.1.3.1: UARTCLK / (16 * baud)
        // must be between 1 and 65535. Check the rate before dividing or adding it.
        guard baudRate > 0, baudRate <= Clock.peripheralFrequencyHz / 16 else {
            status = .invalidBaudRate
            return
        }
        // Rounded divisor in units of 1/64: round(clk_peri * 4 / baud).
        // UInt32 arithmetic fits the configured 12 MHz peripheral clock.
        let divisor = (Clock.peripheralFrequencyHz * 4 + baudRate / 2) / baudRate
        guard divisor >= 64, divisor <= 65_535 * 64 else {
            status = .invalidBaudRate
            return
        }
        status = .none
        // Reset only the selected UART. IO/pad banks are shared with other GPIO users;
        // release their reset if needed without resetting their existing settings.
        let peripherals = config.resetMask | Chip.Reset.ioBank0 | Chip.Reset.padsBank0
        ResetRegisters.reset.setBits(config.resetMask)
        ResetRegisters.reset.clearBits(peripherals)
        var resetReleased = false
        for _ in 0..<Self.maxPollCount {
            if ResetRegisters.resetDone.value & peripherals == peripherals {
                resetReleased = true
                break
            }
        }
        guard resetReleased else {
            status = .resetDidNotComplete
            return
        }

        // Reuse the original state for pins that stay assigned to this UART; capture
        // the current state only when a pin is newly assigned.
        let originalTransmitState = savedPinState(for: tx) ?? capturePinState(tx)
        let originalReceiveState = savedPinState(for: rx) ?? capturePinState(rx)
        regs.UARTCR.value = 0
        if let state = transmitPinState, state.pin != tx && state.pin != rx {
            restorePinState(state)
        }
        if let state = receivePinState, state.pin != tx && state.pin != rx {
            restorePinState(state)
        }

        // RP2040 4.2 UART / RP2350 12.1 UART: same baud-rate generator formula.
        // At 12 MHz and 115200 baud: IBRD=6, FBRD=33, actual baud approximately 115108.
        regs.UARTIBRD.value = divisor / 64
        regs.UARTFBRD.value = divisor % 64
        // WLEN=3: eight bits; FEN=1: FIFO. PEN=0, STP2=0: no parity, one stop bit.
        regs.UARTLCR_H.value = UARTLCR_H.eightDataBits | UARTLCR_H.fifoEnabled
        regs.UARTIMSC.value = 0
        regs.UARTICR.value = UARTICR.allInterrupts

        // Select the validated UART function independently for TX and RX.
        IO_BANK0.control(tx).value = transmitFuncsel
        IO_BANK0.control(rx).value = receiveFuncsel
        PADS_BANK0.gpio(tx).value = PADS_BANK0.transmit
        PADS_BANK0.gpio(rx).value = PADS_BANK0.receive

        regs.UARTCR.value = UARTCR.enabled
            | UARTCR.transmitEnabled | UARTCR.receiveEnabled
        transmitPinState = originalTransmitState
        receivePinState = originalReceiveState
        transmitPin = tx
        receivePin = rx
        self.baudRate = baudRate
    }
}
