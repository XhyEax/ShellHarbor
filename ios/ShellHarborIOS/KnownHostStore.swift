import Foundation
import Observation
import Crypto

struct KnownHostIdentity: Equatable {
    let algorithm: String
    let fingerprint: String
}

@MainActor
@Observable
final class KnownHostStore {
    private(set) var entries: [String: String]
    private(set) var autoTrustNewHosts: Bool
    private let defaults: UserDefaults
    private let storageKey = "mobileKnownHosts"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        autoTrustNewHosts = defaults.bool(forKey: "mobileAutoTrustNewHosts")
    }

    func key(for endpoint: String) -> String? {
        entries[endpoint]
    }

    func trust(_ key: String, for endpoint: String) {
        entries[endpoint] = key
        defaults.set(entries, forKey: storageKey)
    }

    func remove(endpoint: String) {
        entries.removeValue(forKey: endpoint)
        defaults.set(entries, forKey: storageKey)
    }

    func removeAll() {
        entries.removeAll()
        defaults.set(entries, forKey: storageKey)
    }

    func identity(for endpoint: String) -> KnownHostIdentity? {
        guard let key = entries[endpoint] else { return nil }
        let parts = key.split(separator: " ", maxSplits: 1)
        let algorithm = parts.first.map(String.init) ?? "SSH"
        let keyData = parts.count > 1
            ? Data(base64Encoded: String(parts[1])) ?? Data(key.utf8)
            : Data(key.utf8)
        let digest = SHA256.hash(data: keyData)
        let fingerprint = "SHA256:" + Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        return KnownHostIdentity(
            algorithm: algorithm,
            fingerprint: fingerprint
        )
    }

    func setAutoTrustNewHosts(_ enabled: Bool) {
        autoTrustNewHosts = enabled
        defaults.set(enabled, forKey: "mobileAutoTrustNewHosts")
    }
}
