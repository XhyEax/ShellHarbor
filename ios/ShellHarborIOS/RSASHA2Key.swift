@preconcurrency import Crypto
import Foundation
import NIOCore
@preconcurrency import NIOSSH
import _CryptoExtras

enum RSASHA2KeyError: Error {
    case invalidOpenSSHKey
    case encryptedOpenSSHKey
}

private struct OpenSSHKeyReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ data: Data) {
        bytes = Array(data)
    }

    mutating func read(count: Int) throws -> Data {
        guard count >= 0, offset <= bytes.count - count else {
            throw RSASHA2KeyError.invalidOpenSSHKey
        }
        defer { offset += count }
        return Data(bytes[offset ..< offset + count])
    }

    mutating func readUInt32() throws -> UInt32 {
        let value = try read(count: 4)
        return value.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    mutating func readString() throws -> Data {
        try read(count: Int(readUInt32()))
    }
}

private struct OpenSSHRSAPrimitives {
    let n: Data
    let e: Data
    let d: Data
    let p: Data
    let q: Data

    init(openSSH data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw RSASHA2KeyError.invalidOpenSSHKey
        }
        let payload = text
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let decoded = Data(base64Encoded: payload) else {
            throw RSASHA2KeyError.invalidOpenSSHKey
        }

        var outer = OpenSSHKeyReader(decoded)
        guard try outer.read(count: 15) == Data("openssh-key-v1\0".utf8),
              String(data: try outer.readString(), encoding: .utf8) == "none",
              String(data: try outer.readString(), encoding: .utf8) == "none" else {
            throw RSASHA2KeyError.encryptedOpenSSHKey
        }
        _ = try outer.readString()
        guard try outer.readUInt32() == 1 else {
            throw RSASHA2KeyError.invalidOpenSSHKey
        }
        _ = try outer.readString()
        var privateSection = OpenSSHKeyReader(try outer.readString())
        let firstCheck = try privateSection.readUInt32()
        guard try privateSection.readUInt32() == firstCheck,
              String(data: try privateSection.readString(), encoding: .utf8) == "ssh-rsa" else {
            throw RSASHA2KeyError.invalidOpenSSHKey
        }

        n = Self.unsigned(try privateSection.readString())
        e = Self.unsigned(try privateSection.readString())
        d = Self.unsigned(try privateSection.readString())
        _ = try privateSection.readString() // iqmp; swift-crypto derives CRT values.
        p = Self.unsigned(try privateSection.readString())
        q = Self.unsigned(try privateSection.readString())
    }

    private static func unsigned(_ value: Data) -> Data {
        if value.count > 1, value.first == 0 { return value.dropFirst() }
        return value
    }
}

private struct RSASHA256Signature: NIOSSHSignatureProtocol {
    static let signaturePrefix = "rsa-sha2-256"
    let rawRepresentation: Data

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeInteger(UInt32(rawRepresentation.count))
            + buffer.writeData(rawRepresentation)
    }

    static func read(from buffer: inout ByteBuffer) throws -> Self {
        guard let count = buffer.readInteger(as: UInt32.self),
              let data = buffer.readData(length: Int(count)) else {
            throw RSASHA2KeyError.invalidOpenSSHKey
        }
        return Self(rawRepresentation: data)
    }
}

private struct RSASHA256PublicKey: NIOSSHPublicKeyProtocol, NIOSSHUserAuthenticationKeyProtocol {
    static let publicKeyPrefix = "ssh-rsa"
    let rawRepresentation: Data
    let exponent: Data
    let modulus: Data
    let signingKey: _RSA.Signing.PublicKey

    var userAuthenticationAlgorithmPrefix: String { "rsa-sha2-256" }
    var userAuthenticationBlobPrefix: String { "ssh-rsa" }

    init(primitives: OpenSSHRSAPrimitives, signingKey: _RSA.Signing.PublicKey) {
        exponent = Self.mpint(primitives.e)
        modulus = Self.mpint(primitives.n)
        self.signingKey = signingKey
        var raw = Data()
        raw.append(Self.length(exponent.count))
        raw.append(exponent)
        raw.append(Self.length(modulus.count))
        raw.append(modulus)
        rawRepresentation = raw
    }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        guard let signature = signature as? RSASHA256Signature else { return false }
        return signingKey.isValidSignature(
            .init(rawRepresentation: signature.rawRepresentation),
            for: SHA256.hash(data: data),
            padding: .insecurePKCS1v1_5
        )
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeData(rawRepresentation)
    }

    static func read(from buffer: inout ByteBuffer) throws -> Self {
        throw RSASHA2KeyError.invalidOpenSSHKey
    }

    private static func mpint(_ value: Data) -> Data {
        guard let first = value.first, first & 0x80 != 0 else { return value }
        return Data([0]) + value
    }

    private static func length(_ count: Int) -> Data {
        let value = UInt32(count).bigEndian
        return withUnsafeBytes(of: value) { Data($0) }
    }
}

final class RSASHA256PrivateKey: NIOSSHPrivateKeyProtocol {
    static let keyPrefix = "rsa-sha2-256"
    let publicKey: NIOSSHPublicKeyProtocol
    private let signingKey: _RSA.Signing.PrivateKey

    init(openSSH data: Data) throws {
        let primitives = try OpenSSHRSAPrimitives(openSSH: data)
        let key = try _RSA.Signing.PrivateKey(
            n: primitives.n,
            e: primitives.e,
            d: primitives.d,
            p: primitives.p,
            q: primitives.q
        )
        signingKey = key
        publicKey = RSASHA256PublicKey(primitives: primitives, signingKey: key.publicKey)
    }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        let signature = try signingKey.signature(
            for: SHA256.hash(data: data),
            padding: .insecurePKCS1v1_5
        )
        return RSASHA256Signature(rawRepresentation: signature.rawRepresentation)
    }
}

final class RSASHA256AuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let privateKey: NIOSSHPrivateKey
    private var hasOffered = false

    init(username: String, openSSH data: Data) throws {
        self.username = username
        privateKey = NIOSSHPrivateKey(custom: try RSASHA256PrivateKey(openSSH: data))
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !hasOffered, availableMethods.contains(.publicKey) else {
            nextChallengePromise.succeed(nil)
            return
        }
        hasOffered = true
        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "",
                offer: .privateKey(.init(privateKey: privateKey))
            )
        )
    }
}
