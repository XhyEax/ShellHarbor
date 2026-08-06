import Combine
import Foundation

enum PortForwardDirection: String, CaseIterable, Identifiable {
    case local
    case remote
    case dynamic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: "本地"
        case .remote: "远程"
        case .dynamic: "SOCKS5"
        }
    }

    var sshFlag: String {
        switch self {
        case .local: "-L"
        case .remote: "-R"
        case .dynamic: "-D"
        }
    }
}

struct PortForwardRule: Identifiable, Equatable {
    let id: UUID
    var direction: PortForwardDirection
    var bindHost: String
    var listenPort: Int
    var destinationHost: String
    var destinationPort: Int

    init(
        id: UUID = UUID(),
        direction: PortForwardDirection = .local,
        bindHost: String = "127.0.0.1",
        listenPort: Int = 8080,
        destinationHost: String = "127.0.0.1",
        destinationPort: Int = 80
    ) {
        self.id = id
        self.direction = direction
        self.bindHost = bindHost
        self.listenPort = listenPort
        self.destinationHost = destinationHost
        self.destinationPort = destinationPort
    }

    var sshSpecification: String {
        let bind = bindHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if direction == .dynamic {
            return bind.isEmpty ? "\(listenPort)" : "\(bind):\(listenPort)"
        }
        let destination = destinationHost.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let prefix = bind.isEmpty ? "" : "\(bind):"
        return "\(prefix)\(listenPort):\(destination):\(destinationPort)"
    }

    var isValid: Bool {
        (1...65_535).contains(listenPort) &&
            (direction == .dynamic || (
                !destinationHost.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty && (1...65_535).contains(destinationPort)
            ))
    }
}

@MainActor
final class PortForwardController: ObservableObject {
    enum Status: Equatable {
        case stopped
        case starting
        case running
        case failed(String)

        var label: String {
            switch self {
            case .stopped: "未启动"
            case .starting: "连接中"
            case .running: "转发中"
            case .failed: "失败"
            }
        }
    }

    @Published private(set) var statuses: [UUID: Status] = [:]
    private var controls: [UUID: CommandProcessControl] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func fail(_ id: UUID, message: String) {
        statuses[id] = .failed(message)
    }

    func start(
        _ rule: PortForwardRule,
        profile: SessionProfile,
        jumpProfile: SessionProfile?
    ) {
        stop(rule.id)
        guard rule.isValid else {
            statuses[rule.id] = .failed("请填写有效的端口和目标地址。")
            return
        }
        statuses[rule.id] = .starting
        let control = CommandProcessControl()
        controls[rule.id] = control
        tasks[rule.id] = Task { [weak self] in
            do {
                let invocation = try SSHCommandBuilder.portForward(
                    profile: profile,
                    jumpProfile: jumpProfile,
                    rule: rule
                )
                self?.statuses[rule.id] = .running
                let result = try await CommandRunner.run(
                    invocation,
                    control: control
                )
                guard !Task.isCancelled else { return }
                if result.exitCode == 0 {
                    self?.statuses[rule.id] = .stopped
                } else {
                    let message = CommandOutputSummary.text(result.output)
                    self?.statuses[rule.id] = .failed(
                        message.isEmpty
                            ? "SSH 已退出（\(result.exitCode)）。"
                            : message
                    )
                }
            } catch is CancellationError {
                self?.statuses[rule.id] = .stopped
            } catch {
                self?.statuses[rule.id] = .failed(error.localizedDescription)
            }
            self?.controls.removeValue(forKey: rule.id)
            self?.tasks.removeValue(forKey: rule.id)
        }
    }

    func stop(_ id: UUID) {
        tasks[id]?.cancel()
        _ = controls[id]?.stop()
        tasks.removeValue(forKey: id)
        controls.removeValue(forKey: id)
        statuses[id] = .stopped
    }

    func stopAll() {
        for id in Array(tasks.keys) { stop(id) }
    }
}
