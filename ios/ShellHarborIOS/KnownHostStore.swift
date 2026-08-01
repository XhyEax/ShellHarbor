import Foundation
import Observation

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

    func setAutoTrustNewHosts(_ enabled: Bool) {
        autoTrustNewHosts = enabled
        defaults.set(enabled, forKey: "mobileAutoTrustNewHosts")
    }
}
