import SwiftUI
import UIKit
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Compose Mode

enum ComposeMode {
    case new
    case reply(to: EmailDetail, threadId: String)
    case replyAll(to: EmailDetail, threadId: String)
    case forward(original: EmailDetail)
    case draft(id: String, to: [String], subject: String, body: String)
}

// MARK: - Compose View

struct ComposeView: View {
    let mode: ComposeMode

    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: ComposeViewModel
    @FocusState private var focusedField: Field?
    @StateObject private var richTextContext = RichTextContext()
    @State private var showingAIDraft = false

    enum Field: Hashable {
        case to, cc, bcc, subject, body
    }

    init(mode: ComposeMode = .new) {
        self.mode = mode
        self._viewModel = StateObject(wrappedValue: ComposeViewModel(mode: mode))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    // Recipients
                    RecipientField(
                        label: "To",
                        recipients: $viewModel.to,
                        pendingInput: $viewModel.pendingToInput,
                        isFocused: focusedField == .to
                    )
                    .focused($focusedField, equals: .to)

                    Divider().padding(.leading)

                    if viewModel.showCcBcc {
                        RecipientField(
                            label: "Cc",
                            recipients: $viewModel.cc,
                            pendingInput: $viewModel.pendingCcInput,
                            isFocused: focusedField == .cc
                        )
                        .focused($focusedField, equals: .cc)

                        Divider().padding(.leading)

                        RecipientField(
                            label: "Bcc",
                            recipients: $viewModel.bcc,
                            pendingInput: $viewModel.pendingBccInput,
                            isFocused: focusedField == .bcc
                        )
                        .focused($focusedField, equals: .bcc)

                        Divider().padding(.leading)
                    }

                    // Subject
                    HStack {
                        Text("Subject")
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .leading)

                        TextField("", text: $viewModel.subject)
                            .textInputAutocapitalization(.sentences)
                            .focused($focusedField, equals: .subject)
                    }
                    .padding()

                    Divider().padding(.leading)

                    // Body (rich text)
                    ZStack(alignment: .topLeading) {
                        RichTextEditor(
                            attributedText: $viewModel.bodyAttributed,
                            context: richTextContext
                        )
                        .frame(minHeight: 300)
                        .focused($focusedField, equals: .body)

                        if viewModel.bodyAttributed.string.isEmpty {
                            Text("Write your message…")
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                                .padding(.leading, 6)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("composeView")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if viewModel.hasContent {
                            viewModel.showDiscardAlert = true
                        } else {
                            dismiss()
                        }
                    }
                    .accessibilityIdentifier("cancelCompose")
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(action: { showingAIDraft = true }) {
                        Image(systemName: "sparkles")
                    }

                    Button(action: { viewModel.showCcBcc.toggle() }) {
                        Image(systemName: viewModel.showCcBcc ? "chevron.up" : "chevron.down")
                    }

                    Button(action: { viewModel.showAttachmentPicker = true }) {
                        Image(systemName: "paperclip")
                    }

                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(!viewModel.canSend)
                    .accessibilityIdentifier("sendButton")
                }
            }
            .alert("Discard Draft?", isPresented: $viewModel.showDiscardAlert) {
                Button("Discard", role: .destructive) {
                    dismiss()
                }
                Button("Save Draft") {
                    Task {
                        await viewModel.saveDraft()
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .overlay {
                if viewModel.isSending {
                    SendingOverlay()
                } else if viewModel.isGeneratingDraft {
                    StatusOverlay(title: "Drafting...")
                }
            }
            .safeAreaInset(edge: .bottom) {
                RichTextToolbar(context: richTextContext)
            }
            .sheet(isPresented: $showingAIDraft) {
                AIDraftSheet { prompt, tone, length, includeSubject in
                    Task {
                        await viewModel.applyAIDraft(
                            prompt: prompt,
                            tone: tone,
                            length: length,
                            includeSubject: includeSubject
                        )
                    }
                }
            }
            .alert(
                "AI Draft Error",
                isPresented: Binding(
                    get: { viewModel.aiDraftError != nil },
                    set: { if !$0 { viewModel.aiDraftError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.aiDraftError ?? "Unable to generate draft.")
            }
        }
    }

    private var navigationTitle: String {
        switch mode {
        case .new: return "New Message"
        case .reply: return "Reply"
        case .replyAll: return "Reply All"
        case .forward: return "Forward"
        case .draft: return "Draft"
        }
    }

    private func send() {
        // Auto-add any pending input in recipient fields
        viewModel.finalizeRecipients()

        Task {
            let success = await viewModel.send()
            if success {
                dismiss()
            }
        }
    }
}

// MARK: - Recipient Field

struct RecipientField: View {
    let label: String
    @Binding var recipients: [String]
    @Binding var pendingInput: String
    let isFocused: Bool

    private let labelWidth: CGFloat = 60
    private let horizontalPadding: CGFloat = 16

    @State private var suggestions: [PeopleService.Contact] = []
    @State private var showingSuggestions = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: labelWidth, alignment: .leading)
                    .padding(.top, 12)

                FlowLayout(spacing: 6) {
                    ForEach(recipients, id: \.self) { recipient in
                        RecipientChip(email: recipient) {
                            recipients.removeAll { $0 == recipient }
                        }
                    }

                    TextField("", text: $pendingInput)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .frame(minWidth: 100)
                        .onSubmit {
                            addRecipient()
                        }
                        .onChange(of: pendingInput) { _, newValue in
                            if newValue.hasSuffix(" ") || newValue.hasSuffix(",") {
                                pendingInput = String(newValue.dropLast())
                                addRecipient()
                            } else {
                                searchContacts(query: newValue)
                            }
                        }
                }
                .padding(.vertical, 8)
            }
            .padding(.horizontal, horizontalPadding)

            // Autocomplete suggestions
            if showingSuggestions && !suggestions.isEmpty && isFocused {
                HStack(spacing: 0) {
                    Spacer()
                        .frame(width: labelWidth + horizontalPadding)

                    VStack(spacing: 0) {
                        ForEach(suggestions.prefix(5)) { contact in
                            Button(action: {
                                selectContact(contact)
                            }) {
                                HStack(spacing: 10) {
                                    SmartAvatarView(
                                        email: contact.email,
                                        name: contact.name,
                                        size: 28
                                    )

                                    VStack(alignment: .leading, spacing: 1) {
                                        if !contact.name.isEmpty {
                                            Text(contact.name)
                                                .font(.subheadline)
                                                .lineLimit(1)
                                        }
                                        Text(contact.email)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }

                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if contact.id != suggestions.prefix(5).last?.id {
                                Divider()
                                    .padding(.leading, 54)
                            }
                        }
                    }
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                    .padding(.trailing, horizontalPadding)
                }
                .padding(.top, -4)
            }
        }
    }

    private func addRecipient() {
        let trimmed = pendingInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if isValidEmail(trimmed) {
            recipients.append(trimmed)
            pendingInput = ""
            showingSuggestions = false
        }
    }

    /// Validates email format: local@domain.tld
    private func isValidEmail(_ email: String) -> Bool {
        let parts = email.split(separator: "@")
        guard parts.count == 2,
              !parts[0].isEmpty,
              !parts[1].isEmpty else {
            return false
        }
        let domain = String(parts[1])
        // Domain must have at least one dot, not start/end with dot
        guard domain.contains("."),
              !domain.hasPrefix("."),
              !domain.hasSuffix(".") else {
            return false
        }
        return true
    }

    private func selectContact(_ contact: PeopleService.Contact) {
        if !recipients.contains(contact.email) {
            recipients.append(contact.email)
        }
        pendingInput = ""
        showingSuggestions = false
    }

    private func searchContacts(query: String) {
        guard query.count >= 1 else {
            suggestions = []
            showingSuggestions = false
            return
        }

        Task {
            // First try to search, which will fetch contacts if cache is empty
            let results = await PeopleService.shared.searchContacts(query: query)
            // Filter out already selected recipients
            let filtered = results.filter { !recipients.contains($0.email) }
            await MainActor.run {
                suggestions = filtered
                showingSuggestions = !filtered.isEmpty
            }
        }
    }
}

// MARK: - Recipient Chip

struct RecipientChip: View {
    let email: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(displayName)
                .font(.subheadline)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.systemGray5))
        .clipShape(Capsule())
    }

    private var displayName: String {
        if let atIndex = email.firstIndex(of: "@") {
            return String(email[..<atIndex])
        }
        return email
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)

        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .unspecified)
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = proposal.width ?? .infinity
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }

            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), frames)
    }
}

// MARK: - Rich Text Toolbar

struct RichTextToolbar: View {
    @ObservedObject var context: RichTextContext
    @State private var showingLinkPrompt = false
    @State private var linkURL = ""

    var body: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(spacing: 18) {
                Button(action: { context.toggleBold() }) {
                    Image(systemName: "bold")
                }
                Button(action: { context.toggleItalic() }) {
                    Image(systemName: "italic")
                }
                Button(action: { context.toggleUnderline() }) {
                    Image(systemName: "underline")
                }
                Button(action: { context.insertBulletList() }) {
                    Image(systemName: "list.bullet")
                }
                Button(action: { showingLinkPrompt = true }) {
                    Image(systemName: "link")
                }
                Spacer()
                Button(action: { context.toggleFontSize() }) {
                    Image(systemName: "textformat.size")
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .background(.ultraThinMaterial)
        .alert("Add Link", isPresented: $showingLinkPrompt) {
            TextField("https://example.com", text: $linkURL)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            Button("Cancel", role: .cancel) {
                linkURL = ""
            }
            Button("Add") {
                if let url = URL(string: linkURL.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    context.applyLink(url)
                }
                linkURL = ""
            }
        } message: {
            Text("Add a link to the selected text.")
        }
    }
}

// MARK: - AI Draft Sheet

enum AIDraftTone: String, CaseIterable, Identifiable {
    case professional = "Professional"
    case friendly = "Friendly"
    case direct = "Direct"

    var id: String { rawValue }
}

enum AIDraftLength: String, CaseIterable, Identifiable {
    case short = "Short"
    case medium = "Medium"
    case detailed = "Detailed"

    var id: String { rawValue }
}

struct AIDraftResult {
    let subject: String
    let body: String
}

struct AIDraftSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var tone: AIDraftTone = .professional
    @State private var length: AIDraftLength = .medium
    @State private var includeSubject = true

    let onGenerate: (String, AIDraftTone, AIDraftLength, Bool) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("What do you want to say?") {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 140)
                }

                Section("Tone") {
                    Picker("Tone", selection: $tone) {
                        ForEach(AIDraftTone.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Length") {
                    Picker("Length", selection: $length) {
                        ForEach(AIDraftLength.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Toggle("Suggest subject line", isOn: $includeSubject)
                }
            }
            .navigationTitle("AI Draft")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Generate") {
                        onGenerate(prompt, tone, length, includeSubject)
                        dismiss()
                    }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - Rich Text Editor

final class RichTextContext: ObservableObject {
    @Published var selectedRange: NSRange = NSRange(location: 0, length: 0)
    weak var textView: UITextView?
    var onTextChange: ((NSAttributedString) -> Void)?

    func toggleBold() { toggleTrait(.traitBold) }
    func toggleItalic() { toggleTrait(.traitItalic) }

    func toggleUnderline() {
        applyAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue)
    }

    func applyLink(_ url: URL) {
        applyAttribute(.link, value: url)
    }

    func toggleFontSize() {
        guard let textView = textView else { return }
        let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
        let range = textView.selectedRange

        let styles: [UIFont.TextStyle] = [.body, .headline, .title3]

        if range.length > 0 {
            mutable.enumerateAttribute(.font, in: range, options: []) { value, range, _ in
                let currentFont = (value as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
                let nextStyle = nextStyleFor(font: currentFont, styles: styles)
                let nextFont = UIFont.preferredFont(forTextStyle: nextStyle)
                mutable.addAttribute(.font, value: nextFont, range: range)
            }
            textView.attributedText = mutable
            textView.selectedRange = range
            onTextChange?(mutable)
        } else {
            let currentFont = currentFont(from: textView)
            let nextStyle = nextStyleFor(font: currentFont, styles: styles)
            let nextFont = UIFont.preferredFont(forTextStyle: nextStyle)
            textView.typingAttributes[.font] = nextFont
        }
    }

    func clearFormatting() {
        guard let textView = textView else { return }
        let font = UIFont.preferredFont(forTextStyle: .body)
        let mutable = NSMutableAttributedString(string: textView.text ?? "", attributes: [.font: font])
        textView.attributedText = mutable
        textView.typingAttributes = [.font: font]
        onTextChange?(mutable)
    }

    func insertBulletList() {
        guard let textView = textView else { return }
        let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
        let full = mutable.string as NSString
        var range = textView.selectedRange
        if range.length == 0 {
            range = full.lineRange(for: NSRange(location: range.location, length: 0))
        } else {
            range = full.paragraphRange(for: range)
        }

        var index = range.location
        while index < range.location + range.length {
            let lineRange = full.lineRange(for: NSRange(location: index, length: 0))
            let lineText = full.substring(with: lineRange)
            if !lineText.hasPrefix("• ") {
                mutable.insert(NSAttributedString(string: "• "), at: lineRange.location)
                range.length += 2
            }
            index = lineRange.location + lineRange.length + 2
        }

        textView.attributedText = mutable
        textView.selectedRange = NSRange(location: range.location + range.length, length: 0)
        onTextChange?(mutable)
    }

    private func toggleTrait(_ trait: UIFontDescriptor.SymbolicTraits) {
        guard let textView = textView else { return }
        let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
        let range = textView.selectedRange
        let font = currentFont(from: textView)

        if range.length > 0 {
            mutable.enumerateAttribute(.font, in: range, options: []) { value, range, _ in
                let baseFont = (value as? UIFont) ?? font
                let newFont = toggledFont(baseFont, trait: trait)
                mutable.addAttribute(.font, value: newFont, range: range)
            }
            textView.attributedText = mutable
            textView.selectedRange = range
            onTextChange?(mutable)
        } else {
            let newFont = toggledFont(font, trait: trait)
            textView.typingAttributes[.font] = newFont
        }
    }

    private func applyAttribute(_ key: NSAttributedString.Key, value: Any) {
        guard let textView = textView else { return }
        let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
        let range = textView.selectedRange
        if range.length > 0 {
            mutable.addAttribute(key, value: value, range: range)
            textView.attributedText = mutable
            textView.selectedRange = range
            onTextChange?(mutable)
        } else {
            textView.typingAttributes[key] = value
        }
    }

    private func currentFont(from textView: UITextView) -> UIFont {
        if let font = textView.typingAttributes[.font] as? UIFont {
            return font
        }
        return UIFont.preferredFont(forTextStyle: .body)
    }

    private func nextStyleFor(font: UIFont, styles: [UIFont.TextStyle]) -> UIFont.TextStyle {
        let currentStyle = styles.first { UIFont.preferredFont(forTextStyle: $0).fontName == font.fontName } ?? .body
        if let index = styles.firstIndex(of: currentStyle) {
            let nextIndex = (index + 1) % styles.count
            return styles[nextIndex]
        }
        return .body
    }

    private func toggledFont(_ font: UIFont, trait: UIFontDescriptor.SymbolicTraits) -> UIFont {
        var traits = font.fontDescriptor.symbolicTraits
        if traits.contains(trait) {
            traits.remove(trait)
        } else {
            traits.insert(trait)
        }
        if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
            return UIFont(descriptor: descriptor, size: font.pointSize)
        }
        return font
    }
}

struct RichTextEditor: UIViewRepresentable {
    @Binding var attributedText: NSAttributedString
    @ObservedObject var context: RichTextContext

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.delegate = context.coordinator
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        self.context.textView = textView
        self.context.onTextChange = { updated in
            self.attributedText = updated
        }
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if !textView.attributedText.isEqual(attributedText) {
            textView.attributedText = attributedText
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UITextViewDelegate {
        let parent: RichTextEditor

        init(_ parent: RichTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.attributedText = textView.attributedText
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.context.selectedRange = textView.selectedRange
        }
    }
}

// MARK: - Sending Overlay

struct SendingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                Text("Sending...")
                    .font(.headline)
            }
            .padding(32)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }
}

struct StatusOverlay: View {
    let title: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                Text(title)
                    .font(.headline)
            }
            .padding(32)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }
}

// MARK: - Compose ViewModel

@MainActor
class ComposeViewModel: ObservableObject {
    @Published var to: [String] = []
    @Published var cc: [String] = []
    @Published var bcc: [String] = []
    @Published var subject: String = ""
    @Published var bodyAttributed: NSAttributedString = ComposeViewModel.attributedBody(from: "")

    // Pending input in recipient text fields
    @Published var pendingToInput: String = ""
    @Published var pendingCcInput: String = ""
    @Published var pendingBccInput: String = ""

    @Published var showCcBcc = false
    @Published var showAttachmentPicker = false
    @Published var showDiscardAlert = false
    @Published var isSending = false
    @Published var isGeneratingDraft = false
    @Published var aiDraftError: String?
    @Published var error: Error?

    private var replyToMessageId: String?
    private var replyThreadId: String?
    private var draftId: String?

    var hasContent: Bool {
        !to.isEmpty || !subject.isEmpty || !bodyAttributed.string.isEmpty
    }

    var canSend: Bool {
        let hasRecipient = !to.isEmpty || pendingToInput.contains("@")
        return hasRecipient && (!subject.isEmpty || !bodyAttributed.string.isEmpty)
    }

    /// Adds any pending text in recipient fields to the recipient arrays
    func finalizeRecipients() {
        addPendingRecipient(&pendingToInput, to: &to)
        addPendingRecipient(&pendingCcInput, to: &cc)
        addPendingRecipient(&pendingBccInput, to: &bcc)
    }

    private func addPendingRecipient(_ pending: inout String, to recipients: inout [String]) {
        let trimmed = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        if isValidEmail(trimmed) {
            recipients.append(trimmed)
            pending = ""
        }
    }

    /// Validates email format: local@domain.tld
    private func isValidEmail(_ email: String) -> Bool {
        let parts = email.split(separator: "@")
        guard parts.count == 2,
              !parts[0].isEmpty,
              !parts[1].isEmpty else {
            return false
        }
        let domain = String(parts[1])
        // Domain must have at least one dot, not start/end with dot
        guard domain.contains("."),
              !domain.hasPrefix("."),
              !domain.hasSuffix(".") else {
            return false
        }
        return true
    }

    init(mode: ComposeMode) {
        switch mode {
        case .new:
            break

        case .reply(let email, let threadId):
            let senderEmail = EmailParser.extractSenderEmail(from: email.from)
            to = [senderEmail]
            subject = email.subject.hasPrefix("Re:") ? email.subject : "Re: \(email.subject)"
            bodyAttributed = Self.attributedBody(from: buildQuotedReply(email))
            replyThreadId = threadId
            replyToMessageId = email.id

        case .replyAll(let email, let threadId):
            let senderEmail = EmailParser.extractSenderEmail(from: email.from)
            to = [senderEmail]
            cc = email.cc
            subject = email.subject.hasPrefix("Re:") ? email.subject : "Re: \(email.subject)"
            bodyAttributed = Self.attributedBody(from: buildQuotedReply(email))
            replyThreadId = threadId
            replyToMessageId = email.id

        case .forward(let email):
            subject = email.subject.hasPrefix("Fwd:") ? email.subject : "Fwd: \(email.subject)"
            bodyAttributed = Self.attributedBody(from: buildForwardedMessage(email))

        case .draft(let id, let toAddrs, let subj, let bodyText):
            draftId = id
            to = toAddrs
            subject = subj
            bodyAttributed = Self.attributedBody(from: bodyText)
        }
    }

    func send() async -> Bool {
        isSending = true
        defer { isSending = false }

        do {
            _ = try await GmailService.shared.sendEmail(
                to: to,
                cc: cc,
                bcc: bcc,
                subject: subject,
                body: plainBody(),
                bodyHtml: htmlBody(),
                inReplyTo: replyToMessageId,
                threadId: replyThreadId
            )

            // Delete draft if exists
            if let draftId = draftId {
                try? await GmailService.shared.deleteDraft(draftId: draftId)
            }

            // Haptic feedback
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)

            return true
        } catch {
            self.error = error
            return false
        }
    }

    func saveDraft() async {
        do {
            _ = try await GmailService.shared.saveDraft(
                to: to,
                subject: subject,
                body: plainBody(),
                existingDraftId: draftId
            )
        } catch {
            self.error = error
        }
    }

    @MainActor
    func applyAIDraft(prompt: String, tone: AIDraftTone, length: AIDraftLength, includeSubject: Bool) async {
        isGeneratingDraft = true
        aiDraftError = nil
        defer { isGeneratingDraft = false }

        do {
            let draft = try await generateAIDraft(prompt: prompt, tone: tone, length: length)
            if includeSubject, !draft.subject.isEmpty {
                subject = draft.subject
            }
            bodyAttributed = Self.attributedBody(from: draft.body)
        } catch {
            aiDraftError = "Apple Intelligence is unavailable right now."
        }
    }

    private func buildQuotedReply(_ email: EmailDetail) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        let dateStr = dateFormatter.string(from: email.date)

        let senderName = EmailParser.extractSenderName(from: email.from)

        return "\n\nOn \(dateStr), \(senderName) wrote:\n> \(email.body.replacingOccurrences(of: "\n", with: "\n> "))"
    }

    private func buildForwardedMessage(_ email: EmailDetail) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        let dateStr = dateFormatter.string(from: email.date)

        return """

        ---------- Forwarded message ---------
        From: \(email.from)
        Date: \(dateStr)
        Subject: \(email.subject)
        To: \(email.to.joined(separator: ", "))

        \(email.body)
        """
    }

    private func plainBody() -> String {
        bodyAttributed.string
    }

    private func htmlBody() -> String? {
        let range = NSRange(location: 0, length: bodyAttributed.length)
        let documentAttributes: [NSAttributedString.DocumentAttributeKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html
        ]
        if let data = try? bodyAttributed.data(from: range, documentAttributes: documentAttributes),
           let html = String(data: data, encoding: .utf8) {
            return html
        }
        return nil
    }

    private static func attributedBody(from text: String) -> NSAttributedString {
        let font = UIFont.preferredFont(forTextStyle: .body)
        return NSAttributedString(string: text, attributes: [.font: font])
    }

    private func generateAIDraft(prompt: String, tone: AIDraftTone, length: AIDraftLength) async throws -> AIDraftResult {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let session = LanguageModelSession()
            let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let toneValue = tone.rawValue
            let lengthValue = length.rawValue
            let instruction = """
            You are writing an email draft. Tone: \(toneValue). Length: \(lengthValue).
            Output exactly:
            Subject: <subject line>
            Body:
            <email body>

            Prompt:
            \(trimmed)
            """
            let response = try await session.respond(to: instruction)
            let text = String(describing: response.content)
            return parseAIDraft(text)
        }
        #endif
        throw DraftError.unavailable
    }

    private func parseAIDraft(_ text: String) -> AIDraftResult {
        let cleaned = text
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var subject = ""
        var body = cleaned

        if let subjectRange = cleaned.range(of: "Subject:", options: .caseInsensitive),
           let bodyRange = cleaned.range(of: "Body:", options: .caseInsensitive) {
            subject = cleaned[subjectRange.upperBound..<bodyRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            body = cleaned[bodyRange.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return AIDraftResult(subject: subject, body: body)
    }

    private enum DraftError: Error {
        case unavailable
    }
}

// MARK: - Preview

#Preview {
    ComposeView()
}
