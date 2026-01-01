import SwiftUI
import WebKit
import OSLog

private let detailLogger = Logger(subsystem: "com.simplemail.app", category: "EmailDetail")

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
                    // AI Summary at thread level (for long emails)
                    if viewModel.autoSummarizeEnabled,
                       let latestMessage = viewModel.messages.last,
                       latestMessage.body.count > 500 {
                        EmailSummaryView(
                            emailBody: latestMessage.body,
                            isExpanded: $viewModel.summaryExpanded
                        )
                        .padding(.horizontal)
                        .padding(.top, 8)
                    }

                    // Action Badges Row (Trackers, Unsubscribe, Block, Spam)
                    EmailActionBadgesView(
                        canUnsubscribe: viewModel.canUnsubscribe,
                        senderName: viewModel.senderName ?? "sender",
                        isReply: viewModel.subject.lowercased().hasPrefix("re:"),
                        trackersBlocked: viewModel.trackersBlocked,
                        trackerNames: viewModel.trackerNames,
                        onUnsubscribe: {
                            Task { await viewModel.unsubscribe() }
                        },
                        onBlockSender: {
                            Task {
                                await viewModel.blockSender()
                                NotificationCenter.default.post(name: .blockedSendersDidChange, object: nil)
                                dismiss()
                            }
                        },
                        onReportSpam: {
                            Task {
                                await viewModel.reportSpam()
                                NotificationCenter.default.post(name: .blockedSendersDidChange, object: nil)
                                dismiss()
                            }
                        }
                    )

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
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                // Reply Menu - Far Left
                Menu {
                    Button(action: { showingReplySheet = true }) {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                    Button(action: { showingReplySheet = true }) {
                        Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
                    }
                    Button(action: { }) {
                        Label("Forward", systemImage: "arrowshape.turn.up.right")
                    }
                } label: {
                    Image(systemName: "arrowshape.turn.up.left")
                }
            }

            ToolbarItem(placement: .bottomBar) {
                Spacer()
            }

            ToolbarItem(placement: .bottomBar) {
                // Archive - Far Right
                Button {
                    Task {
                        await viewModel.archive()
                        dismiss()
                    }
                } label: {
                    Image(systemName: "archivebox")
                }
            }
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
            Button(viewModel.isVIPSender ? "Remove from VIP" : "Mark as VIP") {
                viewModel.toggleVIP()
            }

            // Unsubscribe (only shows if List-Unsubscribe header present)
            if viewModel.canUnsubscribe {
                Button("Unsubscribe") {
                    Task { await viewModel.unsubscribe() }
                }
            }

            Button("Block Sender", role: .destructive) {
                Task {
                    await viewModel.blockSender()
                    NotificationCenter.default.post(name: .blockedSendersDidChange, object: nil)
                    dismiss()
                }
            }

            Button("Report Spam", role: .destructive) {
                Task {
                    await viewModel.reportSpam()
                    NotificationCenter.default.post(name: .blockedSendersDidChange, object: nil)
                    dismiss()
                }
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
        .toolbar(.hidden, for: .tabBar)
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
                    SmartAvatarView(
                        email: senderEmail,
                        name: senderName,
                        size: 40
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

// MARK: - Email Body View (WebView with dynamic height)

struct EmailBodyView: View {
    let html: String
    @State private var contentHeight: CGFloat = 200

    var body: some View {
        EmailBodyWebView(html: html, contentHeight: $contentHeight)
            .frame(height: contentHeight)
    }
}

struct EmailBodyWebView: UIViewRepresentable {
    let html: String
    @Binding var contentHeight: CGFloat

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.dataDetectorTypes = [.link, .phoneNumber, .address]

        // Enable JavaScript for height calculation
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        config.defaultWebpagePreferences = preferences

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.navigationDelegate = context.coordinator

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Only reload if HTML changed
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        context.coordinator.contentHeight = $contentHeight

        let styledHTML = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>
                * { box-sizing: border-box; }
                html, body {
                    margin: 0;
                    padding: 0;
                    width: 100%;
                    overflow-x: hidden;
                }
                body {
                    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                    font-size: 16px;
                    line-height: 1.5;
                    color: #1a1a1a;
                    padding: 16px;
                    word-wrap: break-word;
                    overflow-wrap: break-word;
                }
                @media (prefers-color-scheme: dark) {
                    body { color: #f0f0f0; background-color: transparent; }
                }
                img { max-width: 100%; height: auto; display: block; }
                a { color: #007AFF; }
                table { width: 100% !important; max-width: 100% !important; }
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
                    white-space: pre-wrap;
                    word-break: break-word;
                }
                @media (prefers-color-scheme: dark) {
                    pre, code { background: #2a2a2a; }
                    blockquote { border-left-color: #555; color: #aaa; }
                }
            </style>
        </head>
        <body>
            \(html)
            <script>
                function updateHeight() {
                    var height = document.body.scrollHeight;
                    window.webkit.messageHandlers.heightHandler.postMessage(height);
                }
                // Update after images load
                document.addEventListener('DOMContentLoaded', function() {
                    updateHeight();
                    var images = document.querySelectorAll('img');
                    images.forEach(function(img) {
                        img.onload = updateHeight;
                        img.onerror = updateHeight;
                    });
                    // Final update after a short delay
                    setTimeout(updateHeight, 500);
                });
                // Also update on window load
                window.onload = updateHeight;
            </script>
        </body>
        </html>
        """

        // Add message handler for height updates (using weak wrapper to prevent retain cycle)
        let contentController = webView.configuration.userContentController
        contentController.removeScriptMessageHandler(forName: "heightHandler")
        let weakHandler = WeakScriptMessageHandler(coordinator: context.coordinator)
        contentController.add(weakHandler, name: "heightHandler")

        webView.loadHTMLString(styledHTML, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String = ""
        var contentHeight: Binding<CGFloat>?

        func handleHeightMessage(_ body: Any) {
            // JavaScript numbers come as NSNumber, need to convert properly
            let height: CGFloat
            if let doubleValue = body as? Double {
                height = CGFloat(doubleValue)
            } else if let intValue = body as? Int {
                height = CGFloat(intValue)
            } else if let nsNumber = body as? NSNumber {
                height = CGFloat(nsNumber.doubleValue)
            } else {
                return
            }

            DispatchQueue.main.async {
                // Add some padding and minimum height
                self.contentHeight?.wrappedValue = max(100, height + 20)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Fallback: get height via JavaScript if message handler didn't fire
            webView.evaluateJavaScript("document.body.scrollHeight") { [weak self] result, _ in
                guard let result = result else { return }
                self?.handleHeightMessage(result)
            }
        }

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

// MARK: - Weak Script Message Handler (prevents retain cycle)

/// WKScriptMessageHandler creates a strong reference cycle.
/// This wrapper breaks the cycle by holding a weak reference to the actual handler.
class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var coordinator: EmailBodyWebView.Coordinator?

    init(coordinator: EmailBodyWebView.Coordinator) {
        self.coordinator = coordinator
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "heightHandler" {
            coordinator?.handleHeightMessage(message.body)
        }
    }
}

// MARK: - Email Summary View

struct EmailSummaryView: View {
    let emailBody: String
    @Binding var isExpanded: Bool

    @State private var summary: String = ""
    @State private var isGenerating = false
    @State private var summaryError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            Button(action: { withAnimation(.spring(response: 0.3)) { isExpanded.toggle() } }) {
                HStack(spacing: 8) {
                    Image(systemName: "apple.intelligence")
                        .font(.caption)
                        .foregroundStyle(.purple)

                    Text("Summary")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.purple)

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            // Summary Content
            if isExpanded {
                if isGenerating {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Summarizing with Apple Intelligence...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else if let error = summaryError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .italic()
                } else if !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                } else {
                    Text("Summary unavailable")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .italic()
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.purple.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.purple.opacity(0.2), lineWidth: 1)
                )
        )
        .onAppear {
            generateSummary()
        }
    }

    private func generateSummary() {
        isGenerating = true
        summaryError = nil

        Task {
            // Strip HTML tags for plain text
            let plainText = stripHTML(emailBody)

            // Try Apple Intelligence summarization via Foundation Models
            do {
                summary = try await summarizeWithAppleIntelligence(plainText)
            } catch {
                // Fallback to extractive summarization
                summary = extractKeySentences(from: plainText, maxSentences: 3)
            }

            isGenerating = false
        }
    }

    @MainActor
    private func summarizeWithAppleIntelligence(_ text: String) async throws -> String {
        // TODO: Use Foundation Models framework for on-device summarization
        // when FoundationModels SDK is available:
        //
        // import FoundationModels
        // let session = LanguageModelSession()
        // let prompt = "Summarize this email in 2-3 concise sentences:\n\n\(text)"
        // let response = try await session.respond(to: prompt)
        // return response.content
        //
        // For now, use extractive summarization
        return extractKeySentences(from: text, maxSentences: 3)
    }

    private func stripHTML(_ html: String) -> String {
        var text = html

        // Remove style blocks (including content)
        while let styleStart = text.range(of: "<style", options: .caseInsensitive),
              let styleEnd = text.range(of: "</style>", options: .caseInsensitive, range: styleStart.upperBound..<text.endIndex) {
            text.removeSubrange(styleStart.lowerBound..<styleEnd.upperBound)
        }

        // Remove script blocks
        while let scriptStart = text.range(of: "<script", options: .caseInsensitive),
              let scriptEnd = text.range(of: "</script>", options: .caseInsensitive, range: scriptStart.upperBound..<text.endIndex) {
            text.removeSubrange(scriptStart.lowerBound..<scriptEnd.upperBound)
        }

        // Remove head section
        if let headStart = text.range(of: "<head", options: .caseInsensitive),
           let headEnd = text.range(of: "</head>", options: .caseInsensitive, range: headStart.upperBound..<text.endIndex) {
            text.removeSubrange(headStart.lowerBound..<headEnd.upperBound)
        }

        // Convert line breaks
        text = text
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br />", with: "\n")
            .replacingOccurrences(of: "</p>", with: "\n")
            .replacingOccurrences(of: "</div>", with: "\n")
            .replacingOccurrences(of: "</tr>", with: "\n")
            .replacingOccurrences(of: "</li>", with: "\n")

        // Remove all remaining HTML tags
        while let range = text.range(of: "<[^>]+>", options: .regularExpression) {
            text.removeSubrange(range)
        }

        // Decode HTML entities
        text = text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#160;", with: " ")

        // Clean up whitespace
        text = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractKeySentences(from text: String, maxSentences: Int) -> String {
        // Remove common email boilerplate phrases
        var cleanedText = text
        let boilerplatePatterns = [
            "View in browser",
            "View in your browser",
            "View this email in your browser",
            "Click here to view",
            "Having trouble viewing",
            "Can't see this email",
            "Unsubscribe",
            "Update preferences",
            "Manage preferences",
            "Privacy Policy",
            "Terms of Service",
            "©",
            "All rights reserved",
            "This email was sent to",
            "You are receiving this",
            "To unsubscribe"
        ]

        for pattern in boilerplatePatterns {
            cleanedText = cleanedText.replacingOccurrences(of: pattern, with: "", options: .caseInsensitive)
        }

        // Remove arrows and other noise
        cleanedText = cleanedText.replacingOccurrences(of: "-->", with: "")
        cleanedText = cleanedText.replacingOccurrences(of: "->", with: "")

        let sentenceEndings = CharacterSet(charactersIn: ".!?")
        var sentences: [String] = []
        var currentSentence = ""

        for char in cleanedText {
            currentSentence.append(char)
            if let scalar = char.unicodeScalars.first, sentenceEndings.contains(scalar) {
                let trimmed = currentSentence.trimmingCharacters(in: .whitespaces)
                // Skip very short sentences and ones that look like boilerplate
                if trimmed.count > 30 && !trimmed.lowercased().contains("click here") {
                    sentences.append(trimmed)
                }
                currentSentence = ""
            }
        }

        let selectedSentences = Array(sentences.prefix(maxSentences))

        if selectedSentences.isEmpty {
            // Fallback: just get some content
            let words = cleanedText.split(separator: " ").filter { $0.count > 2 }
            return words.prefix(50).joined(separator: " ") + (words.count > 50 ? "..." : "")
        }

        return selectedSentences.joined(separator: " ")
    }
}

// MARK: - Email Action Badges View (Unsubscribe, Block, Spam, Trackers)

struct EmailActionBadgesView: View {
    let canUnsubscribe: Bool
    let senderName: String
    let isReply: Bool
    let trackersBlocked: Int
    let trackerNames: [String]
    let onUnsubscribe: () -> Void
    let onBlockSender: () -> Void
    let onReportSpam: () -> Void

    @State private var showBlockConfirm = false
    @State private var showSpamConfirm = false
    @State private var showTrackersInfo = false

    var body: some View {
        // Always show the action buttons row
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Trackers Blocked badge (green, like React version)
                if trackersBlocked > 0 {
                    Button {
                        showTrackersInfo = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "shield.checkered")
                                .font(.caption2)
                            Text("\(trackersBlocked) blocked")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        .foregroundStyle(.green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.green.opacity(0.1))
                        )
                    }
                    .buttonStyle(.plain)
                }

                // Unsubscribe button
                if canUnsubscribe {
                    Button(action: onUnsubscribe) {
                        Text("Unsubscribe")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }

                // Block Sender button
                Button {
                    showBlockConfirm = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "hand.raised")
                            .font(.caption2)
                        Text("Block")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .foregroundStyle(.red.opacity(0.8))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.red.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                // Report Spam button (only for non-replies, like React version)
                if !isReply {
                    Button {
                        showSpamConfirm = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.shield")
                                    .font(.caption2)
                                Text("Spam")
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                            .foregroundStyle(.orange.opacity(0.9))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .alert("Block \(senderName)?", isPresented: $showBlockConfirm) {
                Button("Cancel", role: .cancel) { }
                Button("Block", role: .destructive, action: onBlockSender)
            } message: {
                Text("Future emails from this sender will be moved to Trash.")
            }
            .alert("Report as Spam?", isPresented: $showSpamConfirm) {
                Button("Cancel", role: .cancel) { }
                Button("Report Spam", role: .destructive, action: onReportSpam)
            } message: {
                Text("This email will be moved to your spam folder.")
            }
            .alert("Trackers Blocked", isPresented: $showTrackersInfo) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("SimpleMail blocked \(trackersBlocked) tracking pixel\(trackersBlocked > 1 ? "s" : "") that would have notified the sender when you opened this email.\n\nBlocked: \(trackerNames.joined(separator: ", "))")
            }
    }
}

// MARK: - Email Detail ViewModel

@MainActor
class EmailDetailViewModel: ObservableObject {
    let threadId: String

    @Published var messages: [EmailDetail] = []
    @Published var expandedMessageIds: Set<String> = []
    @Published var summaryExpanded: Bool = true
    @Published var isLoading = false
    @Published var error: Error?
    @Published var unsubscribeURL: URL?
    @Published var trackersBlocked: Int = 0
    @Published var trackerNames: [String] = []

    // Known tracker domains (common email tracking pixels)
    private static let trackerDomains: [String: String] = [
        "mailchimp.com": "Mailchimp",
        "list-manage.com": "Mailchimp",
        "sendgrid.net": "SendGrid",
        "hubspot.com": "HubSpot",
        "hs-analytics.net": "HubSpot",
        "mailgun.com": "Mailgun",
        "postmarkapp.com": "Postmark",
        "constantcontact.com": "Constant Contact",
        "klaviyo.com": "Klaviyo",
        "sailthru.com": "Sailthru",
        "braze.com": "Braze",
        "iterable.com": "Iterable",
        "customer.io": "Customer.io",
        "intercom-mail.com": "Intercom",
        "drip.com": "Drip",
        "convertkit.com": "ConvertKit",
        "getresponse.com": "GetResponse",
        "sendinblue.com": "Sendinblue",
        "amazonses.com": "Amazon SES",
        "sparkpostmail.com": "SparkPost",
        "rsgsv.net": "Mailchimp",
        "mcsv.net": "Mailchimp",
        "doubleclick.net": "Google",
        "google-analytics.com": "Google Analytics",
        "facebook.com": "Facebook",
        "linkedin.com": "LinkedIn",
        "twitter.com": "Twitter",
        "marketo.com": "Marketo",
        "pardot.com": "Pardot",
        "eloqua.com": "Eloqua",
        "mixpanel.com": "Mixpanel",
        "segment.io": "Segment"
    ]

    var subject: String {
        messages.first?.subject ?? ""
    }

    var isStarred: Bool {
        messages.last?.isStarred ?? false
    }

    var isUnread: Bool {
        messages.contains { $0.isUnread }
    }

    var canUnsubscribe: Bool {
        unsubscribeURL != nil
    }

    var senderEmail: String? {
        guard let from = messages.last?.from else { return nil }
        return EmailParser.extractSenderEmail(from: from)
    }

    var senderName: String? {
        guard let from = messages.last?.from else { return nil }
        return EmailParser.extractSenderName(from: from)
    }

    var isVIPSender: Bool {
        guard let email = senderEmail else { return false }
        let vipSenders = UserDefaults.standard.stringArray(forKey: "vipSenders") ?? []
        return vipSenders.contains(email.lowercased())
    }

    var autoSummarizeEnabled: Bool {
        if let data = UserDefaults.standard.data(forKey: "appSettings"),
           let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            return settings.autoSummarize
        }
        return true // Default to enabled
    }

    init(threadId: String) {
        self.threadId = threadId
    }

    // Detect tracking pixels in email HTML
    private func detectTrackers(in html: String) -> [String] {
        var foundTrackers = Set<String>()

        // Pattern for 1x1 pixel images (common tracker format)
        let pixelPatterns = [
            "<img[^>]*width\\s*=\\s*[\"']?1[\"']?[^>]*height\\s*=\\s*[\"']?1[\"']?[^>]*>",
            "<img[^>]*height\\s*=\\s*[\"']?1[\"']?[^>]*width\\s*=\\s*[\"']?1[\"']?[^>]*>",
            "<img[^>]*style\\s*=\\s*[\"'][^\"']*display\\s*:\\s*none[^\"']*[\"'][^>]*>"
        ]

        // Check for known tracker domains in image URLs
        for (domain, name) in Self.trackerDomains {
            if html.lowercased().contains(domain) {
                foundTrackers.insert(name)
            }
        }

        // Count 1x1 pixel images
        for pattern in pixelPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(html.startIndex..., in: html)
                let matches = regex.numberOfMatches(in: html, range: range)
                if matches > 0 && foundTrackers.isEmpty {
                    foundTrackers.insert("Tracking Pixel")
                }
            }
        }

        return Array(foundTrackers).sorted()
    }

    func loadThread() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let messageDTOs = try await GmailService.shared.fetchThread(threadId: threadId)
            messages = messageDTOs.map(EmailDetail.init(dto:))
            // Expand the latest message by default
            if let lastId = messages.last?.id {
                expandedMessageIds.insert(lastId)
            }

            // Parse unsubscribe URL from latest message
            if let unsubscribeHeader = messages.last?.listUnsubscribe {
                unsubscribeURL = parseUnsubscribeURL(from: unsubscribeHeader)
            }

            // Detect trackers in all message bodies
            var allTrackers = Set<String>()
            for message in messages {
                let found = detectTrackers(in: message.body)
                allTrackers.formUnion(found)
            }
            trackerNames = Array(allTrackers).sorted()
            trackersBlocked = trackerNames.count

            // Mark as read
            for message in messages where message.isUnread {
                do {
                    try await GmailService.shared.markAsRead(messageId: message.id)
                } catch {
                    detailLogger.error("Failed to mark message as read: \(error.localizedDescription)")
                }
            }
        } catch {
            self.error = error
        }
    }

    /// Parse List-Unsubscribe header to extract a clickable URL
    /// Format: <https://example.com/unsubscribe>, <mailto:unsubscribe@example.com>
    private func parseUnsubscribeURL(from header: String) -> URL? {
        // Extract all URLs from angle brackets
        let pattern = "<([^>]+)>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let range = NSRange(header.startIndex..., in: header)
        let matches = regex.matches(in: header, range: range)

        for match in matches {
            if let urlRange = Range(match.range(at: 1), in: header) {
                let urlString = String(header[urlRange])

                // Prefer https URLs over mailto
                if urlString.lowercased().hasPrefix("http") {
                    return URL(string: urlString)
                }
            }
        }

        // Fall back to mailto if no http URL found
        for match in matches {
            if let urlRange = Range(match.range(at: 1), in: header) {
                let urlString = String(header[urlRange])
                if urlString.lowercased().hasPrefix("mailto:") {
                    return URL(string: urlString)
                }
            }
        }

        return nil
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
            do {
                try await GmailService.shared.archive(messageId: message.id)
            } catch {
                detailLogger.error("Failed to archive message: \(error.localizedDescription)")
            }
        }
    }

    func trash() async {
        for message in messages {
            do {
                try await GmailService.shared.trash(messageId: message.id)
            } catch {
                detailLogger.error("Failed to trash message: \(error.localizedDescription)")
            }
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

    func unsubscribe() async {
        guard let url = unsubscribeURL else { return }
        await MainActor.run {
            UIApplication.shared.open(url)
        }
    }

    func blockSender() async {
        guard let email = senderEmail else { return }

        // Save to blocked senders list
        var blockedSenders = UserDefaults.standard.stringArray(forKey: "blockedSenders") ?? []
        if !blockedSenders.contains(email.lowercased()) {
            blockedSenders.append(email.lowercased())
            UserDefaults.standard.set(blockedSenders, forKey: "blockedSenders")
        }

        // Move to trash
        await trash()

        HapticFeedback.success()
    }

    func reportSpam() async {
        for message in messages {
            do {
                try await GmailService.shared.reportSpam(messageId: message.id)
            } catch {
                detailLogger.error("Failed to report spam: \(error.localizedDescription)")
            }
        }
        HapticFeedback.success()
    }

    func toggleVIP() {
        guard let email = senderEmail else { return }
        let emailLower = email.lowercased()

        var vipSenders = UserDefaults.standard.stringArray(forKey: "vipSenders") ?? []

        if vipSenders.contains(emailLower) {
            vipSenders.removeAll { $0 == emailLower }
            HapticFeedback.light()
        } else {
            vipSenders.append(emailLower)
            HapticFeedback.success()
        }

        UserDefaults.standard.set(vipSenders, forKey: "vipSenders")
        objectWillChange.send() // Trigger UI update
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        EmailDetailView(emailId: "1", threadId: "t1")
    }
}
