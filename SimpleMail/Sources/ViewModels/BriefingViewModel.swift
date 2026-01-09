import Foundation
import SwiftUI

@MainActor
final class BriefingViewModel: ObservableObject {
    @Published var snapshot: BriefingSnapshot?
    @Published var isRefreshing = false
    @Published var scopeDays = 14
    @Published var showLowConfidence = false
    @Published var showMoreCount = 0
    @Published var lastUpdated: Date?
    @Published var errorMessage: String?

    private var userState = BriefingUserState()

    var accountEmail: String?

    func loadCached() {
        let cached = BriefingService.shared.loadCachedSnapshot(accountEmail: accountEmail, scopeDays: scopeDays)
        if let cached {
            snapshot = cached
            lastUpdated = cached.generatedAt
        }
        userState = BriefingService.shared.loadUserState(accountEmail: accountEmail)
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        errorMessage = nil
        let snapshot = await BriefingService.shared.refreshSnapshot(scopeDays: scopeDays, accountEmail: accountEmail)
        self.snapshot = snapshot
        lastUpdated = snapshot.generatedAt
    }

    func setScopeDays(_ days: Int) {
        guard scopeDays != days else { return }
        scopeDays = days
        showMoreCount = 0
        showLowConfidence = false
        loadCached()
        Task { await refresh() }
    }

    func markDone(_ item: BriefingItem) {
        userState.doneItemIds.insert(item.id)
        persistState()
    }

    func snooze(_ item: BriefingItem, until date: Date) {
        userState.snoozedUntil[item.id] = date
        persistState()
    }

    func muteThread(_ item: BriefingItem) {
        userState.mutedThreadIds.insert(item.sourceThreadId)
        persistState()
    }

    func muteSender(_ sender: String) {
        userState.mutedSenders.insert(sender.lowercased())
        persistState()
    }

    func isSnoozed(_ item: BriefingItem) -> Bool {
        if let until = userState.snoozedUntil[item.id] {
            return until > Date()
        }
        return false
    }

    func showMore() {
        showMoreCount += 5
        showLowConfidence = true
    }

    func sectionedItems(hits: [String: BriefingThreadHit]) -> [(BriefingSection, [BriefingItem])] {
        let base = filteredItems(hits: hits)
        let totalCap = 12 + showMoreCount
        let perSectionCap = 5 + showMoreCount

        var remaining = totalCap
        var result: [(BriefingSection, [BriefingItem])] = []

        for section in BriefingSection.allCases {
            guard remaining > 0 else { break }
            let sectionItems = base.filter { section.matches($0) }
            let limited = Array(sectionItems.prefix(min(perSectionCap, remaining)))
            if !limited.isEmpty {
                result.append((section, limited))
                remaining -= limited.count
            }
        }
        return result
    }

    func totalVisibleItems(hits: [String: BriefingThreadHit]) -> [BriefingItem] {
        let base = filteredItems(hits: hits)
        let maxBase = 12 + showMoreCount
        return Array(base.prefix(maxBase))
    }

    func hitMap() -> [String: BriefingThreadHit] {
        guard let snapshot else { return [:] }
        return Dictionary(uniqueKeysWithValues: snapshot.sources.map { ($0.threadId, $0) })
    }

    func shouldShowShowMore(hits: [String: BriefingThreadHit]) -> Bool {
        let base = filteredItems(hits: hits)
        return base.count > 12 + showMoreCount
    }

    func filteredItems(hits: [String: BriefingThreadHit]) -> [BriefingItem] {
        guard let snapshot else { return [] }
        let now = Date()
        return snapshot.items.filter { item in
            if !showLowConfidence && item.confidence == .low { return false }
            if userState.doneItemIds.contains(item.id) { return false }
            if let snooze = userState.snoozedUntil[item.id], snooze > now { return false }
            if userState.mutedThreadIds.contains(item.sourceThreadId) { return false }
            if let hit = hits[item.sourceThreadId] {
                let sender = EmailParser.extractSenderEmail(from: hit.from).lowercased()
                if userState.mutedSenders.contains(sender) { return false }
            }
            return true
        }
    }

    private func persistState() {
        BriefingService.shared.saveUserState(userState, accountEmail: accountEmail)
    }
}

enum BriefingSection: CaseIterable {
    case dueSoon
    case youOwe
    case waiting
    case money

    var title: String {
        switch self {
        case .dueSoon: return "Due soon"
        case .youOwe: return "You owe"
        case .waiting: return "Waiting on them"
        case .money: return "Money"
        }
    }

    func matches(_ item: BriefingItem) -> Bool {
        switch self {
        case .dueSoon:
            return item.type == .deadline && item.dueAt != nil
        case .youOwe:
            return item.type == .oweReply
        case .waiting:
            return item.type == .waiting
        case .money:
            return item.type == .money
        }
    }
}
