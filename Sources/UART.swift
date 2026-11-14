// Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
// SPDX-License-Identifier: MIT

/// UART0 or UART1 with explicit, pin-map-validated TX/RX GPIOs and baud rate, 8N1.
/// Call Clock.initialize(config:) before open().
/// Reading, writing, and querying transmission require a successful open until close().
// RP2040 datasheet: 4.2.8 UART registers; 2.19.6.1 IO - User Bank;
// 2.19.6.3 Pad Control - User Bank; 2.14 Subsystem Resets; 1.4.3 GPIO Functions.
// https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf
// RP2350 datasheet: 12.1.8 UART registers; 9.11.1 IO - User Bank;
// 9.11.3 Pad Control - User Bank; 7.5.3 Reset registers; 1.2.3 GPIO functions.
// https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf
struct UART {
    enum ErrorCode: UInt32 {
        case none = 0
        case resetDidNotComplete = 1
        case invalidPins = 2
        case invalidBaudRate = 3
        case pinsInUse = 4
    }

    enum Port {
        case uart0
        case uart1

        struct Config {
            let base: UInt32
            let resetMask: UInt32
            let tx: GPIO.Function
            let rx: GPIO.Function
        }
    }

    enum ReadResult: Equatable {
        case byte(UInt8)
        case empty
        case error(UInt32)
    }

    // Each UART instance retains handles for its selected port.
    private struct Registers {
        let UARTDR: RP2.Register32
        let UARTFR: RP2.Register32
        let UARTIBRD: RP2.Register32
        let UARTFBRD: RP2.Register32
        let UARTLCR_H: RP2.Register32
        let UARTCR: RP2.Register32
        let UARTIMSC: RP2.Register32
        let UARTICR: RP2.Register32

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

    private(set) var status: ErrorCode = .none
    // A pin is retained as soon as its GPIO open succeeds.
    private(set) var transmitPin: UInt32? = nil
    private(set) var receivePin: UInt32? = nil
    // Requested baud rate; the hardware divider may introduce rounding error.
    private(set) var baudRate: UInt32? = nil
    private let config: Port.Config
    private let regs: Registers

    // RP2040  4.2.8: UART offsets/fields are shared.
    // RP2350 12.1.8: UART offsets/fields are shared.
    // The selected port supplies the chip-specific UART base address.
    private enum UARTFR {
        static let BUSY: UInt32 = 1 << 3 // Transmission is still in progress.
        static let RXFE: UInt32 = 1 << 4 // Receive FIFO empty.
        static let TXFF: UInt32 = 1 << 5 // Transmit FIFO full.
    }

    private enum UARTLCR_H {
        static let FEN: UInt32 = 1 << 4 // FIFO enable.
        static let WLEN: UInt32 = 3 << 5 // WLEN[6:5] = 0b11: 8 data bits.
    }

    private enum UARTCR {
        static let UARTEN: UInt32 = 1 << 0 // UART enable.
        static let TXE: UInt32 = 1 << 8 // Transmit enable.
        static let RXE: UInt32 = 1 << 9 // Receive enable.
    }

    private enum UARTICR {
        static let allInterrupts: UInt32 = (1 << 11) - 1
    }

    // UARTDR[11:8]: OE (overrun), BE (break), PE (parity), FE (framing).
    private static let receiveErrorMask: UInt32 = 0xF << 8

    private enum BaudRateDivisor {
        static let fractionalScale: UInt32 = 1 << 6 // FBRD has 6 fractional bits.
        static let maxInteger: UInt32 = 0xFFFF // IBRD is 16 bits.
    }

    // Construct register handles only; this does not configure hardware or GPIOs.
    init(_ port: Port) {
        let config: Port.Config
        switch port {
        case .uart0:
            config = .init(
                base: Chip.UART0.base,
                resetMask: Chip.Reset.uart0,
                tx: .uart0TX,
                rx: .uart0RX
            )
        case .uart1:
            config = .init(
                base: Chip.UART1.base,
                resetMask: Chip.Reset.uart1,
                tx: .uart1TX,
                rx: .uart1RX
            )
        }
        self.config = config
        regs = Registers(base: config.base)
    }

    /// Acquire unused TX/RX pins and start the UART. Inspect status for errors.
    /// Call close to release acquired pins, including after a failed open.
    /// Call close before changing pins or opening this UART again.
    mutating func open(tx: UInt32, rx: UInt32, baudRate: UInt32) {
        guard transmitPin == nil, receivePin == nil else {
            status = .pinsInUse
            return
        }
        guard tx != rx else {
            status = .invalidPins
            return
        }
        let peripheralFreqHz = Clock.peripheralFreqMHz * 1_000_000
        // RP2040 4.2.3.1 / RP2350 12.1.3.1: UARTCLK / (16 * baud)
        // must be between 1 and 65535. Check the rate before dividing or adding it.
        guard baudRate > 0, baudRate <= peripheralFreqHz / 16 else {
            status = .invalidBaudRate
            return
        }
        // Round the divisor in 1/64 units: UARTCLK * 4 / baud.
        // UInt32 arithmetic fits the configured 12 MHz peripheral clock.
        let divisor = (peripheralFreqHz * 4 + baudRate / 2) / baudRate
        let integerDivisor = divisor / BaudRateDivisor.fractionalScale
        guard integerDivisor <= BaudRateDivisor.maxInteger else {
            status = .invalidBaudRate
            return
        }
        status = .none

        // GPIO owns pin-number, capability and usage validation.
        // Acquired pins remain held on failure until the caller calls close().
        let txError = GPIO.open(tx, as: config.tx, pad: .init(PDE: true))
        guard txError == .none else {
            status = Self.errorCode(from: txError)
            return
        }
        transmitPin = tx

        let rxError = GPIO.open(rx, as: config.rx, pad: .init(PUE: true))
        guard rxError == .none else {
            status = Self.errorCode(from: rxError)
            return
        }
        receivePin = rx

        // GPIO manages the shared banks; reset only the selected UART here.
        guard RP2.RESETS.reset(config.resetMask) else {
            status = .resetDidNotComplete
            return
        }

        regs.UARTCR.value = 0

        // RP2040 4.2 UART / RP2350 12.1 UART: same baud-rate generator formula.
        // At 12 MHz and 115200 baud: IBRD=6, FBRD=33, actual baud approximately 115108.
        regs.UARTIBRD.value = integerDivisor
        regs.UARTFBRD.value = divisor % BaudRateDivisor.fractionalScale
        // WLEN=3: eight bits; FEN=1: FIFO. PEN=0, STP2=0: no parity, one stop bit.
        regs.UARTLCR_H.value = UARTLCR_H.WLEN | UARTLCR_H.FEN
        regs.UARTIMSC.value = 0
        regs.UARTICR.value = UARTICR.allInterrupts

        regs.UARTCR.value = UARTCR.UARTEN
            | UARTCR.TXE | UARTCR.RXE
        self.baudRate = baudRate
    }

    /// Drain TX, stop the UART, and release its acquired pins. Inspect status for errors.
    mutating func close() {
        if baudRate != nil {
            flush()
            regs.UARTCR.value = 0
            baudRate = nil
        }

        status = .none
        if let tx = transmitPin {
            if GPIO.close(tx) == .none {
                transmitPin = nil
            } else {
                status = .resetDidNotComplete
            }
        }
        if let rx = receivePin {
            if GPIO.close(rx) == .none {
                receivePin = nil
            } else {
                status = .resetDidNotComplete
            }
        }
    }

    /// Check RX once without waiting; distinguish an empty FIFO from UART error flags.
    func tryReadByte() -> ReadResult {
        precondition(baudRate != nil, "UART must be open before reading")
        // RP2040 4.2.8 / RP2350 12.1.8: UARTFR.RXFE and UARTDR share this layout.
        guard regs.UARTFR.value & UARTFR.RXFE == 0 else { return .empty }
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
        precondition(baudRate != nil, "UART must be open before querying transmission")
        return regs.UARTFR.value & UARTFR.BUSY != 0
    }

    /// Enqueue one byte immediately if FIFO space is available.
    /// Return false without writing when the FIFO is full.
    @discardableResult
    func tryWrite(byte: UInt8) -> Bool {
        precondition(baudRate != nil, "UART must be open before writing")
        guard regs.UARTFR.value & UARTFR.TXFF == 0 else { return false }
        regs.UARTDR.value = UInt32(byte)
        return true
    }

    /// Enqueue a byte, waiting without a timeout for FIFO space. Use tryWrite to avoid waiting.
    // RP2040 4.2.8 / RP2350 12.1.8: UARTFR.TXFF and UARTDR.DATA are shared.
    func write(byte: UInt8) {
        while !tryWrite(byte: byte) {}
    }

    func write(_ text: StaticString) {
        precondition(baudRate != nil, "UART must be open before writing")
        for index in 0..<text.utf8CodeUnitCount {
            write(byte: text.utf8Start[index])
        }
    }

    private static func errorCode(from error: GPIO.ErrorCode) -> ErrorCode {
        switch error {
        case .none: return .none
        case .invalidPin, .unsupportedFunction, .notImplemented: return .invalidPins
        case .pinInUse: return .pinsInUse
        case .resetDidNotComplete: return .resetDidNotComplete
        }
    }
}
