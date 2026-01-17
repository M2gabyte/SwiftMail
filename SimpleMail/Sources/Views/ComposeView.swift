import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import OSLog
#if canImport(FoundationModels)
import FoundationModels
#endif

private let logger = Logger(subsystem: "com.simplemail.app", category: "ComposeView")

// MARK: - Compose Mode

enum ComposeMode: Identifiable {
    case new
    case reply(to: EmailDetail, threadId: String)
    case replyAll(to: EmailDetail, threadId: String)
    case forward(original: EmailDetail)
    case draft(id: String, to: [String], subject: String, body: String)
    case restoredDraft(
        draftId: String?,
        to: [String],
        cc: [String],
        bcc: [String],
        subject: String,
        body: String,
        bodyHtml: String?,
        inReplyTo: String?,
        threadId: String?
    )

    var id: String {
        switch self {
        case .new: return "new"
        case .reply(let email, _): return "reply-\(email.id)"
        case .replyAll(let email, _): return "replyAll-\(email.id)"
        case .forward(let email): return "forward-\(email.id)"
        case .draft(let id, _, _, _): return "draft-\(id)"
        case .restoredDraft(let draftId, _, _, _, _, _, _, _, _): return "restored-\(draftId ?? UUID().uuidString)"
        }
    }
}

// MARK: - Compose View

struct ComposeView: View {
    let mode: ComposeMode

    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: ComposeViewModel
    @FocusState private var focusedField: Field?
    @StateObject private var richTextContext = RichTextContext()
    @State private var editingBody: NSAttributedString = NSAttributedString()
    @State private var showingAIDraft = false
    @State private var showingTemplates = false
    @State private var showingScheduleSheet = false
    @State private var showingAttachmentOptions = false
    @State private var showingFileImporter = false
    @State private var showingPhotoPicker = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showUndoToast = false
    @State private var keyboardHeight: CGFloat = 0

    enum Field: Hashable {
        case to, cc, bcc, subject, body
    }

    init(mode: ComposeMode = .new) {
        self.mode = mode
        self._viewModel = StateObject(wrappedValue: ComposeViewModel(mode: mode))
    }

    var body: some View {
        composeRoot
    }

    private var composeRoot: some View {
        let content = applyToolbar(to: applyNavigation(to: composeContent))
        let base = NavigationStack { content }
        let overlays = applyOverlays(to: base)
        let sheets = applySheets(to: overlays)
        return applyObservers(to: sheets)
    }

    private func applyNavigation<V: View>(to view: V) -> some View {
        view
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("composeView")
    }

    private func applyToolbar<V: View>(to view: V) -> some View {
        view.toolbar { composeToolbar }
    }

    private func applyOverlays<V: View>(to view: V) -> some View {
        view
            .overlay { composeOverlay }
            .overlay(alignment: .bottomTrailing) {
                GeometryReader { geometry in
                    RichTextToolbar(
                        context: richTextContext,
                        onAttachment: { viewModel.showAttachmentPicker = true },
                        keyboardHeight: keyboardHeight,
                        safeAreaBottom: geometry.safeAreaInsets.bottom
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
                .ignoresSafeArea(.keyboard)
            }
    }

    private var isReplyMode: Bool {
        switch mode {
        case .reply, .replyAll: return true
        default: return false
        }
    }

    private func applySheets<V: View>(to view: V) -> some View {
        view
            .sheet(isPresented: $showingAIDraft) {
                let allowSubject = !isReplyMode
                AIDraftSheet(
                    allowSubjectToggle: allowSubject,
                    defaultIncludeSubject: allowSubject
                ) { prompt, tone, length, includeSubject in
                    let resolvedInclude = allowSubject ? includeSubject : false
                    Task {
                        await viewModel.generateAIDraftPreview(
                            prompt: prompt,
                            tone: tone,
                            length: length,
                            includeSubject: resolvedInclude
                        )
                    }
                }
            }
            .sheet(item: $viewModel.pendingAIDraft) { draft in
                AIDraftPreviewSheet(
                    draft: draft,
                    applySubject: viewModel.pendingAIDraftIncludeSubject
                ) {
                    let include = (!isReplyMode) && viewModel.pendingAIDraftIncludeSubject ? true : false
                    viewModel.applyAIDraftResult(draft, includeSubject: include)
                    let attributed = ComposeViewModel.attributedBody(from: draft.body)
                    editingBody = attributed
                    viewModel.bodyAttributed = attributed
                }
            }
            .sheet(isPresented: $showingTemplates) {
                TemplatesSheet(
                    templates: viewModel.templates,
                    defaultBody: editingBody.string,
                    onInsert: { template in
                        viewModel.appendTemplate(template)
                    },
                    onAdd: { title, body in
                        viewModel.addTemplate(title: title, body: body)
                    },
                    onDelete: { offsets in
                        viewModel.removeTemplates(at: offsets)
                    }
                )
            }
            .sheet(isPresented: $showingScheduleSheet) {
                ScheduleSendSheet { date in
                    viewModel.scheduleSend(at: date)
                    dismiss()
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
            .confirmationDialog("Add Attachment", isPresented: $showingAttachmentOptions) {
                Button("Photo Library") { showingPhotoPicker = true }
                Button("Files") { showingFileImporter = true }
            }
            .photosPicker(isPresented: $showingPhotoPicker, selection: $selectedPhotos)
            .onChange(of: selectedPhotos) { _, newItems in
                Task {
                    for item in newItems {
                        if let data = try? await item.loadTransferable(type: Data.self) {
                            let type = item.supportedContentTypes.first
                            let mimeType = type?.preferredMIMEType ?? "image/jpeg"
                            let ext = type?.preferredFilenameExtension ?? "jpg"
                            let filename = "Photo-\(UUID().uuidString.prefix(6)).\(ext)"
                            viewModel.addAttachment(data: data, filename: filename, mimeType: mimeType)
                        }
                    }
                    selectedPhotos = []
                }
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [UTType.data],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    Task {
                        for url in urls {
                            if let data = try? Data(contentsOf: url) {
                                let filename = url.lastPathComponent
                                let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                                viewModel.addAttachment(data: data, filename: filename, mimeType: mimeType)
                            }
                        }
                    }
                case .failure:
                    break
                }
            }
            .alert("Discard Draft?", isPresented: $viewModel.showDiscardAlert) {
                Button("Discard", role: .destructive) {
                    // Dismiss immediately - delete draft in background (non-blocking)
                    let draftToDelete = viewModel.discardLocally()
                    dismiss()

                    // Fire-and-forget deletion
                    if let id = draftToDelete {
                        Task { try? await GmailService.shared.deleteDraft(draftId: id) }
                    }
                }
                Button("Save Draft") {
                    Task {
                        await viewModel.saveDraft()
                        viewModel.cancelAutoSave()
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .onDisappear {
                viewModel.cancelAutoSave()
            }
    }

    private func applyObservers<V: View>(to view: V) -> some View {
        view
            .onChange(of: viewModel.showAttachmentPicker) { _, newValue in
                if newValue {
                    showingAttachmentOptions = true
                    viewModel.showAttachmentPicker = false
                }
            }
            .onChange(of: viewModel.subject) { _, _ in
                viewModel.markUserEdited()
                viewModel.scheduleAutoSave()
            }
            .onChange(of: editingBody) { _, newValue in
                viewModel.bodyAttributed = newValue
                viewModel.markUserEdited()
                viewModel.scheduleAutoSave()
            }
            .onChange(of: viewModel.to) { _, _ in
                viewModel.markUserEdited()
                viewModel.scheduleAutoSave()
            }
            .onChange(of: viewModel.cc) { _, _ in
                viewModel.markUserEdited()
                viewModel.scheduleAutoSave()
            }
            .onChange(of: viewModel.bcc) { _, _ in
                viewModel.markUserEdited()
                viewModel.scheduleAutoSave()
            }
            .task {
                // Mark as seeding to prevent auto-save from triggering on programmatic changes
                viewModel.isSeedingBody = true
                defer { viewModel.isSeedingBody = false }

                if editingBody.string.isEmpty {
                    editingBody = viewModel.bodyAttributed
                }
                if let rich = await viewModel.loadDeferredBody() {
                    await MainActor.run {
                        editingBody = rich
                        viewModel.bodyAttributed = rich
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
                if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                    keyboardHeight = frame.height
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardHeight = 0
            }
    }

    private var composeContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                if viewModel.isRecoveredDraft {
                    RecoveredDraftBanner()
                        .padding(.horizontal)
                        .padding(.top, 6)
                }
                // To field
                RecipientField(
                    label: "To",
                    recipients: $viewModel.to,
                    pendingInput: $viewModel.pendingToInput,
                    isFocused: focusedField == .to,
                    showToggle: false
                )
                .focused($focusedField, equals: .to)

                Divider().padding(.leading)

                // Cc/Bcc/From toggle row (collapsed) or individual fields (expanded)
                if !viewModel.showCcBcc {
                    Button(action: { viewModel.showCcBcc = true }) {
                        HStack(spacing: 8) {
                            Text("Cc/Bcc, From:")
                                .font(.body)
                                .foregroundStyle(.secondary)
                            Text(viewModel.fromEmail)
                                .font(.body)
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Divider().padding(.leading)
                } else {
                    RecipientField(
                        label: "Cc",
                        recipients: $viewModel.cc,
                        pendingInput: $viewModel.pendingCcInput,
                        isFocused: focusedField == .cc,
                        showToggle: false
                    )
                    .focused($focusedField, equals: .cc)

                    Divider().padding(.leading)

                    RecipientField(
                        label: "Bcc",
                        recipients: $viewModel.bcc,
                        pendingInput: $viewModel.pendingBccInput,
                        isFocused: focusedField == .bcc,
                        showToggle: false
                    )
                    .focused($focusedField, equals: .bcc)

                    Divider().padding(.leading)

                    HStack {
                        Text("From")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: 60, alignment: .leading)
                        Text(viewModel.fromEmail)
                            .font(.body)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    Divider().padding(.leading)
                }

                // Subject
                HStack {
                    Text("Subject")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    TextField("", text: $viewModel.subject)
                        .font(.body)
                        .textInputAutocapitalization(.sentences)
                        .focused($focusedField, equals: .subject)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider().padding(.leading)

                if !viewModel.attachments.isEmpty {
                    AttachmentPreviewRow(
                        attachments: viewModel.attachments,
                        onRemove: { attachment in
                            viewModel.removeAttachment(attachment)
                        }
                    )
                    .padding(.horizontal)
                    Divider().padding(.leading)
                }

                // Body (rich text)
                ZStack(alignment: .topLeading) {
                    RichTextEditor(
                        attributedText: $editingBody,
                        context: richTextContext
                    )
                    .frame(minHeight: 300)
                    .focused($focusedField, equals: .body)

                    if editingBody.string.isEmpty {
                        Text("Write your message…")
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.leading, 6)
                    }
                }
                .padding(.horizontal)
            }
        }
        .task {
            // Guard programmatic body initialization
            viewModel.isSeedingBody = true
            defer { viewModel.isSeedingBody = false }

            if editingBody.string.isEmpty {
                editingBody = viewModel.bodyAttributed
            }
        }
    }

    @ToolbarContentBuilder
    private var composeToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                if viewModel.hasContent {
                    viewModel.showDiscardAlert = true
                } else {
                    dismiss()
                }
            } label: {
                Text("Cancel")
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("cancelCompose")
        }

        ToolbarItem(placement: .principal) {
            Text(navigationTitle)
                .font(.headline)
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button(action: { showingTemplates = true }) {
                    Label("Templates", systemImage: "doc.text")
                }

                Button(action: { showingScheduleSheet = true }) {
                    Label("Schedule Send", systemImage: "clock")
                }
                .disabled(!viewModel.canSend)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 17))
                    .accessibilityLabel("More options")
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button(action: { showingAIDraft = true }) {
                Image(systemName: "sparkles")
                    .font(.system(size: 17))
            }
            .accessibilityLabel("AI Draft")
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button(action: send) {
                Image(systemName: "paperplane.circle.fill")
                    .font(.title2)
                    .foregroundStyle(viewModel.canSend ? Color.accentColor : .gray)
            }
            .disabled(!viewModel.canSend)
            .accessibilityIdentifier("sendButton")
        }
    }

    @ViewBuilder
    private var composeOverlay: some View {
        if viewModel.isSending {
            SendingOverlay()
        } else if viewModel.isGeneratingDraft {
            StatusOverlay(title: "Drafting...")
        }
    }

    private var navigationTitle: String {
        switch mode {
        case .new: return "New Message"
        case .reply: return "Reply"
        case .replyAll: return "Reply All"
        case .forward: return "Forward"
        case .draft, .restoredDraft: return "Draft"
        }
    }

    private func send() {
        // Auto-add any pending input in recipient fields
        viewModel.finalizeRecipients()

        // Set dismiss callback
        viewModel.dismissAfterQueue = {
            dismiss()
        }

        viewModel.queueSendWithUndo()
    }
}

// MARK: - Recipient Field Helpers

private struct RecipientToken {
    let token: String   // what user is typing right now (e.g. "mark.marge@g")
    let prefix: String  // text before the token (e.g. "anna@x.com, ")
}

/// Returns the active token after last delimiter (comma/semicolon/newline)
private func extractActiveToken(from input: String) -> RecipientToken {
    let delimiters = CharacterSet(charactersIn: ",;\n")
    if let range = input.rangeOfCharacter(from: delimiters, options: .backwards) {
        let after = input[range.upperBound...]
        return RecipientToken(
            token: after.trimmingCharacters(in: .whitespacesAndNewlines),
            prefix: String(input[..<range.upperBound])
        )
    } else {
        return RecipientToken(
            token: input.trimmingCharacters(in: .whitespacesAndNewlines),
            prefix: ""
        )
    }
}

private func isValidEmailFormat(_ s: String) -> Bool {
    let pattern = #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#
    return s.range(of: pattern, options: .regularExpression) != nil
}

private func shouldCommitOnSpace(token: String) -> Bool {
    return isValidEmailFormat(token)
}

private func isEmailMode(_ token: String) -> Bool {
    if token.contains("@") { return true }
    // If they typed something like "mark.marge" treat as email-ish
    if token.contains(".") && !token.contains(" ") { return true }
    return false
}

private func normalizeEmail(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

private func emailScore(email: String, token: String, isSelf: Bool) -> Int {
    let e = normalizeEmail(email)
    let q = normalizeEmail(token)

    if e == q { return 1_000_000 + (isSelf ? 10_000 : 0) }
    if e.hasPrefix(q) { return 900_000 + q.count * 100 + (isSelf ? 10_000 : 0) }

    // local-part prefix
    if let at = e.firstIndex(of: "@") {
        let local = String(e[..<at])
        if local.hasPrefix(q) { return 800_000 + q.count * 100 + (isSelf ? 10_000 : 0) }
    }

    // substring last (never outrank prefix)
    if let idx = e.range(of: q)?.lowerBound {
        let dist = e.distance(from: e.startIndex, to: idx)
        return 700_000 - dist
    }

    return 0
}

// MARK: - Recipient Suggestion

struct RecipientSuggestion: Identifiable, Equatable {
    let id: String
    let name: String?
    let email: String
    let isTyped: Bool  // true if this is the "Use exactly what I typed" suggestion

    init(from contact: PeopleService.Contact) {
        self.id = contact.id
        self.name = contact.name.isEmpty ? nil : contact.name
        self.email = contact.email
        self.isTyped = false
    }

    init(typedEmail: String) {
        self.id = "typed-\(typedEmail)"
        self.name = nil
        self.email = typedEmail
        self.isTyped = true
    }
}

private func rankAndDedupe(
    results: [PeopleService.Contact],
    queryToken: String,
    myEmails: [String],
    alreadySelected: [String]
) -> [RecipientSuggestion] {
    let q = queryToken.trimmingCharacters(in: .whitespacesAndNewlines)
    let emailMode = isEmailMode(q)
    let mySet = Set(myEmails.map(normalizeEmail))
    let selectedSet = Set(alreadySelected.map(normalizeEmail))

    // Dedupe by normalized email
    var bestByEmail: [String: PeopleService.Contact] = [:]
    for r in results {
        let key = normalizeEmail(r.email)
        // Skip already selected recipients
        if selectedSet.contains(key) { continue }

        if bestByEmail[key] == nil {
            bestByEmail[key] = r
        } else {
            // Prefer contact with a name if duplicate
            let existing = bestByEmail[key]!
            if existing.name.isEmpty && !r.name.isEmpty {
                bestByEmail[key] = r
            }
        }
    }

    var deduped = Array(bestByEmail.values)

    // If user is typing an email, do email-first scoring
    if emailMode {
        deduped.sort {
            let aSelf = mySet.contains(normalizeEmail($0.email))
            let bSelf = mySet.contains(normalizeEmail($1.email))
            let sa = emailScore(email: $0.email, token: q, isSelf: aSelf)
            let sb = emailScore(email: $1.email, token: q, isSelf: bSelf)

            if sa != sb { return sa > sb }
            // stable tie-breakers
            if $0.email != $1.email { return $0.email.lowercased() < $1.email.lowercased() }
            return $0.name < $1.name
        }

        // Hard filter: if token contains '@', drop non-matching emails
        if q.contains("@") {
            deduped = deduped.filter { normalizeEmail($0.email).contains(normalizeEmail(q)) }
        }

        var suggestions = deduped.prefix(5).map { RecipientSuggestion(from: $0) }

        // Add "use exactly what I typed" if valid email and not already in list
        if isValidEmailFormat(q) {
            let normalizedQ = normalizeEmail(q)
            let alreadyInList = suggestions.contains { normalizeEmail($0.email) == normalizedQ }
            let alreadySelected = selectedSet.contains(normalizedQ)
            if !alreadyInList && !alreadySelected {
                suggestions.insert(RecipientSuggestion(typedEmail: q), at: 0)
            }
        }

        return Array(suggestions.prefix(5))
    }

    // Non-email mode: simple name/email sorting
    deduped.sort { ($0.name.isEmpty ? $0.email : $0.name) < ($1.name.isEmpty ? $1.email : $1.name) }
    return Array(deduped.prefix(5).map { RecipientSuggestion(from: $0) })
}

private func commitTokenIfNeeded(
    _ input: String,
    addRecipient: (String) -> Void
) -> (newInput: String, committed: Bool) {
    guard let last = input.last else { return (input, false) }

    if last == "," || last == ";" || last == "\n" {
        let dropped = String(input.dropLast())
        let tok = extractActiveToken(from: dropped).token
        if !tok.isEmpty && isValidEmailFormat(tok) {
            addRecipient(tok)
            return (extractActiveToken(from: dropped).prefix, true)
        }
        // Even if not valid, drop the delimiter
        return (dropped, false)
    }

    if last == " " {
        let dropped = String(input.dropLast())
        let tok = extractActiveToken(from: dropped).token
        if shouldCommitOnSpace(token: tok) {
            addRecipient(tok)
            return (extractActiveToken(from: dropped).prefix, true)
        }
        return (input, false)
    }

    return (input, false)
}

// MARK: - Recipient Field

struct RecipientField: View {
    let label: String
    @Binding var recipients: [String]
    @Binding var pendingInput: String
    let isFocused: Bool
    let showToggle: Bool

    private let labelWidth: CGFloat = 60
    private let horizontalPadding: CGFloat = 16

    @State private var suggestions: [RecipientSuggestion] = []
    @State private var showingSuggestions = false
    @State private var searchTask: Task<Void, Never>?
    @State private var lastIssuedQuery: String = ""

    @FocusState private var textFieldFocused: Bool

    /// Current user's email addresses for ranking
    private var myAccountEmails: [String] {
        if let email = AuthService.shared.currentAccount?.email {
            return [email]
        }
        return []
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Text(label)
                    .font(.body)
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
                        .font(.body)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .frame(minWidth: 100, maxWidth: .infinity)
                        .focused($textFieldFocused)
                        .onSubmit {
                            addRecipient()
                        }
                        .onChange(of: pendingInput) { _, newValue in
                            handleInputChange(newValue)
                        }
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture {
                    textFieldFocused = true
                }
            }
            .padding(.horizontal, horizontalPadding)
            .contentShape(Rectangle())
            .onTapGesture {
                textFieldFocused = true
            }

            // Autocomplete suggestions
            if showingSuggestions && !suggestions.isEmpty && isFocused {
                HStack(spacing: 0) {
                    Spacer()
                        .frame(width: labelWidth + horizontalPadding)

                    VStack(spacing: 0) {
                        ForEach(suggestions) { suggestion in
                            Button(action: {
                                selectSuggestion(suggestion)
                            }) {
                                HStack(spacing: 10) {
                                    if suggestion.isTyped {
                                        // "Use exactly what I typed" row
                                        Image(systemName: "envelope")
                                            .font(.system(size: 14))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 28, height: 28)
                                    } else {
                                        SmartAvatarView(
                                            email: suggestion.email,
                                            name: suggestion.name ?? "",
                                            size: 28
                                        )
                                    }

                                    VStack(alignment: .leading, spacing: 1) {
                                        if suggestion.isTyped {
                                            Text("Use \"\(suggestion.email)\"")
                                                .font(.subheadline)
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                        } else if let name = suggestion.name, !name.isEmpty {
                                            Text(name)
                                                .font(.subheadline)
                                                .lineLimit(1)
                                            Text(suggestion.email)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        } else {
                                            Text(suggestion.email)
                                                .font(.subheadline)
                                                .lineLimit(1)
                                        }
                                    }

                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if suggestion.id != suggestions.last?.id {
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

    private func handleInputChange(_ newValue: String) {
        // First check if we should commit a token
        let (newInput, committed) = commitTokenIfNeeded(newValue) { email in
            if !recipients.contains(email) {
                recipients.append(email)
            }
        }

        if committed {
            pendingInput = newInput
            suggestions = []
            showingSuggestions = false
            return
        }

        // Extract the active token for searching
        let token = extractActiveToken(from: newValue).token

        // Don't search empty tokens
        if token.isEmpty {
            suggestions = []
            showingSuggestions = false
            return
        }

        // Cancel previous search and debounce
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            // 150ms debounce
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }

            lastIssuedQuery = token
            let results = await PeopleService.shared.searchContacts(query: token)

            if Task.isCancelled { return }
            // Discard stale results if user typed more
            if lastIssuedQuery != token { return }

            let ranked = rankAndDedupe(
                results: results,
                queryToken: token,
                myEmails: myAccountEmails,
                alreadySelected: recipients
            )

            suggestions = ranked
            showingSuggestions = !ranked.isEmpty
        }
    }

    private func addRecipient() {
        let token = extractActiveToken(from: pendingInput).token
        if isValidEmailFormat(token) {
            if !recipients.contains(token) {
                recipients.append(token)
            }
            pendingInput = extractActiveToken(from: pendingInput).prefix
            suggestions = []
            showingSuggestions = false
        }
    }

    private func selectSuggestion(_ suggestion: RecipientSuggestion) {
        if !recipients.contains(suggestion.email) {
            recipients.append(suggestion.email)
        }
        // Keep the prefix (text before the active token)
        pendingInput = extractActiveToken(from: pendingInput).prefix
        suggestions = []
        showingSuggestions = false
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

// MARK: - Attachment Preview Row

struct ComposeAttachment: Identifiable, Hashable {
    let id: UUID
    let filename: String
    let mimeType: String
    let data: Data

    init(filename: String, mimeType: String, data: Data) {
        self.id = UUID()
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }

    var size: Int { data.count }
    var isImage: Bool { mimeType.hasPrefix("image/") }

    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }
}

struct AttachmentPreviewRow: View {
    let attachments: [ComposeAttachment]
    let onRemove: (ComposeAttachment) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(attachments) { attachment in
                    AttachmentChip(attachment: attachment, onRemove: { onRemove(attachment) })
                }
            }
            .padding(.vertical, 6)
        }
    }
}

struct AttachmentChip: View {
    let attachment: ComposeAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if attachment.isImage, let image = UIImage(data: attachment.data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "doc")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename)
                    .font(.caption)
                    .lineLimit(1)
                Text(attachment.formattedSize)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct RecoveredDraftBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.uturn.left")
            Text("Recovered draft")
                .font(.caption)
                .fontWeight(.medium)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemYellow).opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Rich Text Toolbar

struct RichTextToolbar: View {
    @ObservedObject var context: RichTextContext
    let onAttachment: () -> Void
    let keyboardHeight: CGFloat
    let safeAreaBottom: CGFloat

    @State private var showingFormatSheet = false

    private var bottomPadding: CGFloat {
        // When keyboard is visible, position above keyboard with small margin
        // When keyboard is hidden, use safe area + margin to clear home indicator
        if keyboardHeight > 0 {
            return keyboardHeight - safeAreaBottom + 8
        } else {
            return 16 + safeAreaBottom
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            // Aa button (Format)
            Button(action: { showingFormatSheet = true }) {
                Text("Aa")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 36)
            }
            .buttonStyle(.plain)

            // Attachment button
            Button(action: onAttachment) {
                Image(systemName: "paperclip")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 36)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.trailing, 16)
        .padding(.bottom, bottomPadding)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: keyboardHeight)
        .sheet(isPresented: $showingFormatSheet) {
            FormatSheet(context: context)
        }
    }
}

// MARK: - Format Sheet

struct FormatSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var context: RichTextContext
    @State private var selectedAlignment: TextAlignment = .leading

    private var buttonBackground: Color {
        colorScheme == .dark ? Color(white: 0.2) : Color(.systemGray5)
    }

    private var sheetBackground: Color {
        colorScheme == .dark ? Color(white: 0.12) : Color(.systemGray6)
    }

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                Text("Format")
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 4)

            // Row 1: Bold, Italic, Underline, Strikethrough
            HStack(spacing: 8) {
                FormatStyleButton(
                    label: "B",
                    font: .system(size: 18, weight: .bold),
                    isActive: context.isBold,
                    background: buttonBackground
                ) {
                    context.toggleBold()
                }

                FormatStyleButton(
                    label: "I",
                    font: .system(size: 18, weight: .regular).italic(),
                    isActive: context.isItalic,
                    background: buttonBackground
                ) {
                    context.toggleItalic()
                }

                FormatStyleButton(
                    label: "U",
                    font: .system(size: 18, weight: .regular),
                    isActive: context.isUnderline,
                    underline: true,
                    background: buttonBackground
                ) {
                    context.toggleUnderline()
                }

                FormatStyleButton(
                    label: "S",
                    font: .system(size: 18, weight: .regular),
                    strikethrough: true,
                    background: buttonBackground
                ) {
                    // Strikethrough toggle
                }
            }
            .padding(.horizontal, 16)

            // Row 2: Font, Size controls, Color
            HStack(spacing: 8) {
                Button(action: {}) {
                    HStack(spacing: 8) {
                        Text("Default Font")
                            .font(.subheadline)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(buttonBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)

                HStack(spacing: 0) {
                    Button(action: {}) {
                        Image(systemName: "minus")
                            .font(.system(size: 16, weight: .medium))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .frame(height: 24)

                    Button(action: { context.toggleFontSize() }) {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .medium))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                }
                .background(buttonBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                Button(action: {}) {
                    Circle()
                        .fill(
                            AngularGradient(
                                colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                                center: .center
                            )
                        )
                        .frame(width: 30, height: 30)
                        .overlay(
                            Circle()
                                .fill(Color.white)
                                .frame(width: 10, height: 10)
                        )
                }
                .frame(width: 44, height: 44)
                .background(buttonBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal, 16)

            // Row 3: Lists and Alignment
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    FormatIconButton(systemName: "list.bullet", background: buttonBackground) {
                        context.insertBulletList()
                    }
                    Divider().frame(height: 24)
                    FormatIconButton(systemName: "list.number", background: buttonBackground) {}
                }
                .background(buttonBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                HStack(spacing: 0) {
                    FormatIconButton(
                        systemName: "text.alignleft",
                        isActive: selectedAlignment == .leading,
                        background: buttonBackground
                    ) {
                        selectedAlignment = .leading
                    }
                    Divider().frame(height: 24)
                    FormatIconButton(
                        systemName: "text.aligncenter",
                        isActive: selectedAlignment == .center,
                        background: buttonBackground
                    ) {
                        selectedAlignment = .center
                    }
                    Divider().frame(height: 24)
                    FormatIconButton(
                        systemName: "text.alignright",
                        isActive: selectedAlignment == .trailing,
                        background: buttonBackground
                    ) {
                        selectedAlignment = .trailing
                    }
                }
                .background(buttonBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal, 16)

            // Row 4: Quote and Indent
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    FormatIconButton(systemName: "increase.quotelevel", background: buttonBackground) {}
                    Divider().frame(height: 24)
                    FormatIconButton(systemName: "decrease.quotelevel", background: buttonBackground) {}
                }
                .background(buttonBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                Spacer()

                HStack(spacing: 0) {
                    FormatIconButton(systemName: "decrease.indent", background: buttonBackground) {}
                    Divider().frame(height: 24)
                    FormatIconButton(systemName: "increase.indent", background: buttonBackground) {}
                }
                .background(buttonBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal, 16)

            Spacer()
        }
        .background(sheetBackground)
        .presentationDetents([.height(320)])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(20)
    }
}

// MARK: - Format Style Button (for B, I, U, S)

struct FormatStyleButton: View {
    let label: String
    let font: Font
    var isActive: Bool = false
    var underline: Bool = false
    var strikethrough: Bool = false
    let background: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(font)
                .underline(underline)
                .strikethrough(strikethrough)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(isActive ? Color.accentColor : background)
                .foregroundStyle(isActive ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Format Icon Button

struct FormatIconButton: View {
    let systemName: String
    var isActive: Bool = false
    let background: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 44, height: 44)
                .background(isActive ? Color.accentColor : Color.clear)
                .foregroundStyle(isActive ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
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

struct AIDraftResult: Identifiable {
    let id = UUID()
    let subject: String
    let body: String
}

struct AIDraftPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let draft: AIDraftResult
    let applySubject: Bool
    let onApply: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if applySubject {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Subject")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(draft.subject.isEmpty ? "(No subject)" : draft.subject)
                                .font(.headline)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Body")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(draft.body)
                            .font(.body)
                    }
                }
                .padding()
            }
            .navigationTitle("Preview Draft")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Insert") {
                        onApply()
                        dismiss()
                    }
                }
            }
        }
    }
}

struct AIDraftSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var tone: AIDraftTone = .professional
    @State private var length: AIDraftLength = .medium
    @State private var includeSubject: Bool

    let allowSubjectToggle: Bool
    let onGenerate: (String, AIDraftTone, AIDraftLength, Bool) -> Void

    init(
        allowSubjectToggle: Bool,
        defaultIncludeSubject: Bool,
        onGenerate: @escaping (String, AIDraftTone, AIDraftLength, Bool) -> Void
    ) {
        self.allowSubjectToggle = allowSubjectToggle
        self._includeSubject = State(initialValue: defaultIncludeSubject)
        self.onGenerate = onGenerate
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("What do you want to say?") {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 140)
                }

                Section("Tone") {
                    HStack(spacing: 8) {
                        ForEach(AIDraftTone.allCases) { option in
                            Button(action: { tone = option }) {
                                Text(option.rawValue)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule()
                                            .fill(tone == option ? Color.accentColor : Color(.systemGray6))
                                    )
                                    .foregroundStyle(tone == option ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("Length") {
                    HStack(spacing: 8) {
                        ForEach(AIDraftLength.allCases) { option in
                            Button(action: { length = option }) {
                                Text(option.rawValue)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule()
                                            .fill(length == option ? Color.accentColor : Color(.systemGray6))
                                    )
                                    .foregroundStyle(length == option ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if allowSubjectToggle {
                    Section {
                        Toggle("Suggest subject line", isOn: $includeSubject)
                    }
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

// MARK: - Templates

struct ComposeTemplate: Codable, Identifiable, Hashable {
    let id: UUID
    let title: String
    let body: String

    init(id: UUID = UUID(), title: String, body: String) {
        self.id = id
        self.title = title
        self.body = body
    }
}

struct TemplatesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showingAdd = false

    let templates: [ComposeTemplate]
    let defaultBody: String
    let onInsert: (ComposeTemplate) -> Void
    let onAdd: (String, String) -> Void
    let onDelete: (IndexSet) -> Void

    var body: some View {
        NavigationStack {
            List {
                if templates.isEmpty {
                    ContentUnavailableView(
                        "No Templates",
                        systemImage: "doc.on.doc",
                        description: Text("Save frequently used messages for quick reuse.")
                    )
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(templates) { template in
                        Button {
                            onInsert(template)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(template.title)
                                    .font(.headline)
                                Text(template.body)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .onDelete(perform: onDelete)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Templates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("New") { showingAdd = true }
                }
            }
            .sheet(isPresented: $showingAdd) {
                NewTemplateSheet(defaultBody: defaultBody) { title, body in
                    onAdd(title, body)
                }
            }
        }
    }
}

struct NewTemplateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var templateBody: String

    let onSave: (String, String) -> Void

    init(defaultBody: String, onSave: @escaping (String, String) -> Void) {
        self._templateBody = State(initialValue: defaultBody)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Template name", text: $title)
                }
                Section("Body") {
                    TextEditor(text: $templateBody)
                        .frame(minHeight: 160)
                }
            }
            .navigationTitle("New Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(title, templateBody)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - Schedule Send

struct ScheduleSendSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sendDate = Date().addingTimeInterval(60 * 15)
    let onSchedule: (Date) -> Void

    var body: some View {
        NavigationStack {
            Form {
                DatePicker(
                    "Send at",
                    selection: $sendDate,
                    in: Date().addingTimeInterval(60)...,
                    displayedComponents: [.date, .hourAndMinute]
                )
            }
            .navigationTitle("Schedule Send")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Schedule") {
                        onSchedule(sendDate)
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Rich Text Editor

@MainActor
final class RichTextContext: ObservableObject {
    @Published var selectedRange: NSRange = NSRange(location: 0, length: 0)
    @Published var isBold = false
    @Published var isItalic = false
    @Published var isUnderline = false
    weak var textView: UITextView?
    var onTextChange: ((NSAttributedString) -> Void)?
    var isUpdatingFromUIView = false
    var sessionID = UUID()

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
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isUpdatingFromUIView else { return }
                self.onTextChange?(mutable)
            }
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
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isUpdatingFromUIView else { return }
            self.onTextChange?(mutable)
        }
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
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isUpdatingFromUIView else { return }
            self.onTextChange?(mutable)
        }
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
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isUpdatingFromUIView else { return }
                self.onTextChange?(mutable)
            }
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
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isUpdatingFromUIView else { return }
                self.onTextChange?(mutable)
            }
        } else {
            textView.typingAttributes[key] = value
        }
    }

    func applySelectionState(from textView: UITextView, range: NSRange) {
        guard !isUpdatingFromUIView else { return }
        let attributes: [NSAttributedString.Key: Any]
        if range.length > 0, range.location < textView.attributedText.length {
            attributes = textView.attributedText.attributes(at: range.location, effectiveRange: nil)
        } else {
            attributes = textView.typingAttributes
        }

        let font = (attributes[.font] as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
        let traits = font.fontDescriptor.symbolicTraits
        let bold = traits.contains(.traitBold)
        let italic = traits.contains(.traitItalic)
        let underline = (attributes[.underlineStyle] as? Int).map { $0 != 0 } ?? false

        if isBold != bold { isBold = bold }
        if isItalic != italic { isItalic = italic }
        if isUnderline != underline { isUnderline = underline }
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

// MARK: - Growing Text View

class GrowingTextView: UITextView {
    /// Initialize with explicit TextKit 1 stack to prevent mid-use compatibility mode switches.
    /// UITextView defaults to TextKit 2 but switches to TextKit 1 when certain attributes are used,
    /// which causes "switching to TextKit 1 compatibility mode" warnings and potential glitches.
    convenience init() {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)
        self.init(frame: .zero, textContainer: textContainer)
    }

    override var intrinsicContentSize: CGSize {
        let fallbackWidth = superview?.bounds.width ?? 320
        let fixedWidth = frame.width > 0 ? frame.width : fallbackWidth
        let size = sizeThatFits(CGSize(width: fixedWidth, height: .greatestFiniteMagnitude))
        return CGSize(width: UIView.noIntrinsicMetric, height: max(size.height, 100))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        invalidateIntrinsicContentSize()
    }
}

struct RichTextEditor: UIViewRepresentable {
    @Binding var attributedText: NSAttributedString
    @ObservedObject var context: RichTextContext

    func makeUIView(context: Context) -> GrowingTextView {
        let textView = GrowingTextView()
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.delegate = context.coordinator
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.textContainer.lineFragmentPadding = 0
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .vertical)
        self.context.textView = textView
        self.context.sessionID = UUID()
        context.coordinator.sessionID = self.context.sessionID
        context.coordinator.context = self.context
        self.context.onTextChange = { updated in
            context.coordinator.handleExternalTextChange(updated)
        }
        return textView
    }

    func updateUIView(_ textView: GrowingTextView, context: Context) {
        // Compare string content to avoid unnecessary updates
        if textView.attributedText.string != attributedText.string {
            // Mark as programmatic update to prevent feedback loop
            self.context.isUpdatingFromUIView = true
            context.coordinator.isProgrammaticUpdate = true
            defer {
                context.coordinator.isProgrammaticUpdate = false
                self.context.isUpdatingFromUIView = false
            }

            // Save cursor position
            let selectedRange = textView.selectedRange

            textView.attributedText = attributedText

            // Reset content offset to prevent scroll position issues
            textView.contentOffset = .zero

            // Restore cursor if valid, or move to end for new content
            if selectedRange.location <= attributedText.length {
                textView.selectedRange = selectedRange
            } else {
                textView.selectedRange = NSRange(location: attributedText.length, length: 0)
            }

            // Force size recalculation for SwiftUI
            textView.invalidateIntrinsicContentSize()
            textView.setNeedsLayout()
            textView.layoutIfNeeded()

            // Notify SwiftUI that size changed
            DispatchQueue.main.async {
                textView.invalidateIntrinsicContentSize()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UITextViewDelegate {
        let parent: RichTextEditor
        var isProgrammaticUpdate = false
        var sessionID: UUID?
        weak var context: RichTextContext?
        private var publishTask: Task<Void, Never>?
        private var pendingAttributedText: NSAttributedString?
        private var pendingSelection: NSRange?

        init(_ parent: RichTextEditor) {
            self.parent = parent
        }

        func handleExternalTextChange(_ updated: NSAttributedString) {
            pendingAttributedText = updated
            schedulePublish()
        }

        private func schedulePublish() {
            publishTask?.cancel()
            publishTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                guard let context = self.context, self.sessionID == context.sessionID else { return }
                guard !context.isUpdatingFromUIView else { return }

                if let text = self.pendingAttributedText {
                    self.parent.attributedText = text
                    self.pendingAttributedText = nil
                }
                if let range = self.pendingSelection, let textView = context.textView {
                    context.selectedRange = range
                    context.applySelectionState(from: textView, range: range)
                    self.pendingSelection = nil
                }
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            // Skip if this is a programmatic update to prevent feedback loop
            guard !isProgrammaticUpdate, !parent.context.isUpdatingFromUIView else { return }
            pendingAttributedText = textView.attributedText ?? NSAttributedString()
            schedulePublish()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !parent.context.isUpdatingFromUIView else { return }
            pendingSelection = textView.selectedRange
            schedulePublish()
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

// MARK: - Undo Send Toast

struct UndoSendToast: View {
    let remainingSeconds: Int
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "paperplane.fill")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))

            HStack(spacing: 6) {
                Text("Sent")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)

                if remainingSeconds > 0 {
                    Text("·")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.5))

                    Text("\(remainingSeconds)s")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.white.opacity(0.7))
                        .monospacedDigit()
                }
            }

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

// MARK: - Queued Offline Toast

struct QueuedOfflineToast: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.up.circle")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))

            Text("Queued - will send when online")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.white)

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemOrange).opacity(0.9))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        )
        .padding(.horizontal, 16)
    }
}

// MARK: - Offline Banner

struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.caption)
            Text("You're offline")
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.systemGray))
        .clipShape(Capsule())
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
    @Published var attachments: [ComposeAttachment] = []
    @Published var templates: [ComposeTemplate] = []

    // Pending input in recipient text fields
    @Published var pendingToInput: String = ""
    @Published var pendingCcInput: String = ""
    @Published var pendingBccInput: String = ""

    @Published var showCcBcc = false
    @Published var showAttachmentPicker = false
    @Published var showDiscardAlert = false

    var fromEmail: String {
        AuthService.shared.currentAccount?.email ?? ""
    }
    @Published var isSending = false
    @Published var isGeneratingDraft = false
    @Published var aiDraftError: String?
    @Published var isRecoveredDraft = false
    @Published var pendingAIDraft: AIDraftResult?
    @Published var pendingAIDraftIncludeSubject = true
    @Published var error: Error?

    private var replyToMessageId: String?
    private var replyThreadId: String?
    private var draftId: String?
    private var isSavingDraft = false  // Prevent concurrent saves
    private var pendingHTMLBody: String?
    private var pendingQuotedEmail: EmailDetail?
    nonisolated(unsafe) private static let htmlCache = NSCache<NSString, NSAttributedString>()

    private struct AttributedResult: @unchecked Sendable {
        let value: NSAttributedString?
    }
    private var autoSaveTask: Task<Void, Never>?

    /// True while programmatically setting body (e.g., loading quoted email)
    /// Prevents auto-save from triggering on programmatic changes
    var isSeedingBody = false

    /// True after user has made a real edit (keystroke, not programmatic)
    /// Auto-save only runs after this is true
    private var hasUserEdited = false
    private let templatesKey = "composeTemplates"
    var dismissAfterQueue: (() -> Void)?

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
        loadTemplates()
        switch mode {
        case .new:
            break

        case .reply(let email, let threadId):
            let senderEmail = EmailParser.extractSenderEmail(from: email.from)
            to = [senderEmail]
            subject = email.subject.hasPrefix("Re:") ? email.subject : "Re: \(email.subject)"
            // Use placeholder - loadDeferredBody() will build quote on background thread
            bodyAttributed = Self.attributedBody(from: "\n\n")
            pendingQuotedEmail = email
            replyThreadId = threadId
            replyToMessageId = email.id

        case .replyAll(let email, let threadId):
            let senderEmail = EmailParser.extractSenderEmail(from: email.from)
            to = [senderEmail]
            cc = email.cc
            subject = email.subject.hasPrefix("Re:") ? email.subject : "Re: \(email.subject)"
            // Use placeholder - loadDeferredBody() will build quote on background thread
            bodyAttributed = Self.attributedBody(from: "\n\n")
            pendingQuotedEmail = email
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
            isRecoveredDraft = true

        case .restoredDraft(let id, let toAddrs, let ccAddrs, let bccAddrs, let subj, let bodyText, let bodyHtmlText, let inReplyToId, let threadIdValue):
            draftId = id
            to = toAddrs
            cc = ccAddrs
            bcc = bccAddrs
            subject = subj
            // Prefer HTML body if available for rich text restoration
            if let html = bodyHtmlText, !html.isEmpty, isLikelyHTML(html) {
                bodyAttributed = Self.attributedBody(from: bodyText)
                pendingHTMLBody = html
            } else {
                bodyAttributed = Self.attributedBody(from: bodyText)
            }
            replyToMessageId = inReplyToId
            replyThreadId = threadIdValue
            isRecoveredDraft = true
        }
    }

    /// Load deferred rich body (HTML or quoted email) to avoid publish during view update.
    /// Heavy HTML parsing is done on background thread to avoid blocking main.
    func loadDeferredBody() async -> NSAttributedString? {
        // Extract data to value types BEFORE crossing threads
        let htmlToProcess = pendingHTMLBody
        pendingHTMLBody = nil

        let emailToQuote = pendingQuotedEmail
        pendingQuotedEmail = nil

        // Early exit if nothing to process
        guard htmlToProcess != nil || emailToQuote != nil else { return nil }

        // Extract email data needed for quote building (don't capture EmailDetail across threads)
        let quoteInputs: (from: String, date: Date, body: String, subject: String)?
        if let email = emailToQuote {
            quoteInputs = (from: email.from, date: email.date, body: email.body, subject: email.subject)
        } else {
            quoteInputs = nil
        }

        // Heavy work on background thread
        let result = await Task.detached(priority: .userInitiated) { [htmlToProcess, quoteInputs] () -> AttributedResult in
            // Process pending HTML body
            if let html = htmlToProcess {
                if let rich = Self.parseHTMLToAttributed(html) {
                    return AttributedResult(value: rich)
                }
            }

            // Build quoted reply
            if let inputs = quoteInputs {
                return AttributedResult(value: Self.buildQuotedReplyBackground(
                    from: inputs.from,
                    date: inputs.date,
                    body: inputs.body,
                    subject: inputs.subject
                ))
            }

            return AttributedResult(value: nil)
        }.value

        return result.value
    }

    /// Thread-safe HTML parsing (can be called from background)
    nonisolated private static func parseHTMLToAttributed(_ html: String) -> NSAttributedString? {
        let trimmed = html.count > 250_000 ? String(html.prefix(250_000)) : html
        guard let data = trimmed.data(using: .utf8) else { return nil }

        // Check cache first (NSCache is thread-safe)
        if let cached = htmlCache.object(forKey: trimmed as NSString) {
            return cached
        }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        if let parsed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
            htmlCache.setObject(parsed, forKey: trimmed as NSString)
            return parsed
        }
        return nil
    }

    /// Thread-safe quoted reply builder (can be called from background)
    nonisolated private static func buildQuotedReplyBackground(from: String, date: Date, body: String, subject: String) -> NSAttributedString {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        let dateStr = dateFormatter.string(from: date)

        let senderName = EmailParser.extractSenderName(from: from)
        let header = "On \(dateStr), \(senderName) wrote:"

        let bodyHTML: String
        if isLikelyHTMLStatic(body) {
            bodyHTML = sanitizeHTMLForQuoteStatic(body)
        } else {
            bodyHTML = escapeHTMLStatic(body).replacingOccurrences(of: "\n", with: "<br>")
        }

        let html = """
        <html>
        <head>
          <meta charset="utf-8">
          <style>
            body { font-family: -apple-system; font-size: 16px; color: #111; }
            blockquote {
              margin: 8px 0 0 0;
              padding-left: 12px;
              border-left: 2px solid #d0d0d0;
              color: #555;
            }
            blockquote, blockquote * {
              text-align: left !important;
              margin-left: 0 !important;
            }
            img { max-width: 100%; height: auto; }
          </style>
        </head>
        <body>
          <div><br><br></div>
          <div>\(escapeHTMLStatic(header))</div>
          <blockquote><div class="quoted">\(bodyHTML)</div></blockquote>
        </body>
        </html>
        """

        if let attributed = parseHTMLToAttributed(html) {
            return attributed
        }

        // Fallback to plain text quote
        let plainBody = plainTextFromHTMLStatic(body)
        let quotePreview = summarizeForQuoteStatic(plainBody)
        let fallback = "\n\n\(header)\n> \(quotePreview.replacingOccurrences(of: "\n", with: "\n> "))"
        return attributedBody(from: fallback)
    }

    // MARK: - Static helper methods for background thread use (nonisolated)

    nonisolated private static func isLikelyHTMLStatic(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("<html") ||
            lower.contains("<body") ||
            lower.contains("<div") ||
            lower.contains("<table") ||
            lower.contains("<img")
    }

    nonisolated private static func sanitizeHTMLForQuoteStatic(_ html: String) -> String {
        var result = html
        if result.count > 250_000 {
            result = String(result.prefix(250_000))
        }
        result = result.replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "</?(html|head|body)[^>]*>", with: "", options: .regularExpression)
        return result
    }

    nonisolated private static func escapeHTMLStatic(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    nonisolated private static func plainTextFromHTMLStatic(_ html: String) -> String {
        var text = html
        if text.count > 200_000 {
            text = String(text.prefix(200_000))
        }
        while let start = text.range(of: "<style", options: .caseInsensitive),
              let end = text.range(of: "</style>", options: .caseInsensitive, range: start.upperBound..<text.endIndex) {
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        while let start = text.range(of: "<script", options: .caseInsensitive),
              let end = text.range(of: "</script>", options: .caseInsensitive, range: start.upperBound..<text.endIndex) {
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        text = text
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }

    nonisolated private static func summarizeForQuoteStatic(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let previewLines = lines.prefix(4)
        var preview = previewLines.joined(separator: "\n")
        if preview.count > 320 {
            preview = String(preview.prefix(320))
        }
        if lines.count > previewLines.count || normalized.count > preview.count {
            preview += "…"
        }
        return preview
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
                attachments: mimeAttachments(),
                inReplyTo: replyToMessageId,
                threadId: replyThreadId
            )

            // Delete draft if exists
            if let draftId = draftId {
                do {
                    try await GmailService.shared.deleteDraft(draftId: draftId)
                } catch {
                    // Log but don't fail the send - draft cleanup is non-critical
                    logger.warning("Failed to delete draft \(draftId): \(error.localizedDescription)")
                }
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
        // Prevent concurrent saves (would create duplicate drafts)
        guard !isSavingDraft else { return }
        isSavingDraft = true
        defer { isSavingDraft = false }

        let toRecipients = to
        let emailSubject = subject
        let emailBody = plainBody()
        let existingDraftId = draftId

        // GmailService is an actor - calling it suspends but doesn't block main thread
        // No Task.detached needed, and this allows proper cancellation propagation
        do {
            let newDraftId = try await GmailService.shared.saveDraft(
                to: toRecipients,
                subject: emailSubject,
                body: emailBody,
                existingDraftId: existingDraftId
            )
            // Store the draft ID so subsequent saves UPDATE instead of creating new
            self.draftId = newDraftId
        } catch {
            // Don't set error for cancellation
            if !(error is CancellationError) {
                self.error = error
            }
        }
    }

    func queueSendWithUndo() {
        let pendingEmail = PendingSendManager.PendingEmail(
            to: to,
            cc: cc,
            bcc: bcc,
            subject: subject,
            body: plainBody(),
            bodyHtml: htmlBody(),
            attachments: mimeAttachments(),
            inReplyTo: replyToMessageId,
            threadId: replyThreadId,
            draftId: draftId,
            delaySeconds: undoDelaySeconds(),
            accountEmail: fromEmail
        )

        PendingSendManager.shared.queueSend(pendingEmail)

        // Dismiss immediately so user returns to inbox with undo banner
        dismissAfterQueue?()
    }

    func scheduleSend(at date: Date) {
        guard let accountEmail = AuthService.shared.currentAccount?.email else { return }
        let scheduled = ScheduledSend(
            id: UUID(),
            accountEmail: accountEmail,
            to: to,
            cc: cc,
            bcc: bcc,
            subject: subject,
            body: plainBody(),
            bodyHtml: htmlBody(),
            attachments: scheduledAttachments(),
            sendAt: date
        )
        ScheduledSendManager.shared.schedule(scheduled)
        BackgroundSyncManager.shared.scheduleNotificationCheck()
        HapticFeedback.success()
    }

    func scheduleAutoSave() {
        // Don't schedule auto-save during programmatic body loads or before user has edited
        guard !isSeedingBody, hasUserEdited else { return }

        autoSaveTask?.cancel()
        autoSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            if self.hasContent {
                await self.saveDraft()
            }
        }
    }

    /// Call when user makes a real edit (not programmatic changes)
    func markUserEdited() {
        guard !isSeedingBody else { return }
        hasUserEdited = true
    }

    func cancelAutoSave() {
        autoSaveTask?.cancel()
        autoSaveTask = nil
    }

    /// Get the draft ID for background cleanup, then clear local state
    /// Returns the draft ID if one exists (caller should delete it in background)
    func discardLocally() -> String? {
        cancelAutoSave()
        let idToDelete = draftId
        draftId = nil
        hasUserEdited = false
        return idToDelete
    }

    /// Discard draft: cancel auto-save and delete any saved draft from server
    /// NOTE: This blocks on network - prefer discardLocally() + background deletion
    func discardDraft() async {
        cancelAutoSave()
        // Delete draft from server if it was already saved
        if let draftId = draftId {
            do {
                try await GmailService.shared.deleteDraft(draftId: draftId)
                self.draftId = nil
            } catch {
                // Log but don't block dismiss - draft cleanup is non-critical
                logger.warning("Failed to delete draft \(draftId): \(error.localizedDescription)")
            }
        }
    }

    func addAttachment(data: Data, filename: String, mimeType: String) {
        let attachment = ComposeAttachment(filename: filename, mimeType: mimeType, data: data)
        attachments.append(attachment)
    }

    func removeAttachment(_ attachment: ComposeAttachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    func appendTemplate(_ template: ComposeTemplate) {
        let newBody = bodyAttributed.string.isEmpty ? template.body : "\(bodyAttributed.string)\n\n\(template.body)"
        bodyAttributed = Self.attributedBody(from: newBody)
    }

    func addTemplate(title: String, body: String) {
        var current = templates
        current.append(ComposeTemplate(title: title, body: body))
        templates = current
        saveTemplates()
    }

    func removeTemplates(at offsets: IndexSet) {
        templates.remove(atOffsets: offsets)
        saveTemplates()
    }

    @MainActor
    func generateAIDraftPreview(prompt: String, tone: AIDraftTone, length: AIDraftLength, includeSubject: Bool) async {
        isGeneratingDraft = true
        aiDraftError = nil
        defer { isGeneratingDraft = false }

        do {
            let draft = try await generateAIDraft(prompt: prompt, tone: tone, length: length)
            pendingAIDraft = draft
            pendingAIDraftIncludeSubject = includeSubject
        } catch {
            aiDraftError = "Apple Intelligence is unavailable right now."
        }
    }

    func applyAIDraftResult(_ draft: AIDraftResult, includeSubject: Bool) {
        if includeSubject, !draft.subject.isEmpty {
            subject = draft.subject
        }
        bodyAttributed = Self.attributedBody(from: draft.body)
        pendingAIDraft = nil
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

    private func attributedBody(fromHTML html: String) -> NSAttributedString? {
        let trimmed = html.count > 250_000 ? String(html.prefix(250_000)) : html
        guard let data = trimmed.data(using: .utf8) else { return nil }
        if let cached = Self.htmlCache.object(forKey: trimmed as NSString) {
            return cached
        }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        if let parsed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
            Self.htmlCache.setObject(parsed, forKey: trimmed as NSString)
            return parsed
        }
        return nil
    }

    private func isLikelyHTML(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("<html") ||
            lower.contains("<body") ||
            lower.contains("<div") ||
            lower.contains("<table") ||
            lower.contains("<img")
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

    private func mimeAttachments() -> [MIMEAttachment] {
        attachments.map {
            MIMEAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data)
        }
    }

    private func scheduledAttachments() -> [ScheduledAttachment] {
        attachments.map {
            ScheduledAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data)
        }
    }

    nonisolated static func attributedBody(from text: String) -> NSAttributedString {
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

    private func loadTemplates() {
        let accountEmail = AuthService.shared.currentAccount?.email
        guard let data = AccountDefaults.data(for: templatesKey, accountEmail: accountEmail),
              let decoded = try? JSONDecoder().decode([ComposeTemplate].self, from: data) else {
            templates = []
            return
        }
        templates = decoded
    }

    private func saveTemplates() {
        let accountEmail = AuthService.shared.currentAccount?.email
        if let data = try? JSONEncoder().encode(templates) {
            AccountDefaults.setData(data, for: templatesKey, accountEmail: accountEmail)
        }
    }

    private func undoDelaySeconds() -> Int {
        let accountEmail = AuthService.shared.currentAccount?.email
        if let data = AccountDefaults.data(for: "appSettings", accountEmail: accountEmail),
           let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            return settings.undoSendDelaySeconds
        }
        return 5
    }
}

// MARK: - Preview

#Preview {
    ComposeView()
}
