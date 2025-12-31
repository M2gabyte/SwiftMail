import SwiftUI
import WebKit

// MARK: - Email Detail View

struct EmailDetailView: View {
    let emailId: String
    let threadId: String

    @StateObject private var viewModel: EmailDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingReplySheet = false
    @State private var showingActionSheet = false
    @State private var showingSnoozeSheet = false

    init(emailId: String, threadId: String) {
        self.emailId = emailId
        self.threadId = threadId
        self._viewModel = StateObject(wrappedValue: EmailDetailViewModel(threadId: threadId))
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if viewModel.isLoading {
                    ProgressView()
                        .padding(40)
                } else {
                    ForEach(viewModel.messages) { message in
                        EmailMessageCard(
                            message: message,
                            isExpanded: viewModel.expandedMessageIds.contains(message.id),
                            onToggleExpand: { viewModel.toggleExpanded(message.id) }
                        )
                    }
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(viewModel.subject)
                        .font(.headline)
                        .lineLimit(1)
                    if viewModel.messages.count > 1 {
                        Text("\(viewModel.messages.count) messages")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(action: { showingActionSheet = true }) {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            EmailDetailFooter(
                onReply: { showingReplySheet = true },
                onReplyAll: { showingReplySheet = true },
                onForward: { },
                onArchive: {
                    Task {
                        await viewModel.archive()
                        dismiss()
                    }
                }
            )
        }
        .sheet(isPresented: $showingReplySheet) {
            if let latestMessage = viewModel.messages.last {
                ComposeView(
                    mode: .reply(to: latestMessage, threadId: threadId)
                )
            }
        }
        .sheet(isPresented: $showingSnoozeSheet) {
            SnoozePickerSheet(onSelect: { date in
                Task {
                    await viewModel.snooze(until: date)
                }
            })
        }
        .confirmationDialog("More Actions", isPresented: $showingActionSheet) {
            Button(viewModel.isStarred ? "Unstar" : "Star") {
                Task { await viewModel.toggleStar() }
            }
            Button(viewModel.isUnread ? "Mark as Read" : "Mark as Unread") {
                Task { await viewModel.toggleRead() }
            }
            Button("Snooze") {
                showingSnoozeSheet = true
            }
            Button("Move to Trash", role: .destructive) {
                Task {
                    await viewModel.trash()
                    dismiss()
                }
            }
        }
        .task {
            await viewModel.loadThread()
        }
    }
}

// MARK: - Email Message Card

struct EmailMessageCard: View {
    let message: EmailDetail
    let isExpanded: Bool
    let onToggleExpand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header - always visible
            Button(action: onToggleExpand) {
                HStack(spacing: 12) {
                    AvatarView(
                        initials: initials,
                        email: senderEmail
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(senderName)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Spacer()
                            Text(formatDate(message.date))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if isExpanded {
                            Text("to \(message.to.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Text(message.snippet)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding()
            }
            .buttonStyle(.plain)

            // Body - only when expanded
            if isExpanded {
                Divider()
                    .padding(.leading)

                EmailBodyView(html: message.body)
                    .frame(minHeight: 100)
            }
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    private var senderEmail: String {
        EmailParser.extractSenderEmail(from: message.from)
    }

    private var senderName: String {
        EmailParser.extractSenderName(from: message.from)
    }

    private var initials: String {
        let words = senderName.split(separator: " ")
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        return String(senderName.prefix(2)).uppercased()
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            formatter.timeStyle = .short
        } else {
            formatter.dateFormat = "MMM d, h:mm a"
        }
        return formatter.string(from: date)
    }
}

// MARK: - Email Body View (WebView)

struct EmailBodyView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.dataDetectorTypes = [.link, .phoneNumber, .address]

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.navigationDelegate = context.coordinator

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let styledHTML = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0">
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                    font-size: 16px;
                    line-height: 1.5;
                    color: #1a1a1a;
                    margin: 16px;
                    word-wrap: break-word;
                }
                @media (prefers-color-scheme: dark) {
                    body { color: #f0f0f0; }
                }
                img { max-width: 100%; height: auto; }
                a { color: #007AFF; }
                blockquote {
                    margin: 8px 0;
                    padding-left: 12px;
                    border-left: 3px solid #ccc;
                    color: #666;
                }
                pre, code {
                    background: #f5f5f5;
                    padding: 2px 6px;
                    border-radius: 4px;
                    font-size: 14px;
                }
                @media (prefers-color-scheme: dark) {
                    pre, code { background: #2a2a2a; }
                    blockquote { border-left-color: #555; color: #aaa; }
                }
            </style>
        </head>
        <body>
            \(html)
        </body>
        </html>
        """

        webView.loadHTMLString(styledHTML, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}

// MARK: - Email Detail Footer

struct EmailDetailFooter: View {
    let onReply: () -> Void
    let onReplyAll: () -> Void
    let onForward: () -> Void
    let onArchive: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            FooterButton(icon: "arrowshape.turn.up.left.fill", label: "Reply", action: onReply)
            FooterButton(icon: "arrowshape.turn.up.left.2.fill", label: "Reply All", action: onReplyAll)
            FooterButton(icon: "arrowshape.turn.up.right.fill", label: "Forward", action: onForward)
            FooterButton(icon: "archivebox.fill", label: "Archive", action: onArchive)
        }
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}

struct FooterButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                Text(label)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.blue)
    }
}

// MARK: - Email Detail ViewModel

@MainActor
class EmailDetailViewModel: ObservableObject {
    let threadId: String

    @Published var messages: [EmailDetail] = []
    @Published var expandedMessageIds: Set<String> = []
    @Published var isLoading = false
    @Published var error: Error?

    var subject: String {
        messages.first?.subject ?? ""
    }

    var isStarred: Bool {
        messages.last?.isStarred ?? false
    }

    var isUnread: Bool {
        messages.contains { $0.isUnread }
    }

    init(threadId: String) {
        self.threadId = threadId
    }

    func loadThread() async {
        isLoading = true
        defer { isLoading = false }

        do {
            messages = try await GmailService.shared.fetchThread(threadId: threadId)
            // Expand the latest message by default
            if let lastId = messages.last?.id {
                expandedMessageIds.insert(lastId)
            }
            // Mark as read
            for message in messages where message.isUnread {
                try? await GmailService.shared.markAsRead(messageId: message.id)
            }
        } catch {
            self.error = error
        }
    }

    func toggleExpanded(_ messageId: String) {
        if expandedMessageIds.contains(messageId) {
            expandedMessageIds.remove(messageId)
        } else {
            expandedMessageIds.insert(messageId)
        }
    }

    func archive() async {
        for message in messages {
            try? await GmailService.shared.archive(messageId: message.id)
        }
    }

    func trash() async {
        for message in messages {
            try? await GmailService.shared.trash(messageId: message.id)
        }
    }

    func toggleStar() async {
        guard let lastMessage = messages.last else { return }
        do {
            if lastMessage.isStarred {
                try await GmailService.shared.unstar(messageId: lastMessage.id)
            } else {
                try await GmailService.shared.star(messageId: lastMessage.id)
            }
            await loadThread()
        } catch {
            self.error = error
        }
    }

    func toggleRead() async {
        for message in messages {
            do {
                if message.isUnread {
                    try await GmailService.shared.markAsRead(messageId: message.id)
                } else {
                    try await GmailService.shared.markAsUnread(messageId: message.id)
                }
            } catch {
                self.error = error
            }
        }
        await loadThread()
    }

    func snooze(until date: Date) async {
        // TODO: Save to local snooze database
        // Archive the email
        await archive()
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        EmailDetailView(emailId: "1", threadId: "t1")
    }
}
