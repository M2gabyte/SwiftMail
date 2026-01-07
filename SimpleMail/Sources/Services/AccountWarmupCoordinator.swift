import Foundation

actor AccountWarmupCoordinator {
    static let shared = AccountWarmupCoordinator()

    private var warmupTask: Task<Void, Never>?

    func schedulePrewarmNext(after delay: Duration = .seconds(2)) {
        warmupTask?.cancel()
        warmupTask = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.prewarmNextLikelyAccount()
        }
    }

    private func prewarmNextLikelyAccount() async {
        let (accounts, currentAccount) = await MainActor.run {
            (AuthService.shared.accounts, AuthService.shared.currentAccount)
        }
        guard !accounts.isEmpty else { return }

        let currentEmail = currentAccount?.email.lowercased()
        let nextAccount = nextAccount(after: currentEmail, in: accounts)
        guard let nextAccount else { return }
        let nextEmail = nextAccount.email.lowercased()

        // Warm SwiftData cache by reading a small slice.
        await MainActor.run {
            _ = EmailCacheManager.shared.loadCachedEmails(mailbox: .inbox, limit: 50, accountEmail: nextEmail)
        }

        // Prewarm search index for the next account.
        await SearchIndexManager.shared.prewarmIfNeeded(accountEmail: nextEmail)
    }

    private func nextAccount(after email: String?, in accounts: [AuthService.Account]) -> AuthService.Account? {
        guard let email else {
            return accounts.first
        }
        if let index = accounts.firstIndex(where: { $0.email.lowercased() == email }) {
            let nextIndex = accounts.index(after: index)
            if nextIndex < accounts.endIndex {
                return accounts[nextIndex]
            }
            return accounts.first
        }
        return accounts.first
    }
}
