import Foundation

struct SessionRestorationArchive: Codable, Equatable {
    var selectedWorkspaceID: UUID?
    var sessions: [RestorableSessionSnapshot]
}

struct RestorableSessionSnapshot: Codable, Equatable {
    let workspaceID: UUID
    let remoteID: UUID
    let sessionNumber: Int
    let customName: String?
    let mode: WorkspaceMode
    let localPath: String
    let remotePath: String
    let terminalDirectory: String?
    let terminalBuffer: Data?
    let pendingCommand: String?
    var multiplexer: TerminalMultiplexer? = nil
}

enum SessionRestorationStore {
    static let maximumBufferBytes = 16_777_216

    private static var fileURL: URL {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("ShellHarbor", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent(
            "session-restoration.json"
        )
    }

    static func load() -> SessionRestorationArchive? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(
            SessionRestorationArchive.self,
            from: data
        )
    }

    static func save(_ archive: SessionRestorationArchive) {
        guard !archive.sessions.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(archive) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func limitedBuffer(_ data: Data) -> Data {
        guard data.count > maximumBufferBytes else { return data }
        var suffix = Data(data.suffix(maximumBufferBytes))
        if let newline = suffix.firstIndex(of: 0x0A) {
            suffix.removeSubrange(suffix.startIndex...newline)
        }
        return suffix
    }

    /// `getBufferAsData` serializes each terminal row with LF only. Feeding
    /// that text back into a terminal whose newline mode is disabled advances
    /// the row without returning to column zero, producing staircase output.
    static func replayBuffer(_ data: Data) -> Data {
        var replay = Data()
        replay.reserveCapacity(data.count)
        var previousByte: UInt8?
        for byte in data {
            if byte == 0x0A, previousByte != 0x0D {
                replay.append(0x0D)
            }
            replay.append(byte)
            previousByte = byte
        }
        return replay
    }
}

struct PendingTerminalInput: Equatable {
    private(set) var text = ""
    private(set) var isReliable = true
    private var cursorOffset = 0

    mutating func restore(_ value: String?) {
        text = value ?? ""
        cursorOffset = text.count
        isReliable = true
    }

    @discardableResult
    mutating func record(_ bytes: [UInt8]) -> [String] {
        var submittedCommands: [String] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x1B {
                let remaining = Array(bytes[index...])
                if let consumed = handleEscapeSequence(remaining) {
                    index += consumed
                    continue
                }
                isReliable = false
                index += 1
                continue
            }

            switch byte {
            case 0x0A, 0x0D, 0x03:
                if
                    byte != 0x03,
                    isReliable,
                    !text.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                {
                    submittedCommands.append(text)
                }
                clear()
                index += 1
            case 0x7F, 0x08:
                removeBeforeCursor()
                index += 1
            case 0x01:
                cursorOffset = 0
                index += 1
            case 0x05:
                cursorOffset = text.count
                index += 1
            case 0x04:
                removeAtCursor()
                index += 1
            case 0x15:
                clear()
                index += 1
            case 0x17:
                removePreviousWord()
                index += 1
            case 0x09:
                isReliable = false
                index += 1
            case 0x00...0x1F:
                index += 1
            default:
                let start = index
                while
                    index < bytes.count,
                    bytes[index] >= 0x20,
                    bytes[index] != 0x7F,
                    bytes[index] != 0x1B
                {
                    index += 1
                }
                let value = String(
                    decoding: bytes[start..<index],
                    as: UTF8.self
                )
                insert(value)
            }
        }
        return submittedCommands
    }

    private mutating func handleEscapeSequence(
        _ bytes: [UInt8]
    ) -> Int? {
        if bytes.starts(with: [0x1B, 0x5B, 0x44]) {
            moveCursor(by: -1)
            return 3
        }
        if bytes.starts(with: [0x1B, 0x5B, 0x43]) {
            moveCursor(by: 1)
            return 3
        }
        if bytes.starts(with: [0x1B, 0x5B, 0x48]) {
            cursorOffset = 0
            return 3
        }
        if bytes.starts(with: [0x1B, 0x5B, 0x46]) {
            cursorOffset = text.count
            return 3
        }
        if bytes.starts(with: [0x1B, 0x5B, 0x33, 0x7E]) {
            removeAtCursor()
            return 4
        }
        if bytes.starts(with: [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]) ||
            bytes.starts(with: [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])
        {
            return 6
        }
        if bytes.starts(with: [0x1B, 0x5B, 0x41]) ||
            bytes.starts(with: [0x1B, 0x5B, 0x42])
        {
            isReliable = false
            return 3
        }
        return nil
    }

    private mutating func insert(_ value: String) {
        let index = text.index(text.startIndex, offsetBy: cursorOffset)
        text.insert(contentsOf: value, at: index)
        cursorOffset += value.count
    }

    private mutating func moveCursor(by offset: Int) {
        cursorOffset = min(max(cursorOffset + offset, 0), text.count)
    }

    private mutating func removeBeforeCursor() {
        guard cursorOffset > 0 else { return }
        let index = text.index(text.startIndex, offsetBy: cursorOffset - 1)
        text.remove(at: index)
        cursorOffset -= 1
    }

    private mutating func removeAtCursor() {
        guard cursorOffset < text.count else { return }
        let index = text.index(text.startIndex, offsetBy: cursorOffset)
        text.remove(at: index)
    }

    private mutating func removePreviousWord() {
        while
            cursorOffset > 0,
            text.character(at: cursorOffset - 1)?.isWhitespace == true
        {
            removeBeforeCursor()
        }
        while
            cursorOffset > 0,
            text.character(at: cursorOffset - 1)?.isWhitespace == false
        {
            removeBeforeCursor()
        }
    }

    private mutating func clear() {
        text = ""
        cursorOffset = 0
        isReliable = true
    }
}

struct RemoteDirectoryTracker: Equatable {
    private(set) var currentDirectory: String?
    private(set) var previousDirectory: String?

    mutating func restore(_ directory: String?) {
        currentDirectory = Self.normalized(directory)
        previousDirectory = nil
    }

    mutating func updateFromHost(_ directory: String?) {
        guard let normalized = Self.normalized(directory) else { return }
        if normalized != currentDirectory {
            previousDirectory = currentDirectory
            currentDirectory = normalized
        }
    }

    mutating func record(command: String) {
        for segment in Self.commandSegments(command) {
            let words = Self.shellWords(segment)
            guard !words.isEmpty else { continue }
            let commandIndex = words.first == "builtin" ? 1 : 0
            guard commandIndex < words.count else { continue }
            let name = words[commandIndex]
            guard name == "cd" || name == "pushd" else { continue }
            let argumentIndex = commandIndex + 1
            let argument = argumentIndex < words.count
                ? words[argumentIndex]
                : "~"
            apply(directoryArgument: argument)
        }
    }

    private mutating func apply(directoryArgument: String) {
        guard !directoryArgument.isEmpty else { return }
        if directoryArgument == "-" {
            guard let previousDirectory else { return }
            let old = currentDirectory
            currentDirectory = previousDirectory
            self.previousDirectory = old
            return
        }
        guard
            !directoryArgument.contains("$"),
            !directoryArgument.contains("*"),
            !directoryArgument.contains("?")
        else {
            return
        }

        let destination: String
        if directoryArgument == "~" {
            destination = "~"
        } else if directoryArgument.hasPrefix("/") {
            destination = (directoryArgument as NSString)
                .standardizingPath
        } else if directoryArgument.hasPrefix("~/") {
            destination = Self.standardizeTildePath(directoryArgument)
        } else if let currentDirectory {
            if currentDirectory == "~" {
                destination = Self.standardizeTildePath(
                    "~/" + directoryArgument
                )
            } else if currentDirectory.hasPrefix("~/") {
                destination = Self.standardizeTildePath(
                    currentDirectory + "/" + directoryArgument
                )
            } else {
                destination = ((currentDirectory as NSString)
                    .appendingPathComponent(directoryArgument)
                    as NSString).standardizingPath
            }
        } else {
            return
        }
        previousDirectory = currentDirectory
        currentDirectory = destination
    }

    private static func normalized(_ directory: String?) -> String? {
        guard var value = directory?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("file://"), let url = URL(string: value) {
            value = url.path
        }
        if value == "~" || value.hasPrefix("~/") {
            return standardizeTildePath(value)
        }
        guard value.hasPrefix("/") else { return value }
        return (value as NSString).standardizingPath
    }

    private static func standardizeTildePath(_ path: String) -> String {
        guard path != "~" else { return path }
        let components = path.dropFirst(2).split(
            separator: "/",
            omittingEmptySubsequences: true
        ).map(String.init)
        var result: [String] = []
        for component in components {
            if component == "." {
                continue
            }
            if component == ".." {
                if !result.isEmpty { result.removeLast() }
            } else {
                result.append(component)
            }
        }
        return result.isEmpty ? "~" : "~/" + result.joined(separator: "/")
    }

    private static func commandSegments(_ command: String) -> [String] {
        command
            .replacingOccurrences(of: "&&", with: ";")
            .replacingOccurrences(of: "||", with: ";")
            .split(separator: ";")
            .map(String.init)
    }

    private static func shellWords(_ command: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false

        for character in command.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\", quote != "'" {
                escaped = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty {
                    words.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        if !current.isEmpty { words.append(current) }
        return words
    }
}

private extension String {
    func character(at offset: Int) -> Character? {
        guard offset >= 0, offset < count else { return nil }
        return self[index(startIndex, offsetBy: offset)]
    }
}
