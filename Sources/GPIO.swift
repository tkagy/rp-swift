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
    private typealias register = RP2.Register32
    private typealias spec = Chip.GPIO
    // Raw values identify supported-function bits, not hardware FUNCSEL values.
    enum Function: UInt32 {
        case none = 0, custom, ADC2
        case uart0TX, uart0RX, uart0CTS, uart0RTS
        case uart1TX, uart1RX, uart1CTS, uart1RTS
        case spi0RX, spi0CS, spi0SCK, spi0TX
        case spi1RX, spi1CS, spi1SCK, spi1TX
        case i2c0SDA, i2c0SCL, i2c1SDA, i2c1SCL
    }

    enum DriveStrength: UInt32 { case mA2 = 0, mA4, mA8, mA12 }
    enum ErrorCode: Equatable {
        case none, invalidPin, unsupportedFunction, notImplemented
        case pinInUse, resetDidNotComplete
    }

    // Electrical characteristics of the physical pin, independent of its peripheral.
    struct PadConfig {
        var IE = true                       // Input enable.
        var OD = false                      // Output disable: true disables output.
        var PUE = false                     // Pull-up enable.
        var PDE = false                     // Pull-down enable.
        var DRIVE: DriveStrength = .mA4     // Output drive strength.
        var SCHMITT = true                  // Schmitt trigger enable for the input.
        var SLEWFAST = false                // Fast output slew rate enable.

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

    // Pin numbers are bits 0...29. Iteration yields numbers without allocating an Array.
    struct PinSet: Sequence {
        private var bits: UInt32 = 0
        init() {}

        func contains(_ number: UInt32) -> Bool {
            number < GPIO.pinCount && bits & (UInt32(1) << number) != 0
        }

        mutating func insert(_ number: UInt32) {
            precondition(number < GPIO.pinCount)
            bits |= UInt32(1) << number
        }

        struct Iterator: IteratorProtocol {
            fileprivate var remaining: UInt32
            mutating func next() -> UInt32? {
                guard remaining != 0 else { return nil }
                let number = UInt32(remaining.trailingZeroBitCount)
                remaining &= remaining - 1
                return number
            }
        }

        func makeIterator() -> Iterator { Iterator(remaining: bits) }
    }

    // Supported names are independent UInt32 flags. .none is a real member;
    // an empty set [] means that no functions are supported.
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

    struct Pin {
        let number: UInt32
        fileprivate init(number: UInt32) { self.number = number }

        var supportedFunctions: SupportedFunctions { GPIO.supportedFunctions(for: number) }
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
                if GPIO.supportedFunctions(for: number).contains(function) {
                    result.insert(number)
                }
            }
            return result
        }

        var usedPins: PinSet {
            var result = PinSet()
            for number in 0..<GPIO.pinCount {
                if GPIO.currentFunctions[Int(number)] == function { result.insert(number) }
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

    // Shared supported uses. SIO/custom I/O and PIO operation remain TBD.
    static func supportedFunctions(for number: UInt32) -> SupportedFunctions {
        var functions: SupportedFunctions
        switch number {
        case 0: functions = [.none, .uart0TX, .i2c0SDA, .spi0RX, .custom]
        case 1: functions = [.none, .uart0RX, .i2c0SCL, .spi0CS, .custom]
        case 2: functions = [.none, .uart0CTS, .i2c1SDA, .spi0SCK, .custom]
        case 3: functions = [.none, .uart0RTS, .i2c1SCL, .spi0TX, .custom]
        case 4: functions = [.none, .uart1TX, .i2c0SDA, .spi0RX, .custom]
        case 5: functions = [.none, .uart1RX, .i2c0SCL, .spi0CS, .custom]
        case 6: functions = [.none, .uart1CTS, .i2c1SDA, .spi0SCK, .custom]
        case 7: functions = [.none, .uart1RTS, .i2c1SCL, .spi0TX, .custom]
        case 8: functions = [.none, .uart1TX, .i2c0SDA, .spi1RX, .custom]
        case 9: functions = [.none, .uart1RX, .i2c0SCL, .spi1CS, .custom]
        case 10: functions = [.none, .uart1CTS, .i2c1SDA, .spi1SCK, .custom]
        case 11: functions = [.none, .uart1RTS, .i2c1SCL, .spi1TX, .custom]
        case 12: functions = [.none, .uart0TX, .i2c0SDA, .spi1RX, .custom]
        case 13: functions = [.none, .uart0RX, .i2c0SCL, .spi1CS, .custom]
        case 14: functions = [.none, .uart0CTS, .i2c1SDA, .spi1SCK, .custom]
        case 15: functions = [.none, .uart0RTS, .i2c1SCL, .spi1TX, .custom]
        case 16: functions = [.none, .uart0TX, .i2c0SDA, .spi0RX, .custom]
        case 17: functions = [.none, .uart0RX, .i2c0SCL, .spi0CS, .custom]
        case 18: functions = [.none, .uart0CTS, .i2c1SDA, .spi0SCK, .custom]
        case 19: functions = [.none, .uart0RTS, .i2c1SCL, .spi0TX, .custom]
        case 20: functions = [.none, .uart1TX, .i2c0SDA, .spi0RX, .custom]
        case 21: functions = [.none, .uart1RX, .i2c0SCL, .spi0CS, .custom]
        case 22: return [.none, .custom]
        case 23: functions = [.none, .uart1RTS, .i2c1SCL, .spi0TX, .custom]
        case 24: functions = [.none, .uart1TX, .i2c0SDA, .spi1RX, .custom]
        case 25: functions = [.none, .uart1RX, .i2c0SCL, .spi1CS, .custom]
        case 26: functions = [.none, .uart1CTS, .i2c1SDA, .spi1SCK, .custom]
        case 27: functions = [.none, .uart1RTS, .i2c1SCL, .spi1TX, .custom]
        case 28: return [.none, .custom, .ADC2]
        case 29: functions = [.none, .uart0RX, .i2c0SCL, .spi1CS, .custom]
        default: return []
        }
        let pinBit = UInt32(1) << number
        if spec.uart0TXAuxPins & pinBit != 0 { functions.insert(.uart0TX) }
        if spec.uart0RXAuxPins & pinBit != 0 { functions.insert(.uart0RX) }
        if spec.uart1TXAuxPins & pinBit != 0 { functions.insert(.uart1TX) }
        if spec.uart1RXAuxPins & pinBit != 0 { functions.insert(.uart1RX) }
        return functions
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
    // TBD: selection and operation of custom (SIO) and PIO functions.
    static var custom: FunctionPins { FunctionPins(function: .custom) }

    static func pin(_ number: UInt32) -> Pin? {
        guard isValidPin(number) else { return nil }
        return Pin(number: number)
    }
    static func isValidPin(_ number: UInt32) -> Bool { number < pinCount }

    @discardableResult
    static func open(_ number: UInt32, as function: Function,
                     pad: PadConfig = PadConfig()) -> ErrorCode {
        guard isValidPin(number) else { return .invalidPin }
        guard supportedFunctions(for: number).contains(function) else {
            return .unsupportedFunction
        }
        guard currentFunctions[Int(number)] == .none else { return .pinInUse }
        // .none is an idle state; callers release a pin through close().
        guard function != .none else { return .unsupportedFunction }
        // TBD: custom digital I/O through SIO.
        guard function != .custom else { return .notImplemented }
        guard RP2.RESETS.release(Chip.Reset.ioBank0 | Chip.Reset.padsBank0) else {
            return .resetDidNotComplete
        }
        let control = IO_BANK0.control(number)
        let padRegister = PADS_BANK0.gpio(number)
        control.value = IO_BANK0.FUNCSEL_NULL
        if function == .ADC2 {
            // Prepare only the analog pin; the ADC driver controls conversion/channel 2.
            // A complete write also clears RP2350's ISO bit.
            padRegister.value = PadConfig(
                IE: false, OD: true,
                SCHMITT: false
            ).value
        } else {
            padRegister.value = pad.value
            control.value = funcsel(for: number, function: function)
        }
        currentFunctions[Int(number)] = function
        return .none
    }

    // Stop the peripheral before closing its pins; closing disables digital input/output.
    @discardableResult
    static func close(_ number: UInt32) -> ErrorCode {
        guard isValidPin(number) else { return .invalidPin }
        guard currentFunctions[Int(number)] != .none else { return .none }
        guard RP2.RESETS.release(Chip.Reset.ioBank0 | Chip.Reset.padsBank0) else {
            return .resetDidNotComplete
        }
        IO_BANK0.control(number).value = IO_BANK0.FUNCSEL_NULL
        PADS_BANK0.gpio(number).value = PadConfig(
            IE: false, OD: true,
            SCHMITT: false
        ).value
        currentFunctions[Int(number)] = .none
        return .none
    }

    // Convert a supported function to its hardware encoding.
    private static func funcsel(for number: UInt32, function: Function) -> UInt32 {
        let auxiliaryPins: UInt32
        switch function {
        case .none, .ADC2: return IO_BANK0.FUNCSEL_NULL
        case .custom: return IO_BANK0.FUNCSEL_SIO // SIO operation TBD.
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
