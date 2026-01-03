import SwiftUI
import OSLog

private let logger = Logger(subsystem: "com.simplemail.app", category: "InboxView")
typealias SelectionID = String

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
    @State private var scope: InboxScope = .all
    @State private var scrollOffset: CGFloat = 0
    @State private var restoredComposeMode: ComposeMode?
    @State private var showingFilterSheet = false
    @State private var searchPlacement: SearchPlacement = .bottomBar
    @FocusState private var isSearchFieldFocused: Bool
    private var pendingSendManager = PendingSendManager.shared
    private var networkMonitor = NetworkMonitor.shared

    /// Computed active filter label for bottom command surface
    private var activeFilterLabel: String? {
        viewModel.activeFilter?.rawValue
    }

    /// Whether to show search pill in bottom command surface
    private var showSearchInBottomBar: Bool {
        searchPlacement == .bottomBar
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
            showAccountBadge: viewModel.currentMailbox == .allInboxes,
            highlightTerms: highlightTerms,
            isContinuationInSenderRun: isContinuationInSenderRun
        )
        .listRowBackground(Color(.systemBackground))
        .listRowInsets(EdgeInsets(top: isFirstInSenderRun ? 9 : 5, leading: 16, bottom: 5, trailing: 16))
        .listRowSeparator(.visible)
        .listRowSeparatorTint(Color(.separator).opacity(0.4))
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button { viewModel.archiveEmail(email) } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(.green)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { viewModel.toggleRead(email) } label: {
                Label(email.isUnread ? "Read" : "Unread",
                      systemImage: email.isUnread ? "envelope.open" : "envelope.badge")
            }
            .tint(.blue)
        }
        .onTapGesture {
            if !isSelectionMode {
                viewModel.openEmail(email)
            }
        }
        .onLongPressGesture {
            enterSelectionMode(selecting: email.threadId)
        }
        .onAppear { Task { await viewModel.loadMoreIfNeeded(currentEmail: email) } }
    }

    var body: some View {
        inboxList
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(.bar, for: .navigationBar)
            .toolbar { toolbarContent }
            .searchable(text: $searchText, prompt: "Search")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .searchSuggestions { searchSuggestionsContent }
            .onSubmit(of: .search) {
                commitSearch()
                debouncedSearchText = searchText
                // Perform server-side search
                Task {
                    await viewModel.performSearch(query: searchText)
                }
            }
            .searchToolbarBehavior(showSearchInBottomBar ? .hidden : .minimize)
            .overlay { overlayContent }
            .overlay(alignment: .top) { offlineBannerContent }
            .overlay(alignment: .bottom) { bulkToastContent }
            .overlay(alignment: .bottom) {
                undoSendToastContent
                    .animation(.easeInOut(duration: 0.25), value: pendingSendManager.isPending)
                    .animation(.easeInOut(duration: 0.25), value: pendingSendManager.wasQueuedOffline)
            }
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
            .sheet(isPresented: $showingFilterSheet) {
                FilterSheet(
                    scope: viewModel.scope,
                    activeFilter: $viewModel.activeFilter,
                    filterCounts: viewModel.filterCounts
                )
                .presentationDetents([.medium])
            }
            .confirmationDialog("Move to", isPresented: $showingMoveDialog) {
                Button("Inbox") { performBulkMove(to: .inbox) }
                Button("Archive") { performBulkArchive() }
                Button("Trash", role: .destructive) { performBulkTrash() }
                Button("Cancel", role: .cancel) { }
            }
            .navigationDestination(isPresented: $viewModel.showingEmailDetail) { detailDestination }
            .refreshable { await viewModel.refresh() }
            .task(id: searchText) { await debounceSearch() }
            .onChange(of: searchText) { _, newValue in
                // Clear server search when search text is cleared
                if newValue.isEmpty && viewModel.isSearchActive {
                    viewModel.clearSearch()
                }
            }
            .onChange(of: viewModel.scope) { _, newValue in
                if let active = viewModel.activeFilter,
                   !availableFilters(for: newValue).contains(active) {
                    viewModel.activeFilter = nil
                }
            }
            .onChange(of: viewModel.currentMailbox) { _, _ in
                exitSelectionMode()
            }
            .onChange(of: viewModel.activeFilter) { _, _ in
                exitSelectionMode()
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
            .onAppear { handleAppear() }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in loadSettings() }
            .onReceive(NotificationCenter.default.publisher(for: .accountDidChange)) { _ in loadSettings() }
    }

    // MARK: - Extracted View Components

    private var inboxList: some View {
        ScrollViewReader { proxy in
            List(selection: $selectedThreadIds) {
                Section {
                    InboxHeaderBlock(
                        scope: scopeBinding,
                        activeFilter: $viewModel.activeFilter,
                        filterCounts: viewModel.filterCounts,
                        isCollapsed: isHeaderCollapsed
                    )
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listSectionSpacing(0)

                // Filter active indicator banner
                if let activeFilter = viewModel.activeFilter {
                    Section {
                        FilterActiveBanner(
                            filterLabel: activeFilter.rawValue,
                            filterColor: activeFilter.color,
                            onClear: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    viewModel.activeFilter = nil
                                }
                            }
                        )
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listSectionSpacing(0)
                }

            ForEach(displaySections) { section in
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
                        .padding(.top, index == 0 ? 6 : 0)
                    }
                } header: {
                    // Section headers: solid background for high contrast while scrolling
                    VStack(spacing: 0) {
                        Text(section.title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.primary)
                            .textCase(.uppercase)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.top, 10)
                            .padding(.bottom, 7)

                        // Hairline bottom divider (native 1px)
                        Rectangle()
                            .fill(Color(.separator).opacity(0.6))
                            .frame(height: 1.0 / displayScale)
                    }
                    .background(Color(.systemBackground))
                    .listRowInsets(EdgeInsets())
                }
            }

            if viewModel.isLoadingMore {
                ProgressView().frame(maxWidth: .infinity).padding()
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .bottom) {
                if !isSelectionMode && !showingFilterSheet {
                    BottomCommandSurface(
                        isFilterActive: viewModel.activeFilter != nil,
                        activeFilterLabel: activeFilterLabel,
                        showSearchPill: showSearchInBottomBar,
                        onTapFilter: { showingFilterSheet = true },
                        onTapSearch: { isSearchFieldFocused = true },
                        onTapCompose: { showingCompose = true }
                    )
                } else {
                    Color.clear.frame(height: 56)
                }
            }
            .environment(\.editMode, $editMode)
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        scrollOffset = -value.translation.height
                    }
            )
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
            // Bottom command surface is now overlaid on the list, not in toolbar
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
        }
        selectedThreadIds.insert(threadId)
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

    private var scopeBinding: Binding<InboxScope> {
        Binding(
            get: { viewModel.scope },
            set: { newValue in
                viewModel.scope = newValue
            }
        )
    }

    private func availableFilters(for scope: InboxScope) -> [InboxFilter] {
        if scope == .people {
            return [.unread, .needsReply]
        }
        return InboxFilter.allCases
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
            ContentUnavailableView(
                "No Results",
                systemImage: "magnifyingglass",
                description: Text("No emails found for \"\(viewModel.currentSearchQuery)\"")
            )
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
                ContentUnavailableView(
                    emptyStateTitle,
                    systemImage: emptyStateIcon,
                    description: Text(emptyStateDescription)
                )
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
            searchPlacement = settings.searchPlacement

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
        if viewModel.scope == .people {
            return "No People"
        }
        return "Inbox Zero"
    }

    private var emptyStateDescription: String {
        if let _ = viewModel.activeFilter {
            return "Try clearing your filter."
        }
        if viewModel.scope == .people {
            return "No person-to-person emails yet."
        }
        return "You're all caught up."
    }

    private var emptyStateIcon: String {
        if viewModel.scope == .people {
            return "person.2"
        }
        if viewModel.activeFilter != nil {
            return "line.3.horizontal.decrease.circle"
        }
        return "tray"
    }
}

// MARK: - Inbox Header Block (Tight Filter Chips)

struct InboxHeaderBlock: View {
    @Binding var scope: InboxScope
    @Binding var activeFilter: InboxFilter?
    let filterCounts: [InboxFilter: Int]
    let isCollapsed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // All/People segmented control - always visible
            Picker("", selection: $scope) {
                Text(InboxScope.all.rawValue).tag(InboxScope.all)
                Text(InboxScope.people.rawValue).tag(InboxScope.people)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 3)

            // Filter pills - hide when collapsed
            if !isCollapsed {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        let filters = scope == .people ? [InboxFilter.unread, .needsReply] : InboxFilter.allCases
                        ForEach(filters, id: \.self) { filter in
                            FilterPill(
                                filter: filter,
                                count: filterCounts[filter] ?? 0,
                                isActive: activeFilter == filter,
                                anyFilterActive: activeFilter != nil,
                                onTap: {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        activeFilter = activeFilter == filter ? nil : filter
                                    }
                                }
                            )
                        }
                    }
                    .padding(.top, 2)
                    .padding(.bottom, 4)
                    .padding(.leading, 8)
                }
                .overlay(alignment: .trailing) {
                    LinearGradient(
                        colors: [Color.clear, Color(.systemBackground)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 24)
                    .allowsHitTesting(false)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.bottom, 4)
        .animation(.easeInOut(duration: 0.25), value: isCollapsed)
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
                    .foregroundStyle(.blue)
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
        highlight.foregroundColor = .yellow
        highlight.font = font.bold()

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
        HStack(spacing: isCompact ? 8 : 10) {
            // Avatar (hidden in compact mode)
            // For sender-run continuation: hide avatar but keep alignment
            if !isCompact {
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
                    highlightedText(email.senderName, font: isCompact ? .caption : .subheadline)
                        .font(isCompact ? .caption : (isContinuationInSenderRun ? .caption : .subheadline))
                        .fontWeight(isContinuationInSenderRun ? .regular : (email.isUnread ? .semibold : .medium))
                        .foregroundStyle(isContinuationInSenderRun ? .secondary : .primary)
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
                            .font(.caption2)
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
                highlightedText(EmailPreviewNormalizer.normalizeSubjectForDisplay(email.subject), font: isCompact ? .caption2 : .subheadline)
                    .font(isCompact ? .caption2 : .subheadline)
                    .fontWeight(email.isUnread ? .medium : .regular)
                    .foregroundStyle(email.isUnread ? .primary : Color.primary.opacity(0.85))
                    .lineLimit(1)

                // Snippet (not in compact mode, normalized to remove forwarded boilerplate)
                if !isCompact {
                    highlightedText(EmailPreviewNormalizer.normalizeSnippetForDisplay(email.snippet), font: .caption, baseColor: .secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, isCompact ? 2 : 4)
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
    let scope: InboxScope
    @Binding var activeFilter: InboxFilter?
    let filterCounts: [InboxFilter: Int]
    @Environment(\.dismiss) private var dismiss

    private var availableFilters: [InboxFilter] {
        if scope == .people {
            return [.unread, .needsReply]
        }
        return InboxFilter.allCases
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(availableFilters, id: \.self) { filter in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if activeFilter == filter {
                                    activeFilter = nil
                                } else {
                                    activeFilter = filter
                                }
                            }
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: filter.icon)
                                    .font(.body)
                                    .foregroundStyle(filter.color)
                                    .frame(width: 28)

                                Text(filter.rawValue)
                                    .font(.body)
                                    .foregroundStyle(.primary)

                                Spacer()

                                if let count = filterCounts[filter], count > 0 {
                                    Text("\(count)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }

                                if activeFilter == filter {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.blue)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Filter by")
                } footer: {
                    if scope == .people {
                        Text("Only Unread and Needs Reply filters are available in People view.")
                    }
                }

                if activeFilter != nil {
                    Section {
                        Button(role: .destructive) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                activeFilter = nil
                            }
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "xmark.circle")
                                Text("Clear Filter")
                            }
                            .foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    InboxView()
}
