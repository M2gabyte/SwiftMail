import Foundation

/// Manages recent search history with persistence
@MainActor
final class SearchHistoryManager: ObservableObject {
    static let shared = SearchHistoryManager()

    @Published private(set) var recentSearches: [String] = []

    private let maxHistory = 8
    private let storageKey = "recentSearches"

    private init() {
        loadHistory()
    }

    func addSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Remove if already exists (will re-add at top)
        recentSearches.removeAll { $0.lowercased() == trimmed.lowercased() }

        // Insert at beginning
        recentSearches.insert(trimmed, at: 0)

        // Trim to max
        if recentSearches.count > maxHistory {
            recentSearches = Array(recentSearches.prefix(maxHistory))
        }

        saveHistory()
    }

    func removeSearch(_ query: String) {
        recentSearches.removeAll { $0 == query }
        saveHistory()
    }

    func clearHistory() {
        recentSearches = []
        saveHistory()
    }

    private func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            recentSearches = decoded
        }
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(recentSearches) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
