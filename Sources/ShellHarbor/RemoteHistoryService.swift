import Foundation

enum CommandHistorySource: Equatable {
    case remote
    case local

    var title: String {
        switch self {
        case .remote: "远程命令历史"
        case .local: "本地命令历史"
        }
    }

    var searchPrompt: String {
        switch self {
        case .remote: "搜索远程命令"
        case .local: "搜索本地命令"
        }
    }
}

struct LocalCommandHistoryRecord: Codable, Equatable {
    let command: String
    let date: Date
}

enum LocalCommandHistoryStore {
    private struct Archive: Codable {
        var recordsByRemote: [String: [LocalCommandHistoryRecord]] = [:]
    }

    static let maximumEntriesPerRemote = 300

    private static var defaultFileURL: URL {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("ShellHarbor", isDirectory: true)
        return directory.appendingPathComponent("local-command-history.json")
    }

    static func load(
        for remoteID: UUID,
        fileURL: URL? = nil
    ) -> [CommandHistoryEntry] {
        let records = loadArchive(from: fileURL ?? defaultFileURL)
            .recordsByRemote[remoteID.uuidString] ?? []
        return records.map {
            CommandHistoryEntry(command: $0.command, date: $0.date)
        }
    }

    static func record(
        _ command: String,
        for remoteID: UUID,
        date: Date = Date(),
        fileURL: URL? = nil
    ) {
        let normalized = command.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalized.isEmpty else { return }

        let destination = fileURL ?? defaultFileURL
        var archive = loadArchive(from: destination)
        var records = archive.recordsByRemote[remoteID.uuidString] ?? []
        records.removeAll { $0.command == normalized }
        records.insert(
            LocalCommandHistoryRecord(command: normalized, date: date),
            at: 0
        )
        if records.count > maximumEntriesPerRemote {
            records.removeLast(records.count - maximumEntriesPerRemote)
        }
        archive.recordsByRemote[remoteID.uuidString] = records
        save(archive, to: destination)
    }

    private static func loadArchive(from fileURL: URL) -> Archive {
        guard
            let data = try? Data(contentsOf: fileURL),
            let archive = try? JSONDecoder().decode(Archive.self, from: data)
        else {
            return Archive()
        }
        return archive
    }

    private static func save(_ archive: Archive, to fileURL: URL) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(archive) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            return
        }
    }
}

enum RemoteHistoryService {
    static func load(
        profile: SessionProfile,
        jumpProfile: SessionProfile? = nil
    ) async throws -> [CommandHistoryEntry] {
        let script = """
        if [ -r "$HOME/.zsh_history" ]; then
          printf '__SHELLHARBOR_ZSH__\\n'
          tail -n 1000 "$HOME/.zsh_history"
        elif [ -r "$HOME/.bash_history" ]; then
          printf '__SHELLHARBOR_BASH__\\n'
          tail -n 1000 "$HOME/.bash_history"
        elif [ -r "$HOME/.local/share/fish/fish_history" ]; then
          printf '__SHELLHARBOR_FISH__\\n'
          tail -n 2000 "$HOME/.local/share/fish/fish_history"
        else
          printf '__SHELLHARBOR_NONE__\\n'
        fi
        """
        let invocation = try SSHCommandBuilder.ssh(
            profile: profile,
            jumpProfile: jumpProfile,
            command: script
        )
        let result = try await CommandRunner.run(invocation)
        guard result.exitCode == 0 else {
            throw SSHServiceError.commandFailed(result.exitCode, result.output)
        }
        return parse(result.output)
    }

    static func parse(_ output: String) -> [CommandHistoryEntry] {
        var lines = output.components(separatedBy: .newlines)
        guard let marker = lines.first else { return [] }
        lines.removeFirst()

        let parsed: [CommandHistoryEntry]
        switch marker {
        case "__SHELLHARBOR_ZSH__":
            parsed = parseZsh(lines)
        case "__SHELLHARBOR_BASH__":
            parsed = parseBash(lines)
        case "__SHELLHARBOR_FISH__":
            parsed = parseFish(lines)
        default:
            return []
        }

        var seen = Set<String>()
        var newestFirst: [CommandHistoryEntry] = []
        for entry in parsed.reversed() {
            let command = entry.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty, seen.insert(command).inserted else { continue }
            newestFirst.append(CommandHistoryEntry(command: command, date: entry.date))
            if newestFirst.count == 300 { break }
        }
        return newestFirst
    }

    private static func parseZsh(_ lines: [String]) -> [CommandHistoryEntry] {
        lines.map { line in
            guard line.hasPrefix(": "), let separator = line.firstIndex(of: ";") else {
                return CommandHistoryEntry(command: line, date: nil)
            }
            let metadata = line[line.index(line.startIndex, offsetBy: 2)..<separator]
            let timestampText = metadata.split(separator: ":").first.map(String.init)
            let date = timestampText
                .flatMap(TimeInterval.init)
                .map(Date.init(timeIntervalSince1970:))
            let command = String(line[line.index(after: separator)...])
            return CommandHistoryEntry(command: command, date: date)
        }
    }

    private static func parseBash(_ lines: [String]) -> [CommandHistoryEntry] {
        var pendingDate: Date?
        var entries: [CommandHistoryEntry] = []
        for line in lines {
            if
                line.hasPrefix("#"),
                let timestamp = TimeInterval(line.dropFirst()),
                timestamp > 100_000_000
            {
                pendingDate = Date(timeIntervalSince1970: timestamp)
                continue
            }
            entries.append(CommandHistoryEntry(command: line, date: pendingDate))
            pendingDate = nil
        }
        return entries
    }

    private static func parseFish(_ lines: [String]) -> [CommandHistoryEntry] {
        lines.compactMap { line in
            let prefix = "- cmd: "
            guard line.hasPrefix(prefix) else { return nil }
            let command = String(line.dropFirst(prefix.count))
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\\", with: "\\")
            return CommandHistoryEntry(command: command, date: nil)
        }
    }
}
