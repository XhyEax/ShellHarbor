import Darwin
import Foundation
import mosh

enum MobileMoshError: LocalizedError {
    case pipeCreation
    case streamCreation
    case missingLocale
    case bootstrapFailed
    case invalidBootstrapResponse
    case missingJumpRemote
    case unresolvedHost(String)
    case clientExited(Int32)

    var errorDescription: String? {
        switch self {
        case .pipeCreation, .streamCreation: "无法创建 Mosh 本地终端通道。"
        case .missingLocale: "Mosh UTF-8 locale 资源缺失。"
        case .bootstrapFailed: "无法启动远端 mosh-server。"
        case .invalidBootstrapResponse: "mosh-server 未返回有效的端口和密钥。"
        case .missingJumpRemote: "跳板 Mosh 尚未选择跳板 Remote。"
        case .unresolvedHost(let host): "无法解析 Mosh 主机：\(host)"
        case .clientExited(let code): "Mosh 客户端已退出（\(code)）。"
        }
    }
}

final class MobileMoshTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var inputWriteFD: Int32 = -1
    private var outputReadFD: Int32 = -1
    private var window = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    private var stopped = false

    func run(
        host: String,
        port: String,
        key: String,
        restoredState: Data,
        onStarted: @escaping @Sendable () -> Void,
        onOutput: @escaping @Sendable ([UInt8]) -> Void,
        onState: @escaping @Sendable (Data) -> Void
    ) async throws {
        guard let localePath = Bundle.main.path(forResource: "locales", ofType: "bundle") else {
            throw MobileMoshError.missingLocale
        }
        setenv("PATH_LOCALE", localePath, 1)
        var inputPipe = [Int32](repeating: -1, count: 2)
        var outputPipe = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&inputPipe) == 0, Darwin.pipe(&outputPipe) == 0 else {
            closePair(inputPipe)
            closePair(outputPipe)
            throw MobileMoshError.pipeCreation
        }
        guard let input = fdopen(inputPipe[0], "r"),
              let output = fdopen(outputPipe[1], "w") else {
            closePair(inputPipe)
            closePair(outputPipe)
            throw MobileMoshError.streamCreation
        }
        setvbuf(output, nil, _IONBF, 0)
        lock.withLock {
            inputWriteFD = inputPipe[1]
            outputReadFD = outputPipe[0]
            stopped = false
        }

        let readerFD = outputPipe[0]
        let reader = Task.detached(priority: .userInitiated) {
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = Darwin.read(readerFD, &buffer, buffer.count)
                if count > 0 { onOutput(Array(buffer.prefix(count))) }
                else if count == 0 || errno != EINTR { return }
            }
        }

        onStarted()
        let stateBox = MoshStateCallbackBox(onState)
        let streams = MoshFileBox(input: input, output: output)
        let code: Int32 = await Task.detached(priority: .userInitiated) { [self] in
            host.withCString { hostPointer in
                port.withCString { portPointer in
                    key.withCString { keyPointer in
                        // Mosh's speculative overlay uses terminal attributes
                        // that the iOS SwiftTerm renderer does not reproduce
                        // reliably; predicted glyphs can appear as blank
                        // cells until the server acknowledges them. Disable
                        // prediction so every visible character is confirmed
                        // remote output.
                        "never".withCString { predictionPointer in
                            "no".withCString { overwritePointer in
                                restoredState.withUnsafeBytes { stateBytes in
                                    mosh_main(
                                        streams.input,
                                        streams.output,
                                        &window,
                                        { context, bytes, count in
                                            guard let context, let bytes else { return }
                                            let callback = Unmanaged<MoshStateCallbackBox>
                                                .fromOpaque(context).takeUnretainedValue()
                                            callback.receive(Data(bytes: bytes, count: count))
                                        },
                                        Unmanaged.passUnretained(stateBox).toOpaque(),
                                        hostPointer,
                                        portPointer,
                                        keyPointer,
                                        predictionPointer,
                                        stateBytes.bindMemory(to: CChar.self).baseAddress,
                                        restoredState.count,
                                        overwritePointer
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }.value

        fclose(input)
        fclose(output)
        reader.cancel()
        cleanupDescriptors()
        if code != 0 && !lock.withLock({ stopped }) {
            throw MobileMoshError.clientExited(code)
        }
    }

    func send(_ bytes: [UInt8]) {
        let descriptor = lock.withLock { inputWriteFD }
        guard descriptor >= 0, !bytes.isEmpty else { return }
        bytes.withUnsafeBytes { pointer in
            guard let base = pointer.baseAddress else { return }
            var offset = 0
            while offset < pointer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), pointer.count - offset)
                if count > 0 { offset += count }
                else if errno != EINTR { return }
            }
        }
    }

    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        lock.withLock {
            window.ws_col = UInt16(clamping: cols)
            window.ws_row = UInt16(clamping: rows)
            window.ws_xpixel = UInt16(clamping: pixelWidth)
            window.ws_ypixel = UInt16(clamping: pixelHeight)
        }
    }

    func stop() {
        lock.withLock { stopped = true }
        send([0x1e, 0x2e])
        let descriptor = lock.withLock { () -> Int32 in
            defer { inputWriteFD = -1 }
            return inputWriteFD
        }
        if descriptor >= 0 { Darwin.close(descriptor) }
    }

    private func cleanupDescriptors() {
        let descriptors = lock.withLock { () -> [Int32] in
            defer {
                inputWriteFD = -1
                outputReadFD = -1
            }
            return [inputWriteFD, outputReadFD]
        }
        for descriptor in descriptors where descriptor >= 0 { Darwin.close(descriptor) }
    }

    private func closePair(_ descriptors: [Int32]) {
        for descriptor in descriptors where descriptor >= 0 { Darwin.close(descriptor) }
    }
}

private final class MoshStateCallbackBox: @unchecked Sendable {
    let receive: @Sendable (Data) -> Void
    init(_ receive: @escaping @Sendable (Data) -> Void) { self.receive = receive }
}

private final class MoshFileBox: @unchecked Sendable {
    let input: UnsafeMutablePointer<FILE>
    let output: UnsafeMutablePointer<FILE>
    init(input: UnsafeMutablePointer<FILE>, output: UnsafeMutablePointer<FILE>) {
        self.input = input
        self.output = output
    }
}
