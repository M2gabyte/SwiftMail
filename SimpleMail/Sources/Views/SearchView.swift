import SwiftUI
import OSLog

private let searchLogger = Logger(subsystem: "com.simplemail.app", category: "Search")

// MARK: - Search View

struct SearchView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = SearchViewModel()
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search Bar
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)

                        TextField("Search emails", text: $viewModel.query)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($isSearchFocused)
                            .onSubmit {
                                Task { await viewModel.search() }
                            }

                        if !viewModel.query.isEmpty {
                            Button(action: { viewModel.query = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(10)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    Button("Cancel") {
                        dismiss()
                    }
                }
                .padding()

                Divider()

                if viewModel.query.isEmpty {
                    // Recent searches & suggestions
                    RecentSearchesView(viewModel: viewModel)
                } else if viewModel.isLoading {
                    ProgressView()
                        .frame(maxHeight: .infinity)
                } else if viewModel.results.isEmpty && viewModel.hasSearched {
                    NoResultsView(query: viewModel.query)
                } else {
                    // Results
                    SearchResultsView(
                        results: viewModel.results,
                        onSelect: { email in
                            viewModel.addToRecent(email.subject)
                        }
                    )
                }
            }
            .navigationBarHidden(true)
        }
        .onAppear {
            isSearchFocused = true
        }
    }
}

// MARK: - Recent Searches View

struct RecentSearchesView: View {
    @ObservedObject var viewModel: SearchViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Quick filters
                VStack(alignment: .leading, spacing: 12) {
                    Text("Quick Filters")
                        .font(.headline)
                        .padding(.horizontal)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            QuickFilterChip(icon: "paperclip", label: "Has attachment") {
                                viewModel.query = "has:attachment"
                                Task { await viewModel.search() }
                            }

                            QuickFilterChip(icon: "star.fill", label: "Starred") {
                                viewModel.query = "is:starred"
                                Task { await viewModel.search() }
                            }

                            QuickFilterChip(icon: "envelope.badge", label: "Unread") {
                                viewModel.query = "is:unread"
                                Task { await viewModel.search() }
                            }

                            QuickFilterChip(icon: "doc.fill", label: "Has PDF") {
                                viewModel.query = "filename:pdf"
                                Task { await viewModel.search() }
                            }
                        }
                        .padding(.horizontal)
                    }
                }

                // Recent searches
                if !viewModel.recentSearches.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Recent Searches")
                                .font(.headline)

                            Spacer()

                            Button("Clear") {
                                viewModel.clearRecent()
                            }
                            .font(.subheadline)
                            .foregroundStyle(.blue)
                        }
                        .padding(.horizontal)

                        ForEach(viewModel.recentSearches, id: \.self) { search in
                            Button(action: {
                                viewModel.query = search
                                Task { await viewModel.search() }
                            }) {
                                HStack {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .foregroundStyle(.secondary)

                                    Text(search)
                                        .foregroundStyle(.primary)

                                    Spacer()
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 8)
                            }
                        }
                    }
                }

                Spacer()
            }
            .padding(.vertical)
        }
    }
}

// MARK: - Quick Filter Chip

struct QuickFilterChip: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                Text(label)
                    .font(.subheadline)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemGray6))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Search Results View

struct SearchResultsView: View {
    let results: [Email]
    let onSelect: (Email) -> Void

    var body: some View {
        List {
            ForEach(results) { email in
                NavigationLink(destination: EmailDetailView(emailId: email.id, threadId: email.threadId)) {
                    SearchResultRow(email: email)
                }
                .onTapGesture {
                    onSelect(email)
                }
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - Search Result Row

struct SearchResultRow: View {
    let email: Email

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(email.senderName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Spacer()

                Text(formatDate(email.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(email.subject)
                .font(.subheadline)
                .lineLimit(1)

            Text(email.snippet)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            formatter.timeStyle = .short
        } else if Calendar.current.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            formatter.dateFormat = "MMM d"
        }
        return formatter.string(from: date)
    }
}

// MARK: - No Results View

struct NoResultsView: View {
    let query: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No results for \"\(query)\"")
                .font(.headline)

            Text("Try searching for something else")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Search ViewModel

@MainActor
class SearchViewModel: ObservableObject {
    @Published var query = ""
    @Published var results: [Email] = []
    @Published var isLoading = false
    @Published var hasSearched = false
    @Published var recentSearches: [String] = []

    private let recentSearchesKey = "recentSearches"

    init() {
        loadRecentSearches()
    }

    func search() async {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        isLoading = true
        hasSearched = true
        defer { isLoading = false }

        do {
            results = try await GmailService.shared.search(query: query)
            addToRecent(query)
        } catch {
            searchLogger.error("Search error: \(error.localizedDescription)")
            results = []
        }
    }

    func addToRecent(_ search: String) {
        let trimmed = search.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        recentSearches.removeAll { $0 == trimmed }
        recentSearches.insert(trimmed, at: 0)

        // Keep only last 10
        if recentSearches.count > 10 {
            recentSearches = Array(recentSearches.prefix(10))
        }

        saveRecentSearches()
    }

    func clearRecent() {
        recentSearches.removeAll()
        saveRecentSearches()
    }

    private func loadRecentSearches() {
        recentSearches = UserDefaults.standard.stringArray(forKey: recentSearchesKey) ?? []
    }

    private func saveRecentSearches() {
        UserDefaults.standard.set(recentSearches, forKey: recentSearchesKey)
    }
}

// MARK: - Preview

#Preview {
    SearchView()
}
