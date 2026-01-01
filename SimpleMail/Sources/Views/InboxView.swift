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
    @FocusState private var searchFocused: Bool

    /// Filtered sections based on search text
    private var filteredSections: [EmailSection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return viewModel.emailSections }

        return viewModel.emailSections.compactMap { section in
            let filteredEmails = section.emails.filter { email in
                email.senderName.localizedCaseInsensitiveContains(query) ||
                email.senderEmail.localizedCaseInsensitiveContains(query) ||
                email.subject.localizedCaseInsensitiveContains(query) ||
                email.snippet.localizedCaseInsensitiveContains(query)
            }
            guard !filteredEmails.isEmpty else { return nil }
            return EmailSection(id: section.id, title: section.title, emails: filteredEmails)
        }
    }

    var body: some View {
        List {
            InboxHeaderBlock(
                scope: $viewModel.scope,
                activeFilter: $viewModel.activeFilter,
                filterCounts: viewModel.filterCounts
            )
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 10, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color(.systemBackground))

            ForEach(filteredSections) { section in
                Section {
                    ForEach(section.emails) { email in
                        EmailRow(
                            email: email,
                            isCompact: listDensity == .compact,
                            showAccountBadge: viewModel.currentMailbox == .allInboxes
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

            if viewModel.hasMoreEmails && !viewModel.isLoadingMore {
                Button(action: {
                    if let lastEmail = viewModel.emailSections.last?.emails.last {
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
        .background(Color(.systemBackground))
        .listSectionSpacing(6)
        .accessibilityIdentifier("inboxList")
        .navigationBarTitleDisplayMode(.inline)
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

            ToolbarItem(placement: .bottomBar) {
                HStack(spacing: 12) {
                    Menu {
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
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 18))
                    }
                    .buttonStyle(.plain)

                    BottomSearchPill(text: $searchText, focused: $searchFocused)

                    Button { showingCompose = true } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 18))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("composeButton")
                    .accessibilityLabel("Compose new email")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 44)
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
    let filterCounts: [InboxFilter: Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(greeting)
                .font(.title3.weight(.semibold))

            ScopeToggle(scope: $scope)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
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
            }
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

// MARK: - Scope Toggle

enum InboxScope: String, CaseIterable {
    case all = "All"
    case people = "People"
}

struct ScopeToggle: View {
    @Binding var scope: InboxScope

    var body: some View {
        Picker("Scope", selection: $scope) {
            ForEach(InboxScope.allCases, id: \.self) { option in
                Text(option.rawValue).tag(option)
            }
        }
        .pickerStyle(.segmented)
    }
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
                    .foregroundStyle(isActive ? filter.color : .secondary)
                Text(filter.rawValue)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Group {
                    if isActive {
                        Capsule().fill(.thinMaterial)
                    } else {
                        Capsule().fill(Color.clear)
                    }
                }
            )
            .overlay(
                Capsule().strokeBorder(
                    .primary.opacity(isActive ? 0.22 : 0.10),
                    lineWidth: 1
                )
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
                    Text(email.senderName)
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

                Text(email.subject)
                    .font(isCompact ? .caption2 : .caption)
                    .fontWeight(email.isUnread ? .medium : .regular)
                    .lineLimit(1)

                if !isCompact {
                    Text(email.snippet)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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

// MARK: - Preview

#Preview {
    InboxView()
}
