import Foundation

#if DEBUG
struct MobileConnectionSelfTestResult: Codable {
    let name: String
    let endpoint: String
    let success: Bool
    let detail: String
}

@MainActor
enum MobileConnectionSelfTest {
    private static var hasStarted = false

    static func runIfRequested() async {
        guard !hasStarted else { return }
        hasStarted = true
        let environment = ProcessInfo.processInfo.environment
        guard let manifestPath = environment["SHELLHARBOR_IOS_SELF_TEST_MANIFEST"],
              let resultPath = environment["SHELLHARBOR_IOS_SELF_TEST_RESULTS"] else {
            return
        }

        let manifestURL = URL(fileURLWithPath: manifestPath)
        guard let data = try? Data(contentsOf: manifestURL),
              let profiles = try? JSONDecoder().decode([MobileRemoteProfile].self, from: data) else {
            try? write([
                MobileConnectionSelfTestResult(
                    name: "manifest",
                    endpoint: "-",
                    success: false,
                    detail: "无法读取测试配置"
                )
            ], to: resultPath)
            return
        }

        let runtimeProfiles = profiles.map { profile in
            var result = profile
            if result.authentication == .password,
               !result.password.isEmpty,
               !MobilePasswordCipher.isEncrypted(result.password),
               let encrypted = try? MobilePasswordCipher.encrypt(result.password) {
                result.password = encrypted
            }
            return result
        }
        let byID = Dictionary(uniqueKeysWithValues: runtimeProfiles.map { ($0.id, $0) })
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let sourceIdentityURL = documents?.appendingPathComponent("id_rsa")
        var importedKeyStore: ImportedKeyStore?
        var importedKey: ImportedIdentityKey?
        var identityURL = sourceIdentityURL
        if environment["SHELLHARBOR_IOS_SELF_TEST_IMPORT_KEY"] == "1", let sourceIdentityURL {
            let store = ImportedKeyStore()
            let existing = Set(store.keys.map(\.id))
            do {
                try store.importKey(from: sourceIdentityURL)
                guard let key = store.keys.first(where: { !existing.contains($0.id) }) else {
                    throw SelfTestError.keyImportFailed
                }
                importedKeyStore = store
                importedKey = key
                identityURL = store.keyURL(forID: key.id)
            } catch {
                try? write([MobileConnectionSelfTestResult(name: "id_rsa.key", endpoint: "设置",
                    success: false, detail: "私钥导入失败：\(error.localizedDescription)")], to: resultPath)
                return
            }
        }
        defer {
            if let importedKeyStore, let importedKey { try? importedKeyStore.delete(importedKey) }
        }
        let tailscaleProxyManager = MobileTailscaleProxyManager()
        if environment["SHELLHARBOR_IOS_SELF_TEST_PREWARM"] == "1" {
            await tailscaleProxyManager.prewarm(runtimeProfiles)
        }
        var results: [MobileConnectionSelfTestResult] = []
        try? write(results, to: resultPath)
        for profile in runtimeProfiles {
            let jump = profile.jumpRemoteID.flatMap { byID[$0] }
            let controller = MobileSSHController(
                remote: profile,
                identityURL: profile.authentication == .password ? nil : identityURL,
                jumpRemote: jump,
                jumpIdentityURL: jump?.authentication == .password ? nil : identityURL,
                trustedHostKey: nil,
                trustedJumpHostKey: nil,
                trustHostKey: { _ in },
                trustJumpHostKey: { _ in },
                tailscaleProxyManager: tailscaleProxyManager
            )
            controller.connect { _ in }
            var result = await waitForConnection(controller)
            if !result.success, let diagnostic = diagnosticTail(controller), !diagnostic.isEmpty {
                result.detail += "：\(diagnostic)"
            }
            if result.success {
                result = await verifyPTYRoundTrip(controller)
            }
            if result.success {
                let hostKeyResponder = Task { @MainActor in
                    while !Task.isCancelled {
                        if controller.hostKeyPrompt != nil { controller.acceptHostKey() }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                }
                defer { hostKeyResponder.cancel() }
                do {
                    let (directory, entries) = try await controller.sftpList(at: ".")
                    let transferName = ".shellharbor-ios-selftest-\(UUID().uuidString)"
                    let transferPath = directory == "/" ? "/\(transferName)" : "\(directory)/\(transferName)"
                    let payload = Data((0..<(600 * 1024)).map { UInt8($0 % 251) })
                    var uploaded: Int64 = 0
                    try await controller.sftpUpload(data: payload, to: transferPath) { value, _ in uploaded = value }
                    var downloaded: Int64 = 0
                    let received = try await controller.sftpDownload(path: transferPath, maximumSize: 1_000_000) { value, _ in downloaded = value }
                    try? await controller.sftpDelete(MobileRemoteFile(name: transferName, path: transferPath,
                        size: UInt64(payload.count), permissions: nil, modifiedAt: nil))
                    guard received == payload, uploaded == Int64(payload.count), downloaded == Int64(payload.count) else {
                        throw SelfTestError.invalidTransfer
                    }
                    let inspection = try await controller.executeInspectionCommand("printf '__SHELLHARBOR_INSPECTION__\\nCPU_PERCENT=1.0\\n'")
                    guard inspection.contains("__SHELLHARBOR_INSPECTION__") else {
                        throw SelfTestError.invalidInspection
                    }
                    result = (true, "PTY、分块 SFTP 与巡检命令已连接（目录项 \(entries.count)）")
                } catch {
                    result = (false, "PTY 已连接，但 SFTP 失败：\(error.localizedDescription)")
                }
            }
            results.append(
                MobileConnectionSelfTestResult(
                    name: profile.name,
                    endpoint: profile.endpoint,
                    success: result.success,
                    detail: result.detail
                )
            )
            try? write(results, to: resultPath)
            controller.disconnect()
        }
    }

    private enum SelfTestError: LocalizedError {
        case invalidInspection
        case invalidTransfer
        case keyImportFailed
        var errorDescription: String? {
            switch self {
            case .invalidInspection: "巡检命令响应无效"
            case .invalidTransfer: "SFTP 分块传输校验失败"
            case .keyImportFailed: "导入后未找到私钥"
            }
        }
    }

    private static func diagnosticTail(_ controller: MobileSSHController) -> String? {
        let tail = controller.restorationOutputHistory().suffix(1_000)
        let text = String(decoding: tail, as: UTF8.self)
            .replacingOccurrences(of: #"\u{001B}\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .components(separatedBy: .controlCharacters)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.suffix(500))
    }

    private static func verifyPTYRoundTrip(
        _ controller: MobileSSHController
    ) async -> (success: Bool, detail: String) {
        let marker = "SH-READY"
        // The expected marker is deliberately absent from the typed command,
        // so local terminal echo or Mosh prediction cannot create a false pass.
        controller.send(ArraySlice("printf '\\123\\110\\055\\122\\105\\101\\104\\131\\012'\r".utf8))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        while clock.now < deadline {
            if String(decoding: controller.restorationOutputHistory(), as: UTF8.self).contains(marker) {
                return (true, "PTY 交互已验证")
            }
            if case .failed(let message) = controller.state { return (false, message) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return (false, "PTY 已建立，但未收到命令回显")
    }

    private static func waitForConnection(
        _ controller: MobileSSHController
    ) async -> (success: Bool, detail: String) {
        let clock = ContinuousClock()
        let timeout: Duration = controller.remote.proxyType == .tailscale ? .seconds(60) : .seconds(15)
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if controller.hostKeyPrompt != nil {
                controller.acceptHostKey()
            }
            switch controller.state {
            case .connected:
                return (true, "PTY 已连接")
            case .failed(let message):
                return (false, message)
            case .disconnected:
                return (false, "连接已断开")
            case .idle, .connecting:
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return (false, controller.remote.proxyType == .tailscale ? "60 秒连接超时" : "15 秒连接超时")
    }

    private static func write(
        _ results: [MobileConnectionSelfTestResult],
        to path: String
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(
            to: URL(fileURLWithPath: path),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }
}
#endif
