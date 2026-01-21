import SwiftUI
import OSLog
import UIKit
// MainThreadWatchdog is a local utility in Sources/Utils

private let logger = Logger(subsystem: "com.simplemail.app", category: "InboxView")
typealias SelectionID = String

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct TopBarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Inbox Scope (Primary vs All)

enum InboxScope: String, CaseIterable {
    case primary = "Primary"
    case all = "All"
}

// MARK: - Inbox View

struct InboxView: View {
    @StateObject private var viewModel = InboxViewModel.shared
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
    @State private var scope: InboxScope = .primary
    @State private var showAvatars = true
    @State private var bundlesPlacement: InboxBundlesPlacement = .pinned
    @State private var searchFieldFocused = false
    @State private var isSearchMode = false
    @State private var hasPrewarmedSearch = false
    @State private var inboxScope: InboxLocationScope = .unified
    @State private var bottomBarHeight: CGFloat = 56
    @State private var safeAreaBottom: CGFloat = 0
    @State private var topBarHeight: CGFloat = 0
    private var pendingSendManager = PendingSendManager.shared
    private var networkMonitor = NetworkMonitor.shared

    init() {
        configureListHeaderAppearance()
    }

    /// Cached VIP senders set - computed once per view update, not per-row
    private var cachedVIPSenders: Set<String> {
        Set(AccountDefaults.stringArray(for: "vipSenders", accountEmail: AuthService.shared.currentAccount?.email).map { $0.lowercased() })
    }

    private var isHeaderCollapsed: Bool {
        scrollOffset > 50
    }

    /// Sections to display - either search results or pre-filtered inbox
    /// NOTE: Local search filtering is now done in InboxStoreWorker.computeState
    /// using EmailSnapshot (value types), NOT here in the SwiftUI body.
    private var displaySections: [EmailSection] {
        // If server search is active, show search results
        if viewModel.isSearchActive {
            let emails = viewModel.searchResults
            guard !emails.isEmpty else { return [] }
            return [EmailSection(id: "search", title: "Search Results", emails: emails)]
        }

        // Sections are already filtered in computeState via viewModel.searchFilter
        return viewModel.emailSections
    }

    private var searchModeResults: [EmailDTO] {
        if viewModel.isSearchActive {
            return viewModel.searchResults
        }
        let query = debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return viewModel.localSearchResults
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
        parsedSearchFilter?.highlightTerms ?? []
    }

    private var parsedSearchFilter: SearchFilter? {
        let query = debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        return SearchFilter.parse(query)
    }

    /// Section view - extracted to help compiler with type inference
    @ViewBuilder
    private func sectionView(section: EmailSection, sectionIndex: Int) -> some View {
        let sectionEmails = section.emails
        Section {
            ForEach(Array(sectionEmails.enumerated()), id: \.element.id) { emailIndex, email in
                let previousEmail = emailIndex > 0 ? sectionEmails[emailIndex - 1] : nil
                let isContinuation = previousEmail?.senderEmail.lowercased() == email.senderEmail.lowercased()
                let isFirst = !isContinuation

                emailRowView(
                    for: email,
                    isSelectionMode: isSelectionMode,
                    isContinuationInSenderRun: isContinuation,
                    isFirstInSenderRun: isFirst
                )
                .tag(email.threadId)
            }
        } header: {
            SectionHeaderRow(title: section.title, isFirst: sectionIndex == 0)
        }
    }

    /// Email row with all actions - extracted to help compiler
    @ViewBuilder
    private func emailRowView(for email: EmailDTO, isSelectionMode: Bool, isContinuationInSenderRun: Bool = false, isFirstInSenderRun: Bool = true) -> some View {
        HStack(spacing: 12) {
            if isSelectionMode {
                SelectionIndicator(isSelected: selectedThreadIds.contains(email.threadId))
            }

            EmailRow(
                email: email,
                isCompact: listDensity == .compact,
                showAvatars: showAvatars,
                showAccountBadge: viewModel.currentMailbox == .allInboxes,
                highlightTerms: highlightTerms,
                isContinuationInSenderRun: isContinuationInSenderRun,
                vipSenders: cachedVIPSenders
            )
        }
        .background(Color(.systemBackground))
        .listRowBackground(Color(.systemBackground))
        .listRowInsets(EdgeInsets(top: isFirstInSenderRun ? 9 : 5, leading: 16, bottom: 5, trailing: 16))
        .listRowSeparator(.visible)
        .listRowSeparatorTint(Color(.separator).opacity(0.35))
        .modifier(InstantSwipeModifier(
            onSwipeLeft: { viewModel.archiveEmail(id: email.id) },
            onSwipeRight: { viewModel.toggleRead(emailId: email.id) },
            leftColor: .green,
            rightColor: .accentColor,
            leftIcon: "archivebox",
            rightIcon: email.isUnread ? "envelope.open" : "envelope.badge"
        ))
        .onTapGesture {
            if isSelectionMode {
                toggleSelection(threadId: email.threadId)
            } else {
                // Dismiss keyboard but keep search mode active so user returns to search results
                searchFieldFocused = false
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.openEmail(id: email.id)
                }
            }
        }
        .onLongPressGesture {
            enterSelectionMode(selecting: email.threadId)
        }
        .onAppear { Task { await viewModel.loadMoreIfNeeded(currentEmailId: email.id) } }
    }

    var body: some View {
        baseContentView
            // MARK: - Sheets
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .sheet(isPresented: $showingCompose) { ComposeView() }
            .sheet(item: $restoredComposeMode) { mode in
                ComposeView(mode: mode)
            }
            .sheet(isPresented: $showingLocationSheet) {
                LocationSheetView(
                    selectedMailbox: $viewModel.currentMailbox,
                    onSelectMailbox: { mailbox in
                        viewModel.selectMailbox(mailbox)
                    },
                    onSelectScope: { scope in
                        handleScopeSelection(scope)
                    }
                )
            }
            .sheet(isPresented: $showingBulkSnooze) {
                SnoozePickerSheet { date in
                    performBulkSnooze(until: date)
                }
            }
            // MARK: - Dialogs & Navigation
            .confirmationDialog("Move to", isPresented: $showingMoveDialog) {
                Button("Inbox") { performBulkMove(to: .inbox) }
                Button("Archive") { performBulkArchive() }
                Button("Trash", role: .destructive) { performBulkTrash() }
                Button("Cancel", role: .cancel) { }
            }
            .navigationDestination(isPresented: $viewModel.showingEmailDetail) { detailDestination }
            .refreshable {
                await viewModel.refresh()
            }
            // MARK: - Tasks & onChange handlers
            .task(id: searchText) { await debounceSearch() }
            .onChange(of: searchText) { _, newValue in
                if newValue.isEmpty && viewModel.isSearchActive {
                    viewModel.clearSearch()
                } else if viewModel.isSearchActive && newValue != viewModel.currentSearchQuery {
                    viewModel.clearSearch()
                }
                if isSearchMode {
                    Task {
                        try? await Task.sleep(for: .milliseconds(250))
                        debouncedSearchText = newValue
                    }
                }
            }
            .onChange(of: debouncedSearchText) { _, newValue in
                guard isSearchMode else { return }
                // Update searchFilter on viewModel - filtering happens in computeState
                let query = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                viewModel.searchFilter = query.isEmpty ? nil : SearchFilter.parse(query)
                viewModel.performLocalSearch(query: newValue)
            }
            .onChange(of: viewModel.currentMailbox) { _, _ in
                exitSelectionMode()
                isSearchMode = false
                searchFieldFocused = false
            }
            .onChange(of: viewModel.emails) { _, _ in
                let valid = Set(viewModel.emails.map { $0.threadId })
                selectedThreadIds = selectedThreadIds.intersection(valid)
                if selectedThreadIds.isEmpty && isSelectionMode {
                    exitSelectionMode()
                }
            }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                if newPhase == .background {
                    exitSelectionMode()
                } else if newPhase == .active && oldPhase == .background {
                    Task { await viewModel.refresh() }
                }
            }
            .onChange(of: pendingSendManager.hasRestoredDraft) { _, hasRestored in
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
            }
            .onChange(of: isSearchMode) { _, newValue in
                if !newValue {
                    withAnimation(.easeOut(duration: 0.15)) {
                        searchFieldFocused = false
                    }
                }
            }
            .onChange(of: scope) { _, newScope in
                // Sync local scope with ViewModel's tab for filtering
                switch newScope {
                case .primary:
                    viewModel.currentTab = .primary
                case .all:
                    viewModel.currentTab = .all
                }
            }
            .onChange(of: searchFieldFocused) { _, focused in
                if focused {
                    withAnimation(.snappy(duration: 0.22)) {
                        isSearchMode = true
                    }
                }
            }
            // MARK: - Lifecycle
            .onAppear {
                handleAppear()
                if !hasPrewarmedSearch {
                    DispatchQueue.main.async {
                        hasPrewarmedSearch = true
                    }
                }
                MainThreadWatchdog.start(thresholdMs: 250)
            }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in loadSettings() }
            .onReceive(NotificationCenter.default.publisher(for: .accountDidChange)) { _ in loadSettings() }
            .onChange(of: viewModel.bulkToastMessage) { _, newValue in
                // Haptic feedback for bulk action results
                if newValue != nil {
                    if viewModel.bulkToastIsError {
                        HapticFeedback.error()
                    } else {
                        HapticFeedback.success()
                    }
                }
            }
    }

    private var baseContentView: some View {
        GeometryReader { geometry in
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()

                if !isSearchMode {
                    inboxList
                        .allowsHitTesting(true)
                }

                if isSearchMode || hasPrewarmedSearch {
                    SearchOverlayView(
                        searchText: $searchText,
                        debouncedSearchText: $debouncedSearchText,
                        searchHistory: searchHistory,
                        isSelectionMode: isSelectionMode,
                        isSearching: isSearchMode ? viewModel.isSearching : false,
                        results: isSearchMode ? searchModeResults : [],
                        onSelectRecent: { query in
                            searchText = query
                            debouncedSearchText = query
                        },
                        onTapBackground: {
                            searchFieldFocused = false
                        },
                        emailRowView: { email in
                            emailRowView(for: email, isSelectionMode: isSelectionMode)
                        }
                    )
                    .opacity(isSearchMode ? 1 : 0)
                    .allowsHitTesting(isSearchMode)
                }

            }
            .onAppear { safeAreaBottom = geometry.safeAreaInsets.bottom }
            .onChange(of: geometry.safeAreaInsets.bottom) { _, newValue in
                safeAreaBottom = newValue
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isSearchMode)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isSelectionMode || isSearchMode ? .visible : .hidden, for: .navigationBar)
        .toolbarBackground(isSearchMode ? .hidden : .visible, for: .navigationBar)
        .toolbarBackground(.bar, for: .navigationBar)
        .toolbar { toolbarContent }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled(true)
        .overlay { overlayContent }
        .overlay(alignment: .top) { offlineBannerContent }
        .overlay(alignment: .bottom) {
            bulkToastContent
                .padding(.bottom, bottomBarHeight + safeAreaBottom + 8)
                .zIndex(25)
        }
        .overlay {
            // Bottom bar as overlay - content scrolls behind it (Apple Mail style)
            if !isSelectionMode {
                VStack {
                    Spacer()
                    BottomCommandSurface(
                        searchMode: (isSearchMode || searchFieldFocused) ? .editing : .idle,
                        showSearchField: true,
                        searchText: $searchText,
                        searchFocused: $searchFieldFocused,
                        onSubmitSearch: {
                            commitSearch()
                            debouncedSearchText = searchText
                            Task { await viewModel.performSearch(query: searchText) }
                        },
                        onTapSearch: {
                            searchFieldFocused = true
                            DispatchQueue.main.async {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    isSearchMode = true
                                }
                            }
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
                        onTapMenu: { showingLocationSheet = true },
                        onTapCompose: { showingCompose = true }
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { bottomBarHeight = geo.size.height }
                                .onChange(of: geo.size.height) { _, newHeight in
                                    bottomBarHeight = newHeight
                                }
                        }
                    )
                }
            }
        }
        .overlay(alignment: .bottom) {
            undoActionToastContent
                .padding(.bottom, bottomBarHeight + safeAreaBottom + 8)
                .zIndex(28)
                .animation(.easeInOut(duration: 0.25), value: viewModel.showingUndoToast)
        }
        .overlay(alignment: .bottom) {
            undoSendToastContent
                .padding(.bottom, bottomBarHeight + safeAreaBottom + 8)
                .zIndex(30)
                .animation(.easeInOut(duration: 0.25), value: pendingSendManager.isPending)
                .animation(.easeInOut(duration: 0.25), value: pendingSendManager.wasQueuedOffline)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            // Simple scope picker (only in normal inbox mode)
            if !isSelectionMode && !isSearchMode {
                scopePickerBar
                    .background(
                        GeometryReader { proxy in
                            Color(.systemBackground)
                                .ignoresSafeArea(edges: .top)
                                .preference(key: TopBarHeightKey.self, value: proxy.size.height)
                        }
                    )
            }
        }
    }

    /// Clean top bar with just the centered Primary/All scope picker
    private var scopePickerBar: some View {
        Picker("Scope", selection: $scope) {
            ForEach(InboxScope.allCases, id: \.self) { scopeOption in
                Text(scopeOption.rawValue).tag(scopeOption)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 48) // Inset to keep it compact and centered
        .padding(.top, 0)
        .padding(.bottom, 6)
    }

    // MARK: - Extracted View Components

    private var inboxList: some View {
        mailList
    }

    private var mailList: some View {
        ScrollView {
            // Scroll tracking anchor (invisible)
            Color.clear
                .frame(height: 0)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .preference(
                                key: ScrollOffsetKey.self,
                                value: proxy.frame(in: .named("inboxScroll")).minY
                            )
                    }
                )

            VStack(spacing: 0) {
                if !isSearchMode {
                    // Category viewing header (when drilled into a category from bundle tap)
                    if let category = viewModel.viewingCategory {
                        CategoryViewingHeader(category: category) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                viewModel.viewingCategory = nil
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    // Category bundles (top block) when pinned - only in Primary scope
                    else if bundlesPlacement == .pinned && scope == .primary && !viewModel.bucketRows.isEmpty {
                        CategoryBundlesSection(bundles: viewModel.bucketRows) { bucket in
                            handleBucketTap(bucket)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                        // Visual boundary between bundles and email list
                        Divider()
                            .padding(.leading, 16)
                            .padding(.bottom, 8)
                    }
                }

                // Inline mode: flat list with bundles intermixed by date
                Group {
                    if bundlesPlacement == .inline && scope == .primary {
                        inlineEmailList(sections: displaySections)
                    } else {
                        // Section-based mode (pinned or off)
                        sectionBasedEmailList(sections: displaySections)
                    }
                }
                .padding(.bottom, bottomBarHeight + safeAreaBottom + 8)
            }
        }
        .coordinateSpace(name: "inboxScroll")
        // Opaque background all the way through safe areas so pinned headers never show through
        .background(Color(.systemBackground).ignoresSafeArea())
        // Start content just slightly below the measured top bar; subtract 2pt to align initial and pinned Y
        .padding(.top, max(topBarHeight - 2, 0))
        .onPreferenceChange(ScrollOffsetKey.self) { value in
            scrollOffset = value
        }
        .onPreferenceChange(TopBarHeightKey.self) { value in
            topBarHeight = value
        }
    }

    private struct SearchOverlayView<Row: View>: View {
        @Binding var searchText: String
        @Binding var debouncedSearchText: String
        let searchHistory: SearchHistoryManager
        let isSelectionMode: Bool
        let isSearching: Bool
        let results: [EmailDTO]
        let onSelectRecent: (String) -> Void
        let onTapBackground: () -> Void
        let emailRowView: (EmailDTO) -> Row

        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            let bgColor = colorScheme == .dark ? Color.black : Color(.systemBackground)

            ZStack {
                bgColor
                    .ignoresSafeArea()
                    .onTapGesture { onTapBackground() }

                SearchResultsCard(
                    searchText: $searchText,
                    debouncedSearchText: $debouncedSearchText,
                    searchHistory: searchHistory,
                    isSearching: isSearching,
                    results: results,
                    onSelectRecent: onSelectRecent,
                    emailRowView: emailRowView
                )
                .padding(.bottom, 80)
            }
        }
    }

    private struct SearchResultsCard<Row: View>: View {
        @Binding var searchText: String
        @Binding var debouncedSearchText: String
        let searchHistory: SearchHistoryManager
        let isSearching: Bool
        let results: [EmailDTO]
        let onSelectRecent: (String) -> Void
        let emailRowView: (EmailDTO) -> Row

        @Environment(\.colorScheme) private var colorScheme

        private var rowBackground: Color {
            colorScheme == .dark ? Color.black : Color(.systemBackground)
        }

        var body: some View {
            ZStack {
                List {
                    if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if !searchHistory.recentSearches.isEmpty {
                            Section {
                                ForEach(searchHistory.recentSearches.prefix(8), id: \.self) { query in
                                    Button {
                                        onSelectRecent(query)
                                    } label: {
                                        Label(query, systemImage: "clock.arrow.circlepath")
                                    }
                                    .foregroundStyle(.primary)
                                    .listRowBackground(rowBackground)
                                }
                            } header: {
                                Text("Recent")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        if !results.isEmpty {
                            Section {
                                ForEach(results.prefix(50)) { email in
                                    emailRowView(email)
                                        .listRowBackground(rowBackground)
                                }
                            } header: {
                                Text("Top Hits")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if results.isEmpty && !isSearching {
                            ContentUnavailableView.search(text: searchText)
                                .listRowBackground(rowBackground)
                                .listRowSeparator(.hidden)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(rowBackground)

                if isSearching {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Searching...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
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
            if !searchModeResults.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Select") {
                        startSelectionMode()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary.opacity(0.75))
                }
            }
        } else {
            // Normal mode: toolbar items in safeAreaInset via scopePickerBar
            // Empty spacer to maintain navigation structure
            ToolbarItem(placement: .principal) {
                EmptyView()
            }
        }
    }

    private func handleScopeSelection(_ scope: InboxLocationScope) {
        inboxScope = scope
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
        .help("Archive")

        Button { performBulkTrash() } label: {
            Image(systemName: "trash")
        }
        .disabled(selectedThreadIds.isEmpty)
        .help("Trash")

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
        .help(shouldMarkRead ? "Mark as Read" : "Mark as Unread")

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
        .help(shouldStar ? "Star" : "Unstar")

        Button { showingMoveDialog = true } label: {
            Image(systemName: "folder")
        }
        .disabled(selectedThreadIds.isEmpty)
        .help("Move")

        Button { showingBulkSnooze = true } label: {
            Image(systemName: "clock")
        }
        .disabled(selectedThreadIds.isEmpty)
        .help("Snooze")
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
    private var undoActionToastContent: some View {
        if viewModel.showingUndoToast {
            UndoToast(
                message: viewModel.undoToastMessage,
                remainingSeconds: viewModel.undoRemainingSeconds,
                onUndo: { viewModel.undoArchive() }
            )
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

    private func toggleSelection(threadId: SelectionID) {
        if selectedThreadIds.contains(threadId) {
            selectedThreadIds.remove(threadId)
        } else {
            selectedThreadIds.insert(threadId)
        }
        if selectedThreadIds.isEmpty {
            exitSelectionMode()
        }
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
        let visible = displaySections.flatMap { section in
            section.emails.map(\.threadId)
        }
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
        if isSearchMode {
            EmptyView()
        } else {
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
            } else {
                if displaySections.isEmpty && !viewModel.hasCompletedInitialLoad {
                    // Still loading initial data - show spinner, not empty state
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Loading emails...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if displaySections.isEmpty && !viewModel.isLoading && viewModel.hasCompletedInitialLoad {
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
                } else if viewModel.isLoading && viewModel.emailSections.isEmpty {
                    InboxSkeletonView()
                }
            }
        }
    }

    @ViewBuilder
    private var detailDestination: some View {
        if let email = viewModel.selectedEmail {
            EmailDetailView(
                emailId: email.id,
                threadId: email.threadId,
                accountEmail: email.accountEmail,
                onNavigatePrevious: viewModel.hasPreviousEmail ? { viewModel.goToPreviousEmail() } : nil,
                onNavigateNext: viewModel.hasNextEmail ? { viewModel.goToNextEmail() } : nil,
                hasPrevious: viewModel.hasPreviousEmail,
                hasNext: viewModel.hasNextEmail
            )
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

    // MARK: - Inline category blocks (Gmail-style)

    /// Represents either an email or a bundle in the unified inline list
    private enum InlineItem: Identifiable {
        case email(EmailDTO)
        case bucket(BucketRowModel)

        var id: String {
            switch self {
            case .email(let email): return email.id
            case .bucket(let bundle): return "bucket-\(bundle.id)"
            }
        }

        var date: Date {
            switch self {
            case .email(let email): return email.date
            case .bucket(let bundle): return bundle.latestDate ?? .distantPast
            }
        }
    }

    /// For non-inline mode, we still need sections
    private enum InlineBlock {
        case section(index: Int, section: EmailSection)
        case bucket(BucketRowModel)
    }

    /// Returns a flat list of items (emails + bundles) sorted by date for inline mode
    private func inlineItems(emails: [EmailDTO], bundles: [BucketRowModel]) -> [InlineItem] {
        var items: [InlineItem] = emails.map { .email($0) }
        items.append(contentsOf: bundles.map { .bucket($0) })

        // Sort by date descending (newest first)
        items.sort { $0.date > $1.date }

        return items
    }

    /// For pinned mode or when bundles are off - returns sections without bundles intermixed
    private func inlineCategoryBlocks(sections: [EmailSection], bundles: [BucketRowModel]) -> [InlineBlock] {
        // When bundles array is empty, just return sections
        if bundles.isEmpty {
            return sections.enumerated().map { .section(index: $0.offset, section: $0.element) }
        }

        // Otherwise sort bundles with sections (this path is for pinned mode edge cases)
        var blocks: [(Date, InlineBlock)] = []

        for (idx, section) in sections.enumerated() {
            if let date = section.emails.first?.date {
                blocks.append((date, .section(index: idx, section: section)))
            } else {
                blocks.append((.distantPast, .section(index: idx, section: section)))
            }
        }

        for bundle in bundles {
            let date = bundle.latestDate ?? .distantPast
            blocks.append((date, .bucket(bundle)))
        }

        blocks.sort { $0.0 > $1.0 }
        return blocks.map { $0.1 }
    }

    // MARK: - Email List Views

    /// Builds sections with bundles inserted inline at appropriate positions by date
    private func sectionsWithInlineBundles(sections: [EmailSection], bundles: [BucketRowModel]) -> [(section: EmailSection, items: [InlineItem])] {
        var result: [(section: EmailSection, items: [InlineItem])] = []

        for section in sections {
            // Find bundles that belong in this section (same date range as the section's emails)
            let sectionStart = section.emails.first?.date ?? .distantPast
            let sectionEnd = section.emails.last?.date ?? .distantFuture

            // Get bundles whose latestDate falls within this section's date range
            let sectionBundles = bundles.filter { bundle in
                guard let bundleDate = bundle.latestDate else { return false }
                return bundleDate <= sectionStart && bundleDate >= sectionEnd
            }

            // Create items list: emails + bundles for this section, sorted by date
            var items: [InlineItem] = section.emails.map { .email($0) }
            items.append(contentsOf: sectionBundles.map { .bucket($0) })
            items.sort { $0.date > $1.date }

            result.append((section: section, items: items))
        }

        // Handle any bundles that didn't fit into existing sections (e.g., newer than all emails)
        let usedBundleIds = Set(result.flatMap { pair in
            pair.items.compactMap { item -> String? in
                if case .bucket(let b) = item { return b.id }
                return nil
            }
        })
        let unusedBundles = bundles.filter { !usedBundleIds.contains($0.id) }

        // If there are unused bundles and we have sections, add them to the first section
        if !unusedBundles.isEmpty, var firstPair = result.first {
            var items = firstPair.items
            items.append(contentsOf: unusedBundles.map { .bucket($0) })
            items.sort { $0.date > $1.date }
            result[0] = (section: firstPair.section, items: items)
        }

        return result
    }

    /// Inline mode: sections with bundles intermixed by date within each section
    @ViewBuilder
    private func inlineEmailList(sections: [EmailSection]) -> some View {
        let sectionsWithBundles = sectionsWithInlineBundles(sections: sections, bundles: viewModel.bucketRows)

        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(Array(sectionsWithBundles.enumerated()), id: \.offset) { sectionIndex, pair in
                Section {
                    ForEach(Array(pair.items.enumerated()), id: \.element.id) { itemIndex, item in
                        inlineItemView(item: item, index: itemIndex, items: pair.items)
                    }
                } header: {
                    SectionHeaderRow(title: pair.section.title, isFirst: sectionIndex == 0)
                        .background(Color(.systemBackground))
                }
            }

            loadMoreTrigger
        }
    }

    @ViewBuilder
    private func inlineItemView(item: InlineItem, index: Int, items: [InlineItem]) -> some View {
        switch item {
        case .email(let email):
            let previousItem = index > 0 ? items[index - 1] : nil
            let previousEmail: EmailDTO? = {
                if case .email(let prev) = previousItem { return prev }
                return nil
            }()
            let isContinuation = previousEmail?.senderEmail.lowercased() == email.senderEmail.lowercased()
            let isFirst = !isContinuation

            emailRowView(
                for: email,
                isSelectionMode: isSelectionMode,
                isContinuationInSenderRun: isContinuation,
                isFirstInSenderRun: isFirst
            )
            .padding(.horizontal, 16)
            .padding(.top, isFirst ? 9 : 5)
            .padding(.bottom, 5)

            Divider()
                .background(Color(.separator).opacity(0.35))
                .padding(.leading, isSelectionMode ? 0 : 16)

        case .bucket(let bundle):
            CategoryBundleRow(model: bundle) {
                handleBucketTap(bundle.bucket)
            }
            .padding(.horizontal, 16)
            .padding(.top, 9)
            .padding(.bottom, 5)

            Divider()
                .background(Color(.separator).opacity(0.35))
                .padding(.leading, isSelectionMode ? 0 : 16)
        }
    }

    /// Section-based mode: emails grouped by day with headers (pinned or off)
    @ViewBuilder
    private func sectionBasedEmailList(sections: [EmailSection]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                Section {
                    ForEach(Array(section.emails.enumerated()), id: \.element.id) { emailIndex, email in
                        let previousEmail = emailIndex > 0 ? section.emails[emailIndex - 1] : nil
                        let isContinuation = previousEmail?.senderEmail.lowercased() == email.senderEmail.lowercased()
                        let isFirst = !isContinuation

                        emailRowView(
                            for: email,
                            isSelectionMode: isSelectionMode,
                            isContinuationInSenderRun: isContinuation,
                            isFirstInSenderRun: isFirst
                        )
                        .padding(.horizontal, 16)
                        .padding(.top, isFirst ? 9 : 5)
                        .padding(.bottom, 5)

                        Divider()
                            .background(Color(.separator).opacity(0.35))
                            .padding(.leading, isSelectionMode ? 0 : 16)
                    }
                } header: {
                    SectionHeaderRow(title: section.title, isFirst: index == 0)
                        .background(Color(.systemBackground))
                }
            }

            loadMoreTrigger
        }
    }

    @ViewBuilder
    private var loadMoreTrigger: some View {
        if !isSearchMode {
            Color.clear
                .frame(height: 1)
                .onAppear { Task { await viewModel.loadMoreFromFooter() } }
        }

        if viewModel.isLoadingMore {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding()
        }
    }

    private func handleAppear() {
        StallLogger.mark("InboxView.appear")
        loadSettings()
        if viewModel.currentMailbox == .allInboxes {
            inboxScope = .unified
        } else if let account = AuthService.shared.currentAccount {
            inboxScope = .account(account)
        } else {
            inboxScope = .unified
        }
        // Sync ViewModel tab with local scope (default is Primary)
        viewModel.currentTab = (scope == .primary) ? .primary : .all
        Task.detached(priority: .utility) {
            await viewModel.preloadCachedEmails(
                mailbox: await MainActor.run { viewModel.currentMailbox },
                accountEmail: await MainActor.run {
                    viewModel.currentMailbox == .allInboxes ? nil : AuthService.shared.currentAccount?.email
                }
            )
        }
        // NOTE: WebKit warmup removed from here - now done lazily on first EmailDetail open
        // to avoid injecting 1-2s GPU process startup stalls into inbox browsing
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
            bundlesPlacement = settings.bundlesPlacement

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

    private func handleBucketTap(_ bucket: GmailBucket) {
        HapticFeedback.light()
        // Instantly filter to show this category's emails (no network call)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            viewModel.markBucketSeen(bucket)
            viewModel.viewingCategory = bucket.category
        }
    }

    private var emptyStateTitle: String {
        if viewModel.currentTab == .primary {
            return "No Primary"
        }
        return "Inbox Zero"
    }

    private var emptyStateDescription: String {
        if viewModel.currentTab == .primary {
            return "No primary emails yet."
        }
        return "You're all caught up."
    }

    private var emptyStateIcon: String {
        return "tray"
    }
}

struct SectionHeaderRow: View {
    let title: String
    let isFirst: Bool
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack(alignment: .leading) {
            // Glassy yet opaque-enough background to match the original gray strip look
            Rectangle()
                .fill(.regularMaterial)
                .overlay(
                    Color(UIColor.systemBackground)
                        .opacity(0.45)
                )
                .ignoresSafeArea(edges: [.top, .horizontal])

            VStack(spacing: 0) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .textCase(nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    // Uniform padding keeps pinned and initial positions aligned
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                    .accessibilityAddTraits(.isHeader)

                Rectangle()
                    .fill(Color(.separator).opacity(0.18))
                    .frame(height: 1.0 / displayScale)
                    .padding(.leading, 16)
            }
        }
        .frame(maxWidth: .infinity)
        .zIndex(10)
    }
}

// MARK: - Appearance helpers

private func configureListHeaderAppearance() {
    // Apply once per app run to avoid repeated global UIAppearance churn
    struct Static {
        static var configured = false
    }
    guard !Static.configured else { return }
    Static.configured = true

    // UITableView reuses a separate header container when pinning; set its background
    // so transient reuse doesn't show a black flash.
    let headerAppearance = UITableViewHeaderFooterView.appearance()
    headerAppearance.tintColor = UIColor.systemBackground
    headerAppearance.backgroundColor = UIColor.systemBackground
    headerAppearance.contentView.backgroundColor = UIColor.systemBackground

    if headerAppearance.backgroundView == nil {
        let bg = UIView()
        bg.backgroundColor = UIColor.systemBackground
        headerAppearance.backgroundView = bg
    } else {
        headerAppearance.backgroundView?.backgroundColor = UIColor.systemBackground
    }

    let tableAppearance = UITableView.appearance()
    tableAppearance.backgroundColor = UIColor.systemBackground
    tableAppearance.sectionHeaderTopPadding = 0
    if tableAppearance.backgroundView == nil {
        let bg = UIView()
        bg.backgroundColor = UIColor.systemBackground
        tableAppearance.backgroundView = bg
    } else {
        tableAppearance.backgroundView?.backgroundColor = UIColor.systemBackground
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

// MARK: - Inbox Filter Types (used by ViewModel for filtering)

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
    let email: EmailDTO
    var isCompact: Bool = false
    var showAvatars: Bool = true
    var showAccountBadge: Bool = false
    var highlightTerms: [String] = []
    var isContinuationInSenderRun: Bool = false
    var vipSenders: Set<String> = []

    private var isVIPSender: Bool {
        vipSenders.contains(email.senderEmail.lowercased())
    }

    private var accountLabel: String? {
        guard showAccountBadge, let accountEmail = email.accountEmail else {
            return nil
        }
        return accountEmail.split(separator: "@").first.map(String.init)
    }

    private var accountColor: Color {
        guard let accountEmail = email.accountEmail?.lowercased() else {
            return .secondary
        }
        let palette: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .indigo]
        let hash = accountEmail.unicodeScalars.reduce(0) { $0 + Int($1.value) }
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
        let subjectColor: Color = email.isUnread ? .primary : Color.primary.opacity(0.86)
        let snippetColor: Color = email.isUnread ? Color.secondary.opacity(0.95) : Color.secondary.opacity(0.8)
        let metaColor: Color = Color.secondary.opacity(email.isUnread ? 0.95 : 0.85)

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
                    highlightedText(email.senderName, font: senderFont, baseColor: senderColor)
                        .lineLimit(1)

                    if isVIPSender && !isContinuationInSenderRun {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }

                    Spacer()

                    // Trailing metadata cluster (aligned to text baseline)
                    HStack(alignment: .center, spacing: 4) {
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
                            .monospacedDigit()
                            .foregroundStyle(metaColor)

                        // Unread dot - smaller, aligned with time
                        Circle()
                            .fill(.blue)
                            .frame(width: 6, height: 6)
                            .opacity(email.isUnread ? 1 : 0)
                    }
                    .frame(minWidth: 72, alignment: .trailing)
                }

                // Subject line (pre-normalized in EmailDTO to avoid per-row regex)
                highlightedText(email.displaySubject, font: subjectFont, baseColor: subjectColor)
                    .lineLimit(1)
                    .truncationMode(.tail)

                // Snippet (not in compact mode, pre-normalized in EmailDTO)
                if !isCompact {
                    highlightedText(email.displaySnippet, font: MailTypography.snippet, baseColor: snippetColor)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                }
            }
            .layoutPriority(1)
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
    let remainingSeconds: Int
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "archivebox")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))

            HStack(spacing: 6) {
                Text(message)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)

                if remainingSeconds > 0 {
                    Text("·")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.5))

                    Text("\(remainingSeconds)s")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.white.opacity(0.7))
                        .monospacedDigit()
                }
            }

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

private struct SelectionIndicator: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(.separator).opacity(0.6), lineWidth: 1)
                .frame(width: 22, height: 22)
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: 24)
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

// MARK: - Instant Swipe Modifier

private struct InstantSwipeModifier: ViewModifier {
    let onSwipeLeft: () -> Void
    let onSwipeRight: () -> Void
    let leftColor: Color
    let rightColor: Color
    let leftIcon: String
    let rightIcon: String

    @State private var offset: CGFloat = 0
    @State private var hasTriggered = false

    private let threshold: CGFloat = 80

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .background {
                // Only show backgrounds when actively swiping
                if offset != 0 {
                    HStack(spacing: 0) {
                        // Right swipe background (toggle read)
                        rightColor
                            .overlay(alignment: .leading) {
                                Image(systemName: rightIcon)
                                    .font(.title2)
                                    .foregroundStyle(.white)
                                    .padding(.leading, 20)
                            }
                            .opacity(offset > 0 ? 1 : 0)

                        // Left swipe background (archive)
                        leftColor
                            .overlay(alignment: .trailing) {
                                Image(systemName: leftIcon)
                                    .font(.title2)
                                    .foregroundStyle(.white)
                                    .padding(.trailing, 20)
                            }
                            .opacity(offset < 0 ? 1 : 0)
                    }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        offset = value.translation.width

                        if !hasTriggered {
                            if offset > threshold {
                                hasTriggered = true
                                let generator = UIImpactFeedbackGenerator(style: .medium)
                                generator.impactOccurred()
                                onSwipeRight()
                            } else if offset < -threshold {
                                hasTriggered = true
                                let generator = UIImpactFeedbackGenerator(style: .medium)
                                generator.impactOccurred()
                                onSwipeLeft()
                            }
                        }
                    }
                    .onEnded { _ in
                        withAnimation(.spring(response: 0.3)) {
                            offset = 0
                        }
                        hasTriggered = false
                    }
            )
    }
}

// MARK: - Preview

#Preview {
    InboxView()
}
