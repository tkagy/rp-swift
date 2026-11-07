// Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
// SPDX-License-Identifier: MIT

// CDC PSTN Abstract Control Model control state. Stream owns Bulk I/O separately.
// https://www.usb.org/document-library/class-definitions-communication-devices-12

extension CDC {
    struct ACM: ~Copyable {
        let interfaces: Interfaces
        let endpoints: Endpoints
        let bulkPacketBytes: Int
        var stream = Stream(rx: Buffer(), tx: Buffer())
        private(set) var lineCoding = LineCoding()
        private(set) var controlLineState: UInt16 = 0
        private var notificationPending = true

        init(interfaces: Interfaces, endpoints: Endpoints, bulkPacketBytes: Int) {
            self.interfaces = interfaces
            self.endpoints = endpoints
            self.bulkPacketBytes = bulkPacketBytes
        }

        var dtr: Bool { controlLineState & Self.ControlLine.dtr != 0 }
        var rts: Bool { controlLineState & Self.ControlLine.rts != 0 }

        var isValid: Bool {
            interfaces.communication < UInt8.max && interfaces.data == interfaces.communication + 1
                && endpoints.notification.number != 0 && endpoints.notification.direction == .in
                && endpoints.bulkIn.number != 0 && endpoints.bulkIn.direction == .in
                && endpoints.bulkOut.number != 0 && endpoints.bulkOut.direction == .out
                && endpoints.notification != endpoints.bulkIn
                && (bulkPacketBytes == 8 || bulkPacketBytes == 16 || bulkPacketBytes == 32 || bulkPacketBytes == 64)
        }

        mutating func reset() {
            lineCoding = LineCoding()
            controlLineState = 0
            notificationPending = true
            stream.reset()
        }

        // Present ACM's byte stream like UART to Console. USB endpoint events
        // remain owned by USBDevice.processEvents().
        mutating func readByte() -> UInt8? { stream.readByte() }
        mutating func tryWrite(byte: UInt8) -> Bool { stream.tryWrite(byte: byte) }
        var isTransmitting: Bool { stream.isTransmitting }

        mutating func configure<C: USBDeviceControllerProtocol>(controller: C.Type) {
            C.configure(endpoints.notification, type: .interrupt, maximumPacket: Self.notificationPacketBytes)
            C.configure(endpoints.bulkIn, type: .bulk, maximumPacket: bulkPacketBytes)
            C.configure(endpoints.bulkOut, type: .bulk, maximumPacket: bulkPacketBytes)
            notificationPending = true
            stream.start()
        }

        mutating func serviceBulk<C: USBDeviceControllerProtocol>(controller: C.Type) {
            let endpoints = self.endpoints
            let packetBytes = self.bulkPacketBytes
            stream.service(bulkIn: endpoints.bulkIn, bulkOut: endpoints.bulkOut,
                           packetBytes: packetBytes, controller: controller)
        }

        mutating func completeBulkEndpoint<C: USBDeviceControllerProtocol>(
            _ endpoint: USB.EndpointAddress, controller: C.Type
        ) -> Bool {
            let endpoints = self.endpoints
            let packetBytes = self.bulkPacketBytes
            return stream.completed(endpoint, bulkIn: endpoints.bulkIn, bulkOut: endpoints.bulkOut,
                                    packetBytes: packetBytes, controller: controller)
        }

        mutating func cancelBulkEndpoint<C: USBDeviceControllerProtocol>(
            _ endpoint: USB.EndpointAddress, controller: C.Type
        ) {
            let endpoints = self.endpoints
            let packetBytes = self.bulkPacketBytes
            stream.endpointCancelled(endpoint, bulkIn: endpoints.bulkIn, bulkOut: endpoints.bulkOut,
                                     packetBytes: packetBytes, controller: controller)
        }

        func appendInterfaceDescriptor(_ setup: USB.SetupPacket, to buffer: inout USBDeviceControlBuffer) -> Bool {
            // ACM defines no separately requested Interface descriptor.
            false
        }

        mutating func resetInterface<C: USBDeviceControllerProtocol>(
            _ number: UInt16, controller: C.Type
        ) -> Bool {
            if number == UInt16(interfaces.communication) {
                guard C.halt(endpoints.notification, enabled: false) else { return false }
                endpointCancelled(endpoints.notification)
                return true
            }
            guard number == UInt16(interfaces.data) else { return false }
            return C.halt(endpoints.bulkIn, enabled: false)
                && C.halt(endpoints.bulkOut, enabled: false)
        }

        mutating func endpointCancelled(_ endpoint: USB.EndpointAddress) {
            if endpoint == endpoints.notification { notificationPending = true }
        }

        mutating func service<C: USBDeviceControllerProtocol>(controller: C.Type) {
            guard notificationPending, C.canSubmit(endpoints.notification) else { return }
            // Emulate carrier/DSR readiness for the software terminal. There
            // are no physical break/parity/framing/overrun indications.
            let notificationBytes = Self.Notification.bytes
            for offset in 0..<notificationBytes {
                let byte: UInt8
                switch offset {
                case Self.Notification.requestTypeOffset:
                    byte = USB.requestType(.in, kind: .classSpecific, recipient: .interface)
                case Self.Notification.notificationOffset: byte = Self.Notification.serialState
                case Self.Notification.interfaceIndexOffset: byte = interfaces.communication
                case Self.Notification.lengthLowOffset: byte = Self.Notification.serialStateBytes
                case Self.Notification.serialStateOffset:
                    byte = dtr ? Self.Notification.carrierBits : 0
                default: byte = 0
                }
                C.writeByte(endpoints.notification, at: offset, value: byte)
            }
            if C.submit(endpoints.notification, count: notificationBytes) {
                notificationPending = false
            }
        }

        func prepareRequest(_ setup: USB.SetupPacket, into buffer: inout USBDeviceControlBuffer) -> USBDeviceControlTransfer? {
            guard setup.index == UInt16(interfaces.communication), let request = ControlRequest(rawValue: setup.request) else { return nil }
            switch request {
            case .getLineCoding:
                guard setup.matches(.in, kind: .classSpecific, recipient: .interface), setup.value == 0, setup.length == UInt16(LineCoding.byteCount) else { return nil }
                lineCoding.encode(to: &buffer)
                return .input
            case .setLineCoding:
                guard setup.matches(.out, kind: .classSpecific, recipient: .interface), setup.value == 0, setup.length == UInt16(LineCoding.byteCount) else { return nil }
                return .output(LineCoding.byteCount)
            case .setControlLineState:
                guard setup.matches(.out, kind: .classSpecific, recipient: .interface), setup.length == 0, setup.value & ~Self.ControlLine.validMask == 0 else { return nil }
                return .status
            }
            // SEND_BREAK is not advertised or supported; unknown requests stall EP0.
        }

        func acceptOutput(_ setup: USB.SetupPacket, data: borrowing USBDeviceControlBuffer) -> Bool {
            setup.index == UInt16(interfaces.communication)
                && setup.request == ControlRequest.setLineCoding.rawValue
                && LineCoding.decode(data) != nil
        }

        // Device receives all seven OUT bytes before reaching status IN. Commit
        // after its ACK so a replacement SETUP/reset discards the pending change.
        mutating func completeRequest(_ setup: USB.SetupPacket, data: borrowing USBDeviceControlBuffer) {
            guard setup.index == UInt16(interfaces.communication), let request = ControlRequest(rawValue: setup.request) else { return }
            switch request {
            case .getLineCoding: break
            case .setLineCoding:
                if let coding = LineCoding.decode(data) { lineCoding = coding }
            case .setControlLineState:
                let wasReady = dtr
                controlLineState = setup.value
                if wasReady != dtr { notificationPending = true }
            }
        }

        struct Interfaces {
            let communication: UInt8
            let data: UInt8
            func contains(_ number: UInt16) -> Bool {
                number == UInt16(communication) || number == UInt16(data)
            }
        }

        struct Endpoints {
            let notification: USB.EndpointAddress
            let bulkIn: USB.EndpointAddress
            let bulkOut: USB.EndpointAddress

            func contains(_ endpoint: USB.EndpointAddress) -> Bool {
                endpoint == notification || endpoint == bulkIn || endpoint == bulkOut
            }
        }

        struct LineCoding {
            var bitRate: UInt32 = 115_200
            var stopBits: UInt8 = 0
            var parity: UInt8 = 0
            var dataBits: UInt8 = 8
            static let byteCount = 7

            var isValid: Bool {
                stopBits <= 2 && parity <= 4
                    && (dataBits == 5 || dataBits == 6 || dataBits == 7 || dataBits == 8 || dataBits == 16)
            }

            func encode(to buffer: inout USBDeviceControlBuffer) {
                buffer.append32(bitRate)
                buffer.append(stopBits)
                buffer.append(parity)
                buffer.append(dataBits)
            }

            static func decode(_ buffer: borrowing USBDeviceControlBuffer) -> Self? {
                guard buffer.count == byteCount else { return nil }
                let bitRate = UInt32(buffer[0]) | (UInt32(buffer[1]) << 8)
                    | (UInt32(buffer[2]) << 16) | (UInt32(buffer[3]) << 24)
                let coding = Self(bitRate: bitRate, stopBits: buffer[4], parity: buffer[5], dataBits: buffer[6])
                return coding.isValid ? coding : nil
            }
        }

        private enum ControlRequest: UInt8 {
            case setLineCoding = 0x20, getLineCoding = 0x21, setControlLineState = 0x22
        }
        private enum ControlLine {
            static let dtr: UInt16 = 1 << 0
            static let rts: UInt16 = 1 << 1
            static let validMask = dtr | rts
        }
        private enum Notification {
            static let serialState: UInt8 = 0x20
            static let bytes = 10
            static let requestTypeOffset = 0
            static let notificationOffset = 1
            static let interfaceIndexOffset = 4
            static let lengthLowOffset = 6
            static let serialStateOffset = 8
            static let serialStateBytes: UInt8 = 2
            static let carrierBits: UInt8 = 0x03 // DCD and DSR.
        }
        private enum Capabilities {
            static let lineCodingAndSerialState: UInt8 = 1 << 1
        }
        private static let subclassCode: UInt8 = 0x02
        private static let noProtocol: UInt8 = 0
        private static let noInterval: UInt8 = 0
        private static let dataSubclass: UInt8 = 0
        private static let noCallManagement: UInt8 = 0
        private static let communicationEndpointCount: UInt8 = 1
        private static let dataEndpointCount: UInt8 = 2
        private static let notificationIntervalFrames: UInt8 = 16
        private enum FunctionalDescriptor: UInt8 {
            case callManagement = 1, abstractControlManagement = 2
        }
        static let interfaceCount = 2
        static let endpointCount = 3
        private static let associationDescriptorBytes = 8
        private static let interfaceDescriptorBytes = 9
        private static let callManagementDescriptorBytes = 5
        private static let acmDescriptorBytes = 4
        private static let endpointDescriptorBytes = 7
        static let descriptorBytes = associationDescriptorBytes + interfaceCount * interfaceDescriptorBytes
            + CDC.headerDescriptorBytes + callManagementDescriptorBytes + acmDescriptorBytes
            + CDC.unionDescriptorBytes + endpointCount * endpointDescriptorBytes
        static let notificationPacketBytes = 16

        func appendDescriptors(to buffer: inout USBDeviceControlBuffer) -> Bool {
            // One IAD covers these two contiguous interfaces. Union names both
            // explicitly; no descriptor uses a separate copy of the assignment.
            guard isValid, buffer.canAppend(byteCount: Self.descriptorBytes) else { return false }
            let start = buffer.count
            buffer.beginDescriptor(.interfaceAssociation, length: UInt8(Self.associationDescriptorBytes))
            buffer.append(interfaces.communication)
            buffer.append(UInt8(Self.interfaceCount))
            buffer.append(CDC.communicationClass)
            buffer.append(Self.subclassCode)
            buffer.append(Self.noProtocol)
            buffer.append(USB.StringDescriptorIndex.none.rawValue)
            appendInterface(interfaces.communication, endpoints: Self.communicationEndpointCount,
                            classCode: CDC.communicationClass, subclass: Self.subclassCode, to: &buffer)
            guard CDC.appendHeader(to: &buffer) else { return false }
            beginFunctionalDescriptor(.callManagement, length: UInt8(Self.callManagementDescriptorBytes), to: &buffer)
            buffer.append(Self.noCallManagement)
            buffer.append(interfaces.data)
            beginFunctionalDescriptor(.abstractControlManagement, length: UInt8(Self.acmDescriptorBytes), to: &buffer)
            buffer.append(Capabilities.lineCodingAndSerialState)
            guard CDC.appendUnion(communication: interfaces.communication, data: interfaces.data, to: &buffer) else { return false }
            appendEndpoint(endpoints.notification, type: .interrupt, size: Self.notificationPacketBytes,
                           interval: Self.notificationIntervalFrames, to: &buffer)
            appendInterface(interfaces.data, endpoints: Self.dataEndpointCount,
                            classCode: CDC.dataClass, subclass: Self.dataSubclass, to: &buffer)
            appendEndpoint(endpoints.bulkOut, type: .bulk, size: bulkPacketBytes,
                           interval: Self.noInterval, to: &buffer)
            appendEndpoint(endpoints.bulkIn, type: .bulk, size: bulkPacketBytes,
                           interval: Self.noInterval, to: &buffer)
            precondition(buffer.count - start == Self.descriptorBytes,
                         "CDC descriptor length mismatch")
            return !buffer.overflow
        }

        private func beginFunctionalDescriptor(_ subtype: FunctionalDescriptor, length: UInt8, to buffer: inout USBDeviceControlBuffer) {
            CDC.beginFunctionalDescriptor(subtype.rawValue, length: length, to: &buffer)
        }
        private func appendInterface(_ number: UInt8, endpoints: UInt8, classCode: UInt8, subclass: UInt8, to buffer: inout USBDeviceControlBuffer) {
            buffer.beginDescriptor(.interface, length: UInt8(Self.interfaceDescriptorBytes))
            buffer.append(number)
            buffer.append(USB.Interface.alternateSettingZero)
            buffer.append(endpoints)
            buffer.append(classCode)
            buffer.append(subclass)
            buffer.append(Self.noProtocol)
            buffer.append(USB.StringDescriptorIndex.none.rawValue)
        }
        private func appendEndpoint(_ endpoint: USB.EndpointAddress, type: USB.TransferType, size: Int, interval: UInt8, to buffer: inout USBDeviceControlBuffer) {
            buffer.beginDescriptor(.endpoint, length: UInt8(Self.endpointDescriptorBytes))
            buffer.append(endpoint.address)
            buffer.append(UInt8(type.rawValue))
            buffer.append16(UInt16(size))
            buffer.append(interval)
        }
    }
}

extension CDC.ACM {
    /// Storage is owned by the Composite, independently of ACM control state.
    struct Stream<RX: ~Copyable, TX: ~Copyable>: ~Copyable {
        private var rx: RX
        private var tx: TX
        private(set) var session: UInt32 = 0
        private(set) var isConfigured = false
        private var receiving = false
        private var transmitting = false
        private var inFlightBytes = 0
        private var needsZeroPacket = false
        private var deferZeroPacket = false

        init(rx: consuming RX, tx: consuming TX) {
            self.rx = consume rx
            self.tx = consume tx
        }
    }

    /// Fixed capacity byte FIFO. A submitted TX prefix remains here until ACK.
    struct Buffer: ~Copyable {
        private var bytes: InlineArray<128, UInt8> = .init(repeating: 0)
        private var head = 0
        private(set) var count = 0
        var available: Int { bytes.count - count }

        mutating func clear() { head = 0; count = 0 }
        @discardableResult
        mutating func append(_ byte: UInt8) -> Bool {
            guard available > 0 else { return false }
            bytes[(head + count) % bytes.count] = byte
            count += 1
            return true
        }
        func byte(at offset: Int) -> UInt8 {
            precondition(offset >= 0 && offset < count)
            return bytes[(head + offset) % bytes.count]
        }
        mutating func remove(_ length: Int) {
            precondition(length >= 0 && length <= count)
            head = (head + length) % bytes.count
            count -= length
        }
        mutating func pop() -> UInt8? {
            guard count > 0 else { return nil }
            let byte = bytes[head]
            remove(1)
            return byte
        }
    }
}

extension CDC.ACM.Stream where RX: ~Copyable, TX: ~Copyable, RX == CDC.ACM.Buffer, TX == CDC.ACM.Buffer {
    mutating func reset(configured: Bool = false) {
        rx.clear()
        tx.clear()
        receiving = false
        transmitting = false
        inFlightBytes = 0
        needsZeroPacket = false
        deferZeroPacket = false
        isConfigured = configured
        session &+= 1
    }

    mutating func start() { isConfigured = true }

    mutating func completed<C: USBDeviceControllerProtocol>(
        _ endpoint: USB.EndpointAddress, bulkIn: USB.EndpointAddress,
        bulkOut: USB.EndpointAddress, packetBytes: Int, controller: C.Type
    ) -> Bool {
        if endpoint == bulkOut, receiving {
            receiving = false
            let count = C.receivedCount(endpoint)
            // Only one reserved OUT packet can complete between services.
            guard count >= 0, count <= packetBytes, count <= rx.available else { return false }
            for offset in 0..<count {
                rx.append(C.readByte(endpoint, at: offset))
            }
        } else if endpoint == bulkIn, transmitting {
            tx.remove(inFlightBytes)
            transmitting = false
            inFlightBytes = 0
            deferZeroPacket = needsZeroPacket
        }
        return true
    }

    mutating func endpointCancelled<C: USBDeviceControllerProtocol>(
        _ endpoint: USB.EndpointAddress, bulkIn: USB.EndpointAddress,
        bulkOut: USB.EndpointAddress, packetBytes: Int, controller: C.Type
    ) {
        if endpoint == bulkOut {
            receiving = false
            if C.completedDuringLastCancellation(endpoint) {
                let count = C.receivedCount(endpoint)
                guard count >= 0, count <= packetBytes, count <= rx.available else { return }
                for offset in 0..<count {
                    rx.append(C.readByte(endpoint, at: offset))
                }
            }
        } else if endpoint == bulkIn {
            if C.completedDuringLastCancellation(endpoint) {
                tx.remove(inFlightBytes)
                needsZeroPacket = inFlightBytes == packetBytes
                deferZeroPacket = needsZeroPacket
            }
            // If it was not ACKed, leave the prefix queued and retry it
            // after CLEAR_FEATURE re-enables this endpoint.
            transmitting = false
            inFlightBytes = 0
        }
    }

    mutating func service<C: USBDeviceControllerProtocol>(
        bulkIn: USB.EndpointAddress, bulkOut: USB.EndpointAddress,
        packetBytes: Int, controller: C.Type
    ) {
        // Configuration establishes/ends sessions after cancelling hardware.
        guard isConfigured else { return }
        let size = packetBytes
        // Leave OUT unarmed when full: the host receives NAK and retries.
        if !receiving, rx.available >= size, C.canSubmit(bulkOut) {
            receiving = C.submit(bulkOut, count: size)
        }
        guard !transmitting, C.canSubmit(bulkIn) else { return }
        if needsZeroPacket, tx.count > 0 {
            // Console may have queued the next bytes while the full packet was
            // in flight. Bulk data is a byte stream, so continue without a ZLP.
            needsZeroPacket = false
            deferZeroPacket = false
        }
        if needsZeroPacket, deferZeroPacket {
            // Give Console.poll() one pass to refill TX after the ACK. If no
            // bytes arrive, the next service pass closes this full-packet burst.
            deferZeroPacket = false
            return
        }
        let count = min(tx.count, size)
        guard count > 0 || needsZeroPacket else { return }
        for offset in 0..<count {
            C.writeByte(bulkIn, at: offset, value: tx.byte(at: offset))
        }
        if C.submit(bulkIn, count: count) {
            transmitting = true
            inFlightBytes = count
            // A full-packet burst ends with a ZLP only if TX stays empty.
            needsZeroPacket = count == size
            deferZeroPacket = false
        }
    }

    mutating func readByte() -> UInt8? { isConfigured ? rx.pop() : nil }
    mutating func tryWrite(byte: UInt8) -> Bool {
        isConfigured && tx.append(byte)
    }
    var isTransmitting: Bool { tx.count != 0 || transmitting || needsZeroPacket }
}
