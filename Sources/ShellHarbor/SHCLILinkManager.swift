import Foundation

enum SHCLILinkPreferences {
    private static let enabledKey = "shcliHomebrewLinkEnabled"

    static var savedEnabled: Bool {
        guard UserDefaults.standard.object(forKey: enabledKey) != nil else {
            return true
        }
        return UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func save(enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
    }
}

enum SHCLILinkError: LocalizedError {
    case binaryUnavailable(String)
    case directoryUnavailable(String)
    case destinationOccupied(String)

    var errorDescription: String? {
        switch self {
        case let .binaryUnavailable(path):
            "找不到 shcli：\(path)"
        case let .directoryUnavailable(path):
            "Homebrew bin 不可写：\(path)"
        case let .destinationOccupied(path):
            "已存在非 ShellHarbor 管理的文件，未覆盖：\(path)"
        }
    }
}

enum SHCLILinkManager {
    static let defaultLinkURL = URL(
        fileURLWithPath: "/opt/homebrew/bin/shcli"
    )

    static var packagedBinaryURL: URL {
        Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("shcli") ??
            Bundle.main.bundleURL.appendingPathComponent("shcli")
    }

    static func synchronize(
        enabled: Bool,
        binaryURL: URL = packagedBinaryURL,
        linkURL: URL = defaultLinkURL,
        fileManager: FileManager = .default
    ) throws {
        if enabled {
            guard fileManager.isExecutableFile(atPath: binaryURL.path) else {
                throw SHCLILinkError.binaryUnavailable(binaryURL.path)
            }
            let directory = linkURL.deletingLastPathComponent()
            guard
                fileManager.fileExists(atPath: directory.path),
                fileManager.isWritableFile(atPath: directory.path)
            else {
                throw SHCLILinkError.directoryUnavailable(directory.path)
            }

            if let existingTarget = symbolicLinkTarget(
                at: linkURL,
                fileManager: fileManager
            ) {
                if
                    existingTarget.standardizedFileURL ==
                        binaryURL.standardizedFileURL
                {
                    return
                }
                guard isPackagedSHCLIBinary(existingTarget) else {
                    throw SHCLILinkError.destinationOccupied(linkURL.path)
                }
                try fileManager.removeItem(at: linkURL)
            }
            guard !fileManager.fileExists(atPath: linkURL.path) else {
                throw SHCLILinkError.destinationOccupied(linkURL.path)
            }
            try fileManager.createSymbolicLink(
                at: linkURL,
                withDestinationURL: binaryURL
            )
            return
        }

        guard
            let existingTarget = symbolicLinkTarget(
                at: linkURL,
                fileManager: fileManager
            ),
            existingTarget.standardizedFileURL ==
                binaryURL.standardizedFileURL ||
                isPackagedSHCLIBinary(existingTarget)
        else {
            return
        }
        try fileManager.removeItem(at: linkURL)
    }

    static func removeManagedLegacyLink(
        fileManager: FileManager = .default
    ) {
        let legacyURL = URL(
            fileURLWithPath: "/opt/homebrew/bin/sh-cli"
        )
        guard
            let target = symbolicLinkTarget(
                at: legacyURL,
                fileManager: fileManager
            ),
            target.lastPathComponent == "sh-cli",
            target.path.contains("/ShellHarbor/")
        else {
            return
        }
        try? fileManager.removeItem(at: legacyURL)
    }

    private static func isPackagedSHCLIBinary(_ url: URL) -> Bool {
        guard url.lastPathComponent == "shcli" else { return false }
        let executableDirectory = url.deletingLastPathComponent()
        guard executableDirectory.lastPathComponent == "MacOS" else {
            return false
        }
        let contentsDirectory = executableDirectory.deletingLastPathComponent()
        guard contentsDirectory.lastPathComponent == "Contents" else {
            return false
        }
        return contentsDirectory
            .deletingLastPathComponent()
            .lastPathComponent == "ShellHarbor.app"
    }

    private static func symbolicLinkTarget(
        at linkURL: URL,
        fileManager: FileManager
    ) -> URL? {
        guard
            let destination = try? fileManager
                .destinationOfSymbolicLink(atPath: linkURL.path)
        else {
            return nil
        }
        if destination.hasPrefix("/") {
            return URL(fileURLWithPath: destination)
        }
        return linkURL.deletingLastPathComponent()
            .appendingPathComponent(destination)
    }
}
