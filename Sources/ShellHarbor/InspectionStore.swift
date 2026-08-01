import Foundation

enum InspectionStore {
    private static var fileURL: URL {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("ShellHarbor", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("inspection-logs.json")
    }

    static func load() -> [InspectionRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard
            let data = try? Data(contentsOf: fileURL),
            let records = try? decoder.decode(
                [InspectionRecord].self,
                from: data
            )
        else {
            return []
        }
        return records.sorted { $0.timestamp > $1.timestamp }
    }

    static func save(_ records: [InspectionRecord]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
