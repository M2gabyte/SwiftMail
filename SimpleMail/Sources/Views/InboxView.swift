import SwiftUI
import OSLog

private let logger = Logger(subsystem: "com.simplemail.app", category: "InboxView")
typealias SelectionID = String

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Inbox View

struct InboxView: View {
    @State private var viewModel = InboxViewModel()
    @State private var showingCompose = false
    @State private var listDensity: ListDensity = .comfortable
    @State private var showingSettings = false
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @StateObject private var searchHistory = SearchHistoryManager.shared
    @Environment(\.isSearching) private var isSearching
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @State private var editMode: EditMode = .inactive
    @State private var isSelectionMode = false
    @State private var selectedThreadIds = Set<SelectionID>()
    @State private var showingBulkSnooze = false
    @State private var showingMoveDialog = false
    @State private var showingLocationSheet = false
    @State private var scrollOffset: CGFloat = 0
    @State private var restoredComposeMode: ComposeMode?
    @State private var showingFilterSheet = false
    @State private var showAvatars = true
    @State private var searchFieldFocused = false
    @State private var isSearchMode = false
    private var pendingSendManager = PendingSendManager.shared
    private var networkMonitor = NetworkMonitor.shared

    /// Computed active filter label for bottom command surface
    private var activeFilterLabel: String? {
        viewModel.activeFilter?.rawValue
    }

    private var isHeaderCollapsed: Bool {
        scrollOffset > 50
    }

    /// Sections to display - either search results or filtered inbox
    private var displaySections: [EmailSection] {
        // If server search is active, show search results
        if viewModel.isSearchActive {
            let emails = viewModel.searchResults
            guard !emails.isEmpty else { return [] }
            return [EmailSection(id: "search", title: "Search Results", emails: emails)]
        }

        // Otherwise show normal inbox with local filtering
        let query = debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.emailSections }

        // Parse smart filters for local filtering (while typing, before submit)
        let filter = SearchFilter.parse(query)

        return viewModel.emailSections.compactMap { section in
            let filteredEmails = section.emails.filter { email in
                filter.matches(email)
            }
            guard !filteredEmails.isEmpty else { return nil }
            return EmailSection(id: section.id, title: section.title, emails: filteredEmails)
        }
    }

    private var searchModeResults: [Email] {
        let query = debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let lower = query.lowercased()
        return viewModel.emails.filter { email in
            email.senderName.lowercased().contains(lower) ||
            email.senderEmail.lowercased().contains(lower) ||
            email.subject.lowercased().contains(lower) ||
            email.snippet.lowercased().contains(lower)
        }
    }

    /// Save search to history when user commits
    private func commitSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Don't save bare prefixes or too-short queries to history
        guard query.count >= 2,
              !SearchFilter.suggestions.contains(where: { query == $0.prefix }) else {
            return
        }
        searchHistory.addSearch(query)
    }

    /// Terms to highlight in search results
    private var highlightTerms: [String] {
        let query = debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return SearchFilter.parse(query).highlightTerms
    }

    /// Email row with all actions - extracted to help compiler
    @ViewBuilder
    private func emailRowView(for email: Email, isSelectionMode: Bool, isContinuationInSenderRun: Bool = false, isFirstInSenderRun: Bool = true) -> some View {
        EmailRow(
            email: email,
            isCompact: listDensity == .compact,
            showAvatars: showAvatars,
            showAccountBadge: viewModel.currentMailbox == .allInboxes,
            highlightTerms: highlightTerms,
            isContinuationInSenderRun: isContinuationInSenderRun
        )
        .background(Color(.systemBackground))
        .listRowBackground(Color(.systemBackground))
        .listRowInsets(EdgeInsets(top: isFirstInSenderRun ? 9 : 5, leading: 16, bottom: 5, trailing: 16))
        .listRowSeparator(.visible)
        .listRowSeparatorTint(Color(.separator).opacity(0.25))
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { viewModel.toggleRead(email) } label: {
                Label(email.isUnread ? "Read" : "Unread",
                      systemImage: email.isUnread ? "envelope.open" : "envelope.badge")
            }
            .tint(Color.accentColor)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button { viewModel.archiveEmail(email) } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(.green)
        }
        .onTapGesture {
            if !isSelectionMode {
                if isSearchMode {
                    isSearchMode = false
                    searchFieldFocused = false
                }
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.openEmail(email)
                }
            }
        }
        .onLongPressGesture {
            enterSelectionMode(selecting: email.threadId)
        }
        .onAppear { Task { await viewModel.loadMoreIfNeeded(currentEmail: email) } }
    }

    var body: some View {
        baseView
    }

    private var baseView: AnyView {
        var view: AnyView = AnyView(baseContentView)
        view = AnyView(view.sheet(isPresented: $showingSettings) { SettingsView() })
        view = AnyView(view.sheet(isPresented: $showingCompose) { ComposeView() })
        view = AnyView(view.sheet(item: $restoredComposeMode) { mode in
            ComposeView(mode: mode)
        })
        view = AnyView(view.sheet(isPresented: $showingLocationSheet) {
            LocationSheetView(
                selectedMailbox: $viewModel.currentMailbox,
                onSelectMailbox: { mailbox in
                    viewModel.selectMailbox(mailbox)
                },
                onSelectScope: { scope in
                    handleScopeSelection(scope)
                }
            )
        })
        view = AnyView(view.sheet(isPresented: $showingBulkSnooze) {
            SnoozePickerSheet { date in
                performBulkSnooze(until: date)
            }
        })
        view = AnyView(view.sheet(isPresented: $showingFilterSheet) {
            FilterSheet(
                activeFilter: $viewModel.activeFilter,
                filterCounts: viewModel.filterCounts
            )
            .presentationDetents([.medium])
        })
        view = AnyView(view.confirmationDialog("Move to", isPresented: $showingMoveDialog) {
            Button("Inbox") { performBulkMove(to: .inbox) }
            Button("Archive") { performBulkArchive() }
            Button("Trash", role: .destructive) { performBulkTrash() }
            Button("Cancel", role: .cancel) { }
        })
        view = AnyView(view.navigationDestination(isPresented: $viewModel.showingEmailDetail) { detailDestination })
        view = AnyView(view.refreshable { await viewModel.refresh() })
        view = AnyView(view.task(id: searchText) { await debounceSearch() })
        view = AnyView(view.onChange(of: searchText) { _, newValue in
            if newValue.isEmpty && viewModel.isSearchActive {
                viewModel.clearSearch()
            }
            if isSearchMode {
                Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    debouncedSearchText = newValue
                }
            }
        })
        view = AnyView(view.onChange(of: viewModel.currentMailbox) { _, _ in
            exitSelectionMode()
        })
        view = AnyView(view.onChange(of: viewModel.activeFilter) { oldValue, newValue in
            exitSelectionMode()
            // Haptic feedback for filter changes
            if newValue != nil {
                HapticFeedback.light()
            } else if oldValue != nil {
                HapticFeedback.selection()
            }
        })
        view = AnyView(view.onChange(of: viewModel.emails) { _, _ in
            let valid = Set(viewModel.emails.map { $0.threadId })
            selectedThreadIds = selectedThreadIds.intersection(valid)
            if selectedThreadIds.isEmpty && isSelectionMode {
                exitSelectionMode()
            }
        })
        view = AnyView(view.onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .background {
                exitSelectionMode()
            } else if newPhase == .active && oldPhase == .background {
                Task { await viewModel.refresh() }
            }
        })
        view = AnyView(view.onChange(of: pendingSendManager.hasRestoredDraft) { _, hasRestored in
            if hasRestored, let draft = pendingSendManager.restoredDraft {
                restoredComposeMode = .restoredDraft(
                    draftId: draft.draftId,
                    to: draft.to,
                    cc: draft.cc,
                    bcc: draft.bcc,
                    subject: draft.subject,
                    body: draft.body,
                    bodyHtml: draft.bodyHtml,
                    inReplyTo: draft.inReplyTo,
                    threadId: draft.threadId
                )
                pendingSendManager.clearRestoredDraft()
            }
        })
        view = AnyView(view.onChange(of: isSearchMode) { _, newValue in
            if !newValue {
                withAnimation(.easeOut(duration: 0.15)) {
                    searchFieldFocused = false
                }
            }
        })
        view = AnyView(view.onChange(of: searchFieldFocused) { _, focused in
            if focused {
                withAnimation(.snappy(duration: 0.22)) {
                    isSearchMode = true
                }
            } else if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                withAnimation(.snappy(duration: 0.22)) {
                    isSearchMode = false
                }
            }
        })
        view = AnyView(view.onAppear { handleAppear() })
        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in loadSettings() })
        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .accountDidChange)) { _ in loadSettings() })
        view = AnyView(view.onChange(of: viewModel.bulkToastMessage) { _, newValue in
            // Haptic feedback for bulk action results
            if newValue != nil {
                if viewModel.bulkToastIsError {
                    HapticFeedback.error()
                } else {
                    HapticFeedback.success()
                }
            }
        })
        return view
    }

    private var baseContentView: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            inboxList
                .opacity(isSearchMode ? 0.3 : 1.0)
                .blur(radius: isSearchMode ? 4 : 0)
                .allowsHitTesting(!isSearchMode)

            if isSearchMode {
                ZStack {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            searchFieldFocused = false
                            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                withAnimation(.snappy(duration: 0.22)) {
                                    isSearchMode = false
                                }
                            }
                        }

                    searchModeList
                        .transition(.opacity)
                        .zIndex(10)
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isSearchMode)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(.bar, for: .navigationBar)
        .toolbar { toolbarContent }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled(true)
        .overlay { overlayContent }
        .overlay(alignment: .top) { offlineBannerContent }
            .overlay(alignment: .bottom) { bulkToastContent }
            .overlay(alignment: .bottom) {
                undoSendToastContent
                    .animation(.easeInOut(duration: 0.25), value: pendingSendManager.isPending)
                    .animation(.easeInOut(duration: 0.25), value: pendingSendManager.wasQueuedOffline)
            }
            .overlay(alignment: .bottom) {
                if !isSelectionMode && !showingFilterSheet {
                    BottomCommandSurface(
                        isFilterActive: viewModel.activeFilter != nil,
                        activeFilterLabel: activeFilterLabel,
                        activeFilterCount: viewModel.activeFilter.flatMap { viewModel.filterCounts[$0] },
                        searchMode: isSearchMode ? .editing : .idle,
                        showSearchField: true,
                        searchText: $searchText,
                        searchFocused: $searchFieldFocused,
                        onSubmitSearch: {
                            commitSearch()
                            debouncedSearchText = searchText
                            Task { await viewModel.performSearch(query: searchText) }
                        },
                        onTapSearch: {
                            withAnimation(.easeOut(duration: 0.15)) {
                                isSearchMode = true
                            }
                            searchFieldFocused = true
                        },
                        onCancelSearch: {
                            withAnimation(.easeOut(duration: 0.15)) {
                                isSearchMode = false
                            }
                            searchFieldFocused = false
                            searchText = ""
                            debouncedSearchText = ""
                            viewModel.clearSearch()
                        },
                        onTapFilter: { showingFilterSheet = true },
                        onTapCompose: { showingCompose = true }
                    )
                    .zIndex(20)
                }
            }
    }

    // MARK: - Extracted View Components

    private var inboxList: some View {
        List {
            if !isSearchMode {
                InboxHeaderBlock(
                    currentTab: currentTabBinding,
                    activeFilter: $viewModel.activeFilter,
                    filterCounts: viewModel.filterCounts,
                    isCollapsed: isHeaderCollapsed,
                    onOpenFilters: { showingFilterSheet = true }
                )
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .preference(
                                key: ScrollOffsetKey.self,
                                value: proxy.frame(in: .named("inboxScroll")).minY
                            )
                    }
                )
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

                if let activeFilter = viewModel.activeFilter {
                    FilterActiveBanner(
                        filterLabel: activeFilter.rawValue,
                        filterColor: activeFilter.color,
                        onClear: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                viewModel.activeFilter = nil
                            }
                        }
                    )
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }

            ForEach(Array(displaySections.enumerated()), id: \.element.id) { index, section in
                Section {
                    ForEach(Array(section.emails.enumerated()), id: \.element.id) { index, email in
                        let previousEmail = index > 0 ? section.emails[index - 1] : nil
                        let isContinuation = previousEmail?.senderEmail.lowercased() == email.senderEmail.lowercased()
                        let isFirst = !isContinuation

                        emailRowView(
                            for: email,
                            isSelectionMode: isSelectionMode,
                            isContinuationInSenderRun: isContinuation,
                            isFirstInSenderRun: isFirst
                        )
                        .tag(email.threadId)
                        .padding(.top, index == 0 ? 0 : 0)
                    }
                } header: {
                    SectionHeaderRow(title: section.title, isFirst: index == 0)
                }
            }

            if viewModel.isLoadingMore {
                ProgressView().frame(maxWidth: .infinity).padding()
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(6)
        .contentMargins(.top, 0, for: .scrollContent)
        .contentMargins(.bottom, 56, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .coordinateSpace(name: "inboxScroll")
        .onPreferenceChange(ScrollOffsetKey.self) { value in
            scrollOffset = value
        }
    }

    @ViewBuilder
    private var searchModeContent: some View {
        Rectangle()
            .fill(Color(.separator).opacity(0.3))
            .frame(height: 1.0 / displayScale)
            .listRowInsets(.init())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !searchHistory.recentSearches.isEmpty {
                Section("Recent") {
                    ForEach(searchHistory.recentSearches.prefix(8), id: \.self) { query in
                        Button {
                            searchText = query
                            debouncedSearchText = query
                        } label: {
                            Label(query, systemImage: "clock.arrow.circlepath")
                        }
                        .foregroundStyle(.primary)
                    }
                }
            } else {
                ContentUnavailableView.search(text: "")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        } else {
            ForEach(searchModeResults.prefix(50)) { email in
                emailRowView(for: email, isSelectionMode: isSelectionMode)
            }
            if searchModeResults.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
    }

    private var searchModeList: some View {
        List {
            searchModeContent
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isSelectionMode {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { exitSelectionMode() }
            }

            ToolbarItem(placement: .principal) {
                Text("\(selectedThreadIds.count) Selected")
                    .font(.headline)
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button("Select All") { selectAllVisibleThreads() }
            }

            ToolbarItemGroup(placement: .bottomBar) {
                bulkActionBar
            }
        } else if isSearchMode {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Select") {
                    startSelectionMode()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.primary.opacity(0.75))
            }
        } else {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingLocationSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: viewModel.currentMailbox.icon)
                            .font(.body)
                        Text(viewModel.currentMailbox.rawValue)
                            .font(.subheadline.weight(.medium))
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Location")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button { showingSettings = true } label: {
                    Image(systemName: "gearshape")
                }
            }
            // Bottom command surface is overlaid on the list
        }
    }

    private func handleScopeSelection(_ scope: InboxLocationScope) {
        switch scope {
        case .unified:
            viewModel.selectMailbox(.allInboxes)
        case .account(let account):
            AuthService.shared.switchAccount(to: account)
            if viewModel.currentMailbox == .allInboxes {
                viewModel.selectMailbox(.inbox)
            } else {
                viewModel.selectMailbox(viewModel.currentMailbox)
            }
        }
    }

    private var selectedEmails: [Email] {
        viewModel.emails.filter { selectedThreadIds.contains($0.threadId) }
    }

    private var shouldMarkRead: Bool {
        selectedEmails.contains { $0.isUnread }
    }

    private var shouldStar: Bool {
        selectedEmails.contains { !$0.isStarred }
    }

    @ViewBuilder
    private var bulkActionBar: some View {
        Button { performBulkArchive() } label: {
            Image(systemName: "archivebox")
        }
        .disabled(selectedThreadIds.isEmpty)

        Button { performBulkTrash() } label: {
            Image(systemName: "trash")
        }
        .disabled(selectedThreadIds.isEmpty)

        Button {
            if shouldMarkRead {
                performBulkMarkRead()
            } else {
                performBulkMarkUnread()
            }
        } label: {
            Image(systemName: shouldMarkRead ? "envelope.open" : "envelope.badge")
        }
        .disabled(selectedThreadIds.isEmpty)

        Button {
            if shouldStar {
                performBulkStar()
            } else {
                performBulkUnstar()
            }
        } label: {
            Image(systemName: shouldStar ? "star" : "star.slash")
        }
        .disabled(selectedThreadIds.isEmpty)

        Button { showingMoveDialog = true } label: {
            Image(systemName: "folder")
        }
        .disabled(selectedThreadIds.isEmpty)

        Button { showingBulkSnooze = true } label: {
            Image(systemName: "clock")
        }
        .disabled(selectedThreadIds.isEmpty)
    }

    @ViewBuilder
    private var offlineBannerContent: some View {
        if !networkMonitor.isConnected {
            OfflineBanner()
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.3), value: networkMonitor.isConnected)
        }
    }

    @ViewBuilder
    private var bulkToastContent: some View {
        if let message = viewModel.bulkToastMessage {
            BulkActionToast(
                message: message,
                isError: viewModel.bulkToastIsError,
                showsRetry: viewModel.bulkToastShowsRetry,
                onRetry: { viewModel.retryPendingMutations() }
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var undoSendToastContent: some View {
        Group {
            if pendingSendManager.isPending {
                UndoSendToast(
                    remainingSeconds: pendingSendManager.remainingSeconds,
                    onUndo: {
                        pendingSendManager.undoSend()
                    }
                )
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if pendingSendManager.wasQueuedOffline {
                QueuedOfflineToast()
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        // Auto-dismiss after 3 seconds
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            pendingSendManager.clearQueuedOfflineFlag()
                        }
                    }
            }
        }
    }

    private func enterSelectionMode(selecting threadId: SelectionID) {
        if !isSelectionMode {
            isSelectionMode = true
            editMode = .active
            HapticFeedback.medium()
        }
        selectedThreadIds.insert(threadId)
    }

    private func startSelectionMode() {
        if !isSelectionMode {
            isSelectionMode = true
            editMode = .active
            HapticFeedback.medium()
        }
    }

    private func exitSelectionMode() {
        isSelectionMode = false
        editMode = .inactive
        selectedThreadIds.removeAll()
    }

    private func selectAllVisibleThreads() {
        let visible = displaySections.flatMap { $0.emails.map(\.threadId) }
        selectedThreadIds = Set(visible)
        if !selectedThreadIds.isEmpty {
            isSelectionMode = true
            editMode = .active
        }
    }

    private func performBulkArchive() {
        viewModel.bulkArchive(threadIds: selectedThreadIds)
        exitSelectionMode()
    }

    private func performBulkTrash() {
        viewModel.bulkTrash(threadIds: selectedThreadIds)
        exitSelectionMode()
    }

    private func performBulkMarkRead() {
        viewModel.bulkMarkRead(threadIds: selectedThreadIds)
        exitSelectionMode()
    }

    private func performBulkMarkUnread() {
        viewModel.bulkMarkUnread(threadIds: selectedThreadIds)
        exitSelectionMode()
    }

    private func performBulkStar() {
        viewModel.bulkStar(threadIds: selectedThreadIds)
        exitSelectionMode()
    }

    private func performBulkUnstar() {
        viewModel.bulkUnstar(threadIds: selectedThreadIds)
        exitSelectionMode()
    }

    private func performBulkMove(to mailbox: Mailbox) {
        switch mailbox {
        case .inbox:
            viewModel.bulkMoveToInbox(threadIds: selectedThreadIds)
        case .archive:
            viewModel.bulkArchive(threadIds: selectedThreadIds)
        case .trash:
            viewModel.bulkTrash(threadIds: selectedThreadIds)
        default:
            viewModel.bulkMoveToInbox(threadIds: selectedThreadIds)
        }
        exitSelectionMode()
    }

    private func performBulkSnooze(until date: Date) {
        viewModel.bulkSnooze(threadIds: selectedThreadIds, until: date)
        exitSelectionMode()
    }

    private var currentTabBinding: Binding<InboxTab> {
        Binding(
            get: { viewModel.currentTab },
            set: { newValue in
                viewModel.currentTab = newValue
            }
        )
    }

    @ViewBuilder
    private var searchSuggestionsContent: some View {
        if searchText.isEmpty {
            // Search Filters section
            Section("Search Filters") {
                ForEach(SearchFilter.suggestions, id: \.prefix) { suggestion in
                    Button {
                        searchText = suggestion.prefix
                    } label: {
                        Label(suggestion.description, systemImage: suggestion.icon)
                    }
                    .searchCompletion(suggestion.prefix)
                }
            }

            // Recent searches section
            if !searchHistory.recentSearches.isEmpty {
                Section {
                    ForEach(searchHistory.recentSearches.prefix(5), id: \.self) { query in
                        Button {
                            searchText = query
                        } label: {
                            Label(query, systemImage: "clock.arrow.circlepath")
                        }
                        .searchCompletion(query)
                    }
                } header: {
                    HStack {
                        Text("Recent")
                        Spacer()
                        Button("Clear") { searchHistory.clearHistory() }
                            .font(.caption)
                    }
                }
            }
        } else if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !searchText.contains(":") {
            // Typing suggestions - show smart filter options
            Section("Try") {
                ForEach(SearchFilter.suggestions.prefix(3), id: \.prefix) { suggestion in
                    Button {
                        searchText = "\(suggestion.prefix)\(searchText)"
                    } label: {
                        Label("\(suggestion.prefix)\(searchText)", systemImage: suggestion.icon)
                    }
                    .searchCompletion("\(suggestion.prefix)\(searchText)")
                }
            }
        }
    }

    @ViewBuilder
    private var overlayContent: some View {
        let query = debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if viewModel.isSearching {
            VStack(spacing: 12) {
                ProgressView()
                Text("Searching...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground).opacity(0.8))
        } else if viewModel.isSearchActive && viewModel.searchResults.isEmpty {
            ContentUnavailableView {
                Label("No Results", systemImage: "magnifyingglass")
            } description: {
                Text("No emails found for \"\(viewModel.currentSearchQuery)\"")
            } actions: {
                Button("Clear Search") {
                    searchText = ""
                    debouncedSearchText = ""
                    viewModel.clearSearch()
                }
                .buttonStyle(.bordered)
            }
        } else if !query.isEmpty && !viewModel.isSearchActive && displaySections.isEmpty {
            ContentUnavailableView {
                Label("No Results", systemImage: "magnifyingglass")
            } description: {
                Text("No emails found for \"\(query)\"")
            } actions: {
                Button("Clear Search") {
                    searchText = ""
                    debouncedSearchText = ""
                    viewModel.clearSearch()
                }
                .buttonStyle(.bordered)
            }
        } else if let error = viewModel.error, viewModel.emailSections.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Unable to Load")
                    .font(.title2.bold())
                Text(error.localizedDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    Task {
                        await viewModel.refresh()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        } else if displaySections.isEmpty && !viewModel.isLoading {
            if viewModel.activeFilter != nil {
                // Filter-specific empty state with clear button
                ContentUnavailableView {
                    Label(emptyStateTitle, systemImage: emptyStateIcon)
                } description: {
                    Text(emptyStateDescription)
                } actions: {
                    Button("Clear Filter") {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            viewModel.activeFilter = nil
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView {
                    Label(emptyStateTitle, systemImage: emptyStateIcon)
                } description: {
                    Text(emptyStateDescription)
                } actions: {
                    Button("Check for New Mail") {
                        Task { await viewModel.refresh() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        } else if viewModel.isLoading && viewModel.emailSections.isEmpty {
            InboxSkeletonView()
        }
    }

    @ViewBuilder
    private var detailDestination: some View {
        if let email = viewModel.selectedEmail {
            EmailDetailView(emailId: email.id, threadId: email.threadId, accountEmail: email.accountEmail)
        }
    }

    private func debounceSearch() async {
        // Instant clear for empty search
        if searchText.isEmpty {
            debouncedSearchText = ""
            return
        }
        // Debounce non-empty search
        do {
            try await Task.sleep(for: .milliseconds(300))
            debouncedSearchText = searchText
        } catch { }
    }

    private func handleAppear() {
        loadSettings()
        viewModel.preloadCachedEmails(
            mailbox: viewModel.currentMailbox,
            accountEmail: viewModel.currentMailbox == .allInboxes ? nil : AuthService.shared.currentAccount?.email
        )
    }

    private func loadSettings() {
        let accountEmail = AuthService.shared.currentAccount?.email
        guard let data = AccountDefaults.data(for: "appSettings", accountEmail: accountEmail) else {
            return
        }
        do {
            let settings = try JSONDecoder().decode(AppSettings.self, from: data)
            listDensity = settings.listDensity
            showAvatars = settings.showAvatars

            // Update threading setting on viewModel
            let threadingChanged = viewModel.conversationThreading != settings.conversationThreading
            viewModel.conversationThreading = settings.conversationThreading

            // Reload emails if threading preference changed
            if threadingChanged {
                Task {
                    await viewModel.refresh()
                }
            }
        } catch {
            logger.warning("Failed to decode app settings: \(error.localizedDescription)")
        }
    }

    private var emptyStateTitle: String {
        if let filter = viewModel.activeFilter {
            return "No \(filter.rawValue)"
        }
        if viewModel.currentTab == .primary {
            return "No Primary"
        }
        if viewModel.currentTab == .other {
            return "No Other Mail"
        }
        return "Inbox Zero"
    }

    private var emptyStateDescription: String {
        if let _ = viewModel.activeFilter {
            return "Try clearing your filter."
        }
        if viewModel.currentTab == .primary {
            return "No primary emails yet."
        }
        if viewModel.currentTab == .other {
            return "No other emails yet."
        }
        return "You're all caught up."
    }

    private var emptyStateIcon: String {
        if viewModel.activeFilter != nil {
            return "line.3.horizontal.decrease.circle"
        }
        if viewModel.currentTab == .other {
            return "tray.2"
        }
        return "tray"
    }
}

// MARK: - Inbox Header Block (Tight Filter Chips)

struct InboxHeaderBlock: View {
    @Binding var currentTab: InboxTab
    @Binding var activeFilter: InboxFilter?
    let filterCounts: [InboxFilter: Int]
    let isCollapsed: Bool
    let onOpenFilters: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // All/Primary/Other segmented control - always visible
            Picker("", selection: $currentTab) {
                Text(InboxTab.all.rawValue).tag(InboxTab.all)
                Text(InboxTab.primary.rawValue).tag(InboxTab.primary)
                Text(InboxTab.other.rawValue).tag(InboxTab.other)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 0)
            .padding(.bottom, 0)
        }
        .padding(.top, 0)
        .padding(.bottom, 0)
        .animation(.easeInOut(duration: 0.25), value: isCollapsed)
    }
}

struct SectionHeaderRow: View {
    let title: String
    let isFirst: Bool
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.primary.opacity(0.7))
                .textCase(nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, isFirst ? 4 : 10)
                .padding(.bottom, 4)

            // Inset separator with softer opacity
            Rectangle()
                .fill(Color(.separator).opacity(0.2))
                .frame(height: 1.0 / displayScale)
                .padding(.leading, 16)
        }
        .background(.ultraThinMaterial)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowSeparator(.hidden)
    }
}

private enum MailTypography {
    static let senderUnread = Font.subheadline.weight(.semibold)
    static let senderRead = Font.subheadline.weight(.medium)
    static let senderCompactUnread = Font.subheadline.weight(.semibold)
    static let senderCompactRead = Font.subheadline.weight(.medium)
    static let senderContinuation = Font.footnote.weight(.regular)
    static let subjectUnread = Font.subheadline.weight(.semibold)
    static let subjectRead = Font.subheadline.weight(.regular)
    static let subjectCompactUnread = Font.footnote.weight(.semibold)
    static let subjectCompactRead = Font.footnote.weight(.regular)
    static let snippet = Font.footnote
    static let meta = Font.caption2
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
    var anyFilterActive: Bool = false
    let onTap: () -> Void

    /// De-emphasized when another filter is active
    private var isDeemphasized: Bool {
        anyFilterActive && !isActive
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: filter.icon)
                    .font(.caption2)
                    .foregroundStyle(isActive ? filter.color : filter.color.opacity(isDeemphasized ? 0.35 : 0.6))

                Text(filter.rawValue)
                    .font(.subheadline)
                    .fontWeight(isActive ? .semibold : .regular)
                    .foregroundStyle(isActive ? .primary : Color.primary.opacity(isDeemphasized ? 0.5 : 0.82))

                // Count badge (compact, only when > 0)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color(.systemGray5))
                        .clipShape(Capsule())
                        .opacity(isDeemphasized ? 0.6 : 1.0)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(isActive ? filter.color.opacity(0.16) : Color(.systemGray6).opacity(isDeemphasized ? 0.5 : 1.0))
            )
            .overlay(
                Capsule().strokeBorder(
                    isActive ? filter.color.opacity(0.35) : Color(.separator).opacity(0.55),
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }
}

// MARK: - Filter Active Banner

struct FilterActiveBanner: View {
    let filterLabel: String
    let filterColor: Color
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .font(.subheadline)
                .foregroundStyle(filterColor)

            Text("Filtered by \(filterLabel)")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.primary)

            Spacer()

            Button(action: onClear) {
                Text("Clear")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(filterColor.opacity(0.08))
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
    var showAvatars: Bool = true
    var showAccountBadge: Bool = false
    var highlightTerms: [String] = []
    var isContinuationInSenderRun: Bool = false

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

    private var accountColor: Color {
        guard let email = email.accountEmail?.lowercased() else {
            return .secondary
        }
        let palette: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .indigo]
        let hash = email.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[hash % palette.count]
    }

    /// Highlight matching terms in text without using deprecated Text concatenation.
    private func highlightedText(_ text: String, font: Font, baseColor: Color = .primary) -> Text {
        guard !highlightTerms.isEmpty else {
            return Text(text).font(font).foregroundStyle(baseColor)
        }

        var attributed = AttributedString(text)
        var base = AttributeContainer()
        base.font = font
        base.foregroundColor = baseColor
        attributed.mergeAttributes(base)

        var matches: [Range<String.Index>] = []
        for term in highlightTerms where !term.isEmpty {
            var searchStart = text.startIndex
            while let range = text.range(of: term, options: .caseInsensitive, range: searchStart..<text.endIndex) {
                matches.append(range)
                searchStart = range.upperBound
            }
        }
        matches.sort { $0.lowerBound < $1.lowerBound }

        var lastEnd = text.startIndex
        var highlight = AttributeContainer()
        highlight.backgroundColor = Color(.systemYellow).opacity(0.35)

        for range in matches where range.lowerBound >= lastEnd {
            if let start = AttributedString.Index(range.lowerBound, within: attributed),
               let end = AttributedString.Index(range.upperBound, within: attributed) {
                attributed[start..<end].mergeAttributes(highlight)
                lastEnd = range.upperBound
            }
        }

        return Text(attributed)
    }

    var body: some View {
        let senderFont: Font = {
            if isContinuationInSenderRun {
                return MailTypography.senderContinuation
            }
            if isCompact {
                return email.isUnread ? MailTypography.senderCompactUnread : MailTypography.senderCompactRead
            }
            return email.isUnread ? MailTypography.senderUnread : MailTypography.senderRead
        }()
        let senderColor: Color = {
            if isContinuationInSenderRun {
                return .secondary
            }
            return email.isUnread ? .primary : Color.primary.opacity(0.78)
        }()
        let subjectFont: Font = {
            if isCompact {
                return email.isUnread ? MailTypography.subjectCompactUnread : MailTypography.subjectCompactRead
            }
            return email.isUnread ? MailTypography.subjectUnread : MailTypography.subjectRead
        }()
        let subjectColor: Color = email.isUnread ? .primary : Color.primary.opacity(0.82)
        let snippetColor: Color = email.isUnread ? Color.secondary.opacity(0.9) : Color.secondary.opacity(0.7)

        HStack(spacing: isCompact ? 8 : 10) {
            // Avatar (hidden in compact mode)
            // For sender-run continuation: hide avatar but keep alignment
            if showAvatars {
                if isContinuationInSenderRun {
                    // Empty space to maintain alignment
                    Color.clear
                        .frame(width: 40, height: 40)
                } else {
                    SmartAvatarView(
                        email: email.senderEmail,
                        name: email.senderName,
                        size: 40
                    )
                }
            }

            // Content
            VStack(alignment: .leading, spacing: isCompact ? 2 : 3) {
                // Top row: sender + metadata cluster
                HStack(alignment: .center, spacing: 6) {
                    // Sender name: reduced emphasis for sender-run continuation
                    highlightedText(email.senderName, font: senderFont)
                        .foregroundStyle(senderColor)
                        .lineLimit(1)

                    if isVIPSender && !isContinuationInSenderRun {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }

                    Spacer()

                    // Trailing metadata cluster (aligned)
                    HStack(spacing: 4) {
                        if email.hasAttachments {
                            Image(systemName: "paperclip")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        if showAccountBadge, accountLabel != nil {
                            Circle()
                                .fill(accountColor)
                                .frame(width: 6, height: 6)
                        }

                        Text(DateFormatters.formatEmailDate(email.date))
                            .font(MailTypography.meta)
                            .foregroundStyle(email.isUnread ? .primary : .secondary)

                        // Unread dot aligned with timestamp
                        if email.isUnread {
                            Circle()
                                .fill(.blue)
                                .frame(width: 8, height: 8)
                        }
                    }
                    .frame(minWidth: 78, alignment: .trailing)
                }

                // Subject line (normalized to remove Fwd:/Re: prefixes)
                highlightedText(EmailPreviewNormalizer.normalizeSubjectForDisplay(email.subject), font: subjectFont)
                    .foregroundStyle(subjectColor)
                    .lineLimit(1)

                // Snippet (not in compact mode, normalized to remove forwarded boilerplate)
                if !isCompact {
                    highlightedText(
                        EmailPreviewNormalizer.normalizeSnippetForDisplay(email.snippet),
                        font: MailTypography.snippet,
                        baseColor: snippetColor
                    )
                        .font(MailTypography.snippet)
                        .foregroundStyle(snippetColor)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, isCompact ? 5 : 7)
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

struct BulkActionToast: View {
    let message: String
    let isError: Bool
    let showsRetry: Bool
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.9))

            Text(message)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.white)

            Spacer()

            if showsRetry {
                Button("Retry") {
                    onRetry()
                }
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.yellow)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isError ? Color.red.opacity(0.9) : Color(.darkGray))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        )
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

// MARK: - Filter Sheet

struct FilterSheet: View {
    @Binding var activeFilter: InboxFilter?
    let filterCounts: [InboxFilter: Int]
    @Environment(\.dismiss) private var dismiss

    private let smartFilters: [InboxFilter] = [.unread, .needsReply, .deadlines, .money]
    private let otherFilters: [InboxFilter] = [.newsletters]
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    filterSection(title: "Smart", filters: smartFilters)
                    filterSection(title: "Other", filters: otherFilters)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if activeFilter != nil {
                        Button("Clear") {
                            activeFilter = nil
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func filterSection(title: String, filters: [InboxFilter]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(filters, id: \.self) { filter in
                    let count = filterCounts[filter] ?? 0
                    Button {
                        selectFilter(filter)
                    } label: {
                        SmartFilterCard(
                            filter: filter,
                            count: count,
                            isSelected: activeFilter == filter
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func selectFilter(_ filter: InboxFilter) {
        activeFilter = (activeFilter == filter) ? nil : filter
    }
}

struct SmartFilterCard: View {
    let filter: InboxFilter
    let count: Int
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: filter.icon)
                    .font(.headline)
                    .foregroundStyle(filter.color)
                Spacer()
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(filter.rawValue)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.7) : Color(.separator).opacity(0.3), lineWidth: 1)
        )
        .opacity(count == 0 ? 0.5 : 1)
        .disabled(count == 0)
    }
}

// MARK: - Preview

#Preview {
    InboxView()
}
