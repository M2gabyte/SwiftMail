import Foundation

@MainActor
final class SummaryCache {
    static let shared = SummaryCache()

    private let cacheKey = "summaryCache"
    private let maxEntries = 500
    private let lock = NSLock()

    private init() {}

    func summary(for messageId: String, accountEmail: String?) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = AccountDefaults.data(for: cacheKey, accountEmail: accountEmail) else {
            return nil
        }
        guard let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }
        return dict[messageId]
    }

    func save(summary: String, for messageId: String, accountEmail: String?) {
        lock.lock()
        defer { lock.unlock() }
        var dict: [String: String] = [:]
        if let data = AccountDefaults.data(for: cacheKey, accountEmail: accountEmail),
           let existing = try? JSONDecoder().decode([String: String].self, from: data) {
            dict = existing
        }

        dict[messageId] = summary

        if dict.count > maxEntries {
            let overflow = dict.count - maxEntries
            let keysToRemove = dict.keys.prefix(overflow)
            for key in keysToRemove {
                dict.removeValue(forKey: key)
            }
        }

        if let encoded = try? JSONEncoder().encode(dict) {
            AccountDefaults.setData(encoded, for: cacheKey, accountEmail: accountEmail)
        }
    }
}
