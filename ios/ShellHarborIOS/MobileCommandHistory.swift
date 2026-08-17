import Foundation

enum MobileCommandHistorySource: Equatable {
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

struct MobileCommandHistoryEntry: Identifiable, Hashable {
    let id = UUID()
    let command: String
    let date: Date?
}

private struct MobileLocalCommandHistoryRecord: Codable {
    let command: String
    let date: Date
}

enum MobileLocalCommandHistoryStore {
    private struct Archive: Codable {
        var recordsByRemote: [String: [MobileLocalCommandHistoryRecord]] = [:]
    }

    private static let maximumEntriesPerRemote = 300

    private static var fileURL: URL {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("ShellHarbor", isDirectory: true)
        return directory.appendingPathComponent("local-command-history.json")
    }

    static func load(for remoteID: UUID) -> [MobileCommandHistoryEntry] {
        let records = loadArchive().recordsByRemote[remoteID.uuidString] ?? []
        return records.map {
            MobileCommandHistoryEntry(command: $0.command, date: $0.date)
        }
    }

    static func record(
        _ command: String,
        for remoteID: UUID,
        date: Date = Date()
    ) {
        let normalized = command.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalized.isEmpty else { return }

        var archive = loadArchive()
        var records = archive.recordsByRemote[remoteID.uuidString] ?? []
        records.removeAll { $0.command == normalized }
        records.insert(
            MobileLocalCommandHistoryRecord(
                command: normalized,
                date: date
            ),
            at: 0
        )
        if records.count > maximumEntriesPerRemote {
            records.removeLast(records.count - maximumEntriesPerRemote)
        }
        archive.recordsByRemote[remoteID.uuidString] = records
        save(archive)
    }

    private static func loadArchive() -> Archive {
        guard
            let data = try? Data(contentsOf: fileURL),
            let archive = try? JSONDecoder().decode(Archive.self, from: data)
        else {
            return Archive()
        }
        return archive
    }

    private static func save(_ archive: Archive) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(archive) else { return }
        do {
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            return
        }
    }
}

enum MobileRemoteHistoryService {
    static let script = #"""
if [ -r "$HOME/.zsh_history" ]; then
  printf '__SHELLHARBOR_ZSH__\n'
  tail -n 1000 "$HOME/.zsh_history"
elif [ -r "$HOME/.bash_history" ]; then
  printf '__SHELLHARBOR_BASH__\n'
  tail -n 1000 "$HOME/.bash_history"
elif [ -r "$HOME/.local/share/fish/fish_history" ]; then
  printf '__SHELLHARBOR_FISH__\n'
  tail -n 2000 "$HOME/.local/share/fish/fish_history"
else
  printf '__SHELLHARBOR_NONE__\n'
fi
"""#

    static func parse(_ output: String) -> [MobileCommandHistoryEntry] {
        var lines = output.components(separatedBy: .newlines)
        guard let markerIndex = lines.firstIndex(where: { $0.hasPrefix("__SHELLHARBOR_") }) else {
            return []
        }
        let marker = lines[markerIndex]
        lines = Array(lines.dropFirst(markerIndex + 1))

        let parsed: [MobileCommandHistoryEntry]
        switch marker {
        case "__SHELLHARBOR_ZSH__": parsed = parseZsh(lines)
        case "__SHELLHARBOR_BASH__": parsed = parseBash(lines)
        case "__SHELLHARBOR_FISH__": parsed = parseFish(lines)
        default: return []
        }

        var seen: Set<String> = []
        var newestFirst: [MobileCommandHistoryEntry] = []
        for entry in parsed.reversed() {
            let command = entry.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty, seen.insert(command).inserted else { continue }
            newestFirst.append(.init(command: command, date: entry.date))
            if newestFirst.count == 300 { break }
        }
        return newestFirst
    }

    private static func parseZsh(_ lines: [String]) -> [MobileCommandHistoryEntry] {
        lines.map { line in
            guard line.hasPrefix(": "), let separator = line.firstIndex(of: ";") else {
                return .init(command: line, date: nil)
            }
            let metadata = line[line.index(line.startIndex, offsetBy: 2)..<separator]
            let date = metadata.split(separator: ":").first
                .flatMap { TimeInterval($0) }
                .map(Date.init(timeIntervalSince1970:))
            return .init(command: String(line[line.index(after: separator)...]), date: date)
        }
    }

    private static func parseBash(_ lines: [String]) -> [MobileCommandHistoryEntry] {
        var date: Date?
        var entries: [MobileCommandHistoryEntry] = []
        for line in lines {
            if line.hasPrefix("#"), let timestamp = TimeInterval(line.dropFirst()), timestamp > 100_000_000 {
                date = Date(timeIntervalSince1970: timestamp)
            } else {
                entries.append(.init(command: line, date: date))
                date = nil
            }
        }
        return entries
    }

    private static func parseFish(_ lines: [String]) -> [MobileCommandHistoryEntry] {
        lines.compactMap { line in
            let prefix = "- cmd: "
            guard line.hasPrefix(prefix) else { return nil }
            let command = String(line.dropFirst(prefix.count))
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\\", with: "\\")
            return .init(command: command, date: nil)
        }
    }
}
