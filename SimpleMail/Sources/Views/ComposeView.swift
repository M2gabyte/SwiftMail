import SwiftUI

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

                    // Body
                    TextEditor(text: $viewModel.body)
                        .frame(minHeight: 300)
                        .padding(.horizontal)
                        .focused($focusedField, equals: .body)
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if viewModel.hasContent {
                            viewModel.showDiscardAlert = true
                        } else {
                            dismiss()
                        }
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
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
                }
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

    @State private var suggestions: [PeopleService.Contact] = []
    @State private var showingSuggestions = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
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
            .padding(.horizontal)

            // Autocomplete suggestions
            if showingSuggestions && !suggestions.isEmpty && isFocused {
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
                .padding(.horizontal, 76) // Align with text field
                .padding(.top, -4)
            }
        }
    }

    private func addRecipient() {
        let trimmed = pendingInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed.contains("@") {
            recipients.append(trimmed)
            pendingInput = ""
            showingSuggestions = false
        }
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

// MARK: - Compose ViewModel

@MainActor
class ComposeViewModel: ObservableObject {
    @Published var to: [String] = []
    @Published var cc: [String] = []
    @Published var bcc: [String] = []
    @Published var subject: String = ""
    @Published var body: String = ""

    // Pending input in recipient text fields
    @Published var pendingToInput: String = ""
    @Published var pendingCcInput: String = ""
    @Published var pendingBccInput: String = ""

    @Published var showCcBcc = false
    @Published var showAttachmentPicker = false
    @Published var showDiscardAlert = false
    @Published var isSending = false
    @Published var error: Error?

    private var replyToMessageId: String?
    private var replyThreadId: String?
    private var draftId: String?

    var hasContent: Bool {
        !to.isEmpty || !subject.isEmpty || !body.isEmpty
    }

    var canSend: Bool {
        let hasRecipient = !to.isEmpty || pendingToInput.contains("@")
        return hasRecipient && (!subject.isEmpty || !body.isEmpty)
    }

    /// Adds any pending text in recipient fields to the recipient arrays
    func finalizeRecipients() {
        addPendingRecipient(&pendingToInput, to: &to)
        addPendingRecipient(&pendingCcInput, to: &cc)
        addPendingRecipient(&pendingBccInput, to: &bcc)
    }

    private func addPendingRecipient(_ pending: inout String, to recipients: inout [String]) {
        let trimmed = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed.contains("@") {
            recipients.append(trimmed)
            pending = ""
        }
    }

    init(mode: ComposeMode) {
        switch mode {
        case .new:
            break

        case .reply(let email, let threadId):
            let senderEmail = EmailParser.extractSenderEmail(from: email.from)
            to = [senderEmail]
            subject = email.subject.hasPrefix("Re:") ? email.subject : "Re: \(email.subject)"
            body = buildQuotedReply(email)
            replyThreadId = threadId
            replyToMessageId = email.id

        case .replyAll(let email, let threadId):
            let senderEmail = EmailParser.extractSenderEmail(from: email.from)
            to = [senderEmail]
            cc = email.cc
            subject = email.subject.hasPrefix("Re:") ? email.subject : "Re: \(email.subject)"
            body = buildQuotedReply(email)
            replyThreadId = threadId
            replyToMessageId = email.id

        case .forward(let email):
            subject = email.subject.hasPrefix("Fwd:") ? email.subject : "Fwd: \(email.subject)"
            body = buildForwardedMessage(email)

        case .draft(let id, let toAddrs, let subj, let bodyText):
            draftId = id
            to = toAddrs
            subject = subj
            body = bodyText
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
                body: body,
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
                body: body,
                existingDraftId: draftId
            )
        } catch {
            self.error = error
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
}

// MARK: - Preview

#Preview {
    ComposeView()
}
