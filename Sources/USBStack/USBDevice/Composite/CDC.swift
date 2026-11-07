// Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
// SPDX-License-Identifier: MIT

// CDC definitions and Device-side descriptor encoding shared by CDC subclasses.
// ACM-specific requests and state remain in CDC/ACM.swift.
// https://www.usb.org/document-library/class-definitions-communication-devices-12
enum CDC {
    static let communicationClass: UInt8 = 0x02
    static let dataClass: UInt8 = 0x0A
    static let classInterfaceDescriptorType: UInt8 = 0x24
    static let version: UInt16 = 0x0120

    enum FunctionalDescriptor: UInt8 {
        case header = 0, union = 6
    }
    static let headerDescriptorBytes = 5
    // One subordinate Data interface. Other CDC functions can provide their
    // own Union layout when they require more subordinate interfaces.
    static let unionDescriptorBytes = 5

    static func appendHeader(to buffer: inout USBDeviceControlBuffer) -> Bool {
        guard buffer.canAppend(byteCount: headerDescriptorBytes) else { return false }
        beginFunctionalDescriptor(FunctionalDescriptor.header.rawValue,
                                  length: UInt8(headerDescriptorBytes), to: &buffer)
        buffer.append16(version)
        return true
    }

    static func appendUnion(communication: UInt8, data: UInt8,
                            to buffer: inout USBDeviceControlBuffer) -> Bool {
        guard buffer.canAppend(byteCount: unionDescriptorBytes) else { return false }
        beginFunctionalDescriptor(FunctionalDescriptor.union.rawValue,
                                  length: UInt8(unionDescriptorBytes), to: &buffer)
        buffer.append(communication)
        buffer.append(data)
        return true
    }

    static func beginFunctionalDescriptor(_ subtype: UInt8, length: UInt8,
                                          to buffer: inout USBDeviceControlBuffer) {
        buffer.beginDescriptor(classInterfaceDescriptorType, length: length)
        buffer.append(subtype)
    }
}
