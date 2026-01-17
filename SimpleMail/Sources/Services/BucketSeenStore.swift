import Foundation

@MainActor
final class BucketSeenStore {
    static let shared = BucketSeenStore()
    private init() {}

    private func key(for bucket: GmailBucket) -> String {
        "bucketSeen.v1.\(bucket.rawValue)"
    }

    func getLastSeenDate(accountEmail: String?, bucket: GmailBucket) -> Date? {
        AccountDefaults.date(for: key(for: bucket), accountEmail: accountEmail?.lowercased())
    }

    func setLastSeenDate(accountEmail: String?, bucket: GmailBucket, date: Date) {
        AccountDefaults.setDate(date, for: key(for: bucket), accountEmail: accountEmail?.lowercased())
    }
}
