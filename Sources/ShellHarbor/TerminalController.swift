import Combine
import Foundation
@preconcurrency import SwiftTerm

struct TerminalPasswordPromptResponder {
    private let expectedIdentity: String
    private let password: String
    private var outputTail = ""
    private(set) var didRespond = false

    init(username: String, host: String, password: String) {
        expectedIdentity = "\(username)@\(host)".lowercased()
        self.password = password
    }

    mutating func response(for bytes: [UInt8]) -> [UInt8]? {
        guard !didRespond, !password.isEmpty else { return nil }
        outputTail = String(
            (outputTail + String(decoding: bytes, as: UTF8.self))
                .suffix(1_024)
        )
        let normalized = outputTail.lowercased()
        let moshPrompt = "(\(expectedIdentity)) password:"
        let openSSHPrompt = "\(expectedIdentity)'s password:"
        guard
            normalized.contains(moshPrompt) ||
            normalized.contains(openSSHPrompt)
        else {
            return nil
        }
        didRespond = true
        outputTail = ""
        return Array("\(password)\n".utf8)
    }
}

struct SSHHostKeyConfirmation: Identifiable, Equatable {
    let id = UUID()
    let prompt: String
}

struct SSHHostKeyPromptDetector {
    private var outputTail = ""
    private(set) var didDetect = false

    mutating func confirmation(for bytes: [UInt8]) -> SSHHostKeyConfirmation? {
        guard !didDetect else { return nil }
        outputTail = String(
            (outputTail + String(decoding: bytes, as: UTF8.self))
                .suffix(8_192)
        )
        guard
            outputTail.localizedCaseInsensitiveContains(
                "The authenticity of host"
            ),
            outputTail.localizedCaseInsensitiveContains(
                "Are you sure you want to continue connecting"
            )
        else {
            return nil
        }
        didDetect = true
        let start = outputTail.range(
            of: "The authenticity of host",
            options: .caseInsensitive
        )?.lowerBound ?? outputTail.startIndex
        return SSHHostKeyConfirmation(
            prompt: String(outputTail[start...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

@MainActor
final class TerminalController: ObservableObject {
    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var displayCommand = ""
    @Published private(set) var terminalTitle = ""
    @Published private(set) var connectionToken = UUID()
    @Published private(set) var disconnectToken = UUID()
    @Published private(set) var interruptToken = UUID()
    @Published private(set) var clearToken = UUID()
    @Published private(set) var inputRequest: TerminalInputRequest?
    @Published private(set) var hostKeyConfirmation: SSHHostKeyConfirmation?

    private(set) var invocation: SSHInvocation?
    private(set) var retainedTerminalView: LocalProcessTerminalView?
    private var processDelegateBridge: TerminalProcessDelegateBridge?
    private var pendingInput = PendingTerminalInput()
    private var restoredTerminalBuffer: Data?
    private var restoredPendingCommand: String?
    private var restoredCommandScheduled = false
    private var directoryTracker = RemoteDirectoryTracker()
    private var processDescription = "SSH"
    private var connectionReadyFileURL: URL?
    private var connectionReadyTask: Task<Void, Never>?
    private var automaticPasswordResponder:
        TerminalPasswordPromptResponder?
    private var hostKeyPromptDetector = SSHHostKeyPromptDetector()

    var onRestorationChanged: (() -> Void)?
    var onCommandSubmitted: ((String) -> Void)?
    private(set) var scrollbackLines =
        TerminalScrollbackSettings.defaultLines

    var processDelegate: LocalProcessTerminalViewDelegate? {
        processDelegateBridge
    }

    var hasRetainedTerminalView: Bool {
        retainedTerminalView != nil
    }

    func retainTerminalView(_ view: LocalProcessTerminalView) {
        retainedTerminalView = view
    }

    func setScrollbackLines(_ lines: Int) {
        let normalized = TerminalScrollbackSettings.normalized(lines)
        scrollbackLines = normalized
        retainedTerminalView?.getTerminal().changeScrollback(normalized)
        onRestorationChanged?()
    }

    func prepareRestoration(
        buffer: Data?,
        pendingCommand: String?,
        directory: String?
    ) {
        restoredTerminalBuffer = buffer
        restoredPendingCommand = pendingCommand
        restoredCommandScheduled = false
        pendingInput.restore(pendingCommand)
        directoryTracker.restore(directory)
    }

    func consumeRestoredTerminalBuffer() -> Data? {
        defer { restoredTerminalBuffer = nil }
        return restoredTerminalBuffer
    }

    func scheduleRestoredCommandIfNeeded(
        in view: LocalProcessTerminalView,
        token: UUID
    ) {
        guard
            !restoredCommandScheduled,
            let command = restoredPendingCommand,
            !command.isEmpty
        else {
            return
        }
        restoredCommandScheduled = true
        Task { @MainActor [weak self, weak view] in
            try? await Task.sleep(for: .seconds(2))
            guard
                let self,
                let view,
                self.connectionToken == token,
                view.process.running
            else {
                return
            }
            view.process.send(data: Array(command.utf8)[...])
            view.window?.makeFirstResponder(view)
        }
    }

    func recordTerminalInput(_ bytes: [UInt8]) {
        let commands = pendingInput.record(bytes)
        for command in commands {
            directoryTracker.record(command: command)
            onCommandSubmitted?(command)
        }
        onRestorationChanged?()
    }

    func updateCurrentDirectoryFromHost(_ directory: String?) {
        directoryTracker.updateFromHost(directory)
        onRestorationChanged?()
    }

    func terminalOutputDidChange(_ bytes: [UInt8] = []) {
        if hostKeyConfirmation == nil,
            let confirmation = hostKeyPromptDetector.confirmation(for: bytes) {
            hostKeyConfirmation = confirmation
        }
        if var responder = automaticPasswordResponder {
            let response = responder.response(for: bytes)
            automaticPasswordResponder = responder
            if
                let response,
                let retainedTerminalView,
                retainedTerminalView.process.running
            {
                retainedTerminalView.process.send(data: response[...])
            }
        }
        onRestorationChanged?()
    }

    func respondToHostKeyConfirmation(accept: Bool) {
        guard hostKeyConfirmation != nil else { return }
        hostKeyConfirmation = nil
        let response = accept ? "yes\n" : "no\n"
        guard let retainedTerminalView, retainedTerminalView.process.running else {
            return
        }
        retainedTerminalView.process.send(data: Array(response.utf8)[...])
    }

    func restorationState() -> (
        buffer: Data?,
        pendingCommand: String?,
        directory: String?
    ) {
        let buffer = retainedTerminalView.map {
            $0.getTerminal().getBufferAsData(kind: .normal)
        } ?? restoredTerminalBuffer
        let limitedBuffer = buffer.map(
            SessionRestorationStore.limitedBuffer
        )
        guard
            pendingInput.isReliable,
            !pendingInput.text.isEmpty,
            let bufferText = limitedBuffer.flatMap({
                String(data: $0, encoding: .utf8)
            }),
            Self.lastVisibleLine(in: bufferText).contains(pendingInput.text)
        else {
            return (
                limitedBuffer,
                nil,
                directoryTracker.currentDirectory
            )
        }
        return (
            limitedBuffer,
            pendingInput.text,
            directoryTracker.currentDirectory
        )
    }

    private static func lastVisibleLine(in buffer: String) -> String {
        buffer
            .components(separatedBy: .newlines)
            .last(where: {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }) ?? ""
    }

    func connect(
        profile: SessionProfile,
        jumpProfile: SessionProfile? = nil,
        startupCommand: String? = nil
    ) {
        let preservedState = restorationState()
        disconnect(appendMessage: false)
        retainedTerminalView = nil
        if restoredTerminalBuffer == nil {
            restoredTerminalBuffer = preservedState.buffer
        }
        restoredPendingCommand = preservedState.pendingCommand
        restoredCommandScheduled = false
        if profile.isLocalConnection {
            // A restored Local session may contain the directory from the old
            // shell (for example `/`). Starting a new local process must obey
            // the configured Local starting directory instead of allowing the
            // restoration snapshot to override it indefinitely.
            directoryTracker.restore(profile.remoteStartPath)
        } else if directoryTracker.currentDirectory == nil {
            directoryTracker.restore(profile.remoteStartPath)
        }
        guard profile.isConnectable else {
            state = .failed(SSHServiceError.invalidProfile.localizedDescription)
            return
        }

        do {
            let newInvocation: SSHInvocation
            if profile.isLocalConnection {
                processDescription = "Shell"
                newInvocation = SSHCommandBuilder.localShell(
                    profile.resolvedLocalShell,
                    startingDirectory: directoryTracker.currentDirectory,
                    startupCommand: startupCommand
                )
            } else if profile.isMoshConnection {
                processDescription = "Mosh"
                newInvocation = try SSHCommandBuilder.mosh(
                    profile: profile,
                    jumpProfile: jumpProfile,
                    startingDirectory: directoryTracker.currentDirectory,
                    startupCommand: startupCommand
                )
            } else {
                processDescription = "SSH"
                let readyFileURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "shellharbor-ssh-ready-\(UUID().uuidString)"
                    )
                try? FileManager.default.removeItem(at: readyFileURL)
                let shellCommand = SSHCommandBuilder.interactiveShellCommand(
                    startingDirectory: directoryTracker.currentDirectory,
                    startupCommand: startupCommand
                )
                newInvocation = try SSHCommandBuilder.ssh(
                    profile: profile,
                    jumpProfile: jumpProfile,
                    command: shellCommand,
                    forceTTY: true,
                    connectionReadyFilePath: readyFileURL.path
                )
                connectionReadyFileURL = readyFileURL
            }
            invocation = newInvocation
            if
                profile.resolvedTerminalConnectionMethod == .jumpMosh,
                profile.authentication == .password,
                !profile.password.isEmpty
            {
                automaticPasswordResponder =
                    TerminalPasswordPromptResponder(
                        username: profile.username,
                        host: profile.resolvedHost,
                        password: profile.password
                    )
            }
            state = .connecting
            displayCommand = newInvocation.displayCommand
            terminalTitle = profile.name
            connectionToken = UUID()
            processDelegateBridge = TerminalProcessDelegateBridge(
                controller: self,
                connectionToken: connectionToken
            )
        } catch {
            state = .failed(error.localizedDescription)
            invocation = nil
        }
    }


    func beginPreparingConnection() {
        state = .connecting
    }

    func failPreparingConnection(_ message: String) {
        state = .failed(message)
    }

    func processStarted(for token: UUID) {
        guard token == connectionToken, invocation != nil else { return }
        guard connectionReadyFileURL == nil else {
            waitForSSHConnectionReady(for: token)
            return
        }
        state = .connected
    }

    func processTerminated(exitCode: Int32?, for token: UUID) {
        guard token == connectionToken else { return }
        clearConnectionReadyMarker()
        let outputSummary = retainedTerminalView.flatMap { view -> String? in
            let data = view.getTerminal().getBufferAsData(kind: .normal)
            guard let output = String(data: data, encoding: .utf8) else {
                return nil
            }
            let summary = CommandOutputSummary.text(output)
            return summary.isEmpty ? nil : summary
        }
        invocation = nil
        processDelegateBridge = nil
        if case .disconnected = state { return }
        if let exitCode, exitCode == 0 {
            state = .disconnected
        } else if let exitCode {
            // forkpty reports waitpid's encoded status (for example 10 is
            // surfaced as 2560). Present the actual process exit code.
            let displayedCode = exitCode > 255 && exitCode & 0xff == 0
                ? exitCode >> 8
                : exitCode
            var message = "\(processDescription) 已退出，状态码 \(displayedCode)"
            if let outputSummary {
                message += "\n\n退出前输出：\n\(outputSummary)"
            }
            state = .failed(message)
        } else {
            var message = "\(processDescription) 进程异常结束"
            if let outputSummary {
                message += "\n\n退出前输出：\n\(outputSummary)"
            }
            state = .failed(message)
        }
    }

    func updateTitle(_ title: String, for token: UUID) {
        guard token == connectionToken, !title.isEmpty else { return }
        terminalTitle = title
    }

    func sendInterrupt() {
        guard state == .connected else { return }
        pendingInput.record([0x03])
        interruptToken = UUID()
        onRestorationChanged?()
    }

    func clear() {
        guard state == .connected else { return }
        if
            let retainedTerminalView =
                retainedTerminalView as? SteadyCursorTerminalView
        {
            retainedTerminalView
                .clearLocalBufferPreservingCurrentLine()
            return
        }
        clearToken = UUID()
    }

    func showFind() {
        guard
            let terminalView = retainedTerminalView
                as? SteadyCursorTerminalView
        else {
            return
        }
        terminalView.window?.makeFirstResponder(terminalView)
        DispatchQueue.main.async { [weak terminalView] in
            terminalView?.showTerminalFindBar()
        }
    }

    func insertText(_ text: String) {
        guard state == .connected, !text.isEmpty else { return }
        let bytes = Array(text.utf8)
        pendingInput.record(bytes)
        if
            let retainedTerminalView,
            retainedTerminalView.process.running
        {
            retainedTerminalView.process.send(data: bytes[...])
            DispatchQueue.main.async { [weak retainedTerminalView] in
                retainedTerminalView?.window?
                    .makeFirstResponder(retainedTerminalView)
            }
        } else {
            inputRequest = TerminalInputRequest(text: text)
        }
        onRestorationChanged?()
    }

    func disconnect(appendMessage: Bool = true) {
        clearConnectionReadyMarker()
        automaticPasswordResponder = nil
        hostKeyConfirmation = nil
        hostKeyPromptDetector = SSHHostKeyPromptDetector()
        if invocation != nil {
            disconnectToken = UUID()
        }
        if retainedTerminalView?.process.running == true {
            retainedTerminalView?.terminate()
        }
        processDelegateBridge = nil
        invocation = nil
        state = .disconnected
    }

    private func waitForSSHConnectionReady(for token: UUID) {
        connectionReadyTask?.cancel()
        connectionReadyTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard
                    let self,
                    token == self.connectionToken,
                    self.invocation != nil,
                    let readyFileURL = self.connectionReadyFileURL
                else { return }
                if FileManager.default.fileExists(atPath: readyFileURL.path) {
                    try? FileManager.default.removeItem(at: readyFileURL)
                    self.connectionReadyFileURL = nil
                    self.connectionReadyTask = nil
                    self.state = .connected
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(50))
                } catch {
                    return
                }
            }
        }
    }

    private func clearConnectionReadyMarker() {
        connectionReadyTask?.cancel()
        connectionReadyTask = nil
        if let connectionReadyFileURL {
            try? FileManager.default.removeItem(at: connectionReadyFileURL)
        }
        connectionReadyFileURL = nil
    }
}

struct TerminalInputRequest: Equatable {
    let id = UUID()
    let text: String
}

@MainActor
private final class TerminalProcessDelegateBridge:
    NSObject,
    @preconcurrency LocalProcessTerminalViewDelegate
{
    weak var controller: TerminalController?
    let connectionToken: UUID

    init(controller: TerminalController, connectionToken: UUID) {
        self.controller = controller
        self.connectionToken = connectionToken
    }

    func sizeChanged(
        source: LocalProcessTerminalView,
        newCols: Int,
        newRows: Int
    ) {}

    func setTerminalTitle(
        source: LocalProcessTerminalView,
        title: String
    ) {
        controller?.updateTitle(title, for: connectionToken)
    }

    func hostCurrentDirectoryUpdate(
        source: SwiftTerm.TerminalView,
        directory: String?
    ) {
        controller?.updateCurrentDirectoryFromHost(directory)
    }

    func processTerminated(
        source: SwiftTerm.TerminalView,
        exitCode: Int32?
    ) {
        controller?.processTerminated(
            exitCode: exitCode,
            for: connectionToken
        )
    }
}
