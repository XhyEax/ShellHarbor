import CryptoKit
import Foundation
import Security

enum PasswordCipherError: Error {
    case invalidCiphertext
    case keyCreation
    case keyPersistence
    case encryption
    case decryption
}

enum PasswordCipher {
    static let prefix = "rsa:v1:"
    private static let rsaAlgorithm: SecKeyAlgorithm =
        .rsaEncryptionOAEPSHA256
    private static let keySize = 2_048

    private struct Envelope: Codable {
        let encryptedKey: Data
        let sealedPassword: Data
    }

    private static var keyDirectory: URL {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("ShellHarbor", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private static var privateKeyURL: URL {
        keyDirectory.appendingPathComponent("password-rsa-private.der")
    }

    private static var publicKeyURL: URL {
        keyDirectory.appendingPathComponent("password-rsa-public.der")
    }

    static func isEncrypted(_ value: String) -> Bool {
        value.hasPrefix(prefix)
    }

    static func encrypt(_ plaintext: String) throws -> String {
        let (_, publicKey) = try loadOrCreateKeyPair()
        return try encrypt(plaintext, using: publicKey)
    }

    static func decrypt(_ ciphertext: String) throws -> String {
        let (privateKey, _) = try loadOrCreateKeyPair()
        return try decrypt(ciphertext, using: privateKey)
    }

    static func encrypt(
        _ plaintext: String,
        using publicKey: SecKey
    ) throws -> String {
        guard SecKeyIsAlgorithmSupported(
            publicKey,
            .encrypt,
            rsaAlgorithm
        ) else {
            throw PasswordCipherError.encryption
        }
        let dataKey = SymmetricKey(size: .bits256)
        let sealed = try AES.GCM.seal(
            Data(plaintext.utf8),
            using: dataKey
        )
        guard let sealedPassword = sealed.combined else {
            throw PasswordCipherError.invalidCiphertext
        }
        let rawKey = dataKey.withUnsafeBytes { Data($0) }
        var error: Unmanaged<CFError>?
        guard let encryptedKey = SecKeyCreateEncryptedData(
            publicKey,
            rsaAlgorithm,
            rawKey as CFData,
            &error
        ) as Data? else {
            throw PasswordCipherError.encryption
        }
        let envelope = Envelope(
            encryptedKey: encryptedKey,
            sealedPassword: sealedPassword
        )
        let encoded = try JSONEncoder().encode(envelope)
        return prefix + encoded.base64EncodedString()
    }

    static func decrypt(
        _ ciphertext: String,
        using privateKey: SecKey
    ) throws -> String {
        guard
            isEncrypted(ciphertext),
            let encoded = Data(
                base64Encoded: String(ciphertext.dropFirst(prefix.count))
            ),
            let envelope = try? JSONDecoder().decode(
                Envelope.self,
                from: encoded
            ),
            SecKeyIsAlgorithmSupported(
                privateKey,
                .decrypt,
                rsaAlgorithm
            )
        else {
            throw PasswordCipherError.invalidCiphertext
        }
        var error: Unmanaged<CFError>?
        guard let rawKey = SecKeyCreateDecryptedData(
            privateKey,
            rsaAlgorithm,
            envelope.encryptedKey as CFData,
            &error
        ) as Data? else {
            throw PasswordCipherError.decryption
        }
        let box = try AES.GCM.SealedBox(
            combined: envelope.sealedPassword
        )
        let plaintext = try AES.GCM.open(
            box,
            using: SymmetricKey(data: rawKey)
        )
        guard let value = String(data: plaintext, encoding: .utf8) else {
            throw PasswordCipherError.invalidCiphertext
        }
        return value
    }

    static func generatePrivateKey() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: keySize
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(
            attributes as CFDictionary,
            &error
        ) else {
            throw PasswordCipherError.keyCreation
        }
        return key
    }

    private static func loadOrCreateKeyPair() throws -> (
        privateKey: SecKey,
        publicKey: SecKey
    ) {
        if
            let privateKey = loadKey(
                at: privateKeyURL,
                keyClass: kSecAttrKeyClassPrivate
            )
        {
            if
                let publicKey = loadKey(
                    at: publicKeyURL,
                    keyClass: kSecAttrKeyClassPublic
                )
            {
                return (privateKey, publicKey)
            }
            guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
                throw PasswordCipherError.keyCreation
            }
            try persist(publicKey, at: publicKeyURL, permissions: 0o644)
            return (privateKey, publicKey)
        }

        let privateKey = try generatePrivateKey()
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw PasswordCipherError.keyCreation
        }
        try persist(privateKey, at: privateKeyURL, permissions: 0o600)
        try persist(publicKey, at: publicKeyURL, permissions: 0o644)
        return (privateKey, publicKey)
    }

    private static func loadKey(
        at url: URL,
        keyClass: CFString
    ) -> SecKey? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: keyClass,
            kSecAttrKeySizeInBits as String: keySize
        ]
        return SecKeyCreateWithData(
            data as CFData,
            attributes as CFDictionary,
            nil
        )
    }

    private static func persist(
        _ key: SecKey,
        at url: URL,
        permissions: Int
    ) throws {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(
            key,
            &error
        ) as Data? else {
            throw PasswordCipherError.keyPersistence
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }
}

enum SessionStore {
    private static var fileURL: URL {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("ShellHarbor", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("sessions.json")
    }

    static func load() -> [SessionProfile] {
        guard
            let data = try? Data(contentsOf: fileURL),
            let sessions = try? JSONDecoder().decode([SessionProfile].self, from: data)
        else {
            return []
        }
        var needsMigration = false
        let decrypted = sessions.map {
            var profile = $0
            guard !profile.password.isEmpty else { return profile }
            if PasswordCipher.isEncrypted(profile.password) {
                profile.password = (
                    try? PasswordCipher.decrypt(profile.password)
                ) ?? ""
            } else {
                needsMigration = true
            }
            return profile
        }
        if needsMigration {
            save(decrypted)
        }
        return decrypted
    }

    static func save(_ sessions: [SessionProfile]) {
        let encrypted: [SessionProfile]
        do {
            encrypted = try sessions.map {
                var profile = $0
                if
                    !profile.password.isEmpty,
                    !PasswordCipher.isEncrypted(profile.password)
                {
                    profile.password = try PasswordCipher.encrypt(
                        profile.password
                    )
                }
                return profile
            }
        } catch {
            return
        }
        guard let data = try? JSONEncoder.pretty.encode(encrypted) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
