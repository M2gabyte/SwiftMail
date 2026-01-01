import SwiftUI
import OSLog

private let briefingLogger = Logger(subsystem: "com.simplemail.app", category: "Briefing")

// MARK: - Briefing Screen View

struct BriefingScreenView: View {
    @StateObject private var viewModel = BriefingViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Hero Header
                    BriefingHeroHeader(
                        unreadCount: viewModel.briefing.unreadCount,
                        needsReplyCount: viewModel.briefing.needsReplyCount
                    )

                    // Sections
                    LazyVStack(spacing: 24) {
                        ForEach(viewModel.briefing.sections) { section in
                            BriefingSectionCard(
                                section: section,
                                onItemTap: viewModel.openItem,
                                onViewAll: { viewModel.viewAllInSection(section) },
                                onBulkAction: { viewModel.performBulkAction(for: section) }
                            )
                        }
                    }
                    .padding()
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await viewModel.refresh()
            }
        }
    }
}

// MARK: - Briefing Hero Header

struct BriefingHeroHeader: View {
    let unreadCount: Int
    let needsReplyCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(greeting)
                .font(.title2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            Text(formattedDate)
                .font(.system(size: 32, weight: .bold, design: .serif))

            HStack(spacing: 16) {
                Label("\(unreadCount) unread", systemImage: "envelope.badge")
                Label("\(needsReplyCount) need reply", systemImage: "arrowshape.turn.up.left")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(
            LinearGradient(
                colors: gradientColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 0..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.string(from: Date())
    }

    private var gradientColors: [Color] {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<9:
            return [Color.orange.opacity(0.15), Color.yellow.opacity(0.1)]
        case 9..<17:
            return [Color.blue.opacity(0.1), Color.cyan.opacity(0.1)]
        case 17..<21:
            return [Color.orange.opacity(0.15), Color.pink.opacity(0.1)]
        default:
            return [Color.indigo.opacity(0.15), Color.purple.opacity(0.1)]
        }
    }
}

// MARK: - Briefing Section Card

struct BriefingSectionCard: View {
    let section: BriefingSection
    let onItemTap: (BriefingItem) -> Void
    let onViewAll: () -> Void
    let onBulkAction: () -> Void

    @State private var isCollapsed: Bool

    init(
        section: BriefingSection,
        onItemTap: @escaping (BriefingItem) -> Void,
        onViewAll: @escaping () -> Void,
        onBulkAction: @escaping () -> Void
    ) {
        self.section = section
        self.onItemTap = onItemTap
        self.onViewAll = onViewAll
        self.onBulkAction = onBulkAction
        // Maybe Reply section is collapsed by default
        self._isCollapsed = State(initialValue: section.sectionId == .maybeReply)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Button(action: { withAnimation { isCollapsed.toggle() } }) {
                    HStack(spacing: 8) {
                        Image(systemName: section.sectionId.icon)
                            .foregroundStyle(sectionColor)

                        Text(section.title)
                            .font(.headline)

                        if section.total > 0 {
                            Text("\(section.total)")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(sectionColor.opacity(0.15))
                                .clipShape(Capsule())
                        }

                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                // Bulk action for some sections
                if section.sectionId == .newsletters || section.sectionId == .moneyConfirmations {
                    Button("Archive all") {
                        onBulkAction()
                    }
                    .font(.subheadline)
                    .foregroundStyle(.blue)
                }
            }

            if !isCollapsed {
                // Items
                VStack(spacing: 0) {
                    ForEach(section.items) { item in
                        BriefingItemRow(item: item)
                            .onTapGesture { onItemTap(item) }

                        if item.id != section.items.last?.id {
                            Divider()
                                .padding(.leading, 52)
                        }
                    }
                }
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.05), radius: 4, y: 2)

                // View All link
                if section.total > section.items.count {
                    Button(action: onViewAll) {
                        HStack {
                            Text("View all \(section.total)")
                            Image(systemName: "chevron.right")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.blue)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 4)
                }
            }
        }
    }

    private var sectionColor: Color {
        switch section.sectionId {
        case .snoozedDue: return .purple
        case .needsReply: return .orange
        case .maybeReply: return .yellow
        case .deadlinesToday: return .red
        case .moneyConfirmations: return .green
        case .newsletters: return .blue
        case .everythingElse: return .gray
        }
    }
}

// MARK: - Briefing Item Row

struct BriefingItemRow: View {
    let item: BriefingItem

    var body: some View {
        HStack(spacing: 12) {
            SmartAvatarView(
                email: item.senderEmail,
                name: item.senderName,
                size: 40
            )

            // Content
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.senderName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    Spacer()

                    Text(formatTime(item.receivedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(item.subject)
                    .font(.subheadline)
                    .lineLimit(1)

                HStack {
                    Text(item.snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    // Reason badge
                    if !item.reasonTag.isEmpty {
                        Text(item.reasonTag)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(badgeColor.opacity(0.15))
                            .foregroundStyle(badgeColor)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(12)
        .contentShape(Rectangle())
    }

    private var badgeColor: Color {
        switch item.bucket {
        case .needsReply: return .orange
        case .maybeReply: return .yellow
        case .deadlinesToday: return .red
        case .moneyConfirmations: return .green
        case .snoozedDue: return .purple
        default: return .gray
        }
    }

    private func formatTime(_ date: Date) -> String {
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }

        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}

// MARK: - Briefing ViewModel

@MainActor
class BriefingViewModel: ObservableObject {
    @Published var briefing: Briefing = .empty
    @Published var isLoading = false

    private let engine = BriefingEngine()

    init() {
        Task {
            await loadBriefing()
        }
    }

    func refresh() async {
        await loadBriefing()
    }

    private func loadBriefing() async {
        isLoading = true
        defer { isLoading = false }

        // TODO: Fetch real emails from Gmail
        // For now, use mock data
        let mockEmails = createMockEmails()

        briefing = await engine.buildBriefing(
            emails: mockEmails,
            snoozedEmails: [],
            userEmail: "user@example.com"
        )
    }

    func openItem(_ item: BriefingItem) {
        briefingLogger.debug("Open item: \(item.subject)")
    }

    func viewAllInSection(_ section: BriefingSection) {
        briefingLogger.debug("View all in: \(section.title)")
    }

    func performBulkAction(for section: BriefingSection) {
        briefingLogger.debug("Bulk action for: \(section.title)")
    }

    private func createMockEmails() -> [Email] {
        let calendar = Calendar.current
        let now = Date()

        return [
            Email(
                id: "1", threadId: "t1",
                snippet: "Hey! Quick question - do you have time to chat about the project this week?",
                subject: "Quick question about the project",
                from: "Chelsea Hart <chelsea@gmail.com>",
                date: now, isUnread: true
            ),
            Email(
                id: "2", threadId: "t2",
                snippet: "Your order has shipped. Track your package.",
                subject: "Your Amazon order has shipped",
                from: "Amazon <ship-confirm@amazon.com>",
                date: calendar.date(byAdding: .hour, value: -2, to: now)!,
                isUnread: true, labelIds: ["CATEGORY_UPDATES"]
            ),
            Email(
                id: "3", threadId: "t3",
                snippet: "Reminder: The report is due tomorrow. Please submit by EOD.",
                subject: "Deadline: Report due tomorrow",
                from: "Mark Johnson <mark@company.com>",
                date: calendar.date(byAdding: .hour, value: -5, to: now)!,
                isUnread: true
            ),
            Email(
                id: "4", threadId: "t4",
                snippet: "50% off everything this weekend only!",
                subject: "Weekend Sale - 50% Off!",
                from: "Nordstrom <newsletter@nordstrom.com>",
                date: calendar.date(byAdding: .day, value: -1, to: now)!,
                isUnread: true, labelIds: ["CATEGORY_PROMOTIONS"]
            )
        ]
    }
}

// MARK: - Preview

#Preview {
    BriefingScreenView()
}
