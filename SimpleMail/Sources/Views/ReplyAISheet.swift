import SwiftUI
import UIKit

// MARK: - Reply AI Sheet

struct ReplyAISheet: View {
    let context: ReplyAIContext
    let onInsert: (String) -> Void
    let onOpenLink: ((URL) -> Void)?
    let onArchive: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    @State private var result: ReplyAIResult?
    @State private var errorText: String?
    @State private var selectedReplyIndex: Int?
    @State private var showFillBlanks = false
    @State private var selectedReplyForBlanks: SuggestedReply?

    init(
        context: ReplyAIContext,
        onInsert: @escaping (String) -> Void,
        onOpenLink: ((URL) -> Void)? = nil,
        onArchive: (() -> Void)? = nil
    ) {
        self.context = context
        self.onInsert = onInsert
        self.onOpenLink = onOpenLink
        self.onArchive = onArchive
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    loadingView
                } else if let result = result {
                    resultView(result)
                } else {
                    errorView
                }
            }
            .navigationTitle("AI Reply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await load() }
            .sheet(isPresented: $showFillBlanks) {
                if let reply = selectedReplyForBlanks, let result = result {
                    FillBlanksSheet(
                        replyTemplate: reply.body,
                        placeholders: extractPlaceholders(from: reply.body, intent: result.emailIntent)
                    ) { filledBody in
                        onInsert(filledBody)
                        dismiss()
                    }
                }
            }
            .alert("AI Reply Error", isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "An unknown error occurred.")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Subviews

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)

            Text("Analyzing email...")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Finding the right response")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultView(_ result: ReplyAIResult) -> some View {
        List {
            // Recommended Action Section (if no reply needed)
            if case .noReplyNeeded(let reason, let links) = result.recommendedAction {
                Section {
                    RecommendedActionRow(
                        reason: reason,
                        links: links,
                        onOpenLink: { url in
                            // Just open link, keep compose view open
                            if let linkURL = URL(string: url) {
                                if let openLink = onOpenLink {
                                    openLink(linkURL)
                                } else {
                                    UIApplication.shared.open(linkURL)
                                }
                            }
                        },
                        onOpenAndArchive: { url in
                            // Open link AND archive (dismiss compose = no reply)
                            if let linkURL = URL(string: url) {
                                if let openLink = onOpenLink {
                                    openLink(linkURL)
                                } else {
                                    UIApplication.shared.open(linkURL)
                                }
                            }
                            onArchive?()
                            dismiss()
                        }
                    )
                } header: {
                    Label("Recommended", systemImage: "sparkles")
                }
            }

            // Suggested Replies Section
            Section {
                ForEach(Array(result.suggestedReplies.enumerated()), id: \.element.id) { index, suggestion in
                    SuggestionRow(
                        suggestion: suggestion,
                        index: index,
                        isSelected: selectedReplyIndex == index,
                        emailIntent: result.emailIntent
                    ) { cleanedBody in
                        if suggestion.hasBlanks {
                            // Show fill blanks sheet
                            selectedReplyForBlanks = suggestion
                            showFillBlanks = true
                        } else {
                            // Direct insert
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedReplyIndex = index
                            }

                            let generator = UIImpactFeedbackGenerator(style: .light)
                            generator.impactOccurred()

                            Task {
                                try? await Task.sleep(for: .milliseconds(150))
                                onInsert(cleanedBody)
                                dismiss()
                            }
                        }
                    }
                }
            } header: {
                let showingRecommended = !result.recommendedAction.requiresReply
                Label(showingRecommended ? "Or reply anyway" : "Suggested Replies", systemImage: "text.bubble")
            } footer: {
                Text("Tap to insert into your reply")
                    .font(.caption)
            }
        }
        .listStyle(.insetGrouped)
    }

    private var errorView: some View {
        ContentUnavailableView {
            Label("Couldn't Generate Replies", systemImage: "exclamationmark.bubble")
        } description: {
            Text("Apple Intelligence is unavailable or encountered an error.")
        } actions: {
            Button("Try Again") {
                Task { await load() }
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Helpers

    /// Extract placeholder info from a reply body (local helper to avoid actor isolation)
    private func extractPlaceholders(from body: String, intent: EmailIntent) -> [ReplyPlaceholder] {
        var placeholders: [ReplyPlaceholder] = []

        let hasP1 = body.contains("[[P1]]")
        let hasP2 = body.contains("[[P2]]")

        // Detect if this is a "times" reply (has P1 and P2) or a "question" reply (just P1)
        let isTimesReply = hasP1 && hasP2

        if hasP1 {
            let (label, kind, example) = placeholderInfo(index: 1, intent: intent, isTimesReply: isTimesReply)
            placeholders.append(ReplyPlaceholder(token: "[[P1]]", label: label, kind: kind, example: example))
        }
        if hasP2 {
            let (label, kind, example) = placeholderInfo(index: 2, intent: intent, isTimesReply: isTimesReply)
            placeholders.append(ReplyPlaceholder(token: "[[P2]]", label: label, kind: kind, example: example))
        }
        if body.contains("[[P3]]") {
            let (label, kind, example) = placeholderInfo(index: 3, intent: intent, isTimesReply: false)
            placeholders.append(ReplyPlaceholder(token: "[[P3]]", label: label, kind: kind, example: example))
        }

        return placeholders
    }

    private func placeholderInfo(index: Int, intent: EmailIntent, isTimesReply: Bool) -> (label: String, kind: String, example: String?) {
        // If it's a times-based reply (has both P1 and P2), use time labels
        if isTimesReply {
            if index == 1 {
                return ("First time option", "time", "Tuesday 2pm")
            } else {
                return ("Second time option", "time", "Thursday morning")
            }
        }

        // Single placeholder - context-aware based on intent
        switch intent {
        case .meetingRequest, .introduction:
            return ("Suggested time", "time", "Tuesday 2pm")

        case .questionAsking, .followUp:
            return ("Your response", "info", nil)

        case .surveyRequest:
            // Single placeholder in survey = question, not time
            return ("Your question", "info", nil)

        default:
            return ("Your input", "info", nil)
        }
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        result = nil
        errorText = nil
        selectedReplyIndex = nil

        defer { isLoading = false }

        do {
            let voiceProfile = await VoiceProfileManager.shared.currentProfile(accountEmail: context.accountEmail)
            let aiResult = try await ReplyAIService.shared.generate(context: context, voiceProfile: voiceProfile)
            result = aiResult
        } catch let error as ReplyAIError {
            errorText = error.localizedDescription
        } catch {
            errorText = "Apple Intelligence is unavailable right now."
        }
    }
}

// MARK: - Recommended Action Row

private struct RecommendedActionRow: View {
    let reason: String
    let links: [ExtractedLink]
    let onOpenLink: (String) -> Void
    let onOpenAndArchive: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Reason text
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)

                Text(reason)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }

            // Action buttons - "one tap and you're done"
            if let primaryLink = links.first {
                HStack(spacing: 12) {
                    // Primary: Open & Archive (complete the loop)
                    Button {
                        let generator = UIImpactFeedbackGenerator(style: .medium)
                        generator.impactOccurred()
                        onOpenAndArchive(primaryLink.url)
                    } label: {
                        Label("Open & Done", systemImage: buttonIcon(for: primaryLink))
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(Color.accentColor))
                    }
                    .buttonStyle(.plain)

                    // Secondary: Just open (if user wants to come back)
                    Button {
                        let generator = UIImpactFeedbackGenerator(style: .light)
                        generator.impactOccurred()
                        onOpenLink(primaryLink.url)
                    } label: {
                        Text("Just Open")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(Color(.tertiarySystemFill)))
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func buttonIcon(for link: ExtractedLink) -> String {
        switch link.label {
        case "survey": return "doc.text"
        case "calendar": return "calendar"
        case "document": return "doc"
        default: return "link"
        }
    }
}

// MARK: - Suggestion Row

private struct SuggestionRow: View {
    let suggestion: SuggestedReply
    let index: Int
    let isSelected: Bool
    let emailIntent: EmailIntent
    let onSelect: (String) -> Void

    private let iconColors: [Color] = [.green, .blue, .orange]

    /// Clean body text for display (keep tokens for AttributedString rendering)
    private var cleanedBody: String {
        var text = suggestion.body
        text = text.replacingOccurrences(of: "(?i)\\[title:[^\\]]*\\]\\s*", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)\\[intent:[^\\]]*\\]\\s*", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)\\[your name\\]", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\n{2,}", with: "\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Body with tokens replaced by context-aware labels
    private var displayBody: String {
        var text = cleanedBody
        let hasP1 = text.contains("[[P1]]")
        let hasP2 = text.contains("[[P2]]")
        let isTimesReply = hasP1 && hasP2

        let (p1Label, p2Label) = placeholderLabels(for: emailIntent, isTimesReply: isTimesReply)
        text = text.replacingOccurrences(of: "[[P1]]", with: "⟨\(p1Label)⟩")
        text = text.replacingOccurrences(of: "[[P2]]", with: "⟨\(p2Label)⟩")
        text = text.replacingOccurrences(of: "[[P3]]", with: "⟨your input⟩")
        return text
    }

    private func placeholderLabels(for intent: EmailIntent, isTimesReply: Bool) -> (String, String) {
        // If it's a times-based reply (has both P1 and P2), use time labels
        if isTimesReply {
            return ("time 1", "time 2")
        }

        // Single placeholder - context-aware
        switch intent {
        case .meetingRequest, .introduction:
            return ("time", "time 2")
        case .surveyRequest:
            // Single placeholder in survey = question
            return ("your question", "details")
        case .questionAsking, .followUp:
            return ("your answer", "details")
        default:
            return ("your input", "more info")
        }
    }

    var body: some View {
        Button { onSelect(cleanedBody) } label: {
            VStack(alignment: .leading, spacing: 8) {
                // Header with icon and intent title
                HStack(spacing: 8) {
                    Image(systemName: iconForIndex(index))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(iconColors[index % iconColors.count])
                        .frame(width: 20, height: 20)
                        .background(
                            Circle()
                                .fill(iconColors[index % iconColors.count].opacity(0.15))
                        )

                    Text(suggestion.intent)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)

                    Spacer()

                    if suggestion.hasBlanks {
                        // Indicate this needs fill-in
                        Text("Fill in")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color(.tertiarySystemFill)))
                    }

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .transition(.scale.combined(with: .opacity))
                    }
                }

                // Body preview with pill-style placeholders
                Text(styledPreview)
                    .font(.subheadline)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Create attributed string with pill-style placeholders
    private var styledPreview: AttributedString {
        var result = AttributedString(displayBody)
        result.foregroundColor = .secondary

        // Style the placeholder markers
        let placeholderRanges = [
            ("⟨time 1⟩", Color.accentColor),
            ("⟨time 2⟩", Color.accentColor),
            ("⟨your input⟩", Color.accentColor)
        ]

        for (placeholder, color) in placeholderRanges {
            if let range = result.range(of: placeholder) {
                result[range].foregroundColor = color
                result[range].font = .subheadline.weight(.medium)
            }
        }

        return result
    }

    private func iconForIndex(_ index: Int) -> String {
        switch index {
        case 0: return "hand.thumbsup"
        case 1: return "calendar.badge.clock"
        case 2: return "questionmark.bubble"
        default: return "text.bubble"
        }
    }
}

// MARK: - Fill Blanks Sheet

struct FillBlanksSheet: View {
    let replyTemplate: String
    let placeholders: [ReplyPlaceholder]
    let onDone: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @FocusState private var focusedField: String?

    /// Clean body text for display
    private var cleanedBody: String {
        var text = replyTemplate
        text = text.replacingOccurrences(of: "(?i)\\[title:[^\\]]*\\]\\s*", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)\\[intent:[^\\]]*\\]\\s*", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)\\[your name\\]", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\n{2,}", with: "\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                // Preview section
                Section {
                    Text(livePreview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Preview")
                }

                // Input fields
                Section {
                    ForEach(placeholders) { placeholder in
                        VStack(alignment: .leading, spacing: 6) {
                            // Label with icon
                            HStack(spacing: 6) {
                                Image(systemName: iconForKind(placeholder.kind))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text(placeholder.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            // Text field
                            TextField(
                                placeholder.example ?? "Enter value",
                                text: Binding(
                                    get: { values[placeholder.token] ?? "" },
                                    set: { values[placeholder.token] = $0 }
                                )
                            )
                            .textInputAutocapitalization(.sentences)
                            .focused($focusedField, equals: placeholder.token)
                            .submitLabel(isLastPlaceholder(placeholder) ? .done : .next)
                            .onSubmit {
                                advanceToNextField(from: placeholder)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Fill in the blanks")
                }
            }
            .navigationTitle("Complete Reply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button("Insert") {
                        let generator = UINotificationFeedbackGenerator()
                        generator.notificationOccurred(.success)
                        let filled = substitute(cleanedBody, values: values)
                        onDone(filled)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!allFilled)
                }

                ToolbarItem(placement: .keyboard) {
                    HStack {
                        Spacer()
                        Button("Done") {
                            focusedField = nil
                        }
                    }
                }
            }
            .onAppear {
                // Initialize values
                for placeholder in placeholders {
                    values[placeholder.token] = ""
                }
                // Focus first field
                if let first = placeholders.first {
                    focusedField = first.token
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(hasPartialInput)
    }

    // MARK: - Computed Properties

    private var allFilled: Bool {
        placeholders.allSatisfy { placeholder in
            guard let value = values[placeholder.token] else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var hasPartialInput: Bool {
        values.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var livePreview: AttributedString {
        var text = cleanedBody

        for placeholder in placeholders {
            let value = values[placeholder.token] ?? ""
            // Show pill-style label when empty, actual value when filled
            let displayValue = value.isEmpty ? "⟨\(placeholder.label)⟩" : value
            text = text.replacingOccurrences(of: placeholder.token, with: displayValue)
        }

        var result = AttributedString(text)
        result.foregroundColor = .secondary

        // Style unfilled placeholders as accent-colored pills
        for placeholder in placeholders {
            if let value = values[placeholder.token], value.isEmpty {
                let pillText = "⟨\(placeholder.label)⟩"
                if let range = result.range(of: pillText) {
                    result[range].foregroundColor = .accentColor
                    result[range].font = .subheadline.weight(.medium)
                }
            }
        }

        return result
    }

    // MARK: - Helpers

    private func substitute(_ body: String, values: [String: String]) -> String {
        var result = body
        for (token, value) in values {
            result = result.replacingOccurrences(of: token, with: value)
        }
        return result
    }

    private func iconForKind(_ kind: String) -> String {
        switch kind.lowercased() {
        case "time": return "clock"
        case "decision": return "checkmark.circle"
        case "number": return "number"
        default: return "info.circle"
        }
    }

    private func isLastPlaceholder(_ placeholder: ReplyPlaceholder) -> Bool {
        placeholder.token == placeholders.last?.token
    }

    private func advanceToNextField(from current: ReplyPlaceholder) {
        guard let currentIndex = placeholders.firstIndex(where: { $0.token == current.token }) else { return }
        let nextIndex = currentIndex + 1

        if nextIndex < placeholders.count {
            focusedField = placeholders[nextIndex].token
        } else {
            focusedField = nil
        }
    }
}

// MARK: - Placeholder Chip (for reference, may be used elsewhere)

struct PlaceholderChip: View {
    let placeholder: ReplyPlaceholder

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconForKind(placeholder.kind))
                .font(.caption2)

            Text(placeholder.label)
                .font(.caption)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color(.tertiarySystemFill))
        )
    }

    private func iconForKind(_ kind: String) -> String {
        switch kind.lowercased() {
        case "time": return "clock"
        case "decision": return "checkmark.circle"
        case "number": return "number"
        default: return "info.circle"
        }
    }
}

// MARK: - Preview

#Preview("Reply AI Sheet - Survey") {
    ReplyAISheet(
        context: ReplyAIContext(
            accountEmail: "mark@example.com",
            userName: "Mark",
            senderName: "Amol",
            subject: "Claude Cowork feedback",
            latestInboundPlainText: """
            Hey there!

            My name's Amol and I lead the growth team at Anthropic.

            We launched Claude Cowork ~2 weeks ago, and I'm reaching out to folks who tried Cowork to better understand their experience so we can quickly improve the product.

            If you've got 2-3 minutes, would love if you could fill out this short survey!

            Thanks,
            Amol
            """,
            latestInboundHTML: """
            <p>Hey there!</p>
            <p>My name's <a href="mailto:amol@anthropic.com">Amol</a> and I lead the growth team at Anthropic.</p>
            <p>We launched Claude Cowork ~2 weeks ago, and I'm reaching out to folks who tried Cowork to better understand their experience so we can quickly improve the product.</p>
            <p>If you've got 2-3 minutes, would love if you could fill out this short <a href="https://forms.gle/abc123">survey</a>!</p>
            <p>Thanks,<br>Amol</p>
            """
        ),
        onInsert: { body in
            print("Inserting: \(body)")
        },
        onOpenLink: { url in
            print("Opening: \(url)")
        },
        onArchive: {
            print("Archiving")
        }
    )
}

#Preview("Reply AI Sheet - Meeting") {
    ReplyAISheet(
        context: ReplyAIContext(
            accountEmail: "mark@example.com",
            userName: "Mark",
            senderName: "John",
            subject: "Quick chat?",
            latestInboundPlainText: """
            Hi Mark,

            Are you free for a quick call this week? I'd like to discuss the project timeline.

            Let me know what works.

            Thanks,
            John
            """,
            latestInboundHTML: nil
        ),
        onInsert: { body in
            print("Inserting: \(body)")
        }
    )
}
