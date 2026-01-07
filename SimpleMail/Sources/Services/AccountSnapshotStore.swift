import Foundation

@MainActor
final class AccountSnapshotStore {
    static let shared = AccountSnapshotStore()

    struct Snapshot {
        let accountKey: String
        let mailbox: Mailbox
        let currentTab: InboxTab
        let pinnedTabOption: PinnedTabOption
        let activeFilter: InboxFilter?
        let emails: [Email]
        let viewState: InboxViewState
        let nextPageToken: String?
        let timestamp: Date

        func matches(currentTab: InboxTab, pinnedTabOption: PinnedTabOption, activeFilter: InboxFilter?) -> Bool {
            self.currentTab == currentTab &&
            self.pinnedTabOption == pinnedTabOption &&
            self.activeFilter == activeFilter
        }
    }

    private var snapshots: [String: Snapshot] = [:]

    private init() {}

    func saveSnapshot(
        accountEmail: String?,
        mailbox: Mailbox,
        currentTab: InboxTab,
        pinnedTabOption: PinnedTabOption,
        activeFilter: InboxFilter?,
        emails: [Email],
        viewState: InboxViewState,
        nextPageToken: String?
    ) {
        let key = snapshotKey(accountEmail: accountEmail, mailbox: mailbox)
        snapshots[key] = Snapshot(
            accountKey: key,
            mailbox: mailbox,
            currentTab: currentTab,
            pinnedTabOption: pinnedTabOption,
            activeFilter: activeFilter,
            emails: emails,
            viewState: viewState,
            nextPageToken: nextPageToken,
            timestamp: Date()
        )
    }

    func snapshot(accountEmail: String?, mailbox: Mailbox) -> Snapshot? {
        snapshots[snapshotKey(accountEmail: accountEmail, mailbox: mailbox)]
    }

    func clear(accountEmail: String?) {
        if let accountEmail {
            let accountKey = accountEmail.lowercased()
            snapshots = snapshots.filter { !($0.key.hasPrefix(accountKey + "::")) }
        } else {
            snapshots.removeAll()
        }
    }

    private func snapshotKey(accountEmail: String?, mailbox: Mailbox) -> String {
        let accountKey = (accountEmail?.lowercased() ?? "all")
        return "\(accountKey)::\(mailbox.rawValue)"
    }
}
