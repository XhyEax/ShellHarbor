import Foundation
import ShellHarborCLIKit

private let usage = """
用法：
  shcli ls [--json]
  shcli c <Remote 名称、序号或 UUID> [--mosh|--ssh]
  shcli help

说明：
  c 默认使用 Remote 保存的 SSH/Mosh 方式；--mosh 或 --ssh 可临时覆盖。
  密码读取自 ShellHarbor 本地 RSA 加密配置，并通过匿名管道传递。
"""

private struct ListedRemote: Encodable {
    let index: Int
    let id: UUID
    let name: String
    let group: String
    let endpoint: String
    let authentication: String
    let jumpRemoteID: UUID?
}

private enum ConnectionOverride {
    case configured
    case ssh
    case mosh
}

@main
private enum ShellHarborCLI {
    static func main() {
        do {
            try run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(
                Data("shcli: \(error.localizedDescription)\n".utf8)
            )
            exit(1)
        }
    }

    private static func run(_ arguments: [String]) throws {
        guard let command = arguments.first else {
            print(usage)
            return
        }
        switch command {
        case "help", "--help", "-h":
            print(usage)
        case "ls", "list":
            guard arguments.count <= 2 else {
                throw SHCLIError.invalidConfiguration
            }
            let profiles = try SHRemoteStore.load()
            if arguments.dropFirst().first == "--json" {
                try printJSON(profiles)
            } else {
                printTable(profiles)
            }
        case "c", "connect":
            let values = Array(arguments.dropFirst())
            let flags = values.filter { $0 == "--mosh" || $0 == "--ssh" }
            let selectors = values.filter { $0 != "--mosh" && $0 != "--ssh" }
            guard selectors.count == 1, flags.count <= 1 else {
                print(usage)
                exit(2)
            }
            let override: ConnectionOverride = flags.first == "--mosh"
                ? .mosh
                : (flags.first == "--ssh" ? .ssh : .configured)
            try connect(selector: selectors[0], override: override)
        default:
            throw SHCLIError.remoteNotFound(command)
        }
    }

    private static func printTable(_ profiles: [SHRemoteProfile]) {
        print("INDEX\tGROUP\tNAME\tENDPOINT\tAUTH\tVIA\tID")
        let namesByID = Dictionary(
            uniqueKeysWithValues: profiles.map { ($0.id, $0.name) }
        )
        for (offset, profile) in profiles.enumerated() {
            let via = profile.jumpRemoteID.flatMap { namesByID[$0] } ?? "-"
            print(
                "\(offset + 1)\t\(profile.resolvedGroup)\t\(profile.name)\t" +
                "\(profile.endpoint)\t\(profile.resolvedAuthentication)\t" +
                "\(via)\t\(profile.id.uuidString)"
            )
        }
    }

    private static func printJSON(_ profiles: [SHRemoteProfile]) throws {
        let values = profiles.enumerated().map { offset, profile in
            ListedRemote(
                index: offset + 1,
                id: profile.id,
                name: profile.name,
                group: profile.resolvedGroup,
                endpoint: profile.endpoint,
                authentication: profile.resolvedAuthentication,
                jumpRemoteID: profile.jumpRemoteID
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(values)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func connect(
        selector: String,
        override: ConnectionOverride
    ) throws {
        let profiles = try SHRemoteStore.load()
        var target = try SHRemoteStore.resolve(selector, in: profiles)
        target = try SHRemoteStore.decrypted(target)

        var jump: SHRemoteProfile?
        if let jumpID = target.jumpRemoteID {
            guard let storedJump = profiles.first(where: { $0.id == jumpID }) else {
                throw SHCLIError.jumpRemoteNotFound(target.name)
            }
            jump = try SHRemoteStore.decrypted(storedJump)
        }

        let targetPipe = try target.usesPassword
            ? SHPasswordPipe(password: target.password ?? "")
            : nil
        let jumpPipe = try jump?.usesPassword == true
            ? SHPasswordPipe(password: jump?.password ?? "")
            : nil
        let targetTailscale = try jump == nil
            ? SHTailscaleProxyProcess.startIfNeeded(profile: target)
            : nil
        let jumpTailscale = try jump.flatMap {
            try SHTailscaleProxyProcess.startIfNeeded(profile: $0)
        }
        if let targetTailscale {
            target.proxyPort = targetTailscale.port
        }
        if let jumpTailscale {
            jump?.proxyPort = jumpTailscale.port
        }
        let useMosh = override == .mosh || (
            override == .configured && target.prefersMosh
        )
        let relayProcess = jumpTailscale ?? targetTailscale
        let tailscaleClientPath = try useMosh
            ? relayProcess?.configureMoshClient(target: target.resolvedHost)
            : nil
        let invocation = try useMosh
            ? SHSSHCommandBuilder.buildMosh(
                profile: target,
                jumpProfile: jump,
                targetPasswordDescriptor: targetPipe?.readDescriptor,
                jumpPasswordDescriptor: jumpPipe?.readDescriptor,
                tailscaleClientPath: tailscaleClientPath
            )
            : SHSSHCommandBuilder.build(
                profile: target,
                jumpProfile: jump,
                targetPasswordDescriptor: targetPipe?.readDescriptor,
                jumpPasswordDescriptor: jumpPipe?.readDescriptor
            )

        try withExtendedLifetime((
            targetPipe,
            jumpPipe,
            targetTailscale,
            jumpTailscale
        )) {
            try SHProcessExecutor.replaceCurrentProcess(with: invocation)
        }
    }
}
