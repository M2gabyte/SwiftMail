import SwiftUI
import OSLog

private let logger = Logger(subsystem: "com.simplemail.app", category: "InboxView")

// MARK: - Inbox View

struct InboxView: View {
    @State private var viewModel = InboxViewModel()
    @State private var showingCompose = false
    @State private var listDensity: ListDensity = .comfortable
    @State private var showingSettings = false
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @FocusState private var searchFocused: Bool
    @StateObject private var searchHistory = SearchHistoryManager.shared

    /// Filtered sections based on debounced search text with smart filter support
    private var filteredSections: [EmailSection] {
        let query = debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.emailSections }

        // Parse smart filters
        let filter = SearchFilter.parse(query)

        return viewModel.emailSections.compactMap { section in
            let filteredEmails = section.emails.filter { email in
                filter.matches(email)
            }
            guard !filteredEmails.isEmpty else { return nil }
            return EmailSection(id: section.id, title: section.title, emails: filteredEmails)
        }
    }

    /// Save search to history when user commits
    private func commitSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            searchHistory.addSearch(query)
        }
    }

    /// Terms to highlight in search results
    private var highlightTerms: [String] {
        let query = debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return SearchFilter.parse(query).highlightTerms
    }

    var body: some View {
        List {
            // Scrollable header (compact, no card background)
            InboxHeaderBlock(
                scope: $viewModel.scope,
                activeFilter: $viewModel.activeFilter,
                searchText: $searchText,
                filterCounts: viewModel.filterCounts
            )
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color(.systemBackground))

            // Search suggestions when focused with empty text
            if searchFocused && searchText.isEmpty {
                SearchSuggestionsSection(
                    recentSearches: searchHistory.recentSearches,
                    onSelectSearch: { query in
                        searchText = query
                        commitSearch()
                    },
                    onRemoveSearch: { query in
                        searchHistory.removeSearch(query)
                    },
                    onClearHistory: {
                        searchHistory.clearHistory()
                    }
                )
            }

            // Filter suggestions when typing
            if !searchText.isEmpty && !searchText.contains(":") {
                FilterSuggestionsRow(
                    query: searchText,
                    onSelect: { filter in
                        searchText = filter
                    }
                )
            }

            // Empty state for search
            if !debouncedSearchText.isEmpty && filteredSections.isEmpty {
                ContentUnavailableView.search(text: debouncedSearchText)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            // Empty state for filters (no search active)
            if debouncedSearchText.isEmpty && viewModel.activeFilter != nil && filteredSections.isEmpty {
                ContentUnavailableView(
                    "No Matches",
                    systemImage: viewModel.activeFilter?.icon ?? "envelope",
                    description: Text("No emails match the \"\(viewModel.activeFilter?.rawValue ?? "")\" filter.")
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            ForEach(filteredSections) { section in
                Section {
                    ForEach(section.emails) { email in
                        EmailRow(
                            email: email,
                            isCompact: listDensity == .compact,
                            showAccountBadge: viewModel.currentMailbox == .allInboxes,
                            highlightTerms: highlightTerms
                        )
                        .listRowBackground(Color(.systemBackground))
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowSeparator(.visible)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button {
                                viewModel.archiveEmail(email)
                            } label: {
                                Label("Archive", systemImage: "archivebox")
                            }
                            .tint(.green)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                viewModel.toggleRead(email)
                            } label: {
                                Label(
                                    email.isUnread ? "Read" : "Unread",
                                    systemImage: email.isUnread ? "envelope.open" : "envelope.badge"
                                )
                            }
                            .tint(.blue)
                        }
                        .contextMenu {
                            Button {
                                viewModel.openEmail(email)
                            } label: {
                                Label("Open", systemImage: "envelope.open")
                            }

                            Button {
                                viewModel.archiveEmail(email)
                            } label: {
                                Label("Archive", systemImage: "archivebox")
                            }

                            Button {
                                viewModel.starEmail(email)
                            } label: {
                                Label(email.isStarred ? "Unstar" : "Star", systemImage: email.isStarred ? "star.slash" : "star")
                            }

                            Button {
                                viewModel.toggleRead(email)
                            } label: {
                                Label(email.isUnread ? "Mark as Read" : "Mark as Unread", systemImage: email.isUnread ? "envelope.open" : "envelope.badge")
                            }

                            Divider()

                            Button(role: .destructive) {
                                viewModel.blockSender(email)
                            } label: {
                                Label("Block Sender", systemImage: "hand.raised")
                            }

                            Button(role: .destructive) {
                                viewModel.reportSpam(email)
                            } label: {
                                Label("Report Spam", systemImage: "exclamationmark.shield")
                            }

                            Button(role: .destructive) {
                                viewModel.trashEmail(email)
                            } label: {
                                Label("Trash", systemImage: "trash")
                            }
                        }
                        .onTapGesture {
                            viewModel.openEmail(email)
                        }
                        .onAppear {
                            Task { await viewModel.loadMoreIfNeeded(currentEmail: email) }
                        }
                    }
                } header: {
                    Text(section.title)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                }
            }

            if viewModel.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                        .padding()
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            // Only show "Load More" when there are visible emails (not when filter returns empty)
            if viewModel.hasMoreEmails && !viewModel.isLoadingMore && !filteredSections.isEmpty {
                Button(action: {
                    if let lastEmail = filteredSections.last?.emails.last {
                        Task { await viewModel.loadMoreIfNeeded(currentEmail: lastEmail) }
                    }
                }) {
                    HStack {
                        Spacer()
                        Text("Load More")
                            .font(.subheadline)
                            .foregroundStyle(.blue)
                        Spacer()
                    }
                    .padding()
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .listRowSpacing(0)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemBackground))
        .listSectionSpacing(6)
        .accessibilityIdentifier("inboxList")
        .navigationTitle(viewModel.currentMailbox.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleMenu {
            // Quick switch favorites
            Section("Favorites") {
                ForEach(Mailbox.allCases, id: \.self) { mailbox in
                    Button {
                        viewModel.selectMailbox(mailbox)
                    } label: {
                        if mailbox == viewModel.currentMailbox {
                            Label(mailbox.rawValue, systemImage: "checkmark")
                        } else {
                            Label(mailbox.rawValue, systemImage: mailbox.icon)
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }

            ToolbarItemGroup(placement: .bottomBar) {
                Spacer()

                Button { showingCompose = true } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityIdentifier("composeButton")
                .accessibilityLabel("Compose new email")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 8)
        }
        .navigationDestination(isPresented: $viewModel.showingEmailDetail) {
            if let email = viewModel.selectedEmail {
                EmailDetailView(emailId: email.id, threadId: email.threadId, accountEmail: email.accountEmail)
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showingCompose) {
            ComposeView()
        }
        .refreshable {
            await viewModel.refresh()
        }
        .task(id: searchText) {
            // Debounce search - wait 300ms before applying filter
            do {
                try await Task.sleep(for: .milliseconds(300))
                debouncedSearchText = searchText
            } catch {
                // Task cancelled, ignore
            }
        }
        .overlay(alignment: .bottom) {
            if viewModel.showingUndoToast {
                UndoToast(
                    message: viewModel.undoToastMessage,
                    onUndo: { viewModel.undoArchive() }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, 16)
            }
        }
        .overlay(alignment: .top) {
            if let error = viewModel.error {
                ErrorBanner(
                    error: error,
                    onDismiss: { viewModel.error = nil },
                    onRetry: { Task { await viewModel.loadEmails() } }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.top, 8)
            }
        }
        .overlay {
            if viewModel.isLoading && viewModel.emailSections.isEmpty {
                InboxSkeletonView()
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.error != nil)
        .onAppear {
            loadSettings()
            viewModel.preloadCachedEmails(
                mailbox: viewModel.currentMailbox,
                accountEmail: viewModel.currentMailbox == .allInboxes ? nil : AuthService.shared.currentAccount?.email
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            loadSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .accountDidChange)) { _ in
            loadSettings()
        }
    }

    private func loadSettings() {
        let accountEmail = AuthService.shared.currentAccount?.email
        guard let data = AccountDefaults.data(for: "appSettings", accountEmail: accountEmail) else {
            return
        }
        do {
            let settings = try JSONDecoder().decode(AppSettings.self, from: data)
            listDensity = settings.listDensity
        } catch {
            logger.warning("Failed to decode app settings: \(error.localizedDescription)")
        }
    }
}

// MARK: - Inbox Header Block

struct InboxHeaderBlock: View {
    @Binding var scope: InboxScope
    @Binding var activeFilter: InboxFilter?
    @Binding var searchText: String
    let filterCounts: [InboxFilter: Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Band A: Context

            // 1) Greeting (compact)
            Text(greeting)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)

            // 2) Scope segmented control (small + flat)
            Picker("", selection: $scope) {
                Text("All").tag(InboxScope.all)
                Text("People").tag(InboxScope.people)
            }
            .pickerStyle(.segmented)
            .controlSize(.mini)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            // Band B: Controls

            // 3) Triage chips row (primary visual - quiet filled)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(InboxFilter.allCases, id: \.self) { filter in
                        FilterPill(
                            filter: filter,
                            count: filterCounts[filter] ?? 0,
                            isActive: activeFilter == filter,
                            onTap: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    if activeFilter == filter {
                                        activeFilter = nil
                                    } else {
                                        activeFilter = filter
                                    }
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 10)

            // 4) Search field (compact outlined - secondary)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField("Search", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.primary.opacity(0.10), lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let name = AuthService.shared.currentAccount?.name.components(separatedBy: " ").first ?? ""
        let timeGreeting: String
        switch hour {
        case 0..<12: timeGreeting = "Good morning"
        case 12..<17: timeGreeting = "Good afternoon"
        default: timeGreeting = "Good evening"
        }
        return name.isEmpty ? timeGreeting : "\(timeGreeting), \(name)"
    }
}

// MARK: - Scope

enum InboxScope: String, CaseIterable {
    case all = "All"
    case people = "People"
}

// MARK: - Filter Pills

enum InboxFilter: String, CaseIterable {
    case unread = "Unread"
    case needsReply = "Needs Reply"
    case deadlines = "Deadlines"
    case money = "Money"
    case newsletters = "Newsletters"

    var icon: String {
        switch self {
        case .unread: return "envelope.badge"
        case .needsReply: return "arrowshape.turn.up.left"
        case .deadlines: return "calendar.badge.exclamationmark"
        case .money: return "dollarsign.circle"
        case .newsletters: return "newspaper"
        }
    }

    var color: Color {
        switch self {
        case .unread: return .blue
        case .needsReply: return .orange
        case .deadlines: return .red
        case .money: return .green
        case .newsletters: return .purple
        }
    }
}

struct FilterPill: View {
    let filter: InboxFilter
    let count: Int
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: filter.icon)
                    .font(.caption)
                    .foregroundStyle(isActive ? .primary : .secondary)
                Text(filter.rawValue)
                    .font(isActive ? .subheadline.weight(.semibold) : .subheadline)
                    .foregroundStyle(.primary)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.monospacedDigit())
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.thinMaterial, in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(isActive ? Color.primary.opacity(0.10) : Color.secondary.opacity(0.08))
            )
            .overlay(
                isActive ? Capsule().strokeBorder(.primary.opacity(0.10), lineWidth: 1) : nil
            )
        }
        .buttonStyle(.plain)
    }
}

struct InboxSkeletonView: View {
    var body: some View {
        VStack(spacing: 12) {
            ForEach(0..<6, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Circle()
                            .fill(Color(.systemGray5))
                            .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(.systemGray5))
                                .frame(width: 140, height: 12)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(.systemGray6))
                                .frame(width: 220, height: 10)
                        }
                    }
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.systemGray6))
                        .frame(height: 10)
                }
                .padding()
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
            }
        }
        .padding()
    }
}

// MARK: - Cached Date Formatters (Performance Critical)

private enum DateFormatters {
    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter
    }()

    static let calendar = Calendar.current

    static func formatEmailDate(_ date: Date) -> String {
        if calendar.isDateInToday(date) {
            return timeFormatter.string(from: date)
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        return dateFormatter.string(from: date)
    }

    static func formatDetailDate(_ date: Date) -> String {
        if calendar.isDateInToday(date) {
            return timeFormatter.string(from: date)
        }
        return fullDateFormatter.string(from: date)
    }
}

// MARK: - Email Row

struct EmailRow: View {
    let email: Email
    var isCompact: Bool = false
    var showAccountBadge: Bool = false
    var highlightTerms: [String] = []

    private var isVIPSender: Bool {
        let vipSenders = AccountDefaults.stringArray(for: "vipSenders", accountEmail: email.accountEmail)
        return vipSenders.contains(email.senderEmail.lowercased())
    }

    private var accountLabel: String? {
        guard showAccountBadge, let accountEmail = email.accountEmail else {
            return nil
        }
        return accountEmail.split(separator: "@").first.map(String.init)
    }

    /// Highlight matching terms in text
    private func highlightedText(_ text: String, font: Font, baseColor: Color = .primary) -> Text {
        guard !highlightTerms.isEmpty else {
            return Text(text).foregroundStyle(baseColor)
        }

        var result = Text("")
        var lastEnd = text.startIndex

        // Find all matches and sort by position
        var matches: [(range: Range<String.Index>, term: String)] = []
        for term in highlightTerms where !term.isEmpty {
            var searchStart = text.startIndex
            while let range = text.range(of: term, options: .caseInsensitive, range: searchStart..<text.endIndex) {
                matches.append((range, term))
                searchStart = range.upperBound
            }
        }
        matches.sort { $0.range.lowerBound < $1.range.lowerBound }

        // Build attributed text
        for match in matches {
            if match.range.lowerBound >= lastEnd {
                // Add non-highlighted text before match
                if lastEnd < match.range.lowerBound {
                    result = result + Text(text[lastEnd..<match.range.lowerBound]).foregroundStyle(baseColor)
                }
                // Add highlighted match
                result = result + Text(text[match.range])
                    .foregroundStyle(Color.yellow)
                    .bold()
                lastEnd = match.range.upperBound
            }
        }

        // Add remaining text
        if lastEnd < text.endIndex {
            result = result + Text(text[lastEnd...]).foregroundStyle(baseColor)
        }

        return result
    }

    var body: some View {
        HStack(spacing: isCompact ? 8 : 10) {
            // Avatar (hidden in compact mode)
            if !isCompact {
                SmartAvatarView(
                    email: email.senderEmail,
                    name: email.senderName,
                    size: 36
                )
            }

            // Content
            VStack(alignment: .leading, spacing: isCompact ? 1 : 2) {
                HStack {
                    highlightedText(email.senderName, font: isCompact ? .caption : .subheadline)
                        .font(isCompact ? .caption : .subheadline)
                        .fontWeight(email.isUnread ? .semibold : .regular)
                        .lineLimit(1)

                    if isVIPSender {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }

                    if let accountLabel = accountLabel {
                        Text(accountLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(.systemGray6))
                            .clipShape(Capsule())
                    }

                    Spacer()

                    Text(DateFormatters.formatEmailDate(email.date))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if email.hasAttachments {
                        Image(systemName: "paperclip")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                highlightedText(email.subject, font: isCompact ? .caption2 : .caption)
                    .font(isCompact ? .caption2 : .caption)
                    .fontWeight(email.isUnread ? .medium : .regular)
                    .lineLimit(1)

                if !isCompact {
                    highlightedText(email.snippet, font: .caption2, baseColor: .secondary)
                        .font(.caption2)
                        .lineLimit(1)
                }
            }

            // Unread indicator
            if email.isUnread {
                Circle()
                    .fill(.blue)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.vertical, isCompact ? 0 : 2)
        .contentShape(Rectangle())
    }
}

enum Mailbox: String, CaseIterable {
    case allInboxes = "All Inboxes"
    case inbox = "Inbox"
    case sent = "Sent"
    case archive = "Archive"
    case trash = "Trash"
    case drafts = "Drafts"
    case starred = "Starred"

    var icon: String {
        switch self {
        case .allInboxes: return "tray.full"
        case .inbox: return "tray"
        case .sent: return "paperplane"
        case .archive: return "archivebox"
        case .trash: return "trash"
        case .drafts: return "doc"
        case .starred: return "star"
        }
    }
}

// MARK: - Undo Toast

struct UndoToast: View {
    let message: String
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "archivebox")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))

            Text(message)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.white)

            Spacer()

            Button(action: onUndo) {
                Text("Undo")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.yellow)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.darkGray))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        )
        .padding(.horizontal, 16)
    }
}

// MARK: - Time of Day Gradient

struct TimeOfDayGradient: View {
    var body: some View {
        let hour = Calendar.current.component(.hour, from: Date())
        let colors: [Color] = {
            switch hour {
            case 5..<8: // Early morning
                return [Color(red: 0.98, green: 0.85, blue: 0.75), Color(red: 0.95, green: 0.95, blue: 0.98)]
            case 8..<12: // Morning
                return [Color(red: 0.95, green: 0.97, blue: 1.0), Color(red: 0.98, green: 0.98, blue: 1.0)]
            case 12..<17: // Afternoon
                return [Color(red: 0.97, green: 0.98, blue: 1.0), Color(red: 0.95, green: 0.95, blue: 0.98)]
            case 17..<20: // Evening
                return [Color(red: 0.98, green: 0.92, blue: 0.88), Color(red: 0.95, green: 0.93, blue: 0.98)]
            default: // Night
                return [Color(red: 0.15, green: 0.15, blue: 0.25), Color(red: 0.1, green: 0.1, blue: 0.15)]
            }
        }()

        LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Email Section

struct EmailSection: Identifiable {
    let id: String
    let title: String
    let emails: [Email]
}

// MARK: - Search Suggestions

struct SearchSuggestionsSection: View {
    let recentSearches: [String]
    let onSelectSearch: (String) -> Void
    let onRemoveSearch: (String) -> Void
    let onClearHistory: () -> Void

    var body: some View {
        // Smart filter suggestions
        Section {
            ForEach(SearchFilter.suggestions, id: \.prefix) { suggestion in
                Button {
                    onSelectSearch(suggestion.prefix)
                } label: {
                    Label(suggestion.description, systemImage: suggestion.icon)
                        .foregroundStyle(.primary)
                }
            }
        } header: {
            Text("Search Filters")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(nil)
        }
        .listRowBackground(Color(.systemBackground))

        // Recent searches
        if !recentSearches.isEmpty {
            Section {
                ForEach(recentSearches, id: \.self) { search in
                    HStack {
                        Button {
                            onSelectSearch(search)
                        } label: {
                            Label(search, systemImage: "clock.arrow.circlepath")
                                .foregroundStyle(.primary)
                        }

                        Spacer()

                        Button {
                            onRemoveSearch(search)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                HStack {
                    Text("Recent")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(nil)

                    Spacer()

                    Button("Clear") {
                        onClearHistory()
                    }
                    .font(.caption)
                    .foregroundStyle(.blue)
                }
            }
            .listRowBackground(Color(.systemBackground))
        }
    }
}

struct FilterSuggestionsRow: View {
    let query: String
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchFilter.suggestions.prefix(3), id: \.prefix) { suggestion in
                    Button {
                        onSelect("\(suggestion.prefix)\(query)")
                    } label: {
                        Label("\(suggestion.prefix)\(query)", systemImage: suggestion.icon)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(.systemGray6))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 16)
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

// MARK: - Preview

#Preview {
    InboxView()
}
