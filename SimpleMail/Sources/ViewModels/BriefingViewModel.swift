import Foundation
import Combine

final class BriefingViewModel: ObservableObject {
    @Published var snapshot: BriefingSnapshot? = BriefingSnapshot(items: [], sources: [], debugInfo: BriefingDebugInfo(note: "Briefing disabled"))
    @Published var isLoading = false
    @Published var error: Error?

    func refresh() async {
        // Briefing disabled: no-op.
        snapshot = BriefingSnapshot(items: [], sources: [], debugInfo: BriefingDebugInfo(note: "Briefing disabled"))
    }

    func loadCached() { }
    func markDone(_ item: BriefingItem) { }
    func snooze(_ item: BriefingItem, until date: Date) { }
    func muteThread(_ item: BriefingItem) { }
    func isSnoozed(_ item: BriefingItem) -> Bool { false }
}
