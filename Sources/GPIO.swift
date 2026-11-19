// Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
// SPDX-License-Identifier: MIT

// Bank 0 GPIO management. Common supported functions live here; Chip.GPIO holds differences.
// All assignment changes go through this manager; currentFunction is the usage state.
// RP2040: 1.4.3 GPIO Functions; 2.19.6 IO and pad registers.
// https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf
// RP2350A: 1.2.3 GPIO functions; 9.11 IO and pad registers.
// https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf
// Calls that change pin assignments must be serialized by the caller.
enum GPIO {
    enum ErrorCode: Equatable {
        case none, unsupportedFunction, notImplemented
        case pinInUse, resetDidNotComplete
    }

    private typealias register = RP2.Register32
    private typealias spec = Chip.GPIO
    // Raw values identify hardware-function bits, not hardware FUNCSEL values.
    // TBD: ADC0 (GPIO26), ADC1 (GPIO27), ADC3 (GPIO29) pin configuration.
    enum Function: UInt32 {
        case none = 0, sio, ADC2
        case uart0TX, uart0RX, uart0CTS, uart0RTS
        case uart1TX, uart1RX, uart1CTS, uart1RTS
        case spi0RX, spi0CS, spi0SCK, spi0TX
        case spi1RX, spi1CS, spi1SCK, spi1TX
        case i2c0SDA, i2c0SCL, i2c1SDA, i2c1SCL
    }

    enum DriveStrength: UInt32 { case mA2 = 0, mA4, mA8, mA12 }

    // Electrical characteristics of the physical pin, independent of its peripheral.
    struct PadConfig {
        var IE = true                       // Input enable.
        var OD = false                      // Output disable: true disables output.
        var PUE = false                     // Pull-up enable.
        var PDE = false                     // Pull-down enable.
        var DRIVE: DriveStrength = .mA4     // Output drive strength.
        var SCHMITT = true                  // Schmitt trigger enable for the input.
        var SLEWFAST = false                // Fast output slew rate enable.

        fileprivate static var digitalDisabled: Self {
            Self(IE: false, OD: true, SCHMITT: false)
        }

        fileprivate var value: UInt32 {
            var value = DRIVE.rawValue << PadFields.DRIVE_SHIFT
            if IE { value |= PadFields.IE }
            if OD { value |= PadFields.OD }
            if PUE { value |= PadFields.PUE }
            if PDE { value |= PadFields.PDE }
            if SCHMITT { value |= PadFields.SCHMITT }
            if SLEWFAST { value |= PadFields.SLEWFAST }
            return value
        }
    }

    // Pin numbers are bits 0...29. Iteration yields pins without allocating an Array.
    struct PinSet: Sequence {
        private var bits: UInt32 = 0
        init() {}

        func contains(_ pin: Pin) -> Bool {
            bits & (UInt32(1) << pin.number) != 0
        }

        mutating func insert(_ pin: Pin) {
            bits |= UInt32(1) << pin.number
        }

        struct Iterator: IteratorProtocol {
            fileprivate var remaining: UInt32
            mutating func next() -> Pin? {
                guard remaining != 0 else { return nil }
                let number = UInt32(remaining.trailingZeroBitCount)
                remaining &= remaining - 1
                return Pin(rawValue: number)
            }
        }

        func makeIterator() -> Iterator { Iterator(remaining: bits) }
    }

    // supportedFunctions lists hardware-supported functions, regardless of API implementation status.
    // These are independent UInt32 flags; [] means no functions.
    struct SupportedFunctions: ExpressibleByArrayLiteral, Equatable {
        private var bits: UInt32 = 0

        init(arrayLiteral functions: Function...) {
            for function in functions {
                insert(function)
            }
        }

        func contains(_ function: Function) -> Bool {
            bits & (UInt32(1) << function.rawValue) != 0
        }

        mutating func insert(_ function: Function) {
            bits |= UInt32(1) << function.rawValue
        }

        var isEmpty: Bool { bits == 0 }
    }

    // Bank 0 pins shared by RP2040 and RP2350A; RP2350B is outside this scope.
    enum Pin: UInt32 {
        case  gpio0,  gpio1,  gpio2,  gpio3,  gpio4,  gpio5
        case  gpio6,  gpio7,  gpio8,  gpio9, gpio10, gpio11
        case gpio12, gpio13, gpio14, gpio15, gpio16, gpio17
        case gpio18, gpio19, gpio20, gpio21, gpio22, gpio23
        case gpio24, gpio25, gpio26, gpio27, gpio28, gpio29

        var number: UInt32 { rawValue }

        // Shared supported uses.
        // TBD: PWM, SIO input/output, PIO0/PIO1, CLOCK GPIN/GPOUT,
        // and USB OVCUR DET/VBUS DET/VBUS EN. Chip-specific gaps are in Chip.GPIO.
        var supportedFunctions: SupportedFunctions {
            var functions: SupportedFunctions
            switch self {
            case .gpio0: functions = [.uart0TX, .i2c0SDA, .spi0RX, .sio]
            case .gpio1: functions = [.uart0RX, .i2c0SCL, .spi0CS, .sio]
            case .gpio2: functions = [.uart0CTS, .i2c1SDA, .spi0SCK, .sio]
            case .gpio3: functions = [.uart0RTS, .i2c1SCL, .spi0TX, .sio]
            case .gpio4: functions = [.uart1TX, .i2c0SDA, .spi0RX, .sio]
            case .gpio5: functions = [.uart1RX, .i2c0SCL, .spi0CS, .sio]
            case .gpio6: functions = [.uart1CTS, .i2c1SDA, .spi0SCK, .sio]
            case .gpio7: functions = [.uart1RTS, .i2c1SCL, .spi0TX, .sio]
            case .gpio8: functions = [.uart1TX, .i2c0SDA, .spi1RX, .sio]
            case .gpio9: functions = [.uart1RX, .i2c0SCL, .spi1CS, .sio]
            case .gpio10: functions = [.uart1CTS, .i2c1SDA, .spi1SCK, .sio]
            case .gpio11: functions = [.uart1RTS, .i2c1SCL, .spi1TX, .sio]
            case .gpio12: functions = [.uart0TX, .i2c0SDA, .spi1RX, .sio]
            case .gpio13: functions = [.uart0RX, .i2c0SCL, .spi1CS, .sio]
            case .gpio14: functions = [.uart0CTS, .i2c1SDA, .spi1SCK, .sio]
            case .gpio15: functions = [.uart0RTS, .i2c1SCL, .spi1TX, .sio]
            case .gpio16: functions = [.uart0TX, .i2c0SDA, .spi0RX, .sio]
            case .gpio17: functions = [.uart0RX, .i2c0SCL, .spi0CS, .sio]
            case .gpio18: functions = [.uart0CTS, .i2c1SDA, .spi0SCK, .sio]
            case .gpio19: functions = [.uart0RTS, .i2c1SCL, .spi0TX, .sio]
            case .gpio20: functions = [.uart1TX, .i2c0SDA, .spi0RX, .sio]
            case .gpio21: functions = [.uart1RX, .i2c0SCL, .spi0CS, .sio]
            case .gpio22: functions = [.uart1CTS, .i2c1SDA, .spi0SCK, .sio]
            case .gpio23: functions = [.uart1RTS, .i2c1SCL, .spi0TX, .sio]
            case .gpio24: functions = [.uart1TX, .i2c0SDA, .spi1RX, .sio]
            case .gpio25: functions = [.uart1RX, .i2c0SCL, .spi1CS, .sio]
            case .gpio26: functions = [.uart1CTS, .i2c1SDA, .spi1SCK, .sio]
            case .gpio27: functions = [.uart1RTS, .i2c1SCL, .spi1TX, .sio]
            case .gpio28: functions = [.uart0TX, .i2c0SDA, .spi1RX, .sio, .ADC2]
            case .gpio29: functions = [.uart0RX, .i2c0SCL, .spi1CS, .sio]
            }
            let pinBit = UInt32(1) << number
            if spec.uart0TXAuxPins & pinBit != 0 { functions.insert(.uart0TX) }
            if spec.uart0RXAuxPins & pinBit != 0 { functions.insert(.uart0RX) }
            if spec.uart1TXAuxPins & pinBit != 0 { functions.insert(.uart1TX) }
            if spec.uart1RXAuxPins & pinBit != 0 { functions.insert(.uart1RX) }
            return functions
        }

        var currentFunction: Function { GPIO.currentFunctions[Int(number)] }
        var isInUse: Bool { currentFunction != .none }

        func supports(_ function: Function) -> Bool {
            supportedFunctions.contains(function)
        }
    }

    struct FunctionPins {
        let function: Function

        var pins: PinSet {
            var result = PinSet()
            for number in 0..<GPIO.pinCount {
                if let pin = Pin(rawValue: number), pin.supports(function) {
                    result.insert(pin)
                }
            }
            return result
        }

        var usedPins: PinSet {
            var result = PinSet()
            guard function != .none else { return result }
            for number in 0..<GPIO.pinCount {
                if let pin = Pin(rawValue: number), pin.currentFunction == function {
                    result.insert(pin)
                }
            }
            return result
        }
    }

    struct UARTPins {
        let tx: FunctionPins
        let rx: FunctionPins
        let cts: FunctionPins
        let rts: FunctionPins
    }

    struct SPIPins {
        let tx: FunctionPins
        let rx: FunctionPins
        let sck: FunctionPins
        let cs: FunctionPins
    }

    struct I2CPins {
        let sda: FunctionPins
        let scl: FunctionPins
    }

    // RP2040 and RP2350A expose GPIO0...29; RP2350B is outside this scope.
    // Access stored pin state after firmware RAM setup.
    private static var currentFunctions: InlineArray<30, Function> = .init(repeating: .none)

    static var pinCount: UInt32 { UInt32(currentFunctions.count) }

    static var uart0: UARTPins {
        .init(tx: .init(function: .uart0TX), rx: .init(function: .uart0RX),
              cts: .init(function: .uart0CTS), rts: .init(function: .uart0RTS))
    }
    static var uart1: UARTPins {
        .init(tx: .init(function: .uart1TX), rx: .init(function: .uart1RX),
              cts: .init(function: .uart1CTS), rts: .init(function: .uart1RTS))
    }
    static var spi0: SPIPins {
        .init(tx: .init(function: .spi0TX), rx: .init(function: .spi0RX),
              sck: .init(function: .spi0SCK), cs: .init(function: .spi0CS))
    }
    static var spi1: SPIPins {
        .init(tx: .init(function: .spi1TX), rx: .init(function: .spi1RX),
              sck: .init(function: .spi1SCK), cs: .init(function: .spi1CS))
    }
    static var i2c0: I2CPins {
        .init(sda: .init(function: .i2c0SDA), scl: .init(function: .i2c0SCL))
    }
    static var i2c1: I2CPins {
        .init(sda: .init(function: .i2c1SDA), scl: .init(function: .i2c1SCL))
    }
    // TBD: SIO input/output operations.
    static var sio: FunctionPins { FunctionPins(function: .sio) }

    static func pin(_ number: UInt32) -> Pin? {
        Pin(rawValue: number)
    }
    static func isValidPin(_ number: UInt32) -> Bool { Pin(rawValue: number) != nil }

    // Check pin assignment without changing GPIO state.
    static func validateOpen(_ pin: Pin, as function: Function) -> ErrorCode {
        guard function != .none else { return .unsupportedFunction }
        guard pin.supports(function) else {
            return .unsupportedFunction
        }
        guard !pin.isInUse else { return .pinInUse }
        // TBD: SIO input/output operations.
        guard function != .sio else { return .notImplemented }
        return .none
    }

    static func open(_ pin: Pin, as function: Function,
                     pad: PadConfig = PadConfig()) -> ErrorCode {
        let error = validateOpen(pin, as: function)
        guard error == .none else { return error }
        guard RP2.RESETS.release(Chip.Reset.ioBank0 | Chip.Reset.padsBank0) else {
            return .resetDidNotComplete
        }
        let number = pin.number
        let control = IO_BANK0.control(number)
        let padRegister = PADS_BANK0.gpio(number)
        control.value = IO_BANK0.FUNCSEL_NULL
        if function == .ADC2 {
            // Prepare only the analog pin; the ADC driver controls conversion/channel 2.
            // A complete write also clears RP2350's ISO bit.
            padRegister.value = PadConfig.digitalDisabled.value
        } else {
            padRegister.value = pad.value
            control.value = funcsel(for: number, function: function)
        }
        currentFunctions[Int(number)] = function
        return .none
    }

    // Stop the peripheral before closing its pins; closing disables digital input/output.
    static func close(_ pin: Pin) -> ErrorCode {
        let number = pin.number
        guard currentFunctions[Int(number)] != .none else { return .none }
        guard RP2.RESETS.release(Chip.Reset.ioBank0 | Chip.Reset.padsBank0) else {
            return .resetDidNotComplete
        }
        IO_BANK0.control(number).value = IO_BANK0.FUNCSEL_NULL
        PADS_BANK0.gpio(number).value = PadConfig.digitalDisabled.value
        currentFunctions[Int(number)] = .none
        return .none
    }

    // Convert a supported function to its hardware encoding.
    private static func funcsel(for number: UInt32, function: Function) -> UInt32 {
        let auxiliaryPins: UInt32
        switch function {
        case .none, .ADC2: return IO_BANK0.FUNCSEL_NULL
        case .sio: return IO_BANK0.FUNCSEL_SIO // SIO operation TBD.
        case .spi0RX, .spi0CS, .spi0SCK, .spi0TX,
             .spi1RX, .spi1CS, .spi1SCK, .spi1TX: return IO_BANK0.FUNCSEL_SPI
        case .uart0TX: auxiliaryPins = spec.uart0TXAuxPins
        case .uart0RX: auxiliaryPins = spec.uart0RXAuxPins
        case .uart1TX: auxiliaryPins = spec.uart1TXAuxPins
        case .uart1RX: auxiliaryPins = spec.uart1RXAuxPins
        case .uart0CTS, .uart0RTS, .uart1CTS, .uart1RTS: return IO_BANK0.FUNCSEL_UART
        case .i2c0SDA, .i2c0SCL, .i2c1SDA, .i2c1SCL: return IO_BANK0.FUNCSEL_I2C
        }
        if let selector = spec.uartAuxFuncsel,
           auxiliaryPins & (UInt32(1) << number) != 0 {
            return selector
        }
        return IO_BANK0.FUNCSEL_UART
    }

    private enum PadFields {
        static let DRIVE_SHIFT: UInt32 = 4 // Least significant bit of DRIVE.
        static let IE: UInt32 = 1 << 6
        static let OD: UInt32 = 1 << 7
        static let PUE: UInt32 = 1 << 3
        static let PDE: UInt32 = 1 << 2
        static let SCHMITT: UInt32 = 1 << 1
        static let SLEWFAST: UInt32 = 1
    }

    private enum IO_BANK0 {
        static let stride: UInt32 = 0x08
        static let controlOffset: UInt32 = 0x04
        // GPIO_CTRL.FUNCSEL values; other GPIO_CTRL fields are left at zero.
        static let FUNCSEL_NULL: UInt32 = 0x1F // Disconnect the peripheral function.
        static let FUNCSEL_SPI: UInt32 = 1
        static let FUNCSEL_UART: UInt32 = 2
        static let FUNCSEL_I2C: UInt32 = 3
        static let FUNCSEL_SIO: UInt32 = 5

        static func control(_ number: UInt32) -> register {
            .init(address: spec.IO_BANK0.base + number * stride + controlOffset)
        }
    }

    private enum PADS_BANK0 {
        static let gpioOffset: UInt32 = 0x04
        static let stride: UInt32 = 0x04
        static func gpio(_ number: UInt32) -> register {
            .init(address: spec.PADS_BANK0.base + gpioOffset + number * stride)
        }
    }
}
