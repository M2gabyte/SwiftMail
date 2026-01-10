import Foundation
import OSLog

final class BriefingService {
    static let shared = BriefingService()
    private let logger = Logger(subsystem: "com.simplemail.app", category: "Briefing")

    func loadCachedSnapshot(accountEmail: String?, scopeDays: Int) -> BriefingSnapshot? { nil }
    func saveSnapshot(_ snapshot: BriefingSnapshot, accountEmail: String?) { }
    func loadUserState(accountEmail: String?) -> BriefingUserState { BriefingUserState() }
    func saveUserState(_ state: BriefingUserState, accountEmail: String?) { }

    func refreshSnapshot(scopeDays: Int, accountEmail: String?) async -> BriefingSnapshot {
        // Briefing disabled: avoid hitting any models/APIs and never surface “AI extraction failed”.
        return BriefingSnapshot(items: [], sources: [], debugInfo: BriefingDebugInfo(note: "Briefing disabled"))
    }
}

struct BriefingUserState: Codable { var hiddenIds: Set<String> = [] }
