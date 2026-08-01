import CryptoKit
import Foundation
import Security

enum MobilePasswordCipherError: LocalizedError {
    case keyCreation
    case keyPersistence
    case encryption
    case decryption
    case invalidCiphertext

    var errorDescription: String? {
        switch self {
        case .keyCreation, .keyPersistence: "无法创建本地密码保护密钥。"
        case .encryption: "无法加密密码。"
        case .decryption, .invalidCiphertext: "无法解密已保存的密码。"
        }
    }
}

enum MobilePasswordCipher {
    static let prefix = "rsa:v1:"
    private static let algorithm: SecKeyAlgorithm = .rsaEncryptionOAEPSHA256

    private struct Envelope: Codable {
        let encryptedKey: Data
        let sealedPassword: Data
    }

    static func isEncrypted(_ value: String) -> Bool {
        value.hasPrefix(prefix)
    }

    static func encrypt(_ plaintext: String) throws -> String {
        guard !plaintext.isEmpty else { return "" }
        let privateKey = try loadOrCreatePrivateKey()
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              SecKeyIsAlgorithmSupported(publicKey, .encrypt, algorithm) else {
            throw MobilePasswordCipherError.encryption
        }
        let dataKey = SymmetricKey(size: .bits256)
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: dataKey)
        guard let combined = sealed.combined else { throw MobilePasswordCipherError.encryption }
        let rawKey = dataKey.withUnsafeBytes { Data($0) }
        var error: Unmanaged<CFError>?
        guard let encryptedKey = SecKeyCreateEncryptedData(
            publicKey,
            algorithm,
            rawKey as CFData,
            &error
        ) as Data? else {
            throw MobilePasswordCipherError.encryption
        }
        let envelope = try JSONEncoder().encode(
            Envelope(encryptedKey: encryptedKey, sealedPassword: combined)
        )
        return prefix + envelope.base64EncodedString()
    }

    static func decrypt(_ ciphertext: String) throws -> String {
        guard !ciphertext.isEmpty else { return "" }
        guard isEncrypted(ciphertext),
              let encoded = Data(base64Encoded: String(ciphertext.dropFirst(prefix.count))),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: encoded) else {
            throw MobilePasswordCipherError.invalidCiphertext
        }
        let privateKey = try loadOrCreatePrivateKey()
        var error: Unmanaged<CFError>?
        guard let rawKey = SecKeyCreateDecryptedData(
            privateKey,
            algorithm,
            envelope.encryptedKey as CFData,
            &error
        ) as Data? else {
            throw MobilePasswordCipherError.decryption
        }
        let sealed = try AES.GCM.SealedBox(combined: envelope.sealedPassword)
        let plaintext = try AES.GCM.open(sealed, using: SymmetricKey(data: rawKey))
        guard let result = String(data: plaintext, encoding: .utf8) else {
            throw MobilePasswordCipherError.invalidCiphertext
        }
        return result
    }

    private static func loadOrCreatePrivateKey() throws -> SecKey {
        let url = try privateKeyURL()
        if let data = try? Data(contentsOf: url) {
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                kSecAttrKeySizeInBits as String: 2_048
            ]
            if let key = SecKeyCreateWithData(data as CFData, attributes as CFDictionary, nil) {
                return key
            }
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2_048
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw MobilePasswordCipherError.keyCreation
        }
        guard let data = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw MobilePasswordCipherError.keyPersistence
        }
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return key
    }

    private static func privateKeyURL() throws -> URL {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw MobilePasswordCipherError.keyPersistence
        }
        let directory = support.appendingPathComponent("ShellHarbor", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        return directory.appendingPathComponent("password-rsa-private.der")
    }
}
