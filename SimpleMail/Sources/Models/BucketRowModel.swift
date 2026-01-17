import Foundation

struct BucketRowModel: Identifiable, Equatable {
    let id: String
    let bucket: GmailBucket
    let unseenCount: Int
    let totalCount: Int
    let latestEmail: EmailDTO?
    /// Latest message date in the bucket (used for inline ordering).
    let latestDate: Date?
}
