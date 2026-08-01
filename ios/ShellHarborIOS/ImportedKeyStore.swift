import Foundation
import Observation

struct ImportedIdentityKey: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    let fileName: String
    let importedAt: Date
}

enum IdentityKeyImportError: LocalizedError {
    case unreadable
    case invalidPrivateKey

    var errorDescription: String? {
        switch self {
        case .unreadable: "无法读取所选文件。"
        case .invalidPrivateKey: "该文件不是支持的 OpenSSH 私钥。请选择 OpenSSH 格式的 id_rsa.key。"
        }
    }
}

@MainActor
@Observable
final class ImportedKeyStore {
    private(set) var keys: [ImportedIdentityKey] = []

    private let fileManager: FileManager
    private let metadataURL: URL
    private let keyDirectoryURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let root = support.appendingPathComponent("ShellHarbor", isDirectory: true)
        keyDirectoryURL = root.appendingPathComponent("IdentityKeys", isDirectory: true)
        metadataURL = root.appendingPathComponent("identity-keys.json")
        keys = (try? Data(contentsOf: metadataURL))
            .flatMap { try? JSONDecoder().decode([ImportedIdentityKey].self, from: $0) } ?? []
        keys.removeAll { !fileManager.fileExists(atPath: keyURL(for: $0).path) }
    }

    func importKey(from sourceURL: URL) throws {
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: sourceURL), !data.isEmpty else {
            throw IdentityKeyImportError.unreadable
        }
        guard Self.looksLikePrivateKey(data) else {
            throw IdentityKeyImportError.invalidPrivateKey
        }

        try fileManager.createDirectory(
            at: keyDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        let id = UUID()
        let storedName = "\(id.uuidString).key"
        let destination = keyDirectoryURL.appendingPathComponent(storedName)
        try data.write(to: destination, options: [.atomic, .completeFileProtection])
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: destination.path
        )
        keys.append(
            ImportedIdentityKey(
                id: id,
                name: sourceURL.lastPathComponent,
                fileName: storedName,
                importedAt: Date()
            )
        )
        try persist()
    }

    func delete(_ key: ImportedIdentityKey) throws {
        let url = keyURL(for: key)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        keys.removeAll { $0.id == key.id }
        try persist()
    }

    func keyURL(forID id: UUID?) -> URL? {
        let key: ImportedIdentityKey?
        if let id {
            key = keys.first(where: { $0.id == id })
        } else {
            key = keys.count == 1 ? keys[0] : nil
        }
        guard let key else { return nil }
        return keyURL(for: key)
    }

    private func keyURL(for key: ImportedIdentityKey) -> URL {
        keyDirectoryURL.appendingPathComponent(key.fileName)
    }

    private func persist() throws {
        try fileManager.createDirectory(
            at: metadataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        let data = try JSONEncoder().encode(keys)
        try data.write(to: metadataURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func looksLikePrivateKey(_ data: Data) -> Bool {
        guard data.count <= 2_000_000, let text = String(data: data, encoding: .utf8) else { return false }
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return firstLine == "-----BEGIN OPENSSH PRIVATE KEY-----"
    }
}
