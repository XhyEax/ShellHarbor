import Foundation
import NIOCore
import Observation

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
        partner?.context?.close(promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
        partner?.context?.close(promise: nil)
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

    var selectedSessionID: UUID?
    var bindHost = "127.0.0.1"
    var listenPort = 8080
    var targetHost = "127.0.0.1"
    var targetPort = 80
    private(set) var status: Status = .stopped
    @ObservationIgnored private var listener: Channel?
    @ObservationIgnored private var startTask: Task<Void, Never>?

    func start(using session: MobileSession) {
        stop()
        guard (1...65_535).contains(listenPort),
              (1...65_535).contains(targetPort),
              !targetHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            status = .failed(MobilePortForwardError.invalidConfiguration.localizedDescription)
            return
        }
        status = .starting
        let requestedPort = listenPort
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                let channel = try await session.controller.startLocalPortForward(
                    bindHost: bindHost,
                    listenPort: requestedPort,
                    targetHost: targetHost,
                    targetPort: targetPort
                )
                guard !Task.isCancelled else {
                    try? await channel.close()
                    return
                }
                listener = channel
                status = .running(channel.localAddress?.port ?? requestedPort)
            } catch {
                status = .failed(error.localizedDescription)
            }
            startTask = nil
        }
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        let active = listener
        listener = nil
        status = .stopped
        Task { try? await active?.close() }
    }
}
