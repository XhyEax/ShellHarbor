import Darwin
import Foundation

struct CommandResult: Sendable {
    let exitCode: Int32
    let output: String
}

final class CommandProcessControl: @unchecked Sendable {
    enum State: Equatable {
        case pending
        case running
        case paused
        case stopped
        case finished
    }

    private let lock = NSLock()
    private var process: Process?
    private var storedState: State = .pending

    var state: State {
        lock.withLock { storedState }
    }

    @discardableResult
    func pause() -> Bool {
        let process = lock.withLock { () -> Process? in
            guard
                storedState == .pending || storedState == .running
            else {
                return nil
            }
            storedState = .paused
            return self.process
        }
        if let process {
            Self.signalTree(process.processIdentifier, signal: SIGSTOP)
        }
        return state == .paused
    }

    @discardableResult
    func resume() -> Bool {
        let process = lock.withLock { () -> Process? in
            guard storedState == .paused else { return nil }
            storedState = self.process == nil ? .pending : .running
            return self.process
        }
        if let process {
            Self.signalTree(process.processIdentifier, signal: SIGCONT)
        }
        return state == .pending || state == .running
    }

    @discardableResult
    func stop() -> Bool {
        let process = lock.withLock { () -> Process? in
            guard
                storedState != .stopped,
                storedState != .finished
            else {
                return nil
            }
            storedState = .stopped
            return self.process
        }
        guard let process else { return state == .stopped }
        let pid = process.processIdentifier
        Self.signalTree(pid, signal: SIGCONT)
        Self.signalTree(pid, signal: SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + 1
        ) {
            guard process.isRunning else { return }
            Self.signalTree(pid, signal: SIGKILL)
        }
        return true
    }

    fileprivate func attach(_ process: Process) -> Bool {
        let state = lock.withLock { () -> State in
            self.process = process
            if storedState == .pending {
                storedState = .running
            }
            return storedState
        }
        switch state {
        case .paused:
            Self.signalTree(process.processIdentifier, signal: SIGSTOP)
            return true
        case .stopped:
            Self.signalTree(process.processIdentifier, signal: SIGTERM)
            return false
        default:
            return true
        }
    }

    fileprivate func finish(_ process: Process) {
        lock.withLock {
            guard self.process === process else { return }
            self.process = nil
            if storedState != .stopped {
                storedState = .finished
            }
        }
    }

    private static func signalTree(
        _ rootPID: pid_t,
        signal: Int32
    ) {
        let descendants = descendantPIDs(of: rootPID)
        if signal == SIGSTOP {
            _ = Darwin.kill(rootPID, signal)
        }
        for pid in descendants.reversed() {
            _ = Darwin.kill(pid, signal)
        }
        if signal != SIGSTOP {
            _ = Darwin.kill(rootPID, signal)
        }
    }

    private static func descendantPIDs(of rootPID: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var visited = Set<pid_t>()

        func appendChildren(of parentPID: pid_t) {
            guard visited.insert(parentPID).inserted else { return }
            var children = [pid_t](repeating: 0, count: 256)
            let count = children.withUnsafeMutableBytes { buffer in
                proc_listchildpids(
                    parentPID,
                    buffer.baseAddress,
                    Int32(buffer.count)
                )
            }
            guard count > 0 else { return }
            for childPID in children.prefix(Int(count)) where childPID > 0 {
                result.append(childPID)
                appendChildren(of: childPID)
            }
        }

        appendChildren(of: rootPID)
        return result
    }
}

enum CommandRunner {
    static func run(
        _ invocation: SSHInvocation,
        control: CommandProcessControl? = nil
    ) async throws -> CommandResult {
        let task = Task.detached(priority: .userInitiated) {
            let process = Process()
            let outputPipe = Pipe()
            process.executableURL = invocation.executableURL
            process.arguments = invocation.arguments
            process.environment = invocation.environment
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            try process.run()
            guard control?.attach(process) != false else {
                process.waitUntilExit()
                throw CancellationError()
            }
            defer { control?.finish(process) }
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
            return CommandResult(exitCode: process.terminationStatus, output: output)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            _ = control?.stop()
            task.cancel()
        }
    }
}
