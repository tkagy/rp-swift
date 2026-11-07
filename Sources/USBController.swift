// Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
// SPDX-License-Identifier: MIT

// RP2040/RP2350 USB peripheral driver. The current implementation controls
// Device mode only: endpoint tables, DPRAM ownership and transfers.
enum USBController {
    private typealias register = RP2.Register32
    private typealias spec = Chip.USBController

    enum Mode: Equatable { case device }
    /// Choose whether Device attachment trusts VBUS or samples the PHY signal.
    enum VBUSDetection { case assumePresent, sense }

    /// A captured hardware event batch. Reset/detach supersede stale transfers.
    struct DeviceEvents {
        var vbusPresent: Bool? = nil
        var disconnected = false
        var reset = false
        var setup: USB.SetupPacket? = nil
        // Bit 2*n is endpoint n IN; bit 2*n+1 is endpoint n OUT.
        var completed: UInt32 = 0
        var suspendChanged = false
        var isSuspended = false

        static let endpointCount = 16
        static let slotCount = endpointCount * 2
        static func slot(for endpoint: USB.EndpointAddress) -> Int {
            Int(endpoint.number) * 2 + (endpoint.direction == .in ? 0 : 1)
        }
        static func mask(for endpoint: USB.EndpointAddress) -> UInt32 {
            UInt32(1) << slot(for: endpoint)
        }
        static func endpoint(forSlot slot: Int) -> USB.EndpointAddress {
            precondition(slot >= 0 && slot < slotCount)
            return USB.EndpointAddress(UInt8(slot / 2), slot % 2 == 0 ? .in : .out)
        }
        static let controlMask = mask(for: .controlIn) | mask(for: .controlOut)
    }

    // Use the chip's packet-size policy for descriptors and endpoint setup.
    static let bulkPacketBytes = spec.bulkPacketBytes

    // DPRAM slot capacity; the Device's EP0 and Bulk policies are separate.
    static let packetBytes = 64

    enum ErrorCode: UInt32 {
        case none = 0, alreadyInitialized, alreadyOwned, clockFailure
        case resetDidNotComplete, unsupportedRevision, endpointAbortTimedOut
    }
    struct FailureSnapshot {
        let address: UInt32
        let value: UInt32
    }
    private static var isClaimed = false
    private static var isDeviceStackClaimed = false
    static var maximumBulkPacketBytes: Int { Self.bulkPacketBytes }
    static var isDeviceMode: Bool { mode == .device }
    private(set) static var failureSnapshot: FailureSnapshot? = nil
    private(set) static var status: ErrorCode = .none
    private(set) static var isInitialized = false
    private(set) static var mode: Mode? = nil
    private static let registerBase: UInt32 = 0x5011_0000
    private static let dpramBase: UInt32 = 0x5010_0000
    private static let dpramBytes: UInt32 = 4096
    private static let maxPollCount = 10_000
    private enum Registers {
        static let main = register(address: registerBase + 0x40)
        static let sofRead = register(address: registerBase + 0x48)
        static let sieControl = register(address: registerBase + 0x4C)
        static let sieStatus = register(address: registerBase + 0x50)
        static let mux = register(address: registerBase + 0x74)
        static let power = register(address: registerBase + 0x78)
        static let interruptEnable = register(address: registerBase + 0x90)
        static let rawInterrupts = register(address: registerBase + 0x8C)
        static let reset = register(address: Chip.Reset.base)
        static let resetDone = register(address: Chip.Reset.base + Chip.Reset.doneOffset)
    }

    private static func initializeHardware(vbusDetection: USBController.VBUSDetection) -> Bool {
        Registers.reset.setBits(Chip.Reset.usb)
        Registers.reset.clearBits(Chip.Reset.usb)
        var ready = false
        var lastValue: UInt32 = 0
        for _ in 0..<Self.maxPollCount {
            lastValue = Registers.resetDone.value
            if lastValue & Chip.Reset.usb != 0 { ready = true; break }
        }
        guard ready else {
            Registers.reset.setBits(Chip.Reset.usb)
            status = .resetDidNotComplete
            failureSnapshot = .init(address: Registers.resetDone.address, value: lastValue)
            return false
        }
        Registers.interruptEnable.value = 0
        Registers.main.value = 0
        Registers.sieControl.value = 0
        for offset in stride(from: UInt32(0), to: Self.dpramBytes, by: 4) {
            register(address: Self.dpramBase + offset).value = 0
        }
        let toPHY: UInt32 = 1 << 0
        let softwareConnect: UInt32 = 1 << 3
        let vbusPresent: UInt32 = 1 << 2
        let overrideVBUS: UInt32 = 1 << 3
        Registers.mux.value = toPHY | softwareConnect
        Registers.power.value = vbusDetection == .assumePresent ? vbusPresent | overrideVBUS : 0
        status = .none
        return true
    }

    static func stop() {
        guard isInitialized else {
            isDeviceStackClaimed = false
            return
        }
        requireOwnership()
        Self.shutdownHardware()
        isInitialized = false
        mode = nil
        isVBUSPresent = false
        wasConnected = false
        isDeviceStackClaimed = false
        Self.isClaimed = false
    }

    static func claimDeviceStack() -> Bool {
        guard isInitialized, isDeviceMode, !isDeviceStackClaimed else { return false }
        isDeviceStackClaimed = true
        return true
    }

    static func releaseDeviceStack() {
        isDeviceStackClaimed = false
    }

    private static func shutdownHardware() {
        Registers.interruptEnable.value = 0
        Registers.sieControl.value = 0
        Registers.main.value = 0
        Registers.reset.setBits(Chip.Reset.usb)
    }

    private static func requireOwnership() {
        precondition(SIO.core == .core0, "Use USB on Core 0")
        precondition(isInitialized && Self.isClaimed, "Initialize and own USB before accessing hardware")
    }

    // Only the device controller maps an endpoint to BUFF_STATUS/DPRAM.
    // Host endpoints identify remote devices and use a different layout.
    static func slot(for endpoint: USB.EndpointAddress) -> Int {
        USBController.DeviceEvents.slot(for: endpoint)
    }
    static func mask(for endpoint: USB.EndpointAddress) -> UInt32 { UInt32(1) << slot(for: endpoint) }
    private static let slotCount = USBController.DeviceEvents.slotCount
    private static let endpointTable: UInt32 = 0x08
    private static let bufferTable: UInt32 = 0x80
    private static let controlData: UInt32 = 0x100
    private static let endpointData: UInt32 = 0x180
    private static let endpointEnabled: UInt32 = 1 << 31
    private static let bufferInterrupt: UInt32 = 1 << 29
    private static let typeShift: UInt32 = 26
    private static let available: UInt32 = 1 << 10
    private static let stall: UInt32 = 1 << 11
    private static let data1: UInt32 = 1 << 13
    private static let full: UInt32 = 1 << 15
    private static let lengthMask: UInt32 = 0x3FF
    private static let controllerEnabled: UInt32 = 1
    private static let ep0BufferInterrupt: UInt32 = 1 << 29
    private static let pullup: UInt32 = 1 << 16
    private static let busReset: UInt32 = 1 << 19
    private static let setupReceived: UInt32 = 1 << 17
    private static let suspended: UInt32 = 1 << 4
    private static let resumed: UInt32 = 1 << 11
    private static let resetInterrupt: UInt32 = 1 << 12
    private static let setupInterrupt: UInt32 = 1 << 16
    private static let suspendInterrupt: UInt32 = 1 << 14
    private static let resumeInterrupt: UInt32 = 1 << 15
    private static let connectionInterrupt: UInt32 = 1 << 13
    private static let deviceStartOfFrame: UInt32 = 1 << 17
    private static let connected: UInt32 = 1 << 16
    private static let vbusDetected: UInt32 = 1 << 0
#if RP2040
    // RP2040 datasheet, Appendix B (RP2040-E15):
    // https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf
    // do not make Bulk IN buffers available during the final 200 us of a
    // full-speed frame. The device observes SOF through its polled event path;
    // this is a native implementation of the documented timing workaround.
    private static let frameDurationMicroseconds: UInt64 = 1_000
    private static let e15QuietPeriodMicroseconds: UInt64 = 200
    private static let e15SubmissionWindowMicroseconds =
        frameDurationMicroseconds - e15QuietPeriodMicroseconds
    private static var previousEventPollTime: UInt64? = nil
    private static var lastStartOfFrameTime: UInt64? = nil
#endif
    private static var vbusDetection: USBController.VBUSDetection = .assumePresent
    private(set) static var isVBUSPresent = false
    private static var wasConnected = false

    private static let address = register(address: Self.registerBase)
    private static let bufferStatus = register(address: Self.registerBase + 0x58)
    private static let abort = register(address: Self.registerBase + 0x60)
    private static let abortDone = register(address: Self.registerBase + 0x64)
    private static let stallArm = register(address: Self.registerBase + 0x68)

    private struct EndpointState {
        var enabled = false
        var busy = false
        var nextData1 = false
        var halted = false
        var transferType: USB.TransferType = .control
        var maximumPacket = USBController.packetBytes
        var completedCount = 0
        var completedDuringCancellation = false
    }
    private static var endpoints: InlineArray<32, EndpointState> = .init { _ in EndpointState() }

    static func initialize(mode: Mode, vbusDetection: USBController.VBUSDetection) -> Bool {
        precondition(SIO.core == .core0, "Initialize USB on Core 0")
        guard !isInitialized else { status = .alreadyInitialized; return false }
        guard !Self.isClaimed else { status = .alreadyOwned; return false }
        failureSnapshot = nil
        #if RP2040
        // Device abort/reset errata RP2040-E2/E5 require B2 or later for
        // this implementation. A future Host driver chooses its own policy.
        let chipID = register(address: 0x4000_0000).value
        guard chipID >> 28 >= 2 else {
            status = .unsupportedRevision
            return false
        }
        #endif
        guard Clock.initializeUSB() else { status = .clockFailure; return false }
        // Core 0 only: claim before touching shared hardware. Roll back on failure.
        Self.isClaimed = true
        guard initializeHardware(vbusDetection: vbusDetection) else {
            Self.isClaimed = false
            return false
        }
        isInitialized = true
        self.mode = mode
        self.vbusDetection = vbusDetection
        switch mode {
        case .device: prepareHardware()
        }
        return true
    }

    static func restart() -> Bool {
        requireOwnership()
        failureSnapshot = nil
        guard isInitialized, initializeHardware(vbusDetection: vbusDetection) else { return false }
        prepareHardware()
        return true
    }

    private static func prepareHardware() {
        resetEndpoints()
        Registers.main.value = Self.controllerEnabled
        Registers.sieControl.value = Self.ep0BufferInterrupt
        let status = Registers.sieStatus.value
        isVBUSPresent = vbusDetection == .assumePresent || status & Self.vbusDetected != 0
        wasConnected = status & Self.connected != 0
    }

    static func connect() {
        requireOwnership()
        if isVBUSPresent { Registers.sieControl.value |= Self.pullup }
    }

    static func disconnect() {
        requireOwnership()
        Registers.sieControl.value &= ~Self.pullup
    }

    static func captureEvents() -> USBController.DeviceEvents {
        requireOwnership()
        var events = USBController.DeviceEvents()
        let raw = Registers.rawInterrupts.value
        let status = Registers.sieStatus.value
#if RP2040
        let pollTime = Timer.microseconds
        if raw & Self.deviceStartOfFrame != 0 {
            // SOF arrived between the previous and current poll. Use the
            // earlier sample, so the quiet period begins conservatively early.
            lastStartOfFrameTime = previousEventPollTime
            // INTR.DEV_SOF is read-only; the datasheet specifies that reading
            // SOF_RD clears the pending SOF event.
            _ = Registers.sofRead.value
        }
        previousEventPollTime = pollTime
#endif
        if vbusDetection == .sense {
            let present = status & Self.vbusDetected != 0
            if present != isVBUSPresent { events.vbusPresent = present }
            isVBUSPresent = present
        }
        if raw & Self.connectionInterrupt != 0 {
            let nowConnected = status & Self.connected != 0
            // When VBUS is assumed present, a cable removal is indistinguishable
            // from suspend. Physical detach handling requires .sense mode.
            events.disconnected = vbusDetection == .sense && wasConnected && !nowConnected
                && raw & Self.resetInterrupt == 0
            wasConnected = nowConnected
            Registers.sieStatus.value = Self.connected
        }
        // Detach supersedes all old buffer/status/SETUP events. Device will
        // reset hardware before touching any controller-owned buffer.
        if !isVBUSPresent || events.disconnected { return events }
        if raw & Self.resetInterrupt != 0 {
            Registers.sieStatus.value = Self.busReset
            Self.bufferStatus.value = UInt32.max
            // A SETUP delivered after this snapshot is left for the next
            // poll. Never acknowledge a newer SETUP without reading it.
            events.reset = true
            return events
        }
        if raw & Self.setupInterrupt != 0 {
            let word0 = register(address: Self.dpramBase).value
            let word1 = register(address: Self.dpramBase + 4).value
            events.setup = USB.SetupPacket(word0: word0, word1: word1)
            Registers.sieStatus.value = Self.setupReceived
        }
        events.completed = Self.bufferStatus.value
        Self.bufferStatus.value = events.completed
        for slot in 0..<Self.slotCount where events.completed & (UInt32(1) << slot) != 0 {
            endpoints[slot].busy = false
            endpoints[slot].completedCount = Int(bufferRegister(slot: slot).value & Self.lengthMask)
        }
        if raw & (Self.suspendInterrupt | Self.resumeInterrupt) != 0 {
            events.suspendChanged = true
            events.isSuspended = Registers.sieStatus.value & Self.suspended != 0
            Registers.sieStatus.value = Self.suspended | Self.resumed
        }
        return events
    }

    static func resetEndpoints() {
        requireOwnership()
#if RP2040
        previousEventPollTime = nil
        lastStartOfFrameTime = nil
#endif
        Self.address.value = 0
        Self.abort.value = 0
        Self.abortDone.value = UInt32.max
        Self.stallArm.value = 0
        Self.bufferStatus.value = UInt32.max
        for slot in 0..<Self.slotCount {
            endpoints[slot] = EndpointState()
            bufferRegister(slot: slot).value = 0
            if slot >= 2 { endpointRegister(slot: slot).value = 0 }
        }
        endpoints[slot(for: .controlIn)].enabled = true
        endpoints[slot(for: .controlOut)].enabled = true
    }

    static func setAddress(_ value: UInt8) {
        requireOwnership()
        precondition(value <= 127)
        Self.address.value = UInt32(value)
    }

    static func configure(_ endpoint: USB.EndpointAddress, type: USB.TransferType, maximumPacket: Int) {
        requireOwnership()
        precondition(endpoint.number != 0 && maximumPacket > 0 && maximumPacket <= USBController.packetBytes)
        precondition(!isBusy(endpoint), "Cancel an endpoint before configuring it")
        precondition(type == .bulk || type == .interrupt,
                     "Only nonzero Bulk and Interrupt endpoints are implemented")
        if type == .bulk {
            precondition(maximumPacket == 8 || maximumPacket == 16 || maximumPacket == 32 || maximumPacket == 64)
            precondition(maximumPacket <= maximumBulkPacketBytes,
                         "Bulk packet size exceeds the controller errata policy")
        }
        endpoints[slot(for: endpoint)] = EndpointState(
            enabled: true, transferType: type, maximumPacket: maximumPacket
        )
        bufferRegister(slot: slot(for: endpoint)).value = 0
        endpointRegister(slot: slot(for: endpoint)).value = Self.endpointEnabled | Self.bufferInterrupt
            | (type.rawValue << Self.typeShift) | dataOffset(endpoint)
    }

    static func isBusy(_ endpoint: USB.EndpointAddress) -> Bool {
        isInitialized && endpoints[slot(for: endpoint)].busy
    }
    static func isHalted(_ endpoint: USB.EndpointAddress) -> Bool {
        isInitialized && endpoints[slot(for: endpoint)].halted
    }

    static func canSubmit(_ endpoint: USB.EndpointAddress) -> Bool {
        let state = endpoints[slot(for: endpoint)]
        guard isInitialized && state.enabled && !state.busy && !state.halted else { return false }
#if RP2040
        if endpoint.direction == .in && state.transferType == .bulk {
            // Fail closed until SOF has been observed and after a missed frame.
            guard let lastStartOfFrameTime else { return false }
            let elapsed = Timer.microseconds &- lastStartOfFrameTime
            return elapsed < Self.e15SubmissionWindowMicroseconds
        }
#endif
        return true
    }

    // Revocation uses the device abort handshake, never a CPU overwrite of
    // a controller-owned buffer. B0/B1 are rejected at acquisition (E2).
    static func cancel(mask: UInt32) -> Bool {
        requireOwnership()
        Self.abort.value |= mask
        var done = false
        var lastValue: UInt32 = 0
        for _ in 0..<Self.maxPollCount {
            lastValue = Self.abortDone.value
            if lastValue & mask == mask { done = true; break }
        }
        guard done else {
            status = .endpointAbortTimedOut
            failureSnapshot = .init(address: Self.abortDone.address, value: lastValue)
            return false
        }
        // A packet can finish between the snapshot and abort handshake. Only
        // roll back the optimistic PID for buffers that were never ACKed.
        // Preserve whether an ACK raced with cancellation so the Device stack
        // can retire only completed data and safely retry the rest.
        let completed = Self.bufferStatus.value & mask
        for slot in 0..<Self.slotCount where mask & (UInt32(1) << slot) != 0 {
            endpoints[slot].completedDuringCancellation = completed & (UInt32(1) << slot) != 0
            // submit() advances the software PID optimistically. A revoked
            // buffer that was never ACKed must reuse its original PID when
            // the channel resumes without an endpoint reset (e.g. DTR).
            if endpoints[slot].busy, completed & (UInt32(1) << slot) == 0 {
                endpoints[slot].nextData1.toggle()
            }
            endpoints[slot].completedCount = Int(bufferRegister(slot: slot).value & Self.lengthMask)
            bufferRegister(slot: slot).value = endpoints[slot].halted ? Self.stall : 0
            endpoints[slot].busy = false
        }
        Self.bufferStatus.value = mask
        Self.abort.value &= ~mask
        Self.abortDone.value = mask
        return true
    }

    static func beginControl() -> Bool {
        requireOwnership()
        guard cancel(mask: mask(for: .controlIn) | mask(for: .controlOut)) else { return false }
        Self.stallArm.value = 0
        for slot in 0..<2 {
            endpoints[slot].halted = false
            endpoints[slot].nextData1 = true // First data/status after SETUP is DATA1.
        }
        return true
    }

    static func disableFunctions() -> Bool {
        requireOwnership()
        guard cancel(mask: ~USBController.DeviceEvents.controlMask) else { return false }
        for slot in 2..<Self.slotCount {
            endpoints[slot] = EndpointState()
            endpointRegister(slot: slot).value = 0
        }
        return true
    }

    static func halt(_ endpoint: USB.EndpointAddress, enabled: Bool) -> Bool {
        requireOwnership()
        guard cancel(mask: mask(for: endpoint)) else { return false }
        endpoints[slot(for: endpoint)].halted = enabled
        if !enabled { endpoints[slot(for: endpoint)].nextData1 = false }
        bufferRegister(slot: slot(for: endpoint)).value = enabled ? Self.stall : 0
        return true
    }

    static func stallControl() {
        requireOwnership()
        Self.stallArm.value = mask(for: .controlIn) | mask(for: .controlOut)
        bufferRegister(slot: slot(for: .controlIn)).value = Self.stall
        bufferRegister(slot: slot(for: .controlOut)).value = Self.stall
    }

    // Caller prepares IN data only while !busy, then hands off exactly once.
    @discardableResult
    static func submit(_ endpoint: USB.EndpointAddress, count: Int) -> Bool {
        requireOwnership()
        let slot = slot(for: endpoint)
        guard canSubmit(endpoint) else { return false }
        precondition(count >= 0 && count <= endpoints[slot].maximumPacket)
        let info = UInt32(count) | (endpoints[slot].nextData1 ? Self.data1 : 0)
            | (endpoint.direction == .in ? Self.full : 0)
        let reg = bufferRegister(slot: slot)
        Memory.barrier()
        reg.value = info
        // Two non-elidable peripheral reads exceed one clk_usb period at
        // the supported 125/150 MHz clocks, including bus/accessor overhead.
        // AVAILABLE must be a separate write (RP2040 4.1.2.7.1).
        _ = Registers.sieStatus.value
        _ = Registers.sieStatus.value
        // Check at the handoff point too: the initial eligibility check and
        // the DPRAM setup above may have crossed into the quiet period.
        guard canSubmit(endpoint) else { return false }
        reg.value = info | Self.available
        endpoints[slot].busy = true
        endpoints[slot].nextData1.toggle()
        return true
    }

    static func receivedCount(_ endpoint: USB.EndpointAddress) -> Int {
        endpoints[slot(for: endpoint)].completedCount
    }

    static func completedDuringLastCancellation(_ endpoint: USB.EndpointAddress) -> Bool {
        endpoints[slot(for: endpoint)].completedDuringCancellation
    }

    static func readByte(_ endpoint: USB.EndpointAddress, at index: Int) -> UInt8 {
        requireOwnership()
        let state = endpoints[slot(for: endpoint)]
        precondition(state.enabled && !state.busy, "Read DPRAM only after transfer completion")
        precondition(endpoint.direction == .out && index >= 0 && index < state.completedCount)
        let reg = register(address: Self.dpramBase + dataOffset(endpoint) + UInt32(index & ~3))
        return UInt8(truncatingIfNeeded: reg.value >> ((index & 3) * 8))
    }

    static func writeByte(_ endpoint: USB.EndpointAddress, at index: Int, value: UInt8) {
        requireOwnership()
        let state = endpoints[slot(for: endpoint)]
        precondition(state.enabled && !state.busy, "Write DPRAM only before transfer submission")
        precondition(endpoint.direction == .in && index >= 0 && index < state.maximumPacket)
        let reg = register(address: Self.dpramBase + dataOffset(endpoint) + UInt32(index & ~3))
        let shift = (index & 3) * 8
        reg.value = (reg.value & ~(UInt32(0xFF) << shift)) | (UInt32(value) << shift)
    }

    private static func dataOffset(_ endpoint: USB.EndpointAddress) -> UInt32 {
        if endpoint.number == 0 { return Self.controlData }
        // One 64-byte aligned slot per direction; Host uses a different map.
        return Self.endpointData + UInt32(slot(for: endpoint) - 2) * UInt32(USBController.packetBytes)
    }
    private static func bufferRegister(slot: Int) -> register {
        register(address: Self.dpramBase + Self.bufferTable + UInt32(slot) * 4)
    }
    private static func endpointRegister(slot: Int) -> register {
        register(address: Self.dpramBase + Self.endpointTable + UInt32(slot - 2) * 4)
    }
}
