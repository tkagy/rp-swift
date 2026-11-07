// Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
// SPDX-License-Identifier: MIT

// USB wire definitions shared by the Device and future Host stacks.
// https://www.usb.org/document-library/usb-20-specification
// Wire values are encoded explicitly, never by copying Swift struct layouts.
enum USB {
    enum Specification {
        static let version2_0: UInt16 = 0x0200
    }

    enum DeviceDescriptor {
        // The current Composite uses the Miscellaneous class with IAD protocol.
        static let interfaceDefinedClass: UInt8 = 0
        static let interfaceDefinedSubclass: UInt8 = 0
        static let interfaceDefinedProtocol: UInt8 = 0
        static let miscellaneousClass: UInt8 = 0xEF
        static let commonSubclass: UInt8 = 0x02
        static let interfaceAssociationProtocol: UInt8 = 0x01
        static let bytes = 18
        static let defaultVersion: UInt16 = 0x0100
        static let configurationCount: UInt8 = 1
    }

    enum StringDescriptorIndex: UInt8 {
        case none = 0
        case manufacturer = 1
        case product = 2
        case serialNumber = 3
    }

    enum Interface {
        static let alternateSettingZero: UInt8 = 0
    }

    enum LanguageID {
        static let englishUnitedStates: UInt16 = 0x0409
    }

    enum Direction: UInt8 { case out = 0, `in` = 0x80 }
    enum RequestKind: UInt8 { case standard = 0x00, classSpecific = 0x20, vendor = 0x40, reserved = 0x60 }
    enum Recipient: UInt8 { case device = 0, interface = 1, endpoint = 2, other = 3 }
    enum TransferType: UInt32 { case control = 0, isochronous, bulk, interrupt }

    static func requestType(_ direction: Direction, kind: RequestKind = .standard,
                            recipient: Recipient = .device) -> UInt8 {
        direction.rawValue | kind.rawValue | recipient.rawValue
    }

    struct EndpointAddress: Equatable {
        let number: UInt8
        let direction: Direction

        init(_ number: UInt8, _ direction: Direction) {
            precondition(number < 16, "USB endpoint number exceeds 15")
            self.number = number
            self.direction = direction
        }

        init?(address: UInt16) {
            guard address & ~UInt16(0x8F) == 0 else { return nil }
            self.init(UInt8(address & 0x0F), address & 0x80 == 0 ? .out : .in)
        }

        var address: UInt8 { number | direction.rawValue }
        static let controlIn = EndpointAddress(0, .in)
        static let controlOut = EndpointAddress(0, .out)
    }

    struct SetupPacket {
        let requestType: UInt8
        let request: UInt8
        let value: UInt16
        let index: UInt16
        let length: UInt16

        var direction: Direction { requestType & Direction.in.rawValue == 0 ? .out : .in }
        var kind: RequestKind {
            switch requestType & 0x60 {
            case RequestKind.standard.rawValue: .standard
            case RequestKind.classSpecific.rawValue: .classSpecific
            case RequestKind.vendor.rawValue: .vendor
            default: .reserved
            }
        }

        init(word0: UInt32, word1: UInt32) {
            requestType = UInt8(truncatingIfNeeded: word0)
            request = UInt8(truncatingIfNeeded: word0 >> 8)
            value = UInt16(truncatingIfNeeded: word0 >> 16)
            index = UInt16(truncatingIfNeeded: word1)
            length = UInt16(truncatingIfNeeded: word1 >> 16)
        }

        func matches(_ direction: Direction, kind: RequestKind = .standard,
                     recipient: Recipient = .device) -> Bool {
            requestType == USB.requestType(direction, kind: kind, recipient: recipient)
        }
    }

    enum Descriptor: UInt8 {
        case device = 1, configuration = 2, string = 3, interface = 4, endpoint = 5
        case interfaceAssociation = 11
        static let configurationHeaderBytes = 9
        static let stringHeaderBytes = 2
        static let languageDescriptorBytes = 4
    }

    enum Request: UInt8 {
        case getStatus = 0, clearFeature = 1, setFeature = 3, setAddress = 5
        case getDescriptor = 6, getConfiguration = 8, setConfiguration = 9
        case getInterface = 10, setInterface = 11
    }
}
