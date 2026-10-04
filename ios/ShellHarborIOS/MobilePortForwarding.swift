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

struct MobilePortForwardRuleGroup: Identifiable, Equatable {
    let remoteID: UUID?
    let ruleIDs: [UUID]

    var id: String { remoteID?.uuidString ?? "__ungrouped__" }
}

enum MobilePortForwardPresentation {
    static func groups(
        rules: [MobilePortForwardRule],
        sessionRemoteIDs: [UUID: UUID]
    ) -> [MobilePortForwardRuleGroup] {
        var order: [UUID?] = []
        var ruleIDs: [String: [UUID]] = [:]
        for rule in rules {
            let remoteID = rule.selectedSessionID.flatMap {
                sessionRemoteIDs[$0]
            }
            if !order.contains(where: { $0 == remoteID }) {
                order.append(remoteID)
            }
            let key = remoteID?.uuidString ?? "__ungrouped__"
            ruleIDs[key, default: []].append(rule.id)
        }
        return order.map { remoteID in
            let key = remoteID?.uuidString ?? "__ungrouped__"
            return MobilePortForwardRuleGroup(
                remoteID: remoteID,
                ruleIDs: ruleIDs[key, default: []]
            )
        }
    }

    static func browserURL(
        for rule: MobilePortForwardRule,
        listeningPort: Int
    ) -> URL? {
        guard (1...65_535).contains(listeningPort) else { return nil }
        let configuredHost = rule.bindHost.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let host = configuredHost.isEmpty || configuredHost == "0.0.0.0"
            ? "127.0.0.1"
            : configuredHost
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = listeningPort
        components.path = "/"
        return components.url
    }
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
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

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
        partner?.write(unwrapInboundIn(data))
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.flush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.close()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
        partner?.close()
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

    private func write(_ buffer: ByteBuffer) {
        guard let context else { return }
        let operation = {
            context.write(NIOAny(buffer), promise: nil)
        }
        if context.eventLoop.inEventLoop {
            operation()
        } else {
            context.eventLoop.execute(operation)
        }
    }

    private func close() {
        guard let context else { return }
        let operation = {
            context.close(mode: .all, promise: nil)
        }
        if context.eventLoop.inEventLoop {
            operation()
        } else {
            context.eventLoop.execute(operation)
        }
    }

    private func flush() {
        guard let context else { return }
        if context.eventLoop.inEventLoop {
            context.flush()
        } else {
            context.eventLoop.execute { context.flush() }
        }
    }

    private func partnerBecameWritable() {
        guard let context else { return }
        let operation = { [weak self] in
            guard let self, self.pendingRead else { return }
            self.pendingRead = false
            context.read()
        }
        if context.eventLoop.inEventLoop {
            operation()
        } else {
            context.eventLoop.execute(operation)
        }
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
    @ObservationIgnored private var startTokens: [UUID: UUID] = [:]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rules = defaults.data(forKey: "mobilePortForwardRules")
            .flatMap { try? JSONDecoder().decode([MobilePortForwardRule].self, from: $0) }
            ?? [MobilePortForwardRule()]
    }

    func addRule() { rules.append(MobilePortForwardRule()) }

    func startAll(sessions: [MobileSession]) {
        for rule in rules {
            if statuses[rule.id] == .starting { continue }
            if case .running? = statuses[rule.id] { continue }
            guard let sessionID = rule.selectedSessionID,
                  let session = sessions.first(where: { $0.id == sessionID })
            else {
                statuses[rule.id] = .failed(
                    MobilePortForwardError.sessionNotConnected.localizedDescription
                )
                continue
            }
            start(rule, using: session)
        }
    }

    func stopAll() {
        for id in Set(startTasks.keys).union(listeners.keys) {
            stop(id)
        }
    }

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
        let token = UUID()
        startTokens[rule.id] = token
        startTasks[rule.id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if startTokens[rule.id] == token {
                    startTasks[rule.id] = nil
                }
            }
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
                guard startTokens[rule.id] == token else {
                    try? await channel.close()
                    return
                }
                listeners[rule.id] = channel
                statuses[rule.id] = .running(channel.localAddress?.port ?? requestedPort)
            } catch {
                if startTokens[rule.id] == token {
                    statuses[rule.id] = .failed(error.localizedDescription)
                }
            }
        }
    }

    func stop(_ id: UUID) {
        startTokens[id] = nil
        startTasks[id]?.cancel()
        startTasks[id] = nil
        let active = listeners.removeValue(forKey: id)
        statuses[id] = .stopped
        Task { try? await active?.close() }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: "mobilePortForwardRules")
    }
}
