// Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
// SPDX-License-Identifier: MIT

struct USBDeviceIdentity {
    let vendorID: UInt16
    let productID: UInt16
    var deviceVersion: UInt16 = USB.DeviceDescriptor.defaultVersion
    // bDeviceClass/SubClass/Protocol describe the Device personality.
    // Function classes remain in Configuration and Interface Descriptors.
    let deviceClass: UInt8
    let deviceSubclass: UInt8
    let deviceProtocol: UInt8
    var manufacturer: StaticString
    var product: StaticString
    var serialNumber: StaticString = ""
}

enum USBDeviceControlTransfer { case input, output(Int), status }

private struct EP0State: ~Copyable {
    enum Stage { case idle, dataIn, dataOut(Int), statusIn, statusOut }
    enum Pending {
        case none, address(UInt8), configuration(UInt8), interface(UInt16)
        case halt(USB.EndpointAddress, Bool), function(USB.SetupPacket)
    }
    var stage: Stage = .idle
    var pending: Pending = .none
    var buffer = USBDeviceControlBuffer()
    var responseLength = 0
    var responseOffset = 0
    var needsZeroPacket = false
    var deadline: UInt64 = 0
}

struct USBDeviceControlBuffer: ~Copyable {
    static let capacity = 512
    private var bytes: InlineArray<512, UInt8> = .init(repeating: 0)
    private(set) var count = 0
    private(set) var overflow = false

    func canAppend(byteCount: Int) -> Bool {
        !overflow && byteCount >= 0 && byteCount <= bytes.count - count
    }

    mutating func clear() { count = 0; overflow = false }
    @discardableResult
    mutating func append(_ byte: UInt8) -> Bool {
        guard !overflow, count < bytes.count else { overflow = true; return false }
        bytes[count] = byte
        count += 1
        return true
    }

    mutating func beginDescriptor(_ type: USB.Descriptor, length: UInt8) {
        beginDescriptor(type.rawValue, length: length)
    }
    // Class-specific descriptor types (CDC, future HID) remain with each class.
    mutating func beginDescriptor(_ type: UInt8, length: UInt8) {
        precondition(length >= 2, "USB descriptor must include its length and type")
        append(length)
        append(type)
    }
    mutating func append16(_ word: UInt16) {
        append(UInt8(truncatingIfNeeded: word))
        append(UInt8(truncatingIfNeeded: word >> 8))
    }
    mutating func append32(_ word: UInt32) {
        append16(UInt16(truncatingIfNeeded: word))
        append16(UInt16(truncatingIfNeeded: word >> 16))
    }
    subscript(_ index: Int) -> UInt8 {
        get {
            precondition(index >= 0 && index < count)
            return bytes[index]
        }
    }
}

/// Describes one USB Device's configuration and its class-specific functions.
/// It supplies descriptors, owns function state, and routes class requests;
/// USBDevice retains the shared enumeration and EP0 state machine.
/// Generic calls preserve concrete controller types without existential boxes.
protocol USBDeviceConfiguration: ~Copyable {
    var descriptorBytes: Int { get }
    var interfaceCount: Int { get }
    func isSupported<C: USBDeviceControllerProtocol>(by controller: C.Type) -> Bool
    func appendInterfaceDescriptor(_ setup: USB.SetupPacket, to buffer: inout USBDeviceControlBuffer) -> Bool
    var value: UInt8 { get }
    var isValid: Bool { get }
    func ownsInterface(_ number: UInt16) -> Bool
    func ownsEndpoint(_ endpoint: USB.EndpointAddress) -> Bool
    func appendDescriptor(to buffer: inout USBDeviceControlBuffer) -> Bool
    mutating func reset()
    mutating func configure<C: USBDeviceControllerProtocol>(controller: C.Type)
    mutating func service<C: USBDeviceControllerProtocol>(controller: C.Type)
    mutating func resetInterface<C: USBDeviceControllerProtocol>(_ number: UInt16, controller: C.Type) -> Bool
    mutating func completed<C: USBDeviceControllerProtocol>(_ endpoint: USB.EndpointAddress, controller: C.Type) -> Bool
    mutating func endpointCancelled<C: USBDeviceControllerProtocol>(_ endpoint: USB.EndpointAddress, controller: C.Type) -> Bool
    mutating func prepareRequest(_ setup: USB.SetupPacket, into buffer: inout USBDeviceControlBuffer) -> USBDeviceControlTransfer?
    func acceptOutput(_ setup: USB.SetupPacket, data: borrowing USBDeviceControlBuffer) -> Bool
    mutating func completeRequest(_ setup: USB.SetupPacket, data: borrowing USBDeviceControlBuffer)
}

/// Device event fields and endpoint-completion mapping required by the stack.
protocol USBDeviceControllerEvents {
    var vbusPresent: Bool? { get }
    var disconnected: Bool { get }
    var reset: Bool { get }
    var setup: USB.SetupPacket? { get }
    var completed: UInt32 { get }
    var suspendChanged: Bool { get }
    var isSuspended: Bool { get }
    static var slotCount: Int { get }
    static var controlMask: UInt32 { get }
    static func mask(for endpoint: USB.EndpointAddress) -> UInt32
    static func endpoint(forSlot slot: Int) -> USB.EndpointAddress
}

/// Hardware operations only. One Core 0 owner services the controller.
protocol USBDeviceControllerProtocol {
    associatedtype ErrorCode
    associatedtype FailureSnapshot
    associatedtype Events: USBDeviceControllerEvents

    static var status: ErrorCode { get }
    static var failureSnapshot: FailureSnapshot? { get }
    static var maximumBulkPacketBytes: Int { get }
    static var isInitialized: Bool { get }
    static var isDeviceMode: Bool { get }
    static var isVBUSPresent: Bool { get }
    static func claimDeviceStack() -> Bool
    static func releaseDeviceStack()
    static func restart() -> Bool
    static func stop()
    static func connect()
    static func disconnect()
    static func captureEvents() -> Events
    static func resetEndpoints()
    static func setAddress(_ value: UInt8)
    static func configure(_ endpoint: USB.EndpointAddress, type: USB.TransferType, maximumPacket: Int)
    static func isBusy(_ endpoint: USB.EndpointAddress) -> Bool
    static func isHalted(_ endpoint: USB.EndpointAddress) -> Bool
    static func canSubmit(_ endpoint: USB.EndpointAddress) -> Bool
    static func completedDuringLastCancellation(_ endpoint: USB.EndpointAddress) -> Bool
    static func cancel(mask: UInt32) -> Bool
    static func beginControl() -> Bool
    static func disableFunctions() -> Bool
    static func halt(_ endpoint: USB.EndpointAddress, enabled: Bool) -> Bool
    static func stallControl()
    static func submit(_ endpoint: USB.EndpointAddress, count: Int) -> Bool
    static func receivedCount(_ endpoint: USB.EndpointAddress) -> Int
    static func readByte(_ endpoint: USB.EndpointAddress, at index: Int) -> UInt8
    static func writeByte(_ endpoint: USB.EndpointAddress, at index: Int, value: UInt8)
}

// The stack binds the hardware driver to its Device-facing contract here.
// USBController.swift does not depend on this protocol or the Device stack.
extension USBController: USBDeviceControllerProtocol {}
extension USBController.DeviceEvents: USBDeviceControllerEvents {}

// The common Device stack is parameterized by hardware operations and by the
// concrete configuration that defines which USB functions this Device exposes.
// Full-speed EP0 policy for this Device implementation.
private let usbDeviceControlPacketBytes = 64
// USB 2.0 chapter 9 and EP0 transfer sequencing.
struct USBDevice<Controller: USBDeviceControllerProtocol,
                 Configuration: USBDeviceConfiguration & ~Copyable>: ~Copyable {
    private var configuration: Configuration
    private var ep0 = EP0State()

    init(configuration: consuming Configuration) {
        self.configuration = consume configuration
    }

    enum ErrorCode: UInt32 {
        case none = 0, alreadyRunning, timerNotReady, invalidIdentity, invalidConfiguration, controllerFailure
        case controlTimedOut, invalidPacket
        case controllerNotReady, invalidControllerMode, controllerInUse
    }
    private(set) var status: ErrorCode = .none
    private(set) var isRunning = false
    private(set) var isSuspended = false
    private(set) var isAttached = false
    private(set) var configurationValue: UInt8 = 0
    private(set) var address: UInt8 = 0
    var isConfigured: Bool { isRunning && configurationValue != 0 }
    private var identity: USBDeviceIdentity? = nil
    private var suspendStarted: UInt64 = 0
    private let controlTimeout: UInt64 = 5_000_000

    var controllerStatus: Controller.ErrorCode { Controller.status }
    var controllerFailureSnapshot: Controller.FailureSnapshot? { Controller.failureSnapshot }

    /// Replace the composition only while detached.
    @discardableResult
    mutating func replaceConfiguration(_ replacement: consuming Configuration) -> Bool {
        guard !isRunning else { return false }
        guard isUsable(replacement) else {
            status = .invalidConfiguration
            return false
        }
        configuration = consume replacement
        configuration.reset()
        status = .none
        return true
    }

    private func isUsable(_ candidate: borrowing Configuration) -> Bool {
        candidate.value != 0 && candidate.isValid
            && candidate.interfaceCount > 0 && candidate.interfaceCount <= Int(UInt8.max)
            && candidate.descriptorBytes >= USB.Descriptor.configurationHeaderBytes
            && candidate.descriptorBytes <= USBDeviceControlBuffer.capacity
            && candidate.isSupported(by: Controller.self)
    }

    // RP2 initializes the static controller and selects its mode first.
    @discardableResult
    mutating func initialize(identity: USBDeviceIdentity) -> Bool {
        guard !isRunning else {
            status = .alreadyRunning
            return false
        }
        guard Timer.isInitialized else { status = .timerNotReady; return false }
        guard Controller.isInitialized else { status = .controllerNotReady; return false }
        guard Controller.isDeviceMode else { status = .invalidControllerMode; return false }
        guard identity.vendorID != 0, identity.vendorID != UInt16.max,
              identity.productID != 0, validString(identity.manufacturer, allowEmpty: false),
              validString(identity.product, allowEmpty: false), validString(identity.serialNumber, allowEmpty: true) else {
            status = .invalidIdentity
            return false
        }
        guard isUsable(configuration) else {
            status = .invalidConfiguration
            return false
        }
        guard Controller.claimDeviceStack() else { status = .controllerInUse; return false }
        self.identity = identity
        clearControl()
        configurationValue = 0
        address = 0
        isSuspended = false
        suspendStarted = 0
        isAttached = Controller.isVBUSPresent
        configuration.reset()
        status = .none
        isRunning = true
        Controller.connect()
        return true
    }

    /// Detach and discard old transfers while retaining the prepared controller.
    /// initialize(identity:) can start a fresh session afterwards.
    mutating func stop() {
        guard isRunning else { return }
        Controller.disconnect()
        guard Controller.restart() else { transportFailed(); return }
        resetState()
    }

    private mutating func resetState() {
        isRunning = false
        configurationValue = 0
        address = 0
        isSuspended = false
        suspendStarted = 0
        isAttached = false
        configuration.reset()
        clearControl()
        Controller.releaseDeviceStack()
    }

    // MARK: Event processing

    // Polling is an event source, not a second protocol implementation.
    // A future IRQ adapter can mask its sources and signal foreground work,
    // then the foreground calls serviceEvents/serviceTransfers and unmasks.
    // Keep CDC queues out of the ISR; synchronize the wakeup flag in that
    // adapter. INTE/NVIC stay off here. Do not call USB or Console from a
    // concurrent IRQ/core.
    mutating func processEvents() {
        guard isRunning else { return }
        serviceEvents()
        serviceTransfers()
    }

    private mutating func serviceEvents() {
        guard isRunning else { return }
        let events = Controller.captureEvents()
        process(events)
    }

    private mutating func serviceTransfers() {
        guard isRunning else { return }
        if !isIdle, !isSuspended, Timer.hasReached(deadline: ep0.deadline) {
            status = .controlTimedOut
            stallControl()
        }
        if isRunning && isAttached && isConfigured && !isSuspended {
            configuration.service(controller: Controller.self)
        }
    }

    // Event processing has no dependency on how the CPU was notified.
    private mutating func process(_ events: Controller.Events) {
        guard isRunning else { return }
        if events.vbusPresent == false || events.disconnected {
            // A peripheral reset revokes all old buffers even if cable loss
            // interrupted a packet. Keep Device ownership for reattachment.
            guard Controller.restart() else {
                transportFailed()
                return
            }
            clearControl()
            address = 0
            configurationValue = 0
            isSuspended = false
            suspendStarted = 0
            isAttached = Controller.isVBUSPresent
            configuration.reset()
            Controller.connect()
            return
        }
        if events.vbusPresent == true {
            isAttached = true
            Controller.connect()
        }
        guard isAttached else { return }
        if events.reset {
            clearControl()
            Controller.resetEndpoints()
            address = 0
            configurationValue = 0
            isSuspended = false
            suspendStarted = 0
            configuration.reset()
            return
        }
        if events.suspendChanged, events.isSuspended != isSuspended {
            let now = Timer.microseconds
            if events.isSuspended {
                suspendStarted = now
            } else if !isIdle {
                ep0.deadline &+= now &- suspendStarted
            }
            isSuspended = events.isSuspended
        }
        // Process old function completions before EP0 can commit a new
        // configuration/halt. Otherwise an acknowledged old completion could
        // be mistaken for a packet in the new session.
        for slot in 2..<Controller.Events.slotCount where events.completed & (UInt32(1) << slot) != 0 {
            if isConfigured {
                guard configuration.completed(Controller.Events.endpoint(forSlot: slot), controller: Controller.self) else {
                    transportFailed(.invalidPacket)
                    return
                }
            }
            if !isRunning { return }
        }
        if let setup = events.setup {
            // A status ACK can be latched before the host's next SETUP.
            // Commit that successful request before replacing its state.
            // Data-stage completions must not rearm the superseded transfer.
            if case .statusIn = ep0.stage, events.completed & Controller.Events.mask(for: .controlIn) != 0 {
                commit()
                if !isRunning { return }
            }
            handleSetup(setup)
            return
        }
        if events.completed & Controller.Events.mask(for: .controlIn) != 0 { controlInCompleted() }
        if isRunning, events.completed & Controller.Events.mask(for: .controlOut) != 0 { controlOutCompleted() }
    }

    private var isIdle: Bool {
        if case .idle = ep0.stage { return true }
        return false
    }

    // MARK: Endpoint zero transfers

    private mutating func handleSetup(_ setup: USB.SetupPacket) {
        clearControl()
        guard Controller.beginControl() else {
            transportFailed()
            return
        }
        ep0.deadline = Timer.microseconds &+ controlTimeout
        if setup.kind == .standard {
            guard standardRequest(setup) else {
                stallControl()
                return
            }
        } else if setup.kind == .classSpecific, isConfigured,
                  let transfer = configuration.prepareRequest(setup, into: &ep0.buffer) {
            ep0.pending = .function(setup)
            switch transfer {
            case .input:
                guard setup.direction == .in else { stallControl(); return }
                beginInput(requested: Int(setup.length))
            case .output(let count):
                guard setup.direction == .out,
                      count > 0, count <= USBDeviceControlBuffer.capacity,
                      count == Int(setup.length), ep0.buffer.count == 0,
                      !ep0.buffer.overflow else { stallControl(); return }
                ep0.stage = .dataOut(count)
                armControlOut(count: min(count, usbDeviceControlPacketBytes))
            case .status:
                guard setup.direction == .out,
                      setup.length == 0, ep0.buffer.count == 0,
                      !ep0.buffer.overflow else { stallControl(); return }
                beginStatusIn()
            }
        } else { stallControl() }
    }

    private mutating func standardRequest(_ setup: USB.SetupPacket) -> Bool {
        guard let request = USB.Request(rawValue: setup.request) else { return false }
        switch request {
        case .getDescriptor:
            if setup.matches(.in) {
                guard appendDescriptor(type: UInt8(setup.value >> 8), number: UInt8(truncatingIfNeeded: setup.value),
                                       language: setup.index) else { return false }
            } else if setup.matches(.in, recipient: .interface) {
                guard isConfigured, configuration.ownsInterface(setup.index),
                      configuration.appendInterfaceDescriptor(setup, to: &ep0.buffer) else { return false }
            } else { return false }
            beginInput(requested: Int(setup.length))
        case .setAddress:
            guard setup.requestType == 0, setup.value <= 127, setup.index == 0,
                  setup.length == 0, configurationValue == 0 else { return false }
            ep0.pending = .address(UInt8(setup.value))
            beginStatusIn()
        case .getConfiguration:
            guard setup.matches(.in), setup.value == 0, setup.index == 0,
                  setup.length == 1, address != 0 else { return false }
            ep0.buffer.append(configurationValue)
            beginInput(requested: 1)
        case .setConfiguration:
            guard setup.requestType == 0, setup.index == 0, setup.length == 0, address != 0,
                  setup.value == 0 || setup.value == UInt16(configuration.value) else { return false }
            ep0.pending = .configuration(UInt8(setup.value))
            beginStatusIn()
        case .getStatus:
            guard setup.value == 0, setup.length == 2 else { return false }
            if setup.matches(.in) {
                guard setup.index == 0 else { return false }
                ep0.buffer.append16(0) // Bus powered, no remote wakeup.
            } else if setup.matches(.in, recipient: .interface) {
                guard isConfigured, configuration.ownsInterface(setup.index) else { return false }
                ep0.buffer.append16(0)
            } else if setup.matches(.in, recipient: .endpoint) {
                guard let endpoint = USB.EndpointAddress(address: setup.index),
                      endpoint.number == 0 || (isConfigured && configuration.ownsEndpoint(endpoint)) else { return false }
                ep0.buffer.append16(Controller.isHalted(endpoint) ? 1 : 0)
            } else { return false }
            beginInput(requested: 2)
        case .clearFeature, .setFeature:
            guard setup.matches(.out, recipient: .endpoint), setup.value == 0, setup.length == 0, isConfigured,
                  let endpoint = USB.EndpointAddress(address: setup.index), endpoint.number != 0,
                  configuration.ownsEndpoint(endpoint) else { return false }
            ep0.pending = .halt(endpoint, request == .setFeature)
            beginStatusIn()
        case .getInterface:
            guard setup.matches(.in, recipient: .interface), setup.value == 0, setup.length == 1,
                  isConfigured, configuration.ownsInterface(setup.index) else { return false }
            ep0.buffer.append(USB.Interface.alternateSettingZero)
            beginInput(requested: 1)
        case .setInterface:
            guard setup.matches(.out, recipient: .interface), setup.value == 0, setup.length == 0,
                  isConfigured, configuration.ownsInterface(setup.index) else { return false }
            ep0.pending = .interface(setup.index)
            beginStatusIn()
        }
        return true
    }

    private mutating func beginInput(requested: Int) {
        guard !ep0.buffer.overflow else { status = .invalidPacket; stallControl(); return }
        // With no data stage, SETUP is the last OUT transaction: status is IN.
        if requested == 0 { beginStatusIn(); return }
        ep0.responseLength = min(ep0.buffer.count, requested)
        ep0.responseOffset = 0
        ep0.needsZeroPacket = ep0.buffer.count < requested && ep0.responseLength % usbDeviceControlPacketBytes == 0
        ep0.stage = .dataIn
        sendNextControlPacket()
    }

    private mutating func sendNextControlPacket() {
        if ep0.responseOffset < ep0.responseLength {
            let count = min(ep0.responseLength - ep0.responseOffset, usbDeviceControlPacketBytes)
            for offset in 0..<count {
                Controller.writeByte(.controlIn, at: offset, value: ep0.buffer[ep0.responseOffset + offset])
            }
            ep0.responseOffset += count
            guard Controller.submit(.controlIn, count: count) else {
                transportFailed()
                return
            }
        } else if ep0.needsZeroPacket {
            ep0.needsZeroPacket = false
            guard Controller.submit(.controlIn, count: 0) else {
                transportFailed()
                return
            }
        } else {
            ep0.stage = .statusOut
            // Status always uses DATA1, independently of data-stage toggles.
            armControlOut(count: 0)
        }
    }

    private mutating func beginStatusIn() {
        ep0.stage = .statusIn
        guard Controller.submit(.controlIn, count: 0) else {
            transportFailed()
            return
        }
    }
    private mutating func armControlOut(count: Int) {
        guard Controller.submit(.controlOut, count: count) else {
            transportFailed()
            return
        }
    }

    private mutating func controlInCompleted() {
        switch ep0.stage {
        case .dataIn: sendNextControlPacket()
        case .statusIn:
            commit()
            clearControl()
        default: break // Old transfers are discarded by SETUP/reset.
        }
    }

    private mutating func controlOutCompleted() {
        let count = Controller.receivedCount(.controlOut)
        switch ep0.stage {
        case .dataOut(let expected):
            guard count >= 0, count <= usbDeviceControlPacketBytes,
                  count <= expected - ep0.buffer.count else {
                status = .invalidPacket
                stallControl()
                return
            }
            for offset in 0..<count { ep0.buffer.append(Controller.readByte(.controlOut, at: offset)) }
            if ep0.buffer.count == expected {
                guard case .function(let setup) = ep0.pending,
                      configuration.acceptOutput(setup, data: ep0.buffer) else {
                    stallControl()
                    return
                }
                beginStatusIn()
            } else if count == usbDeviceControlPacketBytes {
                armControlOut(count: min(expected - ep0.buffer.count, usbDeviceControlPacketBytes))
            } else { status = .invalidPacket; stallControl() }
        case .statusOut:
            guard count == 0 else {
                status = .invalidPacket
                stallControl()
                return
            }
            clearControl()
        default: break
        }
    }

    private mutating func commit() {
        switch ep0.pending {
        case .none: break
        case .address(let value):
            address = value
            Controller.setAddress(value)
        case .configuration(let value):
            guard Controller.disableFunctions() else {
                transportFailed()
                return
            }
            configuration.reset()
            configurationValue = value
            if value != 0 { configuration.configure(controller: Controller.self) }
        case .interface(let number):
            if !configuration.resetInterface(number, controller: Controller.self) { transportFailed() }
        case .halt(let endpoint, let halted):
            guard Controller.halt(endpoint, enabled: halted) else {
                transportFailed()
                return
            }
            if !configuration.endpointCancelled(endpoint, controller: Controller.self) { transportFailed() }
        case .function(let setup): configuration.completeRequest(setup, data: ep0.buffer)
        }
    }

    private mutating func clearControl() {
        ep0.stage = .idle
        ep0.pending = .none
        ep0.buffer.clear()
        ep0.responseLength = 0
        ep0.responseOffset = 0
        ep0.needsZeroPacket = false
        ep0.deadline = 0
    }
    private mutating func stallControl() {
        guard Controller.cancel(mask: Controller.Events.controlMask) else {
            transportFailed()
            return
        }
        clearControl()
        Controller.stallControl()
    }
    private mutating func transportFailed(_ failure: ErrorCode = .controllerFailure) {
        status = failure
        // Fatal hardware failures release the peripheral and preserve diagnostics.
        // RP2 must initialize the static controller again before retrying.
        Controller.stop()
        resetState()
    }

    deinit {
        // Static peripheral state must not outlive a dropped active Device.
        if isRunning {
            Controller.disconnect()
            Controller.stop()
            Controller.releaseDeviceStack()
        }
    }

    // MARK: Device and string descriptors

    private mutating func appendDescriptor(type: UInt8, number: UInt8, language: UInt16) -> Bool {
        guard let identity = identity, let descriptor = USB.Descriptor(rawValue: type) else { return false }
        switch descriptor {
        case .device:
            guard number == 0, language == 0 else { return false }
            ep0.buffer.beginDescriptor(.device, length: UInt8(USB.DeviceDescriptor.bytes))
            ep0.buffer.append16(USB.Specification.version2_0)
            // Device personality; function class lives on each interface.
            ep0.buffer.append(identity.deviceClass)
            ep0.buffer.append(identity.deviceSubclass)
            ep0.buffer.append(identity.deviceProtocol)
            ep0.buffer.append(UInt8(usbDeviceControlPacketBytes))
            ep0.buffer.append16(identity.vendorID)
            ep0.buffer.append16(identity.productID)
            ep0.buffer.append16(identity.deviceVersion)
            ep0.buffer.append(USB.StringDescriptorIndex.manufacturer.rawValue)
            ep0.buffer.append(USB.StringDescriptorIndex.product.rawValue)
            ep0.buffer.append(identity.serialNumber.utf8CodeUnitCount == 0
                ? USB.StringDescriptorIndex.none.rawValue
                : USB.StringDescriptorIndex.serialNumber.rawValue)
            ep0.buffer.append(USB.DeviceDescriptor.configurationCount)
        case .configuration:
            guard number == 0, language == 0 else { return false }
            guard configuration.appendDescriptor(to: &ep0.buffer) else {
                status = .invalidConfiguration
                return false
            }
        case .string:
            if number == 0 {
                guard language == 0 else { return false }
                ep0.buffer.beginDescriptor(.string, length: UInt8(USB.Descriptor.languageDescriptorBytes))
                ep0.buffer.append16(USB.LanguageID.englishUnitedStates)
            } else {
                guard language == USB.LanguageID.englishUnitedStates else { return false }
                let string: StaticString
                switch number {
                case USB.StringDescriptorIndex.manufacturer.rawValue: string = identity.manufacturer
                case USB.StringDescriptorIndex.product.rawValue: string = identity.product
                case USB.StringDescriptorIndex.serialNumber.rawValue
                    where identity.serialNumber.utf8CodeUnitCount > 0: string = identity.serialNumber
                default: return false
                }
                ep0.buffer.beginDescriptor(.string,
                    length: UInt8(USB.Descriptor.stringHeaderBytes + string.utf8CodeUnitCount * 2))
                for index in 0..<string.utf8CodeUnitCount { ep0.buffer.append16(UInt16(string.utf8Start[index])) }
            }
        default: return false // FS-only; no device qualifier/other-speed descriptors.
        }
        return true
    }

    // Initial string support is explicitly printable ASCII -> UTF-16LE.
    // Reject unsupported strings rather than emit malformed UTF-16.
    private func validString(_ string: StaticString, allowEmpty: Bool) -> Bool {
        let count = string.utf8CodeUnitCount
        guard count <= 126, allowEmpty || count > 0 else { return false }
        for index in 0..<count {
            if string.utf8Start[index] < 0x20 || string.utf8Start[index] > 0x7E { return false }
        }
        return true
    }
}

// The concrete Composite lends its owned ACM for registration and polling.
// Descriptor assignments and the rest of its configuration stay encapsulated.
extension USBDevice where Configuration: ~Copyable,
    Controller == USBController, Configuration == CompositeConfiguration {
    mutating func withACM<Result>(_ body: (inout CDC.ACM) -> Result) -> Result {
        body(&configuration.acm)
    }
}
