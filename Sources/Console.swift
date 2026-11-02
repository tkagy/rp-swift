// Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
// SPDX-License-Identifier: MIT

protocol ConsoleTransport {
    mutating func poll()
    mutating func readByte() -> UInt8?
    /// Return false without waiting when the transmitter cannot accept a byte.
    mutating func tryWrite(byte: UInt8) -> Bool
    var isTransmitting: Bool { get }
}

/// One console broadcasts its prompt to all attached devices.
/// Initialize Timer first and call poll frequently from a single execution context.
/// Output is queued in fixed inline storage; poll never waits for UART TX space.
enum Console {
    // MARK: - Types

    enum RegistrationResult {
        case added, alreadyRegistered, full
    }

    // private static var devices: InlineArray<2, (any ConsoleTransport)?> = [nil, nil]
    // Storing Serial Device as any ConsoleTransport introduced heap allocation,
    // which this firmware does not support.
    // Use concrete enum cases to keep devices inline and avoid existential boxes 
    // and their heap allocation requirements.
    private enum SerialDevice: ConsoleTransport {
        case uart(UART)
        //case cdc(UsbCDC)
        func poll() {
            switch self {
            case .uart(let uart): uart.poll()
            //case .cdc(let cdc): cdc.poll()
            }
        }

        func readByte() -> UInt8? {
            switch self {
            case .uart(let uart): uart.readByte()
            //case .cdc(let cdc): cdc.readByte()
            }
        }

        func tryWrite(byte: UInt8) -> Bool {
            switch self {
            case .uart(let uart): uart.tryWrite(byte: byte)
            }
        }

        var isTransmitting: Bool {
            switch self {
            case .uart(let uart): uart.isTransmitting
            }
        }

        // Compare hardware identity, independent of each handle's configuration.
        func isSameDevice(as other: SerialDevice) -> Bool {
            switch (self, other) {
            case (.uart(let first), .uart(let second)):
                first.port == second.port
            }
        }
    }

    private enum Key {
        static let backspace: UInt8 = 0x08
        static let tab: UInt8 = 0x09
        static let lineFeed: UInt8 = 0x0A
        static let carriageReturn: UInt8 = 0x0D
        static let controlN: UInt8 = 0x0E
        static let controlP: UInt8 = 0x10
        static let escape: UInt8 = 0x1B
        static let space: UInt8 = 0x20
        static let lastPrintable: UInt8 = 0x7E
        static let delete: UInt8 = 0x7F
        static let csi: UInt8 = 0x5B // ESC [
        static let ss3: UInt8 = 0x4F // ESC O
        static let up: UInt8 = 0x41
        static let down: UInt8 = 0x42
        static let firstFinal: UInt8 = 0x40
        static let lastFinal: UInt8 = 0x7E
        static let firstParameter: UInt8 = 0x30
        static let lastParameter: UInt8 = 0x3F
        static let firstIntermediate: UInt8 = 0x20
        static let lastIntermediate: UInt8 = 0x2F
    }

    private enum EscapeState {
        case none, escape, cursor
    }

    private static let escapeTimeoutMicroseconds: UInt64 = 50_000
    private static let maximumEscapeBytes = 16
    private static let ioByteBudget = 32
    // A help response currently needs at most 20 fragments, including its prompt.
    // Reserve a complete response before consuming input; never discard output.
    private static let responseFragmentReserve = 24

    private typealias LineBytes = InlineArray<32, UInt8>

    private enum OutputFragment {
        case text(StaticString)
        case byte(UInt8)
        case line(LineBytes, Int)

        var count: Int {
            switch self {
            case .text(let text): text.utf8CodeUnitCount
            case .byte: 1
            case .line(_, let count): count
            }
        }

        func byte(at index: Int) -> UInt8 {
            switch self {
            case .text(let text): text.utf8Start[index]
            case .byte(let byte): byte
            case .line(let bytes, _): bytes[index]
            }
        }
    }

    private struct OutputBuffer {
        private var fragments = InlineArray<32, OutputFragment?>(repeating: nil)
        private var head = 0
        private var count = 0
        private var offset = 0

        var isEmpty: Bool { count == 0 }
        var available: Int { fragments.count - count }

        mutating func append(_ fragment: OutputFragment) {
            guard fragment.count > 0 else { return }
            precondition(available > 0, "Console output reservation exhausted")
            fragments[(head + count) % fragments.count] = fragment
            count += 1
        }

        mutating func poll(to device: SerialDevice) {
            var budget = Console.ioByteBudget
            while count > 0 && budget > 0 {
                guard let fragment = fragments[head] else { return }
                guard device.tryWrite(byte: fragment.byte(at: offset)) else { return }
                budget -= 1
                offset += 1
                if offset == fragment.count {
                    fragments[head] = nil
                    head = (head + 1) % fragments.count
                    count -= 1
                    offset = 0
                }
            }
        }
    }

    private struct ReceivedByte {
        let value: UInt8
        let time: UInt64
    }

    private struct ReceiveBuffer {
        private var bytes = InlineArray<128, UInt8>(repeating: 0)
        private var times = InlineArray<128, UInt64>(repeating: 0)
        private var head = 0
        private var count = 0
        private var skipDiscardedLineFeed = false
        private(set) var discarding = false
        var needsOverflowNotice = false

        var isEmpty: Bool { count == 0 }

        mutating func append(_ byte: UInt8, at time: UInt64) {
            if skipDiscardedLineFeed {
                skipDiscardedLineFeed = false
                if byte == Key.lineFeed { return }
            }
            if discarding {
                if byte == Key.carriageReturn || byte == Key.lineFeed {
                    discarding = false
                    skipDiscardedLineFeed = byte == Key.carriageReturn
                }
                return
            }
            guard count < bytes.count else {
                // Invalidate all queued input rather than executing a truncated command.
                head = 0
                count = 0
                needsOverflowNotice = true
                discarding = byte != Key.carriageReturn && byte != Key.lineFeed
                skipDiscardedLineFeed = byte == Key.carriageReturn
                return
            }
            let tail = (head + count) % bytes.count
            bytes[tail] = byte
            times[tail] = time
            count += 1
        }

        mutating func pop() -> ReceivedByte? {
            guard count > 0 else { return nil }
            let byte = ReceivedByte(value: bytes[head], time: times[head])
            head = (head + 1) % bytes.count
            count -= 1
            return byte
        }
    }

    private struct InputBuffer {
        private(set) var bytes = LineBytes(repeating: 0)
        private(set) var count = 0
        private(set) var overflow = false
        var skipLineFeed = false
        var escapeState: EscapeState = .none
        var escapeDeadline: UInt64? = nil
        var escapeByteCount = 0
        var escapeHasIntermediate = false
        var historyOffset: Int? = nil

        mutating func append(_ byte: UInt8) -> Bool {
            guard !overflow else { return false }
            guard count < bytes.count else {
                overflow = true
                return false
            }
            bytes[count] = byte
            count += 1
            return true
        }

        mutating func removeLast() -> Bool {
            guard count > 0 else { return false }
            // Excess bytes were not stored or echoed. Removing a visible byte
            // explicitly resumes editing the retained line after overflow.
            overflow = false
            count -= 1
            return true
        }

        mutating func clear() {
            self = InputBuffer()
        }

        mutating func clearEscape() {
            escapeState = .none
            escapeDeadline = nil
            escapeByteCount = 0
            escapeHasIntermediate = false
        }

        mutating func restore(_ entry: History.Entry) {
            bytes = entry.bytes
            count = entry.count
            overflow = false
        }

        // Treat the entered bytes as a case-sensitive command prefix for Tab completion.
        func isPrefix(of command: StaticString) -> Bool {
            guard count <= command.utf8CodeUnitCount else { return false }
            for index in 0..<count {
                if bytes[index] != command.utf8Start[index] { return false }
            }
            return true
        }

    }

    private enum History {
        struct Entry {
            let bytes: LineBytes
            let count: Int
        }

        // Nil initial values avoid lazy initialization and atomic runtime calls.
        // Index zero is newest; insertion drops the oldest entry when full.
        private static var entries: InlineArray<5, Entry?> = [nil, nil, nil, nil, nil]
        private(set) static var count: Int = 0

        static func add(_ input: InputBuffer) {
            for index in (1..<entries.count).reversed() {
                entries[index] = entries[index - 1]
            }
            entries[0] = Entry(bytes: input.bytes, count: input.count)
            count = min(count + 1, entries.count)
        }

        static func entry(at offset: Int) -> Entry? {
            guard offset >= 0 && offset < count else { return nil }
            return entries[offset]
        }
    }

    private enum Command: Int {
        // Keep raw values consecutive from zero so iteration needs no Array.
        case help, reset, bootsel

        var name: StaticString {
            switch self {
            case .help: "help"
            case .reset: "reset"
            case .bootsel: "bootsel"
            }
        }

        var description: StaticString {
            switch self {
            case .help: "Show supported commands"
            case .reset: "Restart the chip"
            case .bootsel: "Enter USB BOOTSEL mode"
            }
        }

        // Refer to static functions without capturing device or console state.
        // The caller supplies the input device index when invoking the handler.
        var handler: (Int) -> Void {
            switch self {
            case .help: Console.help(to:)
            case .reset: Console.reset(to:)
            case .bootsel: Console.bootsel(to:)
            }
        }

        // Compare input with this command's name exactly and case-sensitively,
        // without constructing a String or using custom comparison operators.
        private func matches(_ input: InputBuffer) -> Bool {
            let name = self.name
            guard input.count == name.utf8CodeUnitCount else { return false }
            for position in 0..<input.count {
                if input.bytes[position] != name.utf8Start[position] { return false }
            }
            return true
        }

        init?(_ input: InputBuffer) {
            var index = 0
            while let command = Command(rawValue: index), !command.matches(input) {
                index += 1
            }
            self.init(rawValue: index)
        }
    }

    private typealias SerialDeviceList = InlineArray<2, SerialDevice?>

    // MARK: - Stored properties

    private static var serialDevices: SerialDeviceList = [nil, nil]

    // Keep the static initial value as [nil, nil]. With the current compiler,
    // [InputBuffer(), InputBuffer()] generated a lazy, once-only initializer.
    // Its synchronization required __atomic_load_4, __atomic_compare_exchange_4,
    // and __atomic_store_4, which this RP2040 runtime does not provide.
    // Creating each buffer explicitly in add() avoids that initialization guard;
    // no atomic operations are needed for this static initialization.
    private static var inputBuffers: InlineArray<2, InputBuffer?> = [nil, nil]

    // Preserve each device's unfinished input while it browses shared history.
    private static var drafts: InlineArray<2, InputBuffer?> = [nil, nil]
    private static var outputBuffers: InlineArray<2, OutputBuffer?> = [nil, nil]
    private static var receiveBuffers: InlineArray<2, ReceiveBuffer?> = [nil, nil]
    private static var pendingCommands: InlineArray<2, Command?> = [nil, nil]
    private static var promptRequested: InlineArray<2, Bool> = [false, false]

    private static var nextDeviceIndex: Int = 0
    private static var name: StaticString = ""

    // MARK: - Public API

    /// Set only the prompt name after Timer initialization. Registrations are preserved.
    static func initialize(name: StaticString) {
        self.name = name
    }

    /// Register a transport and queue its prompt. Duplicate hardware is not reconfigured.
    @discardableResult
    static func add(_ device: UART) -> RegistrationResult {
        add(.uart(device))
    }

    /// Service both ports with bounded RX/TX work. Call frequently to drain queued I/O.
    /// UART writes must be owned by this console while a port is registered.
    static func poll() {
        let now = Timer.microseconds
        for index in serialDevices.indices {
            guard let device = serialDevices[index] else { continue }
            device.poll()
            drainOutput(to: index)

            for _ in 0..<ioByteBudget {
                guard let byte = device.readByte() else { break }
                receiveBuffers[index]?.append(byte, at: now)
            }

            if receiveBuffers[index]!.needsOverflowNotice,
               outputBuffers[index]!.available >= responseFragmentReserve,
               pendingCommands[index] == nil {
                inputBuffers[index]?.clear()
                drafts[index] = nil
                write("\r\nInput overflow. Line discarded.\r\n", to: index)
                prompt(to: index)
                receiveBuffers[index]?.needsOverflowNotice = false
            }

            if !receiveBuffers[index]!.needsOverflowNotice && pendingCommands[index] == nil {
                for _ in 0..<ioByteBudget {
                    guard outputBuffers[index]!.available >= responseFragmentReserve,
                          let byte = receiveBuffers[index]?.pop() else { break }
                    receive(byte.value, at: byte.time, from: index)
                    if pendingCommands[index] != nil { break }
                }
            }
            if receiveBuffers[index]!.isEmpty, var input = inputBuffers[index] {
                expireEscape(&input, at: now)
                inputBuffers[index] = input
            }
            if promptRequested[index], pendingCommands[index] == nil,
               outputBuffers[index]!.available >= responseFragmentReserve {
                if let input = inputBuffers[index] { redraw(input, to: index) }
                promptRequested[index] = false
            }
            drainOutput(to: index)
            finishPendingCommand(from: index)
        }
    }

    /// Request a redraw on each registered device; poll performs the queued output.
    static func prompt() {
        for index in serialDevices.indices {
            if serialDevices[index] != nil {
                promptRequested[index] = true
            }
        }
    }

    // MARK: - Registration and I/O

    private static func add(_ device: SerialDevice) -> RegistrationResult {
        for index in 0..<nextDeviceIndex {
            if let registered = serialDevices[index], registered.isSameDevice(as: device) {
                return .alreadyRegistered
            }
        }
        guard nextDeviceIndex < serialDevices.count else { return .full }
        serialDevices[nextDeviceIndex] = device
        // Initialize at registration time instead of in the static initializer above.
        inputBuffers[nextDeviceIndex] = InputBuffer()
        initializeOutput(at: nextDeviceIndex)
        initializeReceive(at: nextDeviceIndex)
        prompt(to: nextDeviceIndex)
        nextDeviceIndex += 1
        return .added
    }

    // Keep large initialization temporaries in separate stack frames. Combining
    // both constructors in add() exceeded the firmware's 4 KiB stack reservation.
    @inline(never)
    private static func initializeOutput(at deviceIndex: Int) {
        outputBuffers[deviceIndex] = OutputBuffer()
    }

    @inline(never)
    private static func initializeReceive(at deviceIndex: Int) {
        receiveBuffers[deviceIndex] = ReceiveBuffer()
    }

    private static func write(_ text: StaticString, to deviceIndex: Int) {
        outputBuffers[deviceIndex]?.append(.text(text))
    }

    private static func write(byte: UInt8, to deviceIndex: Int) {
        outputBuffers[deviceIndex]?.append(.byte(byte))
    }

    private static func drainOutput(to deviceIndex: Int) {
        guard let device = serialDevices[deviceIndex] else { return }
        outputBuffers[deviceIndex]?.poll(to: device)
    }

    // Queue immutable prompt/input fragments; UART transmission happens in poll().
    private static func prompt(_ input: InputBuffer? = nil, to deviceIndex: Int) {
        write(name, to: deviceIndex)
        write(" >> ", to: deviceIndex)
        if let input = input {
            outputBuffers[deviceIndex]?.append(.line(input.bytes, input.count))
        }
    }

    // MARK: - Input handling

    private static func receive(_ byte: UInt8, at time: UInt64, from deviceIndex: Int) {
        guard var input = inputBuffers[deviceIndex] else { return }
        defer { inputBuffers[deviceIndex] = input }
        expireEscape(&input, at: time)

        let skipLineFeed = input.skipLineFeed
        input.skipLineFeed = false
        if byte == Key.lineFeed && skipLineFeed { return }

        if byte == Key.carriageReturn || byte == Key.lineFeed {
            input.clearEscape()
        } else if byte == Key.escape {
            input.clearEscape()
            input.escapeState = .escape
            input.escapeDeadline = time &+ escapeTimeoutMicroseconds
            return
        } else if input.escapeState != .none,
                  receiveEscape(byte, input: &input, from: deviceIndex) {
            return
        }

        switch byte {
        case Key.controlP:
            previousHistory(&input, to: deviceIndex)

        case Key.controlN:
            nextHistory(&input, to: deviceIndex)

        case Key.tab:
            complete(&input, to: deviceIndex)

        case Key.carriageReturn, Key.lineFeed:
            processLine(&input, from: deviceIndex)
            input.skipLineFeed = byte == Key.carriageReturn

        case Key.backspace, Key.delete:
            if input.removeLast() {
                detachHistory(&input, from: deviceIndex)
                write("\u{08} \u{08}", to: deviceIndex)
            }

        case Key.space...Key.lastPrintable:
            if input.append(byte) {
                detachHistory(&input, from: deviceIndex)
                write(byte: byte, to: deviceIndex)
            } else if input.overflow {
                detachHistory(&input, from: deviceIndex)
            }

        default:
            break
        }
    }

    private static func processLine(_ input: inout InputBuffer, from deviceIndex: Int) {
        write("\r\n", to: deviceIndex)
        if input.overflow {
            write("Line too long.\r\n", to: deviceIndex)
        } else {
            remember(input, from: deviceIndex)
            command(input, from: deviceIndex)
        }
        drafts[deviceIndex] = nil
        input.clear()
        if pendingCommands[deviceIndex] == nil { prompt(to: deviceIndex) }
    }

    private static func expireEscape(_ input: inout InputBuffer, at time: UInt64) {
        if let deadline = input.escapeDeadline, Timer.hasReached(deadline: deadline, at: time) {
            input.clearEscape()
        }
    }

    // True consumes a sequence byte. False reprocesses the byte as normal input.
    private static func receiveEscape(_ byte: UInt8, input: inout InputBuffer, from deviceIndex: Int) -> Bool {
        switch input.escapeState {
        case .escape:
            if byte == Key.csi || byte == Key.ss3 {
                input.escapeState = .cursor
                return true
            }
            input.clearEscape()
            return false
        case .cursor:
            input.escapeByteCount += 1
            guard input.escapeByteCount <= maximumEscapeBytes else {
                input.clearEscape()
                return false
            }
            if byte >= Key.firstParameter && byte <= Key.lastParameter && !input.escapeHasIntermediate {
                return true
            }
            if byte >= Key.firstIntermediate && byte <= Key.lastIntermediate {
                input.escapeHasIntermediate = true
                return true
            }
            guard byte >= Key.firstFinal && byte <= Key.lastFinal else {
                input.clearEscape()
                return false
            }
            let hasIntermediate = input.escapeHasIntermediate
            input.clearEscape()
            // Consume unsupported sequences without turning their bytes into commands.
            guard !hasIntermediate else { return true }
            if byte == Key.up {
                previousHistory(&input, to: deviceIndex)
            } else if byte == Key.down {
                nextHistory(&input, to: deviceIndex)
            }
            return true
        case .none:
            return false
        }
    }

    private static func detachHistory(_ input: inout InputBuffer, from deviceIndex: Int) {
        input.historyOffset = nil
        drafts[deviceIndex] = nil
    }

    private static func remember(_ input: InputBuffer, from deviceIndex: Int) {
        guard input.count > 0 else { return }
        History.add(input)

        // New entries shift the other device's browsing position with its entry.
        // If an entry is evicted, retain the displayed line as independent input.
        // This also avoids writing into the other port's potentially full TX queue.
        for index in inputBuffers.indices where index != deviceIndex {
            guard var otherInput = inputBuffers[index],
                  let offset = otherInput.historyOffset else { continue }
            let shiftedOffset = offset + 1
            if shiftedOffset < History.count {
                otherInput.historyOffset = shiftedOffset
            } else {
                detachHistory(&otherInput, from: index)
            }
            inputBuffers[index] = otherInput
        }
    }

    private static func previousHistory(_ input: inout InputBuffer, to deviceIndex: Int) {
        let offset = input.historyOffset.map { $0 + 1 } ?? 0
        guard offset < History.count else { return }
        if input.historyOffset == nil {
            drafts[deviceIndex] = input
        }
        showHistory(&input, at: offset, to: deviceIndex)
    }

    private static func nextHistory(_ input: inout InputBuffer, to deviceIndex: Int) {
        guard let offset = input.historyOffset else { return }
        if offset > 0 {
            showHistory(&input, at: offset - 1, to: deviceIndex)
            return
        }
        input = drafts[deviceIndex] ?? InputBuffer()
        drafts[deviceIndex] = nil
        redraw(input, to: deviceIndex)
    }

    private static func showHistory(_ input: inout InputBuffer, at offset: Int, to deviceIndex: Int) {
        guard let entry = History.entry(at: offset) else { return }
        // Restore only the line; terminal parsing and browsing state are per device.
        input.restore(entry)
        input.historyOffset = offset
        redraw(input, to: deviceIndex)
    }

    private static func redraw(_ input: InputBuffer, to deviceIndex: Int) {
        write("\r\u{1B}[2K", to: deviceIndex)
        prompt(input, to: deviceIndex)
    }

    private static func complete(_ input: inout InputBuffer, to deviceIndex: Int) {
        guard !input.overflow else { return }
        var match: StaticString? = nil
        var index = 0
        while let command = Command(rawValue: index) {
            index += 1
            guard input.isPrefix(of: command.name) else { continue }
            if match != nil {
                showCompletions(input, to: deviceIndex)
                return
            }
            match = command.name
        }

        guard let match = match, match.utf8CodeUnitCount <= input.bytes.count else { return }
        // Append only the missing bytes; Tab never executes the command.
        if input.count < match.utf8CodeUnitCount { detachHistory(&input, from: deviceIndex) }
        while input.count < match.utf8CodeUnitCount {
            let byte = match.utf8Start[input.count]
            guard input.append(byte) else { return }
            write(byte: byte, to: deviceIndex)
        }
    }

    private static func showCompletions(_ input: InputBuffer, to deviceIndex: Int) {
        write("\r\n", to: deviceIndex)
        var index = 0
        while let command = Command(rawValue: index) {
            index += 1
            if input.isPrefix(of: command.name) {
                write(command.name, to: deviceIndex)
                write("\r\n", to: deviceIndex)
            }
        }
        // Restore the prompt and current input after displaying candidates.
        prompt(input, to: deviceIndex)
    }

    // MARK: - Commands

    private static func command(_ input: InputBuffer, from deviceIndex: Int) {
        guard input.count != 0 else { return }
        guard let command = Command(input) else {
            write("Unknown command. Type help.\r\n", to: deviceIndex)
            return
        }
        command.handler(deviceIndex)
    }

    private static func help(to deviceIndex: Int) {
        write("Commands:\r\n", to: deviceIndex)
        var index = 0
        while let command = Command(rawValue: index) {
            write("  ", to: deviceIndex)
            write(command.name, to: deviceIndex)
            write(" : ", to: deviceIndex)
            write(command.description, to: deviceIndex)
            write("\r\n", to: deviceIndex)
            index += 1
        }
    }

    private static func reset(to deviceIndex: Int) {
        write("Resetting...\r\n", to: deviceIndex)
        pendingCommands[deviceIndex] = .reset
    }

    private static func bootsel(to deviceIndex: Int) {
        write("Entering USB BOOTSEL mode...\r\n", to: deviceIndex)
        pendingCommands[deviceIndex] = .bootsel
    }

    private static func finishPendingCommand(from deviceIndex: Int) {
        guard let command = pendingCommands[deviceIndex],
              outputBuffers[deviceIndex]!.isEmpty,
              let device = serialDevices[deviceIndex], !device.isTransmitting else { return }
        pendingCommands[deviceIndex] = nil
        // Wait for FIFO and shift-register completion via later polls, never flush().
        switch command {
        case .reset:
            if !Chip.BootControl.reset() {
                write("Reset unavailable or rejected.\r\n", to: deviceIndex)
            }
        case .bootsel:
            if !Chip.BootControl.enterBOOTSEL() {
                write("USB BOOTSEL unavailable or rejected.\r\n", to: deviceIndex)
            }
        case .help:
            break
        }
        prompt(to: deviceIndex)
    }
}
