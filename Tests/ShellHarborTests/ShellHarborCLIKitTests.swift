import Foundation
import XCTest
@testable import ShellHarborCLIKit

final class ShellHarborCLIKitTests: XCTestCase {
    func testRemoteResolutionSupportsNameAndUUIDPrefix() throws {
        let first = try profile(
            id: "11111111-1111-1111-1111-111111111111",
            name: "Production"
        )
        let second = try profile(
            id: "22222222-2222-2222-2222-222222222222",
            name: "Staging"
        )

        XCTAssertEqual(
            try SHRemoteStore.resolve(
                "production",
                in: [first, second]
            ).id,
            first.id
        )
        XCTAssertEqual(
            try SHRemoteStore.resolve(
                "22222222",
                in: [first, second]
            ).id,
            second.id
        )
        XCTAssertEqual(
            try SHRemoteStore.resolve("2", in: [first, second]).id,
            second.id
        )
    }

    func testPasswordSSHUsesDescriptorWithoutPlaintextInArguments() throws {
        guard SHSSHCommandBuilder.sshpassPath() != nil else {
            throw XCTSkip("当前环境未安装 sshpass")
        }
        let remote = try profile(
            name: "Password Remote",
            authentication: "password",
            password: "target-secret"
        )

        let invocation = try SHSSHCommandBuilder.build(
            profile: remote,
            jumpProfile: nil,
            targetPasswordDescriptor: 42,
            jumpPasswordDescriptor: nil
        )

        XCTAssertTrue(invocation.executablePath.hasSuffix("sshpass"))
        XCTAssertEqual(Array(invocation.arguments.prefix(2)), ["-d", "42"])
        XCTAssertFalse(
            invocation.arguments.joined(separator: " ")
                .contains("target-secret")
        )
    }

    func testTargetAndJumpPasswordsUseSeparateDescriptors() throws {
        guard SHSSHCommandBuilder.sshpassPath() != nil else {
            throw XCTSkip("当前环境未安装 sshpass")
        }
        let target = try profile(
            name: "Target",
            authentication: "password",
            password: "target-secret",
            jumpRemoteID: "22222222-2222-2222-2222-222222222222"
        )
        let jump = try profile(
            id: "22222222-2222-2222-2222-222222222222",
            name: "Jump",
            authentication: "password",
            password: "jump-secret"
        )

        let invocation = try SHSSHCommandBuilder.build(
            profile: target,
            jumpProfile: jump,
            targetPasswordDescriptor: 42,
            jumpPasswordDescriptor: 43
        )
        let command = invocation.arguments.joined(separator: " ")

        XCTAssertEqual(Array(invocation.arguments.prefix(2)), ["-d", "42"])
        XCTAssertTrue(command.contains("'-d' '43'"))
        XCTAssertFalse(command.contains("target-secret"))
        XCTAssertFalse(command.contains("jump-secret"))
    }

    func testShcliLoadsBashrcForInteractiveBashSessions() throws {
        let remote = try profile(name: "Bash", host: "example.com")
        let invocation = try SHSSHCommandBuilder.build(
            profile: remote,
            jumpProfile: nil,
            targetPasswordDescriptor: nil,
            jumpPasswordDescriptor: nil
        )

        XCTAssertTrue(invocation.arguments.last?.contains("$HOME/.bashrc") == true)
        XCTAssertTrue(invocation.arguments.last?.contains("exec \"$shell\" -i") == true)
    }

    func testPasswordPipeContainsPasswordOnlyInAnonymousDescriptor() throws {
        let pipe = try SHPasswordPipe(password: "pipe-secret")
        let data = FileHandle(
            fileDescriptor: pipe.readDescriptor,
            closeOnDealloc: false
        ).readDataToEndOfFile()

        XCTAssertEqual(String(decoding: data, as: UTF8.self), "pipe-secret\n")
    }

    func testDecodedProfileDefaultsRemainCompatibleWithOldConfig() throws {
        let remote = try profile(name: "Legacy", host: "localhost")

        XCTAssertEqual(remote.resolvedHost, "127.0.0.1")
        XCTAssertEqual(remote.resolvedPort, 22)
        XCTAssertEqual(remote.resolvedAuthentication, "agent")
        XCTAssertEqual(remote.resolvedGroup, "未分组")
    }

    private func profile(
        id: String = "11111111-1111-1111-1111-111111111111",
        name: String,
        host: String = "example.com",
        authentication: String? = nil,
        password: String? = nil,
        jumpRemoteID: String? = nil
    ) throws -> SHRemoteProfile {
        var object: [String: Any] = [
            "id": id,
            "name": name,
            "host": host,
            "username": "deploy"
        ]
        if let authentication {
            object["authentication"] = authentication
        }
        if let password {
            object["password"] = password
        }
        if let jumpRemoteID {
            object["jumpRemoteID"] = jumpRemoteID
        }
        return try JSONDecoder().decode(
            SHRemoteProfile.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }
}
