// Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
// SPDX-License-Identifier: MIT

/// Defines this Composite Device's USB-visible composition and function state.
/// It owns CDC ACM and builds the Composite descriptors; USBDevice supplies the
/// shared enumeration and EP0 state machine. Additional functions, such as HID,
/// are added here when they belong in this Composite Device.
struct CompositeConfiguration: USBDeviceConfiguration, ~Copyable {
    #if PRIVATE_TEST
    static let identity = USBDeviceIdentity(
        vendorID: 0x1209, productID: 0x0001,
        deviceClass: USB.DeviceDescriptor.miscellaneousClass,
        deviceSubclass: USB.DeviceDescriptor.commonSubclass,
        deviceProtocol: USB.DeviceDescriptor.interfaceAssociationProtocol,
        manufacturer: "PersonalStudio",
        product: "rp-swift CDC"
    )
    #else
    #error("Set an assigned USB VID/PID before building; use -D PRIVATE_TEST only for private testing")
    #endif

    var acm: CDC.ACM
    var value: UInt8 { Self.configurationValue }
    var interfaceCount: Int { CDC.ACM.interfaceCount }
    var descriptorBytes: Int { USB.Descriptor.configurationHeaderBytes + CDC.ACM.descriptorBytes }

    func isSupported<C: USBDeviceControllerProtocol>(by controller: C.Type) -> Bool {
        acm.bulkPacketBytes <= C.maximumBulkPacketBytes
    }
    func appendInterfaceDescriptor(_ setup: USB.SetupPacket, to buffer: inout USBDeviceControlBuffer) -> Bool {
        guard acm.interfaces.contains(setup.index) else { return false }
        return acm.appendInterfaceDescriptor(setup, to: &buffer)
    }

    init(bulkPacketBytes: Int) {
        acm = CDC.ACM(interfaces: .init(communication: 0, data: 1),
            endpoints: .init(notification: .init(1, .in), bulkIn: .init(2, .in), bulkOut: .init(2, .out)),
            bulkPacketBytes: bulkPacketBytes)
    }

    private static let configurationValue: UInt8 = 1

    var isValid: Bool {
        acm.isValid
            && acm.endpoints.notification != acm.endpoints.bulkIn
            && acm.endpoints.notification != acm.endpoints.bulkOut
            && acm.endpoints.bulkIn != acm.endpoints.bulkOut
            && acm.interfaces.communication == 0
            && Int(acm.interfaces.data) == interfaceCount - 1
            && descriptorBytes <= USBDeviceControlBuffer.capacity
    }
    func ownsInterface(_ number: UInt16) -> Bool {
        acm.interfaces.contains(number)
    }
    func ownsEndpoint(_ endpoint: USB.EndpointAddress) -> Bool { acm.endpoints.contains(endpoint) }
    mutating func reset() { acm.reset() }
    mutating func configure<C: USBDeviceControllerProtocol>(controller: C.Type) {
        acm.configure(controller: controller)
    }
    mutating func service<C: USBDeviceControllerProtocol>(controller: C.Type) {
        acm.service(controller: controller)
        acm.serviceBulk(controller: controller)
    }

    mutating func resetInterface<C: USBDeviceControllerProtocol>(_ number: UInt16, controller: C.Type) -> Bool {
        guard acm.interfaces.contains(number) else { return false }
        guard acm.resetInterface(number, controller: controller) else { return false }
        if number == UInt16(acm.interfaces.data) { acm.stream.reset(configured: true) }
        return true
    }

    mutating func completed<C: USBDeviceControllerProtocol>(_ endpoint: USB.EndpointAddress, controller: C.Type) -> Bool {
        guard acm.endpoints.contains(endpoint) else { return false }
        // Notifications need no queued payload retirement; Stream handles Bulk.
        return acm.completeBulkEndpoint(endpoint, controller: controller)
    }
    mutating func endpointCancelled<C: USBDeviceControllerProtocol>(_ endpoint: USB.EndpointAddress, controller: C.Type) -> Bool {
        guard acm.endpoints.contains(endpoint) else { return false }
        acm.endpointCancelled(endpoint)
        if endpoint == acm.endpoints.bulkIn || endpoint == acm.endpoints.bulkOut {
            // USBDevice.halt() has already revoked this endpoint. Preserve the
            // other direction and let Stream retire or retry the affected packet.
            acm.cancelBulkEndpoint(endpoint, controller: controller)
        }
        return true
    }

    mutating func prepareRequest(_ setup: USB.SetupPacket, into buffer: inout USBDeviceControlBuffer) -> USBDeviceControlTransfer? {
        guard acm.interfaces.contains(setup.index) else { return nil }
        return acm.prepareRequest(setup, into: &buffer)
    }
    func acceptOutput(_ setup: USB.SetupPacket, data: borrowing USBDeviceControlBuffer) -> Bool {
        guard acm.interfaces.contains(setup.index) else { return false }
        return acm.acceptOutput(setup, data: data)
    }
    mutating func completeRequest(_ setup: USB.SetupPacket, data: borrowing USBDeviceControlBuffer) {
        guard acm.interfaces.contains(setup.index) else { return }
        acm.completeRequest(setup, data: data)
    }
    func appendDescriptor(to buffer: inout USBDeviceControlBuffer) -> Bool {
        guard isValid, buffer.canAppend(byteCount: descriptorBytes) else { return false }
        let start = buffer.count
        let headerBytes = USB.Descriptor.configurationHeaderBytes
        let totalBytes = descriptorBytes
        buffer.beginDescriptor(.configuration, length: UInt8(headerBytes))
        buffer.append16(UInt16(totalBytes))
        buffer.append(UInt8(interfaceCount))
        buffer.append(value)
        buffer.append(USB.StringDescriptorIndex.none.rawValue)
        buffer.append(ConfigurationAttributes.busPowered)
        buffer.append(ConfigurationAttributes.maximumPowerUnits)
        guard acm.appendDescriptors(to: &buffer) else { return false }
        // Capacity is checked before writing. A length mismatch is an
        // implementation error, distinct from a recoverable full buffer.
        precondition(buffer.count - start == totalBytes,
                     "USB configuration descriptor length mismatch")
        return !buffer.overflow
    }

    private enum ConfigurationAttributes {
        static let busPowered: UInt8 = 1 << 7
        static let maximumPowerUnits: UInt8 = 50 // 100 mA in 2 mA units.
    }
}

/// The firmware's concrete Composite Device: the shared USBDevice stack using
/// CompositeConfiguration. This is a type alias, so it adds no separate state.
/// Another Device personality can use the same stack with its own configuration,
/// for example `USBDevice<USBController, HIDConfiguration>` for HID alone.
/// The controller is the single static RP2 hardware module.
typealias Composite = USBDevice<USBController, CompositeConfiguration>

extension USBDevice where Configuration: ~Copyable,
    Controller == USBController, Configuration == CompositeConfiguration {
    init() {
        self.init(configuration: CompositeConfiguration(bulkPacketBytes: USBController.maximumBulkPacketBytes))
    }

    /// Return the initialized Device, following UART's fluent initialization API.
    /// The controller hardware must already be initialized in Device mode by RP2.
    consuming func initialize() -> Self {
        var device = consume self
        guard device.initialize(identity: CompositeConfiguration.identity) else { faultHandler() }
        return consume device
    }
}
