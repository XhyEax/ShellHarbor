import Foundation
import Darwin
import NIOCore
import Observation

enum MobileLocalNetworkAddresses {
    static var ipv4: [String] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }
        var values: [String] = []
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(item.pointee.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_LOOPBACK == 0,
                  item.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            var address = item.pointee.ifa_addr.pointee
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                &address,
                socklen_t(item.pointee.ifa_addr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }
            let end = host.firstIndex(of: 0) ?? host.endIndex
            values.append(String(decoding: host[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self))
        }
        return Array(Set(values)).sorted()
    }
}

struct MobilePortForwardRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var selectedSessionID: UUID?
    var bindHost = "0.0.0.0"
    var listenPort = 8080
    var targetHost = "127.0.0.1"
    var targetPort = 80
}

enum MobilePortForwardError: LocalizedError {
    case sessionNotConnected
    case invalidConfiguration

    var errorDescription: String? {
        switch self {
        case .sessionNotConnected: "请先连接一个 SSH Session。"
        case .invalidConfiguration: "请填写有效的监听端口、目标地址和目标端口。"
        }
    }
}

final class MobilePortForwardGlue: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    private var partner: MobilePortForwardGlue?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    private init() {}

    static func matchedPair() -> (MobilePortForwardGlue, MobilePortForwardGlue) {
        let first = MobilePortForwardGlue()
        let second = MobilePortForwardGlue()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.context?.write(data, promise: nil)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.context?.flush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.context?.close(mode: .all, promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
        partner?.context?.close(promise: nil)
    }

    func read(context: ChannelHandlerContext) {
        if partner?.context?.channel.isWritable == true {
            context.read()
        } else {
            pendingRead = true
        }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
        context.fireChannelWritabilityChanged()
    }

    private func partnerBecameWritable() {
        guard pendingRead else { return }
        pendingRead = false
        context?.read()
    }
}

@Observable @MainActor
final class MobilePortForwardStore {
    enum Status: Equatable {
        case stopped
        case starting
        case running(Int)
        case failed(String)
    }

    var rules: [MobilePortForwardRule] {
        didSet { persist() }
    }
    private(set) var statuses: [UUID: Status] = [:]
    @ObservationIgnored private var listeners: [UUID: Channel] = [:]
    @ObservationIgnored private var startTasks: [UUID: Task<Void, Never>] = [:]

    init() {
        rules = UserDefaults.standard.data(forKey: "mobilePortForwardRules")
            .flatMap { try? JSONDecoder().decode([MobilePortForwardRule].self, from: $0) }
            ?? [MobilePortForwardRule()]
    }

    func addRule() { rules.append(MobilePortForwardRule()) }

    func removeRule(_ id: UUID) {
        stop(id)
        rules.removeAll { $0.id == id }
    }

    func start(_ rule: MobilePortForwardRule, using session: MobileSession) {
        stop(rule.id)
        guard (1...65_535).contains(rule.listenPort),
              (1...65_535).contains(rule.targetPort),
              !rule.targetHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            statuses[rule.id] = .failed(MobilePortForwardError.invalidConfiguration.localizedDescription)
            return
        }
        statuses[rule.id] = .starting
        let requestedPort = rule.listenPort
        startTasks[rule.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let channel = try await session.controller.startLocalPortForward(
                    bindHost: rule.bindHost,
                    listenPort: requestedPort,
                    targetHost: rule.targetHost,
                    targetPort: rule.targetPort
                )
                guard !Task.isCancelled else {
                    try? await channel.close()
                    return
                }
                listeners[rule.id] = channel
                statuses[rule.id] = .running(channel.localAddress?.port ?? requestedPort)
            } catch {
                statuses[rule.id] = .failed(error.localizedDescription)
            }
            startTasks[rule.id] = nil
        }
    }

    func stop(_ id: UUID) {
        startTasks[id]?.cancel()
        startTasks[id] = nil
        let active = listeners.removeValue(forKey: id)
        statuses[id] = .stopped
        Task { try? await active?.close() }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        UserDefaults.standard.set(data, forKey: "mobilePortForwardRules")
    }
}
