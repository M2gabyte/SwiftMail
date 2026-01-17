import SwiftUI
import WebKit
import OSLog
#if canImport(FoundationModels)
import FoundationModels
#endif

#if DEBUG
struct StallLogger {
    private static let start = Date()
    private static let logger = Logger(subsystem: "com.simplemail.app", category: "Stall")
    static func mark(_ label: String) {
        let delta = Date().timeIntervalSince(start)
        logger.info("STALL \(label, privacy: .public) t=\(delta, format: .fixed(precision: 3))s")
    }
}
#else
struct StallLogger { static func mark(_ label: String) { } }
#endif

// MARK: - Shared WebView Pool (local to this file to avoid target config issues)
final class WKWebViewPool {
    static let shared = WKWebViewPool()
    private var pool: [WKWebView] = []
    private let maxSize = 3
    private let lock = NSLock()

    private init() {}

    func dequeue() -> WKWebView {
        lock.lock(); defer { lock.unlock() }
        if let webView = pool.popLast() {
            reset(webView)
            return webView
        }
        return makeWebView()
    }

    func recycle(_ webView: WKWebView) {
        lock.lock(); defer { lock.unlock() }
        reset(webView)
        if pool.count < maxSize {
            pool.append(webView)
        }
    }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.dataDetectorTypes = [.link, .phoneNumber, .address]
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = false
        config.defaultWebpagePreferences = preferences
        let controller = WKUserContentController()
        config.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        return webView
    }

    private func reset(_ webView: WKWebView) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.scrollView.setContentOffset(.zero, animated: false)
        // Don't loadHTMLString here - unnecessary navigation that adds churn.
        // Real content will be loaded when the email body is set.
    }
}

// Background renderer for HTML/plaintext - runs sanitization off main thread
actor BodyRenderActor {
    struct RenderSettings: Hashable, Sendable {
        let blockImages: Bool
        let blockTrackingPixels: Bool
        let stripTrackingParameters: Bool
    }

    struct RenderedBody: Sendable {
        let html: String          // Sanitized HTML (for fallback/caching)
        let plain: String         // Plain text version
        let styledHTML: String    // Complete styled HTML ready for WebView
    }

    func render(html: String, settings: RenderSettings) async -> RenderedBody {
        // SECURITY: Sanitize HTML to prevent XSS attacks (done here, off main thread)
        var safeHTML = HTMLSanitizer.sanitize(html)
        // Remove zero-width characters that create empty space in marketing emails
        safeHTML = HTMLSanitizer.removeZeroWidthCharacters(safeHTML)
        safeHTML = HTMLSanitizer.stripTinyImages(safeHTML)
        let plain = HTMLSanitizer.plainText(safeHTML)

        // Apply conditional transformations based on settings
        var processedHTML = safeHTML
        processedHTML = HTMLSanitizer.addLazyLoading(processedHTML)
        if settings.blockImages {
            processedHTML = HTMLSanitizer.blockImages(processedHTML)
        }
        if settings.stripTrackingParameters {
            processedHTML = HTMLSanitizer.stripTrackingParameters(processedHTML)
        }

        // Build the complete styled HTML (this avoids doing it on main thread)
        let trackingCSS = settings.blockTrackingPixels ? """
                /* Hide tracking pixels and tiny spacer images */
                img[width="1"], img[height="1"],
                img[width="0"], img[height="0"],
                img[style*="display:none"], img[style*="display: none"] {
                    display: none !important;
                }
        """ : ""

        let styledHTML = Self.buildStyledHTML(
            body: processedHTML,
            trackingCSS: trackingCSS,
            allowRemoteImages: !settings.blockImages
        )
        return RenderedBody(html: safeHTML, plain: plain, styledHTML: styledHTML)
    }

    /// Build the complete styled HTML document. All string work done off-main.
    /// No JavaScript is injected - height is measured natively via scrollView.contentSize.
    private static func buildStyledHTML(body: String, trackingCSS: String, allowRemoteImages: Bool) -> String {
        let csp = allowRemoteImages
            ? "default-src 'none'; img-src data: https:; style-src 'unsafe-inline'; font-src data: https:;"
            : "default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:;"

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <meta http-equiv="Content-Security-Policy" content="\(csp)">
            <style>
                /* Base layout constraints - don't override email styling */
                * { box-sizing: border-box; }
                html, body {
                    margin: 0;
                    padding: 0;
                    width: 100%;
                    max-width: 100%;
                    overflow-x: hidden;
                }
                body { word-wrap: break-word; overflow-wrap: break-word; background: transparent; color: inherit; }
                img { max-width: 100% !important; height: auto !important; }
                video, iframe, canvas { max-width: 100% !important; height: auto !important; }
                td, th { word-break: break-word; }
                a { color: inherit; }
                \(trackingCSS)
                img[data-blocked-src] {
                    display: none !important;
                    width: 0 !important;
                    height: 0 !important;
                }
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
                .blocked-form { border: 1px dashed #ccc; padding: 8px; margin: 8px 0; }
            </style>
        </head>
        <body>\(body)</body>
        </html>
        """
    }
}

private let detailLogger = Logger(subsystem: "com.simplemail.app", category: "EmailDetail")

// MARK: - Email Detail View

struct EmailDetailView: View {
    let emailId: String
    let threadId: String
    let accountEmail: String?

    @StateObject private var viewModel: EmailDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingReplySheet = false
    @State private var showingActionSheet = false
    @State private var showingSnoozeSheet = false
    @State private var bottomBarHeight: CGFloat = 0
    @State private var safeAreaBottom: CGFloat = 0
    @State private var pendingChipAction: PendingChipAction?

    init(emailId: String, threadId: String, accountEmail: String? = nil) {
        self.emailId = emailId
        self.threadId = threadId
        self.accountEmail = accountEmail
        self._viewModel = StateObject(wrappedValue: EmailDetailViewModel(threadId: threadId, accountEmail: accountEmail))
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if viewModel.isLoading {
                    ProgressView()
                        .padding(40)
                } else if let error = viewModel.error {
                    ContentUnavailableView {
                        Label("Failed to Load", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error.localizedDescription)
                    }
                    .padding(40)
                } else {
                    // AI Summary at thread level (for long emails)
                    // Check plain text length using full body, not the snippet placeholder
                    if viewModel.autoSummarizeEnabled,
                       let latestMessage = viewModel.messages.last,
                       let fullBody = viewModel.latestMessageFullBody,
                       EmailTextHelper.plainTextLength(fullBody) > 300 {
                        EmailSummaryView(
                            emailId: latestMessage.id,
                            accountEmail: latestMessage.accountEmail,
                            emailBody: fullBody,
                            isExpanded: $viewModel.summaryExpanded
                        )
                        .padding(.horizontal)
                        .padding(.top, 8)
                    }

                    // Action Chips Row (Trackers, Unsubscribe, Block, Spam)
                    EmailActionChipsView(
                        canUnsubscribe: viewModel.canUnsubscribe,
                        senderName: viewModel.senderName ?? "sender",
                        isReply: viewModel.subject.lowercased().hasPrefix("re:"),
                        trackersBlocked: viewModel.trackersBlocked,
                        pendingAction: $pendingChipAction
                    )

                    ForEach(Array(viewModel.messages.enumerated()), id: \.element.id) { index, message in
                        let isLastMessage = index == viewModel.messages.count - 1
                        EmailMessageCard(
                            message: message,
                            styledHTML: viewModel.styledHTML(for: message),
                            renderedPlain: viewModel.plainText(for: message),
                            isExpanded: viewModel.expandedMessageIds.contains(message.id),
                            bottomInset: isLastMessage ? bottomBarHeight + safeAreaBottom + 28 : 0,
                            onToggleExpand: { viewModel.toggleExpanded(message.id) }
                        )
                    }
                }
            }
        }
        .background(
            GeometryReader { geometry in
                Color(.systemGroupedBackground)
                    .onAppear { safeAreaBottom = geometry.safeAreaInsets.bottom }
                    .onChange(of: geometry.safeAreaInsets.bottom) { _, newValue in
                        safeAreaBottom = newValue
                    }
            }
        )
        .accessibilityIdentifier("emailDetailView")
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            DetailBottomBar(
                onReply: { showingReplySheet = true },
                onArchive: {
                    Task {
                        await viewModel.archive()
                        dismiss()
                    }
                },
                onTrash: {
                    Task {
                        await viewModel.trash()
                        dismiss()
                    }
                }
            )
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
            Button("Archive") {
                Task {
                    await viewModel.archive()
                    dismiss()
                }
            }
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
            Button("Print") {
                viewModel.printEmail()
            }

            if viewModel.isInNonPrimaryCategory {
                Button("Move to Primary") {
                    Task { await viewModel.moveToPrimary() }
                }
            }

            Button("Move to Trash", role: .destructive) {
                Task {
                    await viewModel.trash()
                    dismiss()
                }
            }
        }
        .modifier(ChipDialogModifier(
            pendingAction: $pendingChipAction,
            trackersBlocked: viewModel.trackersBlocked,
            senderName: viewModel.senderName ?? "Sender",
            senderEmail: viewModel.senderEmail,
            emailId: emailId,
            threadId: threadId,
            onUnsubscribe: { await viewModel.unsubscribe() },
            onBlockSender: { await viewModel.blockSender() },
            onReportSpam: { await viewModel.reportSpam() },
            onDismiss: { dismiss() }
        ))
        .task {
            // WebKit warmup now happens on row tap (before navigation starts)
            // so it overlaps with the push animation instead of competing with it
            await viewModel.loadThread()
        }
        .toolbar(.hidden, for: .tabBar)
        .onAppear { StallLogger.mark("EmailDetail.appear") }
    }
}

// MARK: - Email Message Card

struct EmailMessageCard: View {
    let message: EmailDetail
    let styledHTML: String?     // nil = not ready yet, show skeleton
    let renderedPlain: String
    let isExpanded: Bool
    var bottomInset: CGFloat = 0  // Bottom inset to clear toolbar (for last message)
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

                EmailBodyView(styledHTML: styledHTML, bottomInset: bottomInset)
                    .frame(minHeight: 100)
            }
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }

    private var senderEmail: String {
        EmailParser.extractSenderEmail(from: message.from)
    }

    private var senderName: String {
        EmailParser.extractSenderName(from: message.from)
    }

    private func formatDate(_ date: Date) -> String {
        if MessageDateFormatters.calendar.isDateInToday(date) {
            return MessageDateFormatters.timeFormatter.string(from: date)
        }
        return MessageDateFormatters.fullDateFormatter.string(from: date)
    }
}

private enum MessageDateFormatters {
    static let calendar = Calendar.current
    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()
    static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter
    }()
}

// MARK: - Email Body Skeleton (loading placeholder)

struct EmailBodySkeleton: View {
    @State private var isAnimating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Simulate text lines with varying widths
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(.systemGray5))
                    .frame(height: 14)
                    .frame(maxWidth: lineWidth(for: index), alignment: .leading)
            }
        }
        .padding()
        .opacity(isAnimating ? 0.5 : 1.0)
        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isAnimating)
        .onAppear { isAnimating = true }
    }

    private func lineWidth(for index: Int) -> CGFloat {
        // Vary line widths to look like text
        switch index {
        case 0: return .infinity
        case 1: return .infinity
        case 2: return 280
        case 3: return .infinity
        default: return 180
        }
    }
}

// MARK: - Email Body View (WebView with dynamic height, deferred mount)

struct EmailBodyView: View {
    let styledHTML: String?  // nil = not ready yet, show skeleton
    var bottomInset: CGFloat = 0  // Bottom inset to clear toolbar (for last message)
    @State private var contentHeight: CGFloat = 200
    @State private var showSkeleton = false
    @State private var webViewReady = false

    var body: some View {
        ZStack {
            // Skeleton: shown after 250ms delay if HTML not ready
            if showSkeleton && styledHTML == nil {
                EmailBodySkeleton()
                    .frame(height: 200)
                    .transition(.opacity)
            }

            // WebView: only mounted when HTML is ready
            if let html = styledHTML {
                EmailBodyWebView(
                    styledHTML: html,
                    contentHeight: $contentHeight,
                    onContentReady: {
                        webViewReady = true
                        StallLogger.mark("EmailBodyView.webReady")
                    },
                    bottomInset: bottomInset
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: contentHeight)
                .opacity(webViewReady ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: webViewReady)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: styledHTML != nil ? contentHeight : 200)
        .task {
            // Only show skeleton if HTML takes longer than 250ms
            try? await Task.sleep(for: .milliseconds(250))
            if styledHTML == nil {
                withAnimation(.easeIn(duration: 0.1)) {
                    showSkeleton = true
                }
            }
        }
        .onChange(of: styledHTML) { _, newValue in
            // Reset state when HTML changes to avoid showing old content at opacity 1
            webViewReady = false
            contentHeight = 200

            if newValue != nil {
                // HTML arrived, hide skeleton
                withAnimation(.easeOut(duration: 0.1)) {
                    showSkeleton = false
                }
            }
        }
    }
}

// MARK: - Email Text Helper

enum EmailTextHelper {
    /// Calculate plain text length from HTML, stripping tags and normalizing whitespace
    static func plainTextLength(_ html: String) -> Int {
        var text = html

        // Remove style/script blocks
        text = text.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: "", options: .regularExpression)

        // Remove HTML tags
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)

        // Decode common entities
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&zwnj;", with: "")
        text = text.replacingOccurrences(of: "&zwj;", with: "")

        // Normalize whitespace
        text = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return text.count
    }
}

// MARK: - HTML Sanitizer

enum HTMLSanitizer {
    /// Remove potentially dangerous HTML elements for security
    /// Strips script, iframe, object, embed, form, and event handlers
    static func sanitize(_ html: String) -> String {
        var result = html

        // Remove script tags and their contents
        result = result.replacingOccurrences(
            of: "<script[^>]*>[\\s\\S]*?</script>",
            with: "",
            options: .regularExpression
        )

        // Remove inline event handlers (onclick, onerror, etc.), quoted or unquoted
        result = result.replacingOccurrences(
            of: "\\son\\w+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Remove javascript: URLs
        result = result.replacingOccurrences(
            of: "javascript\\s*:",
            with: "blocked:",
            options: [.regularExpression, .caseInsensitive]
        )

        // Remove iframe tags
        result = result.replacingOccurrences(
            of: "<iframe[^>]*>[\\s\\S]*?</iframe>",
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "<iframe[^>]*/?>",
            with: "",
            options: .regularExpression
        )

        // Remove meta refresh and base href redirects
        result = result.replacingOccurrences(
            of: "<meta[^>]*http-equiv\\s*=\\s*[\"']?refresh[\"']?[^>]*>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        result = result.replacingOccurrences(
            of: "<base[^>]*>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Remove object/embed tags
        result = result.replacingOccurrences(
            of: "<object[^>]*>[\\s\\S]*?</object>",
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "<embed[^>]*/?>",
            with: "",
            options: .regularExpression
        )

        // Remove form tags (prevent phishing forms)
        result = result.replacingOccurrences(
            of: "<form[^>]*>",
            with: "<div class=\"blocked-form\">",
            options: .regularExpression
        )
        result = result.replacingOccurrences(of: "</form>", with: "</div>")

        return result
    }

    /// Remove zero-width characters that create empty space in marketing emails
    static func removeZeroWidthCharacters(_ html: String) -> String {
        var result = html
        // Remove HTML entities for zero-width characters
        result = result.replacingOccurrences(of: "&zwnj;", with: "")
        result = result.replacingOccurrences(of: "&zwj;", with: "")
        result = result.replacingOccurrences(of: "&#8204;", with: "")
        result = result.replacingOccurrences(of: "&#8205;", with: "")
        result = result.replacingOccurrences(of: "&#x200C;", with: "")
        result = result.replacingOccurrences(of: "&#x200D;", with: "")
        result = result.replacingOccurrences(of: "&#x200B;", with: "") // zero-width space
        result = result.replacingOccurrences(of: "&#8203;", with: "")
        // Remove actual Unicode zero-width characters
        result = result.replacingOccurrences(of: "\u{200B}", with: "") // zero-width space
        result = result.replacingOccurrences(of: "\u{200C}", with: "") // zero-width non-joiner
        result = result.replacingOccurrences(of: "\u{200D}", with: "") // zero-width joiner
        result = result.replacingOccurrences(of: "\u{FEFF}", with: "") // byte order mark
        return result
    }

    /// Very lightweight plain-text extractor for logging/preview.
    static func plainText(_ html: String) -> String {
        var text = html

        // Remove style/script blocks first
        text = text.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: "", options: .regularExpression)

        // Strip HTML tags
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)

        // Decode common HTML entities (must do before collapsing whitespace)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        text = text.replacingOccurrences(of: "&apos;", with: "'")
        text = text.replacingOccurrences(of: "&zwnj;", with: "")
        text = text.replacingOccurrences(of: "&zwj;", with: "")
        text = text.replacingOccurrences(of: "&#160;", with: " ")
        text = text.replacingOccurrences(of: "&#8203;", with: "") // zero-width space

        // Collapse whitespace
        let collapsed = text.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Simple inline HTML for quick plaintext-first rendering.
    static func inlinePlainHTML(_ text: String) -> String {
        let escaped = text.htmlEscaped()
        return """
        <html><body style="font-family:-apple-system;font-size:16px;padding:12px;">\(escaped)</body></html>
        """
    }

    /// Remove obvious 1x1 / 2x2 tracking pixels while keeping normal images.
    static func stripTinyImages(_ html: String) -> String {
        // Drop imgs that explicitly declare width/height <= 2
        let tinyPattern = "<img[^>]*(width\\s*=\\s*\"?[0-2]\"?[^>]*height\\s*=\\s*\"?[0-2]\"?|height\\s*=\\s*\"?[0-2]\"?[^>]*width\\s*=\\s*\"?[0-2]\"?)[^>]*>"
        var result = html.replacingOccurrences(of: tinyPattern, with: "", options: [.regularExpression, .caseInsensitive])

        // Drop common pixel filenames when size not declared
        let pixelNames = ["pixel", "track", "beacon", "open", "1x1", "1px"]
        if let regex = try? NSRegularExpression(pattern: "<img[^>]*src\\s*=\\s*[\"'][^\"'>]*(\(pixelNames.joined(separator: "|")))[^\"'>]*[\"'][^>]*>", options: [.caseInsensitive]) {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        return result
    }

    /// Add lazy-loading to images that don't already declare it.
    static func addLazyLoading(_ html: String) -> String {
        let pattern = "<img(?![^>]*\\sloading=)([^>]*?)>"
        return html.replacingOccurrences(of: pattern, with: "<img loading=\"lazy\" $1>", options: [.regularExpression, .caseInsensitive])
    }

    /// Block remote images by converting img src to data-src
    static func blockImages(_ html: String) -> String {
        var result = html

        // Remove <source> elements that can load remote images (picture/srcset)
        result = result.replacingOccurrences(
            of: "<source[^>]*srcset\\s*=\\s*[\"'][^\"']*https?://[^\"']*[\"'][^>]*/?>",
            with: "",
            options: .regularExpression
        )

        // Block http/https images (swap src -> data-blocked-src)
        result = result.replacingOccurrences(
            of: "<img([^>]*)src\\s*=\\s*[\"'](https?://[^\"']+)[\"']([^>]*)>",
            with: "<img$1data-blocked-src=\"$2\" src=\"data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7\"$3>",
            options: .regularExpression
        )

        // Strip srcset from images (prevents remote loads even with blocked src)
        result = result.replacingOccurrences(
            of: "\\s+srcset\\s*=\\s*[\"'][^\"']*[\"']",
            with: "",
            options: .regularExpression
        )

        // Strip width/height attributes from blocked images to avoid giant whitespace
        result = result.replacingOccurrences(
            of: "(<img[^>]*data-blocked-src=[\"'][^\"']+[\"'][^>]*?)\\s+(width|height)\\s*=\\s*[\"']?\\d+[\"']?",
            with: "$1",
            options: .regularExpression
        )

        // Neutralize remote background images in inline styles and style blocks
        result = result.replacingOccurrences(
            of: "url\\(\\s*[\"']?https?://[^\\)\"']+[\"']?\\s*\\)",
            with: "none",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "@import\\s+url\\(\\s*[\"']?https?://[^\\)\"']+[\"']?\\s*\\)\\s*;?",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        return result
    }

    static func stripTrackingParameters(_ html: String) -> String {
        let trackingParams: Set<String> = [
            "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
            "gclid", "fbclid", "mc_eid", "mc_cid", "igshid", "_hsenc", "_hsmi", "mkt_tok"
        ]

        guard let regex = try? NSRegularExpression(
            pattern: "href\\s*=\\s*([\"'])(.*?)\\1",
            options: [.caseInsensitive]
        ) else {
            return html
        }

        let nsRange = NSRange(html.startIndex..., in: html)
        var output = html
        var offset = 0

        regex.enumerateMatches(in: html, options: [], range: nsRange) { match, _, _ in
            guard let match,
                  let urlRange = Range(match.range(at: 2), in: html) else {
                return
            }

            let original = String(html[urlRange])
            guard var components = URLComponents(string: original),
                  let items = components.queryItems,
                  !items.isEmpty else {
                return
            }

            let filtered = items.filter { item in
                !trackingParams.contains(item.name.lowercased())
            }
            guard filtered.count != items.count else { return }

            components.queryItems = filtered.isEmpty ? nil : filtered
            guard let cleaned = components.url?.absoluteString else { return }

            let adjustedRange = NSRange(
                location: match.range(at: 2).location + offset,
                length: match.range(at: 2).length
            )
            if let swiftRange = Range(adjustedRange, in: output) {
                output.replaceSubrange(swiftRange, with: cleaned)
                offset += cleaned.count - original.count
            }
        }

        return output
    }
}

/// Simplified WebView that loads pre-rendered styled HTML.
/// All heavy processing (sanitization, image blocking, tracking removal, styling)
/// is done off-main in BodyRenderActor before reaching this view.
/// Height is measured natively via scrollView.contentSize KVO (no JavaScript).
struct EmailBodyWebView: UIViewRepresentable {
    let styledHTML: String      // Pre-rendered complete HTML document
    @Binding var contentHeight: CGFloat
    var onContentReady: (() -> Void)?  // Called when WebView commits navigation (content visible)
    var bottomInset: CGFloat = 0  // Bottom inset to clear toolbar
    var webViewPool = WKWebViewPool.shared

    func makeUIView(context: Context) -> WKWebView {
        let webView = webViewPool.dequeue()
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        context.coordinator.bind(to: webView)
        StallLogger.mark("EmailBodyWebView.makeUIView")
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Always apply bottom inset for toolbar clearance (even if HTML unchanged)
        if webView.scrollView.contentInset.bottom != bottomInset {
            webView.scrollView.contentInset.bottom = bottomInset
            webView.scrollView.scrollIndicatorInsets.bottom = bottomInset
        }

        // Use object identity of the string to detect changes
        // (styledHTML is immutable and comes from pre-rendered cache)
        let key = ObjectIdentifier(styledHTML as NSString)
        guard context.coordinator.lastKey != key else { return }
        context.coordinator.lastKey = key
        context.coordinator.contentHeight = $contentHeight
        context.coordinator.onContentReady = onContentReady

        // HTML is already fully processed - just load it
        webView.loadHTMLString(styledHTML, baseURL: nil)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.unbind()
        webView.stopLoading()
        WKWebViewPool.shared.recycle(webView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(contentHeight: $contentHeight, onContentReady: onContentReady)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var lastKey: ObjectIdentifier?
        var contentHeight: Binding<CGFloat>?
        var onContentReady: (() -> Void)?

        private var didSignalReady = false
        private var contentSizeObservation: NSKeyValueObservation?
        private var heightWorkItem: DispatchWorkItem?

        init(contentHeight: Binding<CGFloat>, onContentReady: (() -> Void)?) {
            self.contentHeight = contentHeight
            self.onContentReady = onContentReady
            super.init()
        }

        func bind(to webView: WKWebView) {
            // Observe content size; debounce to avoid excessive updates.
            contentSizeObservation = webView.scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, change in
                guard let self else { return }
                guard let newSize = change.newValue else { return }

                self.heightWorkItem?.cancel()
                let item = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    let height = max(100, newSize.height + 40)
                    DispatchQueue.main.async {
                        self.contentHeight?.wrappedValue = height
                    }
                }
                self.heightWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
            }
        }

        func unbind() {
            heightWorkItem?.cancel()
            heightWorkItem = nil
            contentSizeObservation?.invalidate()
            contentSizeObservation = nil
            didSignalReady = false
        }

        private func signalReadyOnce() {
            guard !didSignalReady else { return }
            didSignalReady = true
            onContentReady?()
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            StallLogger.mark("EmailBodyWebView.didCommit")
            signalReadyOnce()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            StallLogger.mark("EmailBodyWebView.didFinish")
            // Ensure we never leave the skeleton up if didCommit is delayed.
            signalReadyOnce()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            StallLogger.mark("EmailBodyWebView.didFail")
            signalReadyOnce()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            StallLogger.mark("EmailBodyWebView.didFailProvisional")
            signalReadyOnce()
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

// MARK: - HTML escaping

private extension String {
    func htmlEscaped() -> String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

// MARK: - Email Summary View (MessageSummaryCard)

struct EmailSummaryView: View {
    let emailId: String
    let accountEmail: String?
    let emailBody: String
    @Binding var isExpanded: Bool

    @State private var summary: String = ""
    @State private var isGenerating = false
    @State private var summaryError: String?

    private let cardShape = RoundedRectangle(cornerRadius: GlassTokens.radiusLarge, style: .continuous)

    var body: some View {
        Button(action: { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isExpanded.toggle() } }) {
            HStack(spacing: 0) {
                // Left accent bar with gradient and inset
                LinearGradient(
                    colors: [Color.purple.opacity(0.45), Color.purple.opacity(0.25)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 1.5))
                .padding(.vertical, 7)
                .padding(.leading, 2)

                VStack(alignment: .leading, spacing: 6) {
                    // Header row with chevron
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)

                        Text("Summary")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Spacer()

                        // Rotating chevron with larger hitbox
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                            .padding(6)
                            .contentShape(Rectangle())
                    }
                    .padding(.trailing, -6) // compensate for chevron padding

                    // Summary content with fade when collapsed
                    summaryContent
                }
                .padding(.leading, 8)
                .padding(.trailing, 10)
                .padding(.top, 6)
                .padding(.bottom, 8)
            }
            .background(
                cardShape.fill(GlassTokens.secondaryGroupedBackground)
            )
            .overlay(
                cardShape.stroke(
                    GlassTokens.strokeColor.opacity(GlassTokens.strokeOpacity),
                    lineWidth: GlassTokens.strokeWidth
                )
            )
            .clipShape(cardShape)
            .shadow(
                color: GlassTokens.shadowColor.opacity(GlassTokens.shadowOpacity),
                radius: GlassTokens.shadowRadius,
                y: GlassTokens.shadowY
            )
        }
        .buttonStyle(.plain)
        .onAppear {
            generateSummary()
        }
    }

    @ViewBuilder
    private var summaryContent: some View {
        if isGenerating {
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Summarizing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let error = summaryError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.orange)
                .italic()
        } else if !summary.isEmpty {
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(isExpanded ? nil : 3)
                .multilineTextAlignment(.leading)
                .mask {
                    if isExpanded {
                        Rectangle()
                    } else {
                        // Subtle fade at bottom when collapsed
                        VStack(spacing: 0) {
                            Rectangle()
                            LinearGradient(
                                colors: [.black, .black.opacity(0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 14)
                        }
                    }
                }
        } else {
            Text("Summary unavailable")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .italic()
        }
    }

    private func generateSummary() {
        isGenerating = true
        summaryError = nil

        Task {
            let resolvedSummary: String
            if let cached = SummaryCache.shared.summary(for: emailId, accountEmail: accountEmail) {
                resolvedSummary = cached
            } else if let computed = await SummaryService.summarizeIfNeeded(
                messageId: emailId,
                body: emailBody,
                accountEmail: accountEmail
            ) {
                resolvedSummary = computed
            } else {
                resolvedSummary = "Short email — summary not needed."
            }

            await MainActor.run {
                summary = resolvedSummary
                isGenerating = false
            }
        }
    }

    @MainActor
    private func summarizeWithAppleIntelligence(_ text: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let session = LanguageModelSession()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let limited = String(trimmed.prefix(5000))
            let prompt = """
            Summarize this email in 1-2 concise sentences. Focus on the key outcome, dates, amounts, and any action required. Avoid boilerplate and legal footer text.

            Email:
            \(limited)
            """
            let response = try await session.respond(to: prompt)
            let summaryText = String(describing: response.content)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !summaryText.isEmpty {
                return summaryText
            }
        }
        #endif
        throw SummaryError.unavailable
    }

    private func stripHTML(_ html: String) -> String {
        var text = decodeQuotedPrintable(html)

        // Remove hidden/preheader blocks that often contain filler
        text = text.replacingOccurrences(
            of: "<(div|span|p)[^>]*class\\s*=\\s*[\"'][^\"']*preheader[^\"']*[\"'][^>]*>[\\s\\S]*?</\\1>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "<(div|span|p)[^>]*(display\\s*:\\s*none|visibility\\s*:\\s*hidden)[^>]*>[\\s\\S]*?</\\1>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

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

        // Decode numeric HTML entities (&#123; and &#x1F4A9;)
        text = decodeNumericEntities(text)

        // Decode named HTML entities
        text = text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#160;", with: " ")
            // Zero-width characters (used in marketing emails)
            .replacingOccurrences(of: "&zwnj;", with: "")
            .replacingOccurrences(of: "&zwj;", with: "")
            .replacingOccurrences(of: "&#8204;", with: "")
            .replacingOccurrences(of: "&#8205;", with: "")
            .replacingOccurrences(of: "&#x200C;", with: "")
            .replacingOccurrences(of: "&#x200D;", with: "")
            // Other common entities
            .replacingOccurrences(of: "&mdash;", with: "—")
            .replacingOccurrences(of: "&ndash;", with: "–")
            .replacingOccurrences(of: "&rsquo;", with: "'")
            .replacingOccurrences(of: "&lsquo;", with: "'")
            .replacingOccurrences(of: "&rdquo;", with: "\"")
            .replacingOccurrences(of: "&ldquo;", with: "\"")
            .replacingOccurrences(of: "&hellip;", with: "...")
            .replacingOccurrences(of: "&bull;", with: "•")
            .replacingOccurrences(of: "&copy;", with: "©")
            .replacingOccurrences(of: "&reg;", with: "®")
            .replacingOccurrences(of: "&trade;", with: "™")

        // Collapse any remaining non-breaking space entities (including &amp;nbsp; and &nbsp without semicolons)
        text = text
            .replacingOccurrences(of: "&nbsp;", with: " ", options: .caseInsensitive)
            .replacingOccurrences(of: "&nbsp", with: " ", options: .caseInsensitive)
            .replacingOccurrences(of: "\u{00A0}", with: " ")

        // Remove invisible/control characters that commonly appear in marketing emails
        text = text
            .replacingOccurrences(of: "\u{034F}", with: "") // combining grapheme joiner
            .replacingOccurrences(of: "\u{00AD}", with: "") // soft hyphen

        // Remove repeated semicolon noise left by entity padding
        text = text.replacingOccurrences(
            of: "(?:\\s*;\\s*){2,}",
            with: " ",
            options: .regularExpression
        )

        // Clean up whitespace
        text = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeNumericEntities(_ text: String) -> String {
        var result = text
        result = replaceMatches(in: result, pattern: "&#(\\d+);?") { match, nsText in
            let valueString = nsText.substring(with: match.range(at: 1))
            guard let value = Int(valueString),
                  let scalar = UnicodeScalar(value) else {
                return ""
            }
            return String(scalar)
        }
        result = replaceMatches(in: result, pattern: "&#x([0-9a-fA-F]+);?") { match, nsText in
            let valueString = nsText.substring(with: match.range(at: 1))
            guard let value = Int(valueString, radix: 16),
                  let scalar = UnicodeScalar(value) else {
                return ""
            }
            return String(scalar)
        }
        return result
    }

    private func decodeQuotedPrintable(_ input: String) -> String {
        let bytes = Array(input.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)

        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 61 { // '='
                if index + 1 < bytes.count, bytes[index + 1] == 10 {
                    // Soft line break: "=\n"
                    index += 2
                    continue
                }
                if index + 2 < bytes.count, bytes[index + 1] == 13, bytes[index + 2] == 10 {
                    // Soft line break: "=\r\n"
                    index += 3
                    continue
                }
                if index + 2 < bytes.count,
                   let high = hexNibble(bytes[index + 1]),
                   let low = hexNibble(bytes[index + 2]) {
                    output.append((high << 4) | low)
                    index += 3
                    continue
                }
            }
            output.append(byte)
            index += 1
        }

        return String(data: Data(output), encoding: .utf8) ?? input
    }

    private func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48       // 0-9
        case 65...70: return byte - 55       // A-F
        case 97...102: return byte - 87      // a-f
        default: return nil
        }
    }

    private func replaceMatches(
        in text: String,
        pattern: String,
        transform: (NSTextCheckingResult, NSString) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            let replacement = transform(match, nsText)
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        return result
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

    private func isShortEmail(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(separator: " ")
        if words.count < 60 {
            return true
        }
        let sentenceEndings = CharacterSet(charactersIn: ".!?")
        var sentenceCount = 0
        for char in trimmed.unicodeScalars where sentenceEndings.contains(char) {
            sentenceCount += 1
            if sentenceCount >= 3 {
                return false
            }
        }
        return sentenceCount <= 2
    }

    private enum SummaryError: Error {
        case unavailable
    }
}

// MARK: - Pending Chip Action (for confirmation dialogs)

enum PendingChipAction: Identifiable {
    case tracker
    case unsubscribe
    case block
    case spam

    var id: Self { self }
}

// MARK: - Chip Dialog Modifier (helps type-checker by extracting modifiers)

struct ChipDialogModifier: ViewModifier {
    @Binding var pendingAction: PendingChipAction?
    let trackersBlocked: Int
    let senderName: String
    let senderEmail: String?
    let emailId: String
    let threadId: String
    let onUnsubscribe: () async -> Void
    let onBlockSender: () async -> Void
    let onReportSpam: () async -> Void
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        content
            .alert("Tracking Prevented", isPresented: trackerBinding) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("SimpleMail blocked \(trackersBlocked) tracking pixel\(trackersBlocked == 1 ? "" : "s") from notifying the sender when you opened this email.")
            }
            .alert("Unsubscribe from \(senderName)?", isPresented: unsubscribeBinding) {
                Button("Cancel", role: .cancel) {
                    pendingAction = nil
                }
                Button("Unsubscribe", role: .destructive) {
                    Task {
                        await onUnsubscribe()
                        NotificationCenter.default.post(
                            name: .unsubscribed,
                            object: nil,
                            userInfo: ["senderName": senderName, "emailId": emailId]
                        )
                    }
                }
            } message: {
                Text("You'll stop getting these emails.")
            }
            .alert("Block \(senderName)?", isPresented: blockBinding) {
                Button("Cancel", role: .cancel) {
                    pendingAction = nil
                }
                Button("Block Sender", role: .destructive) {
                    Task {
                        await onBlockSender()
                        NotificationCenter.default.post(name: .blockedSendersDidChange, object: nil)
                        NotificationCenter.default.post(
                            name: .senderBlocked,
                            object: nil,
                            userInfo: ["senderName": senderName, "senderEmail": senderEmail ?? "", "emailId": emailId, "threadId": threadId]
                        )
                        onDismiss()
                    }
                }
            } message: {
                Text("You won't see emails from this sender.")
            }
            .alert("Mark as spam?", isPresented: spamBinding) {
                Button("Cancel", role: .cancel) {
                    pendingAction = nil
                }
                Button("Mark as Spam", role: .destructive) {
                    Task {
                        await onReportSpam()
                        NotificationCenter.default.post(name: .blockedSendersDidChange, object: nil)
                        NotificationCenter.default.post(
                            name: .spamReported,
                            object: nil,
                            userInfo: ["senderName": senderName, "emailId": emailId, "threadId": threadId]
                        )
                        onDismiss()
                    }
                }
            } message: {
                Text("This email will be moved to Spam.")
            }
    }

    private var trackerBinding: Binding<Bool> {
        Binding(
            get: { pendingAction == .tracker },
            set: { if !$0 { pendingAction = nil } }
        )
    }

    private var unsubscribeBinding: Binding<Bool> {
        Binding(
            get: { pendingAction == .unsubscribe },
            set: { if !$0 { pendingAction = nil } }
        )
    }

    private var blockBinding: Binding<Bool> {
        Binding(
            get: { pendingAction == .block },
            set: { if !$0 { pendingAction = nil } }
        )
    }

    private var spamBinding: Binding<Bool> {
        Binding(
            get: { pendingAction == .spam },
            set: { if !$0 { pendingAction = nil } }
        )
    }
}

// MARK: - Email Action Chips View

struct EmailActionChipsView: View {
    let canUnsubscribe: Bool
    let senderName: String
    let isReply: Bool
    let trackersBlocked: Int

    @Binding var pendingAction: PendingChipAction?

    // Standard stroke opacity for all action chips
    private let chipStrokeOpacity: Double = 0.20

    var body: some View {
        VStack(spacing: 0) {
            // Chip row - all chips grouped together, left-aligned
            HStack(spacing: 10) {
                // Tracker status chip (special - keeps green accent)
                if trackersBlocked > 0 {
                    ActionChip(strokeOpacity: 0.26) {
                        pendingAction = .tracker
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "shield.fill")
                                .font(.system(size: 11, weight: .medium))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.green)
                            Text("\(trackersBlocked)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.green)
                        }
                    }
                    .accessibilityLabel("\(trackersBlocked) tracker\(trackersBlocked > 1 ? "s" : "") blocked")
                }

                // Unsubscribe chip - equal peer
                if canUnsubscribe {
                    ActionChip(strokeOpacity: chipStrokeOpacity) {
                        pendingAction = .unsubscribe
                    } label: {
                        Text("Unsubscribe")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }

                // Block chip - equal peer
                ActionChip(strokeOpacity: chipStrokeOpacity) {
                    pendingAction = .block
                } label: {
                    Text("Block")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Block \(senderName)")

                // Spam chip - equal peer (not for replies)
                if !isReply {
                    ActionChip(strokeOpacity: chipStrokeOpacity) {
                        pendingAction = .spam
                    } label: {
                        Text("Spam")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Mark as spam")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 2)
            .padding(.bottom, 8)

            // Subtle divider to anchor strip
            Rectangle()
                .fill(Color(UIColor.separator).opacity(0.12))
                .frame(height: 0.5)
                .padding(.horizontal, 12)
        }
    }
}

// MARK: - Action Chip Component (equal-weight, quiet, tappable)

struct ActionChip<Label: View>: View {
    let strokeOpacity: Double
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var isPressed = false

    private let visualHeight: CGFloat = 28
    private let horizontalPadding: CGFloat = 12

    var body: some View {
        Button {
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
            action()
        } label: {
            label()
                .padding(.horizontal, horizontalPadding)
                .frame(height: visualHeight)
                .background(
                    Capsule()
                        .fill(GlassTokens.chromeMaterial)
                )
                .overlay(
                    // Pressed highlight overlay
                    Capsule()
                        .fill(Color.white.opacity(isPressed ? 0.06 : 0))
                )
                .overlay(
                    Capsule()
                        .stroke(
                            GlassTokens.strokeColor.opacity(isPressed ? strokeOpacity + 0.06 : strokeOpacity),
                            lineWidth: GlassTokens.strokeWidth
                        )
                )
                .shadow(
                    color: GlassTokens.shadowColor.opacity(GlassTokens.shadowOpacity),
                    radius: GlassTokens.shadowRadius,
                    y: GlassTokens.shadowY
                )
                .scaleEffect(isPressed ? 0.98 : 1.0)
                .animation(.easeOut(duration: 0.15), value: isPressed)
        }
        .buttonStyle(ActionChipButtonStyle(isPressed: $isPressed))
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

// MARK: - Action Chip Button Style

struct ActionChipButtonStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, newValue in
                isPressed = newValue
            }
    }
}

// MARK: - Legacy Glass Chip Component (for backwards compatibility)

struct GlassChip<Label: View>: View {
    enum Style { case status, primary, secondary }

    let style: Style
    let foregroundColor: Color
    let strokeColor: Color
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var isPressed = false

    private let visualHeight: CGFloat = 28

    var body: some View {
        Button {
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
            action()
        } label: {
            label()
                .foregroundStyle(foregroundColor)
                .padding(.horizontal, 12)
                .frame(height: visualHeight)
                .background(
                    Capsule()
                        .fill(GlassTokens.chromeMaterial)
                )
                .overlay(
                    Capsule()
                        .fill(Color.white.opacity(isPressed ? 0.06 : 0))
                )
                .overlay(
                    Capsule()
                        .stroke(
                            strokeColor.opacity(isPressed ? 1.3 : 1.0),
                            lineWidth: GlassTokens.strokeWidth
                        )
                )
                .shadow(
                    color: GlassTokens.shadowColor.opacity(GlassTokens.shadowOpacity),
                    radius: GlassTokens.shadowRadius,
                    y: GlassTokens.shadowY
                )
                .scaleEffect(isPressed ? 0.98 : 1.0)
                .animation(.easeOut(duration: 0.15), value: isPressed)
        }
        .buttonStyle(GlassChipButtonStyle(isPressed: $isPressed))
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

// MARK: - Glass Chip Button Style

struct GlassChipButtonStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.8), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, newValue in
                isPressed = newValue
            }
    }
}

// MARK: - Action Pill Modifier

extension View {
    func actionPill(height: CGFloat, strokeColor: Color = GlassTokens.strokeColor.opacity(0.18)) -> some View {
        self
            .padding(.horizontal, 10)
            .frame(height: height)
            .background(Capsule().fill(GlassTokens.chromeMaterial))
            .overlay(Capsule().stroke(strokeColor, lineWidth: GlassTokens.strokeWidth))
            .shadow(color: GlassTokens.shadowColor.opacity(GlassTokens.shadowOpacity), radius: GlassTokens.shadowRadius, y: GlassTokens.shadowY)
    }
}

// MARK: - Detail Bottom Bar (Glass styled)

struct DetailBottomBar: View {
    let onReply: () -> Void
    let onArchive: () -> Void
    let onTrash: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            // Reply button with context menu (primary action)
            Menu {
                Button(action: onReply) {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                }
                Button(action: onReply) {
                    Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
                }
                Button(action: {}) {
                    Label("Forward", systemImage: "arrowshape.turn.up.right")
                }
            } label: {
                Image(systemName: "arrowshape.turn.up.left")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            } primaryAction: {
                onReply()
            }
            .accessibilityLabel("Reply")

            // Archive button (secondary)
            Button(action: onArchive) {
                Image(systemName: "archivebox")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Archive")

            // Trash button (destructive)
            Button(action: onTrash) {
                Image(systemName: "trash")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.red.opacity(0.7))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Delete")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(GlassTokens.chromeMaterial)
        )
        .glassStroke(Capsule())
        .glassShadow()
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// MARK: - Email Detail ViewModel

@MainActor
class EmailDetailViewModel: ObservableObject {
    let threadId: String
    let accountEmail: String?

    @Published var messages: [EmailDetail] = []
    @Published var expandedMessageIds: Set<String> = []
    @Published var summaryExpanded: Bool = false  // Collapsed by default, tap to expand
    @Published var isLoading = false
    @Published var error: Error?
    /// Full body of latest message (for AI summary check - not the placeholder snippet)
    @Published var latestMessageFullBody: String?
    @Published var unsubscribeURL: URL?
    @Published var trackersBlocked: Int = 0
    @Published var trackerNames: [String] = []
    @Published private var renderedBodies: [String: BodyRenderActor.RenderedBody] = [:]

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

    // Precomputed lowercased domains for O(1) contains checks
    nonisolated(unsafe) private static let trackerDomainsLowercased: [(domain: String, name: String)] = {
        trackerDomains.map { (domain: $0.key.lowercased(), name: $0.value) }
    }()

    // Short-circuit keywords to skip expensive regex if no trackers likely present
    nonisolated(unsafe) private static let trackerHintKeywords = ["pixel", "track", "beacon", "open", "click"]

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
        let settingsAccountEmail = accountEmail ?? AuthService.shared.currentAccount?.email
        let vipSenders = AccountDefaults.stringArray(for: "vipSenders", accountEmail: settingsAccountEmail)
        return vipSenders.contains(email.lowercased())
    }

    /// Check if the email is in a non-Primary Gmail category (Promotions, Social, Updates, Forums)
    var isInNonPrimaryCategory: Bool {
        let nonPrimaryCategories = ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL", "CATEGORY_UPDATES", "CATEGORY_FORUMS"]
        guard let labelIds = messages.first?.labelIds else { return false }
        return !nonPrimaryCategories.filter { labelIds.contains($0) }.isEmpty
    }

    /// The category this email is in, if any
    var currentCategory: GmailCategory? {
        guard let labelIds = messages.first?.labelIds else { return nil }
        for category in GmailCategory.allCases {
            if labelIds.contains(category.rawValue) {
                return category
            }
        }
        return nil
    }

    var autoSummarizeEnabled: Bool {
        let settingsAccountEmail = accountEmail ?? AuthService.shared.currentAccount?.email
        guard let data = AccountDefaults.data(for: "appSettings", accountEmail: settingsAccountEmail) else {
            return true // Default to enabled
        }
        do {
            let settings = try JSONDecoder().decode(AppSettings.self, from: data)
            return settings.autoSummarize
        } catch {
            detailLogger.warning("Failed to decode app settings for auto-summarize: \(error.localizedDescription)")
            return true // Default to enabled
        }
    }

    var trackingProtectionEnabled: Bool {
        renderSettings.blockTrackingPixels
    }

    /// Get render settings from AppSettings (used for background HTML processing)
    private var renderSettings: BodyRenderActor.RenderSettings {
        let settingsAccountEmail = accountEmail ?? AuthService.shared.currentAccount?.email
        guard let data = AccountDefaults.data(for: "appSettings", accountEmail: settingsAccountEmail) else {
            return BodyRenderActor.RenderSettings(blockImages: true, blockTrackingPixels: true, stripTrackingParameters: true)
        }
        do {
            let settings = try JSONDecoder().decode(AppSettings.self, from: data)
            return BodyRenderActor.RenderSettings(
                blockImages: settings.blockRemoteImages,
                blockTrackingPixels: settings.blockTrackingPixels,
                stripTrackingParameters: settings.stripTrackingParameters
            )
        } catch {
            return BodyRenderActor.RenderSettings(blockImages: true, blockTrackingPixels: true, stripTrackingParameters: true)
        }
    }

    /// Get pre-rendered styled HTML ready for WebView (all processing done off-main)
    /// Returns nil if HTML is not ready yet - caller should show skeleton placeholder
    func styledHTML(for message: EmailDetail) -> String? {
        renderedBodies[message.id]?.styledHTML
    }

    func bodyHTML(for message: EmailDetail) -> String {
        renderedBodies[message.id]?.html ?? message.body
    }

    func plainText(for message: EmailDetail) -> String {
        renderedBodies[message.id]?.plain ?? HTMLSanitizer.plainText(message.body)
    }

    private func accountForThread() -> AuthService.Account? {
        guard let accountEmail = messages.first?.accountEmail?.lowercased() else {
            return AuthService.shared.currentAccount
        }
        return AuthService.shared.accounts.first { $0.email.lowercased() == accountEmail }
    }

    init(threadId: String, accountEmail: String?) {
        self.threadId = threadId
        self.accountEmail = accountEmail
    }
    private let renderActor = BodyRenderActor()
    private var didLogBodySwap = false

    // Detect tracking pixels in email HTML (optimized: lowercase once, precomputed domains)
    nonisolated private static func detectTrackers(in html: String) -> [String] {
        var foundTrackers = Set<String>()

        // Lowercase ONCE, then check all domains against the lowercased string
        let lower = html.lowercased()

        // Check for known tracker domains (using precomputed lowercased domains)
        for (domain, name) in trackerDomainsLowercased {
            if lower.contains(domain) {
                foundTrackers.insert(name)
            }
        }

        // Short-circuit: only run expensive regex if hint keywords suggest trackers might be present
        let hasHintKeyword = trackerHintKeywords.contains { lower.contains($0) }

        // Count 1x1 pixel images (only if we haven't found domain-based trackers or hints suggest pixels)
        if foundTrackers.isEmpty || hasHintKeyword {
            // Pattern for 1x1 pixel images (common tracker format)
            let pixelPatterns = [
                "<img[^>]*width\\s*=\\s*[\"']?1[\"']?[^>]*height\\s*=\\s*[\"']?1[\"']?[^>]*>",
                "<img[^>]*height\\s*=\\s*[\"']?1[\"']?[^>]*width\\s*=\\s*[\"']?1[\"']?[^>]*>",
                "<img[^>]*style\\s*=\\s*[\"'][^\"']*display\\s*:\\s*none[^\"']*[\"'][^>]*>"
            ]

            for pattern in pixelPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                    let range = NSRange(html.startIndex..., in: html)
                    let matches = regex.numberOfMatches(in: html, range: range)
                    if matches > 0 && foundTrackers.isEmpty {
                        foundTrackers.insert("Tracking Pixel")
                        break // Found one, no need to check other patterns
                    }
                }
            }
        }

        return Array(foundTrackers).sorted()
    }

    func loadThread() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let messageDTOs: [EmailDetailDTO]
            if let accountEmail = accountEmail?.lowercased(),
               let account = AuthService.shared.accounts.first(where: { $0.email.lowercased() == accountEmail }) {
                messageDTOs = try await GmailService.shared.fetchThread(threadId: threadId, account: account)
            } else {
                messageDTOs = try await GmailService.shared.fetchThread(threadId: threadId)
            }

            // FAST PATH: Show minimal placeholders immediately WITHOUT HTML processing on main
            // Use snippet (already available) as placeholder text to avoid HTMLSanitizer.plainText() on main
            let placeholders = messageDTOs.map { dto -> EmailDetail in
                let detail = EmailDetail(dto: dto)
                // Use snippet as quick placeholder - real HTML will be swapped in from background
                detail.body = HTMLSanitizer.inlinePlainHTML(dto.snippet)
                return detail
            }
            messages = placeholders
            // Store full body for AI summary check (not the snippet placeholder)
            latestMessageFullBody = messageDTOs.last?.body
            StallLogger.mark("EmailDetail.threadLoaded")

            // Expand the latest message by default
            if let lastId = messages.last?.id {
                expandedMessageIds.insert(lastId)
            }

            // Parse unsubscribe URL from latest message (cheap string parsing, OK on main)
            if let unsubscribeHeader = messages.last?.listUnsubscribe {
                unsubscribeURL = parseUnsubscribeURL(from: unsubscribeHeader)
            }

            // Extract data to value types BEFORE crossing threads (SwiftData objects can't cross)
            let dtoSnapshots = messageDTOs.map { (id: $0.id, body: $0.body, snippet: $0.snippet) }
            let shouldDetectTrackers = trackingProtectionEnabled

            // IMPORTANT: Render the SELECTED/LATEST message first for fast perceived load
            let latestMessageId = messages.last?.id

            // BACKGROUND: Heavy work - tracker detection, HTML sanitization, plaintext extraction
            Task.detached(priority: .userInitiated) { [weak self, renderActor] in
                guard let self else { return }

#if DEBUG
                let renderStart = CFAbsoluteTimeGetCurrent()
#endif

                // Get render settings on main actor (do this first, before any heavy work)
                let settings = await MainActor.run { [weak self] in
                    self?.renderSettings ?? BodyRenderActor.RenderSettings(blockImages: true, blockTrackingPixels: true, stripTrackingParameters: true)
                }

                // PRIORITY: Render the latest/selected message FIRST
                // This is the one the user sees immediately, others are collapsed
                if let latestId = latestMessageId,
                   let latestSnapshot = dtoSnapshots.first(where: { $0.id == latestId }) {
                    let rendered = await renderActor.render(html: latestSnapshot.body, settings: settings)
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.renderedBodies[latestSnapshot.id] = rendered
                        StallLogger.mark("EmailDetail.bodySwap")
                        self.didLogBodySwap = true
#if DEBUG
                        let ms = Int((CFAbsoluteTimeGetCurrent() - renderStart) * 1000)
                        detailLogger.info("render.latest id=\(latestId, privacy: .public) ms=\(ms)")
#endif
                    }
                }

                // Now render remaining messages (collapsed, not immediately visible)
                for snapshot in dtoSnapshots where snapshot.id != latestMessageId {
                    let rendered = await renderActor.render(html: snapshot.body, settings: settings)
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.renderedBodies[snapshot.id] = rendered
                    }
                }

                // Tracker detection (runs after visible content is ready)
                if shouldDetectTrackers {
                    var allTrackers = Set<String>()
                    for snapshot in dtoSnapshots {
                        let found = Self.detectTrackers(in: snapshot.body)
                        allTrackers.formUnion(found)
                    }
                    let trackerNamesSorted = Array(allTrackers).sorted()

                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.trackerNames = trackerNamesSorted
                        self.trackersBlocked = trackerNamesSorted.count
                    }
                }

#if DEBUG
                let totalMs = Int((CFAbsoluteTimeGetCurrent() - renderStart) * 1000)
                detailLogger.info("render.all complete ms=\(totalMs)")
#endif
            }

            // Mark as read (fire off async, don't block)
            let unreadIds = messages.filter(\.isUnread).map(\.id)
            let account = accountForThread()
            for messageId in unreadIds {
                Task {
                    do {
                        if let account {
                            try await GmailService.shared.markAsRead(messageId: messageId, account: account)
                        } else {
                            try await GmailService.shared.markAsRead(messageId: messageId)
                        }
                    } catch {
                        detailLogger.error("Failed to mark message as read: \(error.localizedDescription)")
                    }
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
        NotificationCenter.default.post(
            name: .archiveThreadRequested,
            object: nil,
            userInfo: ["threadId": threadId]
        )
    }

    func trash() async {
        NotificationCenter.default.post(
            name: .trashThreadRequested,
            object: nil,
            userInfo: ["threadId": threadId]
        )
    }

    func toggleStar() async {
        guard let lastMessage = messages.last else { return }
        do {
            if lastMessage.isStarred {
                if let account = accountForThread() {
                    try await GmailService.shared.unstar(messageId: lastMessage.id, account: account)
                } else {
                    try await GmailService.shared.unstar(messageId: lastMessage.id)
                }
            } else {
                if let account = accountForThread() {
                    try await GmailService.shared.star(messageId: lastMessage.id, account: account)
                } else {
                    try await GmailService.shared.star(messageId: lastMessage.id)
                }
            }
            await loadThread()
        } catch {
            self.error = error
        }
    }

    func toggleRead() async {
        // Use batch API for efficiency
        let unreadIds = messages.filter(\.isUnread).map(\.id)
        let readIds = messages.filter { !$0.isUnread }.map(\.id)

        do {
            if !unreadIds.isEmpty {
                if let account = accountForThread() {
                    try await GmailService.shared.batchMarkAsRead(messageIds: unreadIds, account: account)
                } else {
                    try await GmailService.shared.batchMarkAsRead(messageIds: unreadIds)
                }
            }
            if !readIds.isEmpty {
                if let account = accountForThread() {
                    try await GmailService.shared.batchMarkAsUnread(messageIds: readIds, account: account)
                } else {
                    try await GmailService.shared.batchMarkAsUnread(messageIds: readIds)
                }
            }
            await loadThread()
        } catch {
            self.error = error
        }
    }

    func moveToPrimary() async {
        guard let lastMessage = messages.last else { return }
        do {
            if let account = accountForThread() {
                try await GmailService.shared.moveToPrimary(messageId: lastMessage.id, account: account)
            } else {
                try await GmailService.shared.moveToPrimary(messageId: lastMessage.id)
            }
            // Notify inbox to update local email labels
            NotificationCenter.default.post(
                name: .movedToPrimaryRequested,
                object: nil,
                userInfo: ["messageId": lastMessage.id]
            )
            await loadThread()
            HapticFeedback.success()
        } catch {
            self.error = error
        }
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
        let settingsAccountEmail = accountEmail ?? AuthService.shared.currentAccount?.email
        var blockedSenders = AccountDefaults.stringArray(for: "blockedSenders", accountEmail: settingsAccountEmail)
        if !blockedSenders.contains(email.lowercased()) {
            blockedSenders.append(email.lowercased())
            AccountDefaults.setStringArray(blockedSenders, for: "blockedSenders", accountEmail: settingsAccountEmail)
        }

        // Move to trash
        await trash()

        HapticFeedback.success()
    }

    func reportSpam() async {
        let account = accountForThread()
        for message in messages {
            do {
                if let account {
                    try await GmailService.shared.reportSpam(messageId: message.id, account: account)
                } else {
                    try await GmailService.shared.reportSpam(messageId: message.id)
                }
            } catch {
                detailLogger.error("Failed to report spam: \(error.localizedDescription)")
            }
        }
        HapticFeedback.success()
    }

    func toggleVIP() {
        guard let email = senderEmail else { return }
        let emailLower = email.lowercased()

        let settingsAccountEmail = accountEmail ?? AuthService.shared.currentAccount?.email
        var vipSenders = AccountDefaults.stringArray(for: "vipSenders", accountEmail: settingsAccountEmail)

        if vipSenders.contains(emailLower) {
            vipSenders.removeAll { $0 == emailLower }
            HapticFeedback.light()
        } else {
            vipSenders.append(emailLower)
            HapticFeedback.success()
        }

        AccountDefaults.setStringArray(vipSenders, for: "vipSenders", accountEmail: settingsAccountEmail)
        objectWillChange.send() // Trigger UI update
    }

    func printEmail() {
        guard !messages.isEmpty else { return }

        let printController = UIPrintInteractionController.shared
        let printInfo = UIPrintInfo(dictionary: nil)
        printInfo.jobName = subject.isEmpty ? "Email" : subject
        printInfo.outputType = .general
        printController.printInfo = printInfo

        // Build HTML content for printing
        var htmlContent = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
                    font-size: 12pt;
                    line-height: 1.5;
                    color: #000;
                    padding: 20px;
                }
                .email-header {
                    border-bottom: 1px solid #ccc;
                    padding-bottom: 12px;
                    margin-bottom: 16px;
                }
                .email-subject {
                    font-size: 16pt;
                    font-weight: bold;
                    margin-bottom: 8px;
                }
                .email-meta {
                    font-size: 10pt;
                    color: #666;
                }
                .email-meta strong {
                    color: #000;
                }
                .message-separator {
                    border-top: 1px solid #ddd;
                    margin: 20px 0;
                    padding-top: 16px;
                }
                .message-header {
                    font-size: 10pt;
                    color: #666;
                    margin-bottom: 12px;
                }
                .message-body {
                    font-size: 12pt;
                }
                img { max-width: 100%; height: auto; }
                a { color: #007AFF; }
                /* Fix table layouts for printing */
                table { width: 100% !important; table-layout: auto !important; }
                td, th {
                    width: auto !important;
                    min-width: 0 !important;
                    word-wrap: break-word;
                    white-space: normal !important;
                }
                /* Prevent single-character-per-line issue */
                * {
                    max-width: 100% !important;
                    word-break: normal !important;
                }
            </style>
        </head>
        <body>
        """

        // Add thread subject header
        htmlContent += """
        <div class="email-header">
            <div class="email-subject">\(escapeHTML(subject))</div>
        </div>
        """

        // Add each message in the thread
        for (index, message) in messages.enumerated() {
            if index > 0 {
                htmlContent += "<div class=\"message-separator\"></div>"
            }

            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .long
            dateFormatter.timeStyle = .short
            let dateString = dateFormatter.string(from: message.date)

            htmlContent += """
            <div class="message-header">
                <div><strong>From:</strong> \(escapeHTML(message.from))</div>
                <div><strong>To:</strong> \(escapeHTML(message.to.joined(separator: ", ")))</div>
                <div><strong>Date:</strong> \(dateString)</div>
            </div>
            <div class="message-body">
                \(sanitizeHTMLForPrint(message.body))
            </div>
            """
        }

        htmlContent += """
        </body>
        </html>
        """

        // Create print formatter with HTML content
        let printFormatter = UIMarkupTextPrintFormatter(markupText: htmlContent)
        printFormatter.perPageContentInsets = UIEdgeInsets(top: 36, left: 36, bottom: 36, right: 36)
        printController.printFormatter = printFormatter

        // Present print dialog
        printController.present(animated: true) { _, completed, error in
            if let error = error {
                detailLogger.error("Print failed: \(error.localizedDescription)")
            } else if completed {
                detailLogger.info("Print job completed successfully")
            }
        }
    }

    private func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func sanitizeHTMLForPrint(_ html: String) -> String {
        var result = html

        // Remove fixed width attributes from tables and cells
        result = result.replacingOccurrences(
            of: "\\s+width\\s*=\\s*[\"']?\\d+[\"']?",
            with: "",
            options: .regularExpression
        )

        // Remove inline width styles that cause narrow columns
        result = result.replacingOccurrences(
            of: "width\\s*:\\s*\\d+px",
            with: "width: auto",
            options: [.regularExpression, .caseInsensitive]
        )

        // Remove max-width constraints that might be too narrow
        result = result.replacingOccurrences(
            of: "max-width\\s*:\\s*\\d+px",
            with: "max-width: 100%",
            options: [.regularExpression, .caseInsensitive]
        )

        // Remove min-width that forces narrow columns
        result = result.replacingOccurrences(
            of: "min-width\\s*:\\s*\\d+px",
            with: "min-width: 0",
            options: [.regularExpression, .caseInsensitive]
        )

        return result
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        EmailDetailView(emailId: "1", threadId: "t1")
    }
}
