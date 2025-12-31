import SwiftUI
import SwiftData

// MARK: - Inbox View

struct InboxView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = InboxViewModel()
    @State private var showingSearch = false
    @State private var showingCompose = false
    @State private var showingSnooze = false
    @State private var emailToSnooze: Email?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Sticky Header with Scope Toggle and Pills
                StickyInboxHeader(
                    scope: $viewModel.scope,
                    activeFilter: $viewModel.activeFilter,
                    filterCounts: viewModel.filterCounts
                )

                // Email List with Pull to Refresh
                EmailListView(
                    sections: viewModel.emailSections,
                    isLoading: viewModel.isLoading,
                    isLoadingMore: viewModel.isLoadingMore,
                    hasMoreEmails: viewModel.hasMoreEmails,
                    onTap: { email in viewModel.openEmail(email) },
                    onArchive: { email in viewModel.archiveEmail(email) },
                    onSnooze: { email in
                        emailToSnooze = email
                        showingSnooze = true
                    },
                    onToggleRead: { email in viewModel.toggleRead(email) },
                    onStar: { email in viewModel.starEmail(email) },
                    onTrash: { email in viewModel.trashEmail(email) },
                    onLoadMore: { email in
                        Task { await viewModel.loadMoreIfNeeded(currentEmail: email) }
                    },
                    onRefresh: {
                        await viewModel.refresh()
                    }
                )
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    MailboxDropdown(
                        currentMailbox: viewModel.currentMailbox,
                        onSelect: { mailbox in viewModel.selectMailbox(mailbox) }
                    )
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Button(action: { showingSearch = true }) {
                            Image(systemName: "magnifyingglass")
                        }
                        Button(action: { showingCompose = true }) {
                            Image(systemName: "square.and.pencil")
                        }
                    }
                }
            }
            .navigationDestination(isPresented: $viewModel.showingEmailDetail) {
                if let email = viewModel.selectedEmail {
                    EmailDetailView(emailId: email.id, threadId: email.threadId)
                }
            }
            .sheet(isPresented: $showingSearch) {
                SearchView()
            }
            .sheet(isPresented: $showingCompose) {
                ComposeView()
            }
            .sheet(isPresented: $showingSnooze) {
                SnoozePickerSheet { date in
                    if let email = emailToSnooze {
                        viewModel.snoozeEmail(email, until: date)
                    }
                    emailToSnooze = nil
                }
            }
        }
    }
}

// MARK: - Sticky Inbox Header

struct StickyInboxHeader: View {
    @Binding var scope: InboxScope
    @Binding var activeFilter: InboxFilter?
    let filterCounts: [InboxFilter: Int]

    var body: some View {
        VStack(spacing: 8) {
            // Greeting + Scope Toggle on same row
            HStack {
                Text(greeting)
                    .font(.title3)
                    .fontWeight(.semibold)

                Spacer()

                ScopeToggle(scope: $scope)
            }
            .padding(.horizontal)

            // Filter Pills
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
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
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
        HStack(spacing: 0) {
            ForEach(InboxScope.allCases, id: \.self) { option in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        scope = option
                    }
                }) {
                    Text(option.rawValue)
                        .font(.subheadline)
                        .fontWeight(scope == option ? .semibold : .regular)
                        .foregroundStyle(scope == option ? .white : .secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(scope == option ? Color.accentColor : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
        )
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
                Text(filter.rawValue)
                    .font(.subheadline)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(isActive ? .white.opacity(0.3) : filter.color.opacity(0.2))
                        )
                }
            }
            .foregroundStyle(isActive ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isActive ? filter.color : Color(.systemGray6))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Email List View

struct EmailListView: View {
    let sections: [EmailSection]
    let isLoading: Bool
    let isLoadingMore: Bool
    let hasMoreEmails: Bool
    let onTap: (Email) -> Void
    let onArchive: (Email) -> Void
    let onSnooze: (Email) -> Void
    let onToggleRead: (Email) -> Void
    let onStar: (Email) -> Void
    let onTrash: (Email) -> Void
    let onLoadMore: (Email) -> Void
    let onRefresh: () async -> Void

    var body: some View {
        List {
            ForEach(sections) { section in
                Section {
                    ForEach(section.emails) { email in
                        EmailRow(email: email)
                            .listRowBackground(Color(.systemBackground))
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    onArchive(email)
                                } label: {
                                    Label("Archive", systemImage: "archivebox")
                                }
                                .tint(.orange)

                                Button(role: .destructive) {
                                    onTrash(email)
                                } label: {
                                    Label("Trash", systemImage: "trash")
                                }
                                .tint(.red)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    onToggleRead(email)
                                } label: {
                                    Label(
                                        email.isUnread ? "Read" : "Unread",
                                        systemImage: email.isUnread ? "envelope.open" : "envelope.badge"
                                    )
                                }
                                .tint(.blue)

                                Button {
                                    onSnooze(email)
                                } label: {
                                    Label("Snooze", systemImage: "clock")
                                }
                                .tint(.purple)

                                Button {
                                    onStar(email)
                                } label: {
                                    Label(
                                        email.isStarred ? "Unstar" : "Star",
                                        systemImage: email.isStarred ? "star.slash" : "star.fill"
                                    )
                                }
                                .tint(.yellow)
                            }
                            .onTapGesture {
                                onTap(email)
                            }
                            .onAppear {
                                // Trigger pagination when approaching end
                                onLoadMore(email)
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

            // Loading more indicator
            if isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                        .padding()
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            // Load more button (fallback)
            if hasMoreEmails && !isLoadingMore {
                Button(action: {
                    if let lastEmail = sections.last?.emails.last {
                        onLoadMore(lastEmail)
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
        .refreshable {
            await onRefresh()
        }
        .overlay {
            if isLoading && sections.isEmpty {
                ProgressView("Loading emails...")
            }
        }
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

    var body: some View {
        HStack(spacing: 10) {
            // Avatar
            AvatarView(
                initials: email.senderInitials,
                email: email.senderEmail
            )
            .frame(width: 36, height: 36)

            // Content
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(email.senderName)
                        .font(.subheadline)
                        .fontWeight(email.isUnread ? .semibold : .regular)
                        .lineLimit(1)

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
                    .font(.caption)
                    .fontWeight(email.isUnread ? .medium : .regular)
                    .lineLimit(1)

                Text(email.snippet)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // Unread indicator
            if email.isUnread {
                Circle()
                    .fill(.blue)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Avatar View

struct AvatarView: View {
    let initials: String
    let email: String
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle()
                .fill(avatarColor)
            Text(initials)
                .font(size > 32 ? .caption : .system(size: size * 0.35))
                .fontWeight(.semibold)
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }

    private var avatarColor: Color {
        let hash = email.hashValue
        let colors: [Color] = [
            .blue, .green, .orange, .purple, .pink, .teal, .indigo, .cyan
        ]
        return colors[abs(hash) % colors.count]
    }
}

// MARK: - Mailbox Dropdown

struct MailboxDropdown: View {
    let currentMailbox: Mailbox
    let onSelect: (Mailbox) -> Void

    var body: some View {
        Menu {
            ForEach(Mailbox.allCases, id: \.self) { mailbox in
                Button(action: { onSelect(mailbox) }) {
                    Label(mailbox.rawValue, systemImage: mailbox.icon)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(currentMailbox.rawValue)
                    .font(.headline)
                Image(systemName: "chevron.down")
                    .font(.caption)
            }
        }
    }
}

enum Mailbox: String, CaseIterable {
    case inbox = "Inbox"
    case sent = "Sent"
    case archive = "Archive"
    case trash = "Trash"
    case drafts = "Drafts"
    case starred = "Starred"

    var icon: String {
        switch self {
        case .inbox: return "tray"
        case .sent: return "paperplane"
        case .archive: return "archivebox"
        case .trash: return "trash"
        case .drafts: return "doc"
        case .starred: return "star"
        }
    }
}

// MARK: - Floating Nav Pill

struct FloatingNavPill: View {
    let onSearch: () -> Void
    let onCompose: () -> Void

    var body: some View {
        HStack(spacing: 24) {
            Button(action: onSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
            }
            Button(action: onCompose) {
                Image(systemName: "square.and.pencil")
                    .font(.title3)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(
            Capsule()
                .fill(.black.opacity(0.8))
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
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

// MARK: - Preview

#Preview {
    InboxView()
}
