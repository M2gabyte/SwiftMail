import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
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
    @State private var showingTemplates = false
    @State private var showingScheduleSheet = false
    @State private var showingAttachmentOptions = false
    @State private var showingFileImporter = false
    @State private var showingPhotoPicker = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showUndoToast = false

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
                    if viewModel.isRecoveredDraft {
                        RecoveredDraftBanner()
                            .padding(.horizontal)
                            .padding(.top, 6)
                    }
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

                    Button(action: { showingTemplates = true }) {
                        Image(systemName: "doc.on.doc")
                    }

                    Button(action: { viewModel.showCcBcc.toggle() }) {
                        Image(systemName: viewModel.showCcBcc ? "chevron.up" : "chevron.down")
                    }

                    Button(action: { viewModel.showAttachmentPicker = true }) {
                        Image(systemName: "paperclip")
                    }

                    Button(action: { showingScheduleSheet = true }) {
                        Image(systemName: "clock")
                    }
                    .disabled(!viewModel.canSend)

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
                        await viewModel.generateAIDraftPreview(
                            prompt: prompt,
                            tone: tone,
                            length: length,
                            includeSubject: includeSubject
                        )
                    }
                }
            }
            .sheet(item: $viewModel.pendingAIDraft) { draft in
                AIDraftPreviewSheet(
                    draft: draft,
                    applySubject: viewModel.pendingAIDraftIncludeSubject
                ) {
                    viewModel.applyAIDraftResult(draft, includeSubject: viewModel.pendingAIDraftIncludeSubject)
                }
            }
            .sheet(isPresented: $showingTemplates) {
                TemplatesSheet(
                    templates: viewModel.templates,
                    defaultBody: viewModel.bodyAttributed.string,
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
            .photosPicker(isPresented: $showingPhotoPicker, selection: $selectedPhotos, matching: .images)
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
                allowedContentTypes: [.data],
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
            .onChange(of: viewModel.showAttachmentPicker) { _, newValue in
                if newValue {
                    showingAttachmentOptions = true
                    viewModel.showAttachmentPicker = false
                }
            }
            .onChange(of: viewModel.didSend) { _, newValue in
                if newValue {
                    dismiss()
                    viewModel.didSend = false
                }
            }
            .overlay(alignment: .bottom) {
                if viewModel.showUndoSend {
                    UndoSendToast(
                        onUndo: { viewModel.undoSend() }
                    )
                    .padding(.bottom, 56)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onChange(of: viewModel.subject) { _, _ in
                viewModel.scheduleAutoSave()
            }
            .onChange(of: viewModel.bodyAttributed) { _, _ in
                viewModel.scheduleAutoSave()
            }
            .onChange(of: viewModel.to) { _, _ in
                viewModel.scheduleAutoSave()
            }
            .onChange(of: viewModel.cc) { _, _ in
                viewModel.scheduleAutoSave()
            }
            .onChange(of: viewModel.bcc) { _, _ in
                viewModel.scheduleAutoSave()
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

        viewModel.queueSendWithUndo()
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
    @State private var showingLinkPrompt = false
    @State private var linkURL = ""

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                FormatButton(
                    systemName: "bold",
                    isActive: context.isBold,
                    action: { context.toggleBold() }
                )
                FormatButton(
                    systemName: "italic",
                    isActive: context.isItalic,
                    action: { context.toggleItalic() }
                )
                FormatButton(
                    systemName: "underline",
                    isActive: context.isUnderline,
                    action: { context.toggleUnderline() }
                )
            }

            Divider()
                .frame(height: 18)

            HStack(spacing: 6) {
                FormatButton(systemName: "list.bullet") {
                    context.insertBulletList()
                }
                FormatButton(systemName: "link") {
                    showingLinkPrompt = true
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                FormatButton(systemName: "textformat.size") {
                    context.toggleFontSize()
                }
                FormatButton(action: { context.clearFormatting() }) {
                    RemoveFormattingIcon()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
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

struct FormatButton<Label: View>: View {
    let isActive: Bool
    let action: () -> Void
    let label: () -> Label

    init(
        isActive: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.isActive = isActive
        self.action = action
        self.label = label
    }

    init(systemName: String, isActive: Bool = false, action: @escaping () -> Void) where Label == Image {
        self.init(isActive: isActive, action: action) {
            Image(systemName: systemName)
        }
    }

    var body: some View {
        Button(action: action) {
            label()
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isActive ? .white : .primary)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(isActive ? Color.accentColor : Color(.systemGray6))
                )
        }
        .buttonStyle(.plain)
    }
}

struct RemoveFormattingIcon: View {
    var body: some View {
        ZStack {
            Image(systemName: "textformat")
            Image(systemName: "xmark")
                .font(.caption2)
                .offset(x: 6, y: -6)
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

final class RichTextContext: ObservableObject {
    @Published var selectedRange: NSRange = NSRange(location: 0, length: 0)
    @Published var isBold = false
    @Published var isItalic = false
    @Published var isUnderline = false
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

    func updateSelectionState() {
        guard let textView = textView else { return }
        let range = textView.selectedRange
        let attributes: [NSAttributedString.Key: Any]
        if range.length > 0, range.location < textView.attributedText.length {
            attributes = textView.attributedText.attributes(at: range.location, effectiveRange: nil)
        } else {
            attributes = textView.typingAttributes
        }

        let font = (attributes[.font] as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
        let traits = font.fontDescriptor.symbolicTraits
        isBold = traits.contains(.traitBold)
        isItalic = traits.contains(.traitItalic)

        if let underline = attributes[.underlineStyle] as? Int {
            isUnderline = underline != 0
        } else {
            isUnderline = false
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
            parent.context.updateSelectionState()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.context.selectedRange = textView.selectedRange
            parent.context.updateSelectionState()
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
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "paperplane")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))

            Text("Sending soon…")
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
    @Published var isSending = false
    @Published var isGeneratingDraft = false
    @Published var aiDraftError: String?
    @Published var showUndoSend = false
    @Published var didSend = false
    @Published var isRecoveredDraft = false
    @Published var pendingAIDraft: AIDraftResult?
    @Published var pendingAIDraftIncludeSubject = true
    @Published var error: Error?

    private var replyToMessageId: String?
    private var replyThreadId: String?
    private var draftId: String?
    private var sendTask: Task<Void, Never>?
    private var autoSaveTask: Task<Void, Never>?
    private let templatesKey = "composeTemplates"

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
            isRecoveredDraft = true
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
                attachments: mimeAttachments(),
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

    func queueSendWithUndo() {
        sendTask?.cancel()
        showUndoSend = true
        didSend = false

        sendTask = Task { [weak self] in
            let delay = await MainActor.run { self?.undoDelaySeconds() ?? 5 }
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            let success = await self.send()
            await MainActor.run {
                self.showUndoSend = false
                self.didSend = success
            }
        }
    }

    func undoSend() {
        sendTask?.cancel()
        showUndoSend = false
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
        autoSaveTask?.cancel()
        autoSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            if self.hasContent {
                await self.saveDraft()
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
