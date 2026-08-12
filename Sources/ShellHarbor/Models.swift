import AppKit
import Darwin
import Foundation
import SwiftUI

enum LocalShell: String, CaseIterable, Identifiable {
    case system
    case zsh
    case bash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟随本机"
        case .zsh: "zsh"
        case .bash: "bash"
        }
    }

    var resolvedPath: String {
        switch self {
        case .system:
            Self.systemShellPath
        case .zsh:
            "/bin/zsh"
        case .bash:
            "/bin/bash"
        }
    }

    var shellName: String {
        URL(fileURLWithPath: resolvedPath).lastPathComponent
    }

    static var saved: LocalShell {
        guard
            let value = UserDefaults.standard.string(
                forKey: "localShell"
            ),
            let shell = LocalShell(rawValue: value)
        else {
            return .system
        }
        return shell
    }

    static var systemShellPath: String {
        if
            let account = getpwuid(getuid()),
            let pointer = account.pointee.pw_shell
        {
            let path = String(cString: pointer)
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        if
            let path = ProcessInfo.processInfo.environment["SHELL"],
            FileManager.default.isExecutableFile(atPath: path)
        {
            return path
        }
        return "/bin/zsh"
    }
}

enum AuthenticationMethod: String, Codable, CaseIterable, Identifiable {
    case password
    case privateKey
    case agent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .password: "密码"
        case .privateKey: "私钥"
        case .agent: "SSH Agent"
        }
    }

}

enum HostKeyPolicy: String, Codable, CaseIterable, Identifiable {
    case ask
    case acceptNew
    case strict

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: "跟随 ~/.ssh/config"
        case .acceptNew: "自动接受新主机"
        case .strict: "严格校验"
        }
    }
}

enum SSHProxyType: String, Codable, CaseIterable, Identifiable {
    case none
    case socks5
    case httpConnect
    case tailscale

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "无（直接连接）"
        case .socks5: "SOCKS5"
        case .httpConnect: "HTTP CONNECT"
        case .tailscale: "Tailscale"
        }
    }

    var ncProtocol: String? {
        switch self {
        case .none: nil
        case .socks5, .tailscale: "5"
        case .httpConnect: "connect"
        }
    }

    var defaultPort: Int {
        switch self {
        case .none: 0
        case .socks5: 1080
        case .httpConnect: 8080
        case .tailscale: 15_040
        }
    }
}

enum TailscaleNodeIdentity {
    static let name = "shellharbor-mac"
}

enum TailscaleLoginServer {
    static func normalized(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains("://") else { return trimmed }
        return "https://\(trimmed)"
    }

    static func displayName(_ value: String?) -> String? {
        guard let normalized = normalized(value) else { return nil }
        for prefix in ["https://", "http://"] where
            normalized.lowercased().hasPrefix(prefix)
        {
            return String(normalized.dropFirst(prefix.count))
        }
        return normalized
    }
}

enum SSHJumpMode: String, Codable, CaseIterable, Identifiable {
    case sshJump
    case forward

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sshJump: "SSH Jump（默认）"
        case .forward: "Forward（ProxyCommand）"
        }
    }
}

enum TerminalConnectionMethod: String, Codable, CaseIterable, Identifiable {
    case ssh
    case mosh
    case jumpMosh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ssh: "SSH"
        case .mosh: "Mosh"
        case .jumpMosh: "跳板 Mosh"
        }
    }
}

enum MoshJumpMode: String, Codable, CaseIterable, Identifiable {
    case directTarget
    case moshOnJump

    var id: String { rawValue }

    var title: String {
        switch self {
        case .directTarget:
            "目标机 Mosh"
        case .moshOnJump:
            "跳板机 Mosh → SSH 目标"
        }
    }
}

enum MoshCommandResolver {
    static let candidates = [
        "/opt/homebrew/bin/mosh",
        "/usr/local/bin/mosh",
        "/opt/local/bin/mosh",
        "/usr/bin/mosh"
    ]

    static func detectedCommand(
        fileManager: FileManager = .default
    ) -> String {
        candidates.first(where: {
            fileManager.isExecutableFile(atPath: $0)
        }) ?? "mosh"
    }
}

enum RemoteIcon: String, Codable, CaseIterable, Identifiable {
    case server
    case macOS
    case iPhone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .server: "服务器"
        case .macOS: "PC"
        case .iPhone: "iPhone"
        }
    }

    var symbol: String {
        switch self {
        case .server: "server.rack"
        case .macOS: "desktopcomputer"
        case .iPhone: "iphone"
        }
    }
}

enum RemoteGroupName {
    static let ungrouped = "未分组"

    static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard
            !normalized.isEmpty,
            normalized != ungrouped
        else {
            return nil
        }
        return normalized
    }
}

struct RemoteGroupSection: Identifiable {
    let id: String
    let name: String
    let sessions: [SessionProfile]

    static func sections(
        from sessions: [SessionProfile]
    ) -> [RemoteGroupSection] {
        var names: [String: String] = [:]
        var buckets: [String: [SessionProfile]] = [:]
        var order: [String] = []

        for session in sessions {
            let name = session.resolvedRemoteGroup
            let key = name.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            if buckets[key] == nil {
                order.append(key)
                names[key] = name
                buckets[key] = []
            }
            buckets[key, default: []].append(session)
        }

        let ungroupedKey = RemoteGroupName.ungrouped.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        if let index = order.firstIndex(of: ungroupedKey) {
            order.append(order.remove(at: index))
        }

        return order.compactMap { key in
            guard
                let name = names[key],
                let sessions = buckets[key]
            else {
                return nil
            }
            return RemoteGroupSection(
                id: key,
                name: name,
                sessions: sessions
            )
        }
    }
}

enum FileSortColumn: String, Equatable {
    case name
    case size
    case modified
    case created
}

enum FileNameValidator {
    static func normalized(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard
            !value.isEmpty,
            value != ".",
            value != "..",
            !value.contains("/"),
            !value.contains("\0")
        else {
            return nil
        }
        return value
    }
}

enum FileNameCollisionResolver {
    static func uniqueName(
        for originalName: String,
        isDirectory: Bool,
        isUnavailable: (String) -> Bool
    ) -> String {
        guard isUnavailable(originalName) else { return originalName }

        let path = originalName as NSString
        let pathExtension = isDirectory ? "" : path.pathExtension
        let baseName = pathExtension.isEmpty
            ? originalName
            : path.deletingPathExtension

        var index = 1
        while true {
            let candidate = pathExtension.isEmpty
                ? "\(baseName) (\(index))"
                : "\(baseName) (\(index)).\(pathExtension)"
            if !isUnavailable(candidate) {
                return candidate
            }
            index += 1
        }
    }
}

enum FileNameEditing {
    static func renameCaretOffset(
        for name: String,
        isDirectory: Bool
    ) -> Int {
        let path = name as NSString
        guard !isDirectory else {
            return path.length
        }
        let searchStart = name.hasPrefix(".") ? 1 : 0
        guard searchStart < path.length else { return path.length }
        let dotRange = path.range(
            of: ".",
            options: [],
            range: NSRange(
                location: searchStart,
                length: path.length - searchStart
            )
        )
        return dotRange.location == NSNotFound
            ? path.length
            : dotRange.location
    }
}

enum ShellPathInputFormatter {
    static func text(for paths: [String]) -> String {
        paths
            .filter { !$0.isEmpty }
            .map(shellArgument)
            .joined(separator: " ")
    }

    private static func shellArgument(_ path: String) -> String {
        let safe = CharacterSet(
            charactersIn:
                "abcdefghijklmnopqrstuvwxyz" +
                "ABCDEFGHIJKLMNOPQRSTUVWXYZ" +
                "0123456789_@%+=:,./~-"
        )
        if path.unicodeScalars.allSatisfy(safe.contains) {
            return path
        }
        return SSHCommandBuilder.shellQuote(path)
    }
}

enum TerminalTheme: String, CaseIterable, Identifiable {
    case night
    case graphite
    case solarizedDark
    case light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .night: "夜间"
        case .graphite: "石墨"
        case .solarizedDark: "Solarized Dark"
        case .light: "浅色"
        }
    }

    var preferredColorScheme: ColorScheme {
        self == .light ? .light : .dark
    }

    static var saved: TerminalTheme {
        guard
            let rawValue = UserDefaults.standard.string(forKey: "terminalTheme"),
            let theme = TerminalTheme(rawValue: rawValue)
        else {
            return .night
        }
        return theme
    }
}

enum TerminalFontFamily: String, CaseIterable, Identifiable {
    case notoMonoForPowerline = "Noto Mono for Powerline"
    case dejaVuSansMono = "DejaVu Sans Mono"
    case ptMono = "PT Mono"
    case sourceCodeProMedium = "Source Code Pro Medium"
    case ubuntuMono = "Ubuntu Mono"
    case courierNew = "Courier New"
    case cascadiaCode = "Cascadia Code"
    case firaCode = "Fira Code"
    case jetBrainsMono = "JetBrains Mono"
    case meslo = "Meslo"

    var id: String { rawValue }

    private static let userDefaultsKey = "terminalFontFamily"

    private var fontNames: [String] {
        switch self {
        case .notoMonoForPowerline:
            ["NotoMonoForPowerline", "Noto Mono for Powerline", "NotoMono-Regular"]
        case .dejaVuSansMono: ["DejaVuSansMonoPowerline", "DejaVuSansMono", rawValue]
        case .ptMono: ["PTMono-Regular", rawValue]
        case .sourceCodeProMedium: ["SourceCodeProForPowerline-Medium", "SourceCodePro-Medium", rawValue]
        case .ubuntuMono: ["UbuntuMonoDerivativePowerline-Regular", "UbuntuMono-Regular", rawValue]
        case .courierNew: ["CourierNewPSMT", rawValue]
        case .cascadiaCode: ["CascadiaCode-Regular", rawValue]
        case .firaCode: ["FiraCode-Regular", rawValue]
        case .jetBrainsMono: ["JetBrainsMono-Regular", rawValue]
        case .meslo:
            ["MesloLGMDZForPowerline-Regular", "MesloLGM-Regular", "MesloLGMDZ-Regular", rawValue]
        }
    }

    func nsFont(size: CGFloat) -> NSFont {
        for name in fontNames {
            if let font = NSFont(name: name, size: size) { return font }
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static var saved: TerminalFontFamily {
        guard
            let rawValue = UserDefaults.standard.string(forKey: userDefaultsKey),
            let family = TerminalFontFamily(rawValue: rawValue)
        else {
            return .dejaVuSansMono
        }
        return family
    }

    static func save(_ family: TerminalFontFamily) {
        UserDefaults.standard.set(family.rawValue, forKey: userDefaultsKey)
    }
}

enum TerminalFontSizeSettings {
    static let defaultSize = 16.0
    static let allowedSizes = 8.0...32.0
    private static let userDefaultsKey = "terminalFontSize"

    static var savedSize: Double {
        let saved = UserDefaults.standard.double(forKey: userDefaultsKey)
        return saved == 0 ? defaultSize : normalized(saved)
    }

    static func normalized(_ size: Double) -> Double {
        min(max(size, allowedSizes.lowerBound), allowedSizes.upperBound)
    }

    static func save(_ size: Double) {
        UserDefaults.standard.set(normalized(size), forKey: userDefaultsKey)
    }
}

enum TerminalScrollbackSettings {
    static let defaultLines = 100_000
    static let allowedLines = 1_000...1_000_000
    private static let userDefaultsKey = "terminalScrollbackLines"

    static var savedLines: Int {
        let saved = UserDefaults.standard.integer(forKey: userDefaultsKey)
        return saved == 0 ? defaultLines : normalized(saved)
    }

    static func normalized(_ lines: Int) -> Int {
        min(max(lines, allowedLines.lowerBound), allowedLines.upperBound)
    }

    static func save(_ lines: Int) {
        UserDefaults.standard.set(
            normalized(lines),
            forKey: userDefaultsKey
        )
    }
}

struct SessionProfile: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = "新建会话"
    var host = "127.0.0.1"
    var port = 22
    var username = ""
    var authentication: AuthenticationMethod = .agent
    var password = ""
    var privateKeyPath = ""
    var remoteStartPath = ""
    var lastLocalPath: String?
    var lastRemotePath: String?
    var hostKeyPolicy: HostKeyPolicy = .ask
    var keepAliveSeconds = 30
    var accentHex = "#4F8CFF"
    var remoteIcon: RemoteIcon?
    var remoteGroup: String?
    var lastWorkspaceMode: String?
    var lastLocalSortColumn: String?
    var lastLocalSortAscending: Bool?
    var lastRemoteSortColumn: String?
    var lastRemoteSortAscending: Bool?
    var inspectionEnabled: Bool?
    var inspectionIntervalMinutes: Int?
    var jumpRemoteID: UUID?
    var sshJumpMode: SSHJumpMode?
    var savedProxyID: UUID?
    var proxyType: SSHProxyType?
    var proxyHost: String?
    var proxyPort: Int?
    var tailscaleAuthKey: String?
    var tailscaleLoginServer: String?
    var tailscaleHostname: String?
    /// Runtime-only Mosh UDP relay range assigned by TailscaleProxyManager.
    var tailscaleMoshPortRange: String?
    var tailscaleMoshControlPort: Int?
    var tailscaleMoshClientPath: String?
    var terminalConnectionMethod: TerminalConnectionMethod?
    var moshCommand: String?
    var moshServerCommand: String?
    var jumpMoshCommand: String?
    /// Preserved for configuration exchange with the embedded iOS Mosh
    /// implementation, whose jump mode starts mosh-server on the jump host.
    var jumpMoshServerCommand: String?
    var moshUDPPort: String?
    var moshJumpMode: MoshJumpMode?
    /// Only populated by the built-in Local profile. Persisted Remote
    /// definitions leave this nil, preserving the existing JSON format.
    var localShell: String?

    var resolvedRemoteIcon: RemoteIcon {
        remoteIcon ?? .server
    }

    var resolvedRemoteGroup: String {
        RemoteGroupName.normalized(remoteGroup) ??
            RemoteGroupName.ungrouped
    }

    var resolvedInspectionEnabled: Bool {
        inspectionEnabled ?? true
    }

    var resolvedInspectionIntervalMinutes: Int {
        max(1, inspectionIntervalMinutes ?? 15)
    }

    var isLocalConnection: Bool {
        localShell != nil
    }

    var resolvedLocalShell: LocalShell {
        localShell.flatMap(LocalShell.init(rawValue:)) ?? .system
    }

    var resolvedProxyType: SSHProxyType {
        proxyType ?? .none
    }

    var resolvedSSHJumpMode: SSHJumpMode {
        sshJumpMode ?? .sshJump
    }

    var resolvedTerminalConnectionMethod: TerminalConnectionMethod {
        let method = terminalConnectionMethod ?? .ssh
        if jumpRemoteID == nil, method == .jumpMosh {
            return .mosh
        }
        if
            jumpRemoteID != nil,
            method == .mosh,
            moshJumpMode == .moshOnJump
        {
            return .jumpMosh
        }
        return method
    }

    var isMoshConnection: Bool {
        resolvedTerminalConnectionMethod != .ssh
    }

    var resolvedMoshJumpMode: MoshJumpMode {
        resolvedTerminalConnectionMethod == .jumpMosh
            ? .moshOnJump
            : .directTarget
    }

    var resolvedMoshCommand: String {
        let value = moshCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            return MoshCommandResolver.detectedCommand()
        }
        // Earlier versions accepted a complete command in this field. Keep
        // existing profiles usable while treating the value as a path now.
        if let optionRange = value.range(of: " --") {
            return String(value[..<optionRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    var resolvedMoshServerCommand: String {
        let value = moshServerCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !value.isEmpty {
            return value
        }

        // Migrate the common legacy form:
        // /path/to/mosh --server=/path/to/mosh-server
        let legacy = moshCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard
            let marker = legacy.range(of: " --server=")
        else {
            return ""
        }
        return String(legacy[marker.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var resolvedJumpMoshCommand: String {
        let command = jumpMoshCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return command.isEmpty ? "mosh" : command
    }

    var resolvedMoshUDPPort: String {
        (moshUDPPort ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }

    var resolvedProxyHost: String {
        if resolvedProxyType == .tailscale {
            return "127.0.0.1"
        }
        let value = proxyHost?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty && isProxyEnabled
            ? "127.0.0.1"
            : value
    }

    var resolvedProxyPort: Int {
        proxyPort ?? resolvedProxyType.defaultPort
    }

    var isProxyEnabled: Bool {
        resolvedProxyType != .none
    }

    var isProxyConfigurationValid: Bool {
        !isProxyEnabled ||
        (
            !resolvedProxyHost.isEmpty &&
            (
                resolvedProxyType == .tailscale ||
                (1...65535).contains(resolvedProxyPort)
            ) &&
            (
                resolvedProxyType != .tailscale ||
                !(tailscaleAuthKey ?? "").trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
            )
        )
    }

    var resolvedTailscaleHostname: String {
        let value = (tailscaleHostname ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return value.isEmpty ? TailscaleNodeIdentity.name : value
    }

    var proxySummary: String? {
        guard isProxyEnabled else { return nil }
        return
            "\(resolvedProxyType.title) " +
            "\(resolvedProxyHost):\(resolvedProxyPort)"
    }

    var resolvedHost: String {
        let value = host.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if
            value.isEmpty ||
            value.caseInsensitiveCompare("localhost") == .orderedSame
        {
            return "127.0.0.1"
        }
        return value
    }

    var resolvedRemoteFilePath: String {
        let value = remoteStartPath.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return value.isEmpty ? "~" : value
    }

    var subtitle: String {
        if isLocalConnection {
            return "\(NSUserName()) · \(resolvedLocalShell.shellName)"
        }
        return "\(username.isEmpty ? "user" : username)@\(resolvedHost):\(port)"
    }

    var isConnectable: Bool {
        if isLocalConnection {
            return FileManager.default.isExecutableFile(
                atPath: resolvedLocalShell.resolvedPath
            )
        }
        return
            !username.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty &&
            (1...65535).contains(port) &&
            isProxyConfigurationValid
    }

    static func localhost(username: String) -> SessionProfile {
        var profile = SessionProfile()
        profile.name = "本机"
        profile.host = "127.0.0.1"
        profile.port = 22
        profile.username = username
        profile.authentication = .agent
        profile.hostKeyPolicy = .ask
        return profile
    }

    static func local(id: UUID, shell: LocalShell) -> SessionProfile {
        var profile = SessionProfile()
        profile.id = id
        profile.name = "Local"
        profile.host = "127.0.0.1"
        profile.username = NSUserName()
        profile.remoteStartPath =
            FileManager.default.homeDirectoryForCurrentUser.path
        profile.remoteIcon = .macOS
        profile.localShell = shell.rawValue
        profile.inspectionEnabled = false
        return profile
    }
}

struct InspectionRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let remoteID: UUID
    let timestamp: Date
    let isReachable: Bool
    let cpuUsagePercent: Double?
    let memoryUsagePercent: Double?
    let memoryTotalBytes: Int64?
    let memoryAvailableBytes: Int64?
    let diskTotalBytes: Int64?
    let diskAvailableBytes: Int64?
    let diskUsagePercent: Double?
    let errorMessage: String?

    var healthStatus: InspectionHealthStatus {
        guard isReachable else { return .offline }
        let values = [
            cpuUsagePercent,
            memoryUsagePercent,
            diskUsagePercent
        ].compactMap { $0 }
        return values.contains(where: { $0 >= 90 })
            ? .warning
            : .healthy
    }

    var cpuLabel: String {
        Self.percentLabel(cpuUsagePercent)
    }

    var memoryLabel: String {
        Self.percentLabel(memoryUsagePercent)
    }

    var diskUsageLabel: String {
        Self.percentLabel(diskUsagePercent)
    }

    var diskSpaceLabel: String {
        guard
            let available = diskAvailableBytes,
            let total = diskTotalBytes
        else {
            return "—"
        }
        return "\(Self.byteLabel(available)) / \(Self.byteLabel(total))"
    }

    var memorySpaceLabel: String {
        guard
            let available = memoryAvailableBytes,
            let total = memoryTotalBytes
        else {
            return "—"
        }
        return "\(Self.byteLabel(available)) / \(Self.byteLabel(total))"
    }

    private static func percentLabel(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f%%", value)
    }

    private static func byteLabel(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)
    }
}

enum InspectionHealthStatus: String, CaseIterable, Sendable {
    case healthy
    case warning
    case offline

    var title: String {
        switch self {
        case .healthy: "正常"
        case .warning: "警告"
        case .offline: "离线"
        }
    }

    var icon: String {
        switch self {
        case .healthy: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .offline: "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .healthy: .green
        case .warning: .orange
        case .offline: .red
        }
    }
}

struct InspectionStatistics: Equatable {
    let total: Int
    let healthy: Int
    let warning: Int
    let offline: Int

    init(records: [InspectionRecord]) {
        total = records.count
        healthy = records.count { $0.healthStatus == .healthy }
        warning = records.count { $0.healthStatus == .warning }
        offline = records.count { $0.healthStatus == .offline }
    }

    var healthyRate: Double {
        guard total > 0 else { return 0 }
        return Double(healthy) / Double(total)
    }
}

struct CommandHistoryEntry: Identifiable, Hashable {
    let id = UUID()
    let command: String
    let date: Date?
}

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)

    var label: String {
        switch self {
        case .disconnected: "未连接"
        case .connecting: "正在连接"
        case .connected: "已连接"
        case .failed: "连接失败"
        }
    }

    var color: Color {
        switch self {
        case .disconnected: .secondary
        case .connecting: .orange
        case .connected: .green
        case .failed: .red
        }
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

struct FileEntry: Identifiable, Hashable, Sendable {
    let id = UUID()
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modifiedAt: Date?
    let createdAt: Date?

    init(
        name: String,
        path: String,
        isDirectory: Bool,
        size: Int64,
        modifiedAt: Date?,
        createdAt: Date? = nil
    ) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
    }

    var sizeLabel: String {
        guard !isDirectory else { return "文件夹" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var modifiedLabel: String {
        guard let modifiedAt else { return "—" }
        return modifiedAt.formatted(date: .numeric, time: .shortened)
    }

    var createdLabel: String {
        guard let createdAt else { return "—" }
        return createdAt.formatted(date: .numeric, time: .shortened)
    }
}

enum RemoteFilePreviewPolicy {
    static let maximumSize: Int64 = 10 * 1_024 * 1_024
    static let supportedExtensions: Set<String> = [
        "log", "txt", "plist"
    ]

    static func shouldOpenAfterDownload(_ entry: FileEntry) -> Bool {
        guard !entry.isDirectory, entry.size < maximumSize else {
            return false
        }
        let pathExtension = (entry.name as NSString)
            .pathExtension
            .lowercased()
        return supportedExtensions.contains(pathExtension)
    }
}

enum TransferDirection: String {
    case upload
    case download

    var symbol: String {
        self == .upload ? "arrow.up" : "arrow.down"
    }

    var title: String {
        self == .upload ? "上传" : "下载"
    }
}

enum TransferStatus: Equatable {
    case queued
    case running
    case paused
    case finished
    case failed(String)
    case cancelled

    var reservesDestination: Bool {
        switch self {
        case .queued, .running, .paused:
            true
        case .finished, .failed, .cancelled:
            false
        }
    }

    var label: String {
        switch self {
        case .queued: "等待中"
        case .running: "进行中"
        case .paused: "已暂停"
        case .finished: "已完成"
        case .failed: "失败"
        case .cancelled: "已停止"
        }
    }
}

struct TransferItem: Identifiable {
    let id: UUID
    let fileName: String
    let source: String
    let destination: String
    let direction: TransferDirection
    let isDirectory: Bool
    var totalBytes: Int64?
    var transferredBytes: Int64
    var bytesPerSecond: Double
    var status: TransferStatus
    var startedAt: Date?
    var finishedAt: Date?
    var log: String

    init(
        id: UUID,
        fileName: String,
        source: String,
        destination: String,
        direction: TransferDirection,
        isDirectory: Bool = false,
        totalBytes: Int64?,
        transferredBytes: Int64,
        bytesPerSecond: Double,
        status: TransferStatus,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        log: String
    ) {
        self.id = id
        self.fileName = fileName
        self.source = source
        self.destination = destination
        self.direction = direction
        self.isDirectory = isDirectory
        self.totalBytes = totalBytes
        self.transferredBytes = transferredBytes
        self.bytesPerSecond = bytesPerSecond
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.log = log
    }

    var progressFraction: Double? {
        guard let totalBytes else { return nil }
        guard totalBytes > 0 else {
            return status == .finished ? 1 : 0
        }
        return min(max(Double(transferredBytes) / Double(totalBytes), 0), 1)
    }

    var totalSizeLabel: String? {
        guard let totalBytes else { return nil }
        return ByteCountFormatter.string(
            fromByteCount: totalBytes,
            countStyle: .file
        )
    }

    var progressLabel: String? {
        guard let totalBytes, let progressFraction else { return nil }
        let transferred = ByteCountFormatter.string(
            fromByteCount: min(transferredBytes, totalBytes),
            countStyle: .file
        )
        let total = ByteCountFormatter.string(
            fromByteCount: totalBytes,
            countStyle: .file
        )
        return "\(transferred) / \(total) · \(Int((progressFraction * 100).rounded()))%"
    }

    var speedLabel: String? {
        guard bytesPerSecond > 0 else { return nil }
        let bytes = Int64(bytesPerSecond.rounded())
        return "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))/秒"
    }

    var transferredSizeLabel: String? {
        guard transferredBytes > 0 || status == .finished else { return nil }
        return ByteCountFormatter.string(
            fromByteCount: transferredBytes,
            countStyle: .file
        )
    }

    var durationLabel: String? {
        guard
            let startedAt,
            let finishedAt,
            finishedAt >= startedAt
        else {
            return nil
        }
        return TransferDurationFormatter.string(
            for: finishedAt.timeIntervalSince(startedAt)
        )
    }

    var completionSummaryLabel: String? {
        guard
            status == .finished,
            let transferredSizeLabel,
            let durationLabel
        else {
            return nil
        }
        return "已传输 \(transferredSizeLabel) · 耗时 \(durationLabel)"
    }
}

enum TransferDurationFormatter {
    static func string(for rawSeconds: TimeInterval) -> String {
        let seconds = max(rawSeconds, 0)
        if seconds < 10 {
            return String(format: "%.1f 秒", seconds)
        }

        let roundedSeconds = Int(seconds.rounded())
        if roundedSeconds < 60 {
            return "\(roundedSeconds) 秒"
        }

        let hours = roundedSeconds / 3_600
        let minutes = (roundedSeconds % 3_600) / 60
        let remainingSeconds = roundedSeconds % 60
        if hours > 0 {
            return "\(hours) 小时 \(minutes) 分 \(remainingSeconds) 秒"
        }
        return "\(minutes) 分 \(remainingSeconds) 秒"
    }
}
