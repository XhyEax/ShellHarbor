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

    private(set) var invocation: SSHInvocation?
    private(set) var retainedTerminalView: LocalProcessTerminalView?
    private var processDelegateBridge: TerminalProcessDelegateBridge?
    private var pendingInput = PendingTerminalInput()
    private var restoredTerminalBuffer: Data?
    private var restoredPendingCommand: String?
    private var restoredCommandScheduled = false
    private var directoryTracker = RemoteDirectoryTracker()
    private var processDescription = "SSH"
    private var automaticPasswordResponder:
        TerminalPasswordPromptResponder?

    var onRestorationChanged: (() -> Void)?
    private(set) var scrollbackLines =
        TerminalScrollbackSettings.defaultLines

    var processDelegate: LocalProcessTerminalViewDelegate? {
        processDelegateBridge
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
        }
        onRestorationChanged?()
    }

    func updateCurrentDirectoryFromHost(_ directory: String?) {
        directoryTracker.updateFromHost(directory)
        onRestorationChanged?()
    }

    func terminalOutputDidChange(_ bytes: [UInt8] = []) {
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
        jumpProfile: SessionProfile? = nil
    ) {
        let preservedState = restorationState()
        disconnect(appendMessage: false)
        retainedTerminalView = nil
        if restoredTerminalBuffer == nil {
            restoredTerminalBuffer = preservedState.buffer
        }
        restoredPendingCommand = preservedState.pendingCommand
        restoredCommandScheduled = false
        if directoryTracker.currentDirectory == nil {
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
                    startingDirectory: directoryTracker.currentDirectory
                )
            } else if profile.isMoshConnection {
                processDescription = "Mosh"
                newInvocation = try SSHCommandBuilder.mosh(
                    profile: profile,
                    jumpProfile: jumpProfile,
                    startingDirectory: directoryTracker.currentDirectory
                )
            } else {
                processDescription = "SSH"
                let shellCommand = SSHCommandBuilder.interactiveShellCommand(
                    startingDirectory: directoryTracker.currentDirectory
                )
                newInvocation = try SSHCommandBuilder.ssh(
                    profile: profile,
                    jumpProfile: jumpProfile,
                    command: shellCommand,
                    forceTTY: true
                )
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

    func processStarted(for token: UUID) {
        guard token == connectionToken, invocation != nil else { return }
        state = .connected
    }

    func processTerminated(exitCode: Int32?, for token: UUID) {
        guard token == connectionToken else { return }
        invocation = nil
        processDelegateBridge = nil
        if case .disconnected = state { return }
        if let exitCode, exitCode == 0 {
            state = .disconnected
        } else if let exitCode {
            state = .failed("\(processDescription) 已退出，状态码 \(exitCode)")
        } else {
            state = .failed("\(processDescription) 进程异常结束")
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
        terminalView.showTerminalFindBar()
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
        automaticPasswordResponder = nil
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
