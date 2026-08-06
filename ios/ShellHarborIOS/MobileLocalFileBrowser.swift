import Foundation
import Observation

enum MobileFileNameValidator {
    static func normalized(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value != ".",
              value != "..",
              !value.contains("/"),
              !value.contains("\0") else {
            return nil
        }
        return value
    }
}

enum MobileFileSortField: String, CaseIterable, Identifiable {
    case name
    case modifiedAt
    case createdAt
    case size

    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: "名称"
        case .modifiedAt: "修改日期"
        case .createdAt: "创建日期"
        case .size: "大小"
        }
    }
}

struct MobileLocalFile: Identifiable, Equatable, Sendable {
    var id: String { url.path }
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64?
    let modifiedAt: Date?
    let createdAt: Date?

    init(
        url: URL,
        name: String,
        isDirectory: Bool,
        size: Int64?,
        modifiedAt: Date?,
        createdAt: Date? = nil
    ) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
    }
}

@MainActor
@Observable
final class MobileLocalFileBrowser {
    private(set) var currentURL: URL
    private(set) var entries: [MobileLocalFile] = []
    var pathInput = "/"
    var focusedPath: String?
    var errorMessage: String?
    private(set) var sortField: MobileFileSortField
    private(set) var sortAscending: Bool

    private let rootURL: URL
    private let remoteID: UUID

    init(remoteID: UUID, relativePath: String = "") {
        self.remoteID = remoteID
        sortField = MobileFileSortField(
            rawValue: UserDefaults.standard.string(forKey: "mobileLocalSortField.\(remoteID.uuidString)") ?? ""
        ) ?? .name
        sortAscending = UserDefaults.standard.object(
            forKey: "mobileLocalSortAscending.\(remoteID.uuidString)"
        ) as? Bool ?? true
        rootURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let remembered = relativePath.isEmpty ? Self.rememberedPath(for: remoteID) : relativePath
        let requested = remembered.isEmpty
            ? rootURL
            : rootURL.appendingPathComponent(remembered, isDirectory: true)
        var isDirectory: ObjCBool = false
        currentURL = FileManager.default.fileExists(atPath: requested.path, isDirectory: &isDirectory)
            && isDirectory.boolValue ? requested : rootURL
        pathInput = displayPath
        refresh()
    }

    var relativePath: String {
        let root = rootURL.standardizedFileURL.path
        let current = currentURL.standardizedFileURL.path
        guard current.hasPrefix(root) else { return "" }
        return String(current.dropFirst(root.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var canGoToParent: Bool {
        currentURL.standardizedFileURL != rootURL.standardizedFileURL
    }

    var displayPath: String {
        relativePath.isEmpty ? "/" : "/\(relativePath)"
    }

    func refresh() {
        do {
            let keys: Set<URLResourceKey> = [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                .creationDateKey
            ]
            entries = try FileManager.default.contentsOfDirectory(
                at: currentURL,
                includingPropertiesForKeys: Array(keys),
                options: []
            ).map { url in
                let values = try url.resourceValues(forKeys: keys)
                let isDirectory = values.isDirectory == true
                return MobileLocalFile(
                    url: url,
                    name: url.lastPathComponent,
                    isDirectory: isDirectory,
                    size: isDirectory ? nil : values.fileSize.map(Int64.init),
                    modifiedAt: values.contentModificationDate,
                    createdAt: values.creationDate
                )
            }.sorted(by: compare)
            if let focusedPath,
               !entries.contains(where: { $0.url.standardizedFileURL.path == focusedPath }) {
                self.focusedPath = nil
                pathInput = displayPath
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setSortField(_ field: MobileFileSortField) {
        sortField = field
        UserDefaults.standard.set(field.rawValue, forKey: "mobileLocalSortField.\(remoteID.uuidString)")
        entries.sort(by: compare)
    }

    func toggleSortDirection() {
        sortAscending.toggle()
        UserDefaults.standard.set(sortAscending, forKey: "mobileLocalSortAscending.\(remoteID.uuidString)")
        entries.sort(by: compare)
    }

    func open(_ file: MobileLocalFile) -> URL? {
        guard file.isDirectory else { return file.url }
        currentURL = file.url
        focusedPath = nil
        pathInput = displayPath
        rememberCurrentPath()
        refresh()
        return nil
    }

    func goToParent() {
        guard canGoToParent else { return }
        currentURL.deleteLastPathComponent()
        focusedPath = nil
        pathInput = displayPath
        rememberCurrentPath()
        refresh()
    }

    func navigateToPathInput() {
        let rawValue = pathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let target: URL
        if rawValue.isEmpty || rawValue == "/" || rawValue == "~" {
            target = rootURL
        } else if rawValue.hasPrefix(rootURL.path) {
            target = URL(fileURLWithPath: rawValue)
        } else if rawValue.hasPrefix("/") || rawValue.hasPrefix("~/") {
            let relative = rawValue
                .replacingOccurrences(of: "~/", with: "", options: [.anchored])
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            target = rootURL.appendingPathComponent(relative)
        } else {
            target = currentURL.appendingPathComponent(rawValue)
        }

        let standardized = target.standardizedFileURL
        let rootPath = rootURL.standardizedFileURL.path
        let targetPath = standardized.path
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else {
            errorMessage = "本地路径必须位于 ShellHarbor 文稿目录内。"
            pathInput = displayPath
            return
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetPath, isDirectory: &isDirectory) else {
            errorMessage = "找不到本地路径：\(rawValue)"
            return
        }

        if isDirectory.boolValue {
            currentURL = standardized
            focusedPath = nil
            pathInput = displayPath
        } else {
            currentURL = standardized.deletingLastPathComponent()
            focusedPath = targetPath
            pathInput = displayPathForFile(standardized)
        }
        rememberCurrentPath()
        refresh()
    }

    func createDirectory(named name: String) {
        guard let normalized = MobileFileNameValidator.normalized(name) else {
            errorMessage = "文件名不能为空，不能是 . 或 ..，也不能包含 /。"
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: collisionFreeURL(for: normalized, isDirectory: true),
                withIntermediateDirectories: false
            )
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ file: MobileLocalFile) {
        delete([file])
    }

    func delete(_ files: [MobileLocalFile]) {
        do {
            for file in files { try FileManager.default.removeItem(at: file.url) }
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rename(_ file: MobileLocalFile, to name: String) {
        guard let normalized = MobileFileNameValidator.normalized(name) else {
            errorMessage = "文件名不能为空，不能是 . 或 ..，也不能包含 /。"
            return
        }
        guard normalized != file.name else { return }
        do {
            let destination = currentURL.appendingPathComponent(normalized)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                errorMessage = "同名文件已经存在。"
                return
            }
            try FileManager.default.moveItem(at: file.url, to: destination)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func collisionFreeURL(for name: String, isDirectory: Bool = false) -> URL {
        let original = currentURL.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: original.path) else { return original }
        let pathExtension = isDirectory ? "" : original.pathExtension
        let base = isDirectory ? name : original.deletingPathExtension().lastPathComponent
        for index in 1...10_000 {
            let candidateName = pathExtension.isEmpty
                ? "\(base) (\(index))"
                : "\(base) (\(index)).\(pathExtension)"
            let candidate = currentURL.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return currentURL.appendingPathComponent("\(UUID().uuidString)-\(name)")
    }

    private func rememberCurrentPath() {
        var paths = UserDefaults.standard.dictionary(forKey: "mobileLocalPaths") as? [String: String] ?? [:]
        paths[remoteID.uuidString] = relativePath
        UserDefaults.standard.set(paths, forKey: "mobileLocalPaths")
    }

    private func displayPathForFile(_ url: URL) -> String {
        let relative = String(
            url.standardizedFileURL.path.dropFirst(
                rootURL.standardizedFileURL.path.count
            )
        ).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? "/" : "/\(relative)"
    }

    private func compare(_ lhs: MobileLocalFile, _ rhs: MobileLocalFile) -> Bool {
        if sortField == .modifiedAt || sortField == .createdAt {
            let leftDate = sortField == .modifiedAt ? lhs.modifiedAt : lhs.createdAt
            let rightDate = sortField == .modifiedAt ? rhs.modifiedAt : rhs.createdAt
            if (leftDate == nil) != (rightDate == nil) {
                return leftDate != nil
            }
        }
        let order: ComparisonResult
        switch sortField {
        case .name:
            order = lhs.name.localizedStandardCompare(rhs.name)
        case .modifiedAt:
            order = compareOptional(lhs.modifiedAt, rhs.modifiedAt)
        case .createdAt:
            order = compareOptional(lhs.createdAt, rhs.createdAt)
        case .size:
            let left = lhs.size ?? 0
            let right = rhs.size ?? 0
            order = left == right ? .orderedSame
                : (left < right ? .orderedAscending : .orderedDescending)
        }
        if order == .orderedSame {
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return sortAscending ? order == .orderedAscending : order == .orderedDescending
    }

    private func compareOptional<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
        case (nil, nil): .orderedSame
        case (nil, _): .orderedAscending
        case (_, nil): .orderedDescending
        }
    }

    private static func rememberedPath(for remoteID: UUID) -> String {
        let paths = UserDefaults.standard.dictionary(forKey: "mobileLocalPaths") as? [String: String]
        return paths?[remoteID.uuidString] ?? ""
    }
}
