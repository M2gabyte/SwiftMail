import SwiftUI

struct BriefingView: View {
    @StateObject var viewModel: BriefingViewModel
    let onOpenEmail: (Email) -> Void

    @State private var snoozeTarget: BriefingItem?
    @State private var showingSnooze = false

    private var hits: [String: BriefingThreadHit] {
        viewModel.hitMap()
    }

    var body: some View {
        List {
            BriefingHeader(
                scopeDays: viewModel.scopeDays,
                isRefreshing: viewModel.isRefreshing,
                lastUpdated: viewModel.lastUpdated,
                onScopeChange: { viewModel.setScopeDays($0) }
            )
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if viewModel.snapshot != nil, !viewModel.totalVisibleItems(hits: hits).isEmpty {
                ForEach(viewModel.sectionedItems(hits: hits), id: \.0) { section, items in
                    Section {
                        ForEach(items) { item in
                            BriefingItemRow(
                                item: item,
                                    hit: hits[item.sourceThreadId],
                                    dueLabel: dueLabel(for: item),
                                    onOpen: { openItem(item) },
                                    onSnooze: { snooze(item) },
                                    onDone: { viewModel.markDone(item) },
                                    onMuteThread: { viewModel.muteThread(item) },
                                    onMuteSender: { sender in viewModel.muteSender(sender) }
                                )
                        }
                    } header: {
                        Text(section.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                    }
                }

                if viewModel.shouldShowShowMore(hits: hits) {
                    Button("Show more") {
                        viewModel.showMore()
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowSeparator(.hidden)
                }
            } else if let snapshot = viewModel.snapshot {
                BriefingEmptyState(
                    scopeDays: viewModel.scopeDays,
                    sourceCount: snapshot.sources.count,
                    note: snapshot.generationNote,
                    onSwitchScope: { viewModel.setScopeDays($0) }
                )
                .listRowSeparator(.hidden)
            } else {
                ProgressView("Building briefing…")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .refreshable {
            await viewModel.refresh()
        }
        .onAppear {
            viewModel.loadCached()
            Task { await viewModel.refresh() }
        }
        .sheet(isPresented: $showingSnooze) {
            SnoozePickerSheet { date in
                if let target = snoozeTarget {
                    viewModel.snooze(target, until: date)
                }
                snoozeTarget = nil
            }
        }
    }

    private func openItem(_ item: BriefingItem) {
        guard let messageId = item.sourceMessageIds.first else { return }
        let emails = EmailCacheManager.shared.loadCachedEmails(by: [messageId], accountEmail: viewModel.accountEmail)
        if let email = emails.first {
            onOpenEmail(email)
        }
    }

    private func snooze(_ item: BriefingItem) {
        snoozeTarget = item
        showingSnooze = true
    }

    private func dueLabel(for item: BriefingItem) -> String? {
        guard let dueAt = item.dueAt,
              let date = ISO8601DateFormatter().date(from: dueAt) else {
            return nil
        }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        }
        if calendar.isDateInTomorrow(date) {
            return "Tomorrow"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}

private struct BriefingHeader: View {
    let scopeDays: Int
    let isRefreshing: Bool
    let lastUpdated: Date?
    let onScopeChange: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Briefing (Beta)")
                    .font(.title3.weight(.semibold))
                Spacer()
                if isRefreshing {
                    ProgressView()
                }
            }

            HStack(spacing: 12) {
                Text("Inbox")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color(.secondarySystemBackground))
                    )
                Picker("Range", selection: Binding(
                    get: { scopeDays },
                    set: { onScopeChange($0) }
                )) {
                    Text("14d").tag(14)
                    Text("30d").tag(30)
                }
                .pickerStyle(.segmented)

                if let lastUpdated {
                    Text("Updated \(relativeTime(from: lastUpdated))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let debug = viewModel.snapshot?.debugInfo {
                Text("Debug: candidates \(debug.candidateCount) · shortlist \(debug.shortlistCount) · AI \(debug.aiItemCount) · kept \(debug.keptItemCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func relativeTime(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct BriefingItemRow: View {
    let item: BriefingItem
    let hit: BriefingThreadHit?
    let dueLabel: String?
    let onOpen: () -> Void
    let onSnooze: () -> Void
    let onDone: () -> Void
    let onMuteThread: () -> Void
    let onMuteSender: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)

            Text(item.whyQuote)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 8) {
                if let dueLabel {
                    BriefingChip(text: dueLabel, color: .orange)
                }
                if let hit {
                    BriefingChip(text: chipText(for: hit), color: .blue)
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
        .contextMenu {
            Button("Open") { onOpen() }
            Button("Snooze") { onSnooze() }
            Button("Done") { onDone() }
            Button("Mute thread") { onMuteThread() }
            if let hit {
                Button("Mute sender") { onMuteSender(EmailParser.extractSenderEmail(from: hit.from)) }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("Done") { onDone() }
                .tint(.green)
            Button("Snooze") { onSnooze() }
                .tint(.orange)
        }
    }

    private func chipText(for hit: BriefingThreadHit) -> String {
        let sender = EmailParser.extractSenderName(from: hit.from)
        let subject = hit.subject.isEmpty ? "No subject" : hit.subject
        let date = ISO8601DateFormatter().date(from: hit.dateISO) ?? Date()
        let time = timeLabel(for: date)
        return "\(sender) · \(subject) · \(time)"
    }

    private func timeLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}

private struct BriefingChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(color.opacity(0.12))
            )
    }
}

private struct BriefingEmptyState: View {
    let scopeDays: Int
    let sourceCount: Int
    let note: String?
    let onSwitchScope: (Int) -> Void

    var body: some View {
        VStack(spacing: 8) {
            if sourceCount == 0 {
                Text("No cached emails found")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("Open your inbox once to sync, then come back.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Nothing urgent found in last \(scopeDays) days")
                    .font(.headline)
                    .foregroundStyle(.primary)
                if let note {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button("Try 30 days") {
                    onSwitchScope(30)
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 24)
    }
}
