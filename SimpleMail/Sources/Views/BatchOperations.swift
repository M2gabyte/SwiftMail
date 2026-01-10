import SwiftUI
import UIKit
import OSLog

private let batchLogger = Logger(subsystem: "com.simplemail.app", category: "BatchOperations")

// MARK: - Batch Selection Mode

enum BatchAction: String, CaseIterable {
    case archive = "Archive"
    case trash = "Trash"
    case markRead = "Mark Read"
    case markUnread = "Mark Unread"
    case star = "Star"
    case unstar = "Unstar"
    case spam = "Report Spam"
    case important = "Mark Important"

    var icon: String {
        switch self {
        case .archive: return "archivebox"
        case .trash: return "trash"
        case .markRead: return "envelope.open"
        case .markUnread: return "envelope.badge"
        case .star: return "star.fill"
        case .unstar: return "star.slash"
        case .spam: return "exclamationmark.triangle"
        case .important: return "flag.fill"
        }
    }

    var color: Color {
        switch self {
        case .archive: return .orange
        case .trash: return .red
        case .markRead, .markUnread: return .blue
        case .star: return .yellow
        case .unstar: return .gray
        case .spam: return .red
        case .important: return .orange
        }
    }
}

// MARK: - Batch Operations View Model

@MainActor
class BatchOperationsViewModel: ObservableObject {
    @Published var isSelectionMode = false
    @Published var selectedEmailIds: Set<String> = []
    @Published var isProcessing = false
    @Published var error: Error?

    var selectedCount: Int { selectedEmailIds.count }

    func toggleSelection(for emailId: String) {
        if selectedEmailIds.contains(emailId) {
            selectedEmailIds.remove(emailId)
        } else {
            selectedEmailIds.insert(emailId)
        }
        HapticFeedback.selection()
    }

    func selectAll(_ emails: [Email]) {
        selectedEmailIds = Set(emails.map { $0.id })
        HapticFeedback.light()
    }

    func deselectAll() {
        selectedEmailIds.removeAll()
        HapticFeedback.light()
    }

    func exitSelectionMode() {
        isSelectionMode = false
        selectedEmailIds.removeAll()
    }

    func performAction(_ action: BatchAction) async {
        guard !selectedEmailIds.isEmpty else { return }

        isProcessing = true
        defer { isProcessing = false }

        let emailIds = Array(selectedEmailIds)

        do {
            for emailId in emailIds {
                switch action {
                case .archive:
                    try await GmailService.shared.archive(messageId: emailId)
                case .trash:
                    try await GmailService.shared.trash(messageId: emailId)
                case .markRead:
                    try await GmailService.shared.markAsRead(messageId: emailId)
                case .markUnread:
                    try await GmailService.shared.markAsUnread(messageId: emailId)
                case .star:
                    try await GmailService.shared.star(messageId: emailId)
                case .unstar:
                    try await GmailService.shared.unstar(messageId: emailId)
                case .spam:
                    try await GmailService.shared.reportSpam(messageId: emailId)
                case .important:
                    try await GmailService.shared.markImportant(messageId: emailId)
                }
            }

            HapticFeedback.success()
            exitSelectionMode()
        } catch {
            self.error = error
            HapticFeedback.error()
        }
    }
}

// MARK: - Batch Action Bar

struct BatchActionBar: View {
    @ObservedObject var viewModel: BatchOperationsViewModel
    let onRefresh: () async -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack {
                // Selection count
                Text("\(viewModel.selectedCount) selected")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                // Quick actions
                HStack(spacing: 16) {
                    BatchActionButton(action: .archive) {
                        Task { await viewModel.performAction(.archive) }
                    }

                    BatchActionButton(action: .trash) {
                        Task { await viewModel.performAction(.trash) }
                    }

                    BatchActionButton(action: .markRead) {
                        Task { await viewModel.performAction(.markRead) }
                    }

                    // More menu
                    Menu {
                        ForEach(BatchAction.allCases, id: \.self) { action in
                            Button(action: {
                                Task {
                                    await viewModel.performAction(action)
                                    await onRefresh()
                                }
                            }) {
                                Label(action.rawValue, systemImage: action.icon)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                    }
                }
            }
            .padding()
            .background(.ultraThinMaterial)
        }
        .overlay {
            if viewModel.isProcessing {
                ProgressView()
                    .padding()
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

struct BatchActionButton: View {
    let action: BatchAction
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: action.icon)
                .font(.title3)
                .foregroundStyle(action.color)
        }
    }
}

// MARK: - Selectable Email Row

struct SelectableEmailRow: View {
    let email: EmailDTO
    let isSelected: Bool
    let onToggle: () -> Void
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Selection checkbox
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? .blue : .secondary)
            }
            .buttonStyle(.plain)

            // Email content
            EmailRowContent(email: email)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
    }
}

struct EmailRowContent: View {
    let email: EmailDTO

    var body: some View {
        HStack(spacing: 10) {
            SmartAvatarView(
                email: email.senderEmail,
                name: email.senderName,
                size: 36
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(email.senderName)
                        .font(.subheadline)
                        .fontWeight(email.isUnread ? .semibold : .regular)
                        .lineLimit(1)

                    Spacer()

                    if email.isStarred {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                }

                Text(email.subject)
                    .font(.caption)
                    .fontWeight(email.isUnread ? .medium : .regular)
                    .lineLimit(1)

                Text(email.snippet)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if email.isUnread {
                Circle()
                    .fill(.blue)
                    .frame(width: 6, height: 6)
            }
        }
    }
}

// MARK: - Print Email Functionality

struct PrintEmailButton: View {
    let email: EmailDetail

    var body: some View {
        Button(action: printEmail) {
            Label("Print", systemImage: "printer")
        }
    }

    private func printEmail() {
        let printController = UIPrintInteractionController.shared

        let printInfo = UIPrintInfo(dictionary: nil)
        printInfo.outputType = .general
        printInfo.jobName = email.subject
        printController.printInfo = printInfo

        // Create HTML for printing
        let html = buildPrintableHTML()

        let formatter = UIMarkupTextPrintFormatter(markupText: html)
        formatter.perPageContentInsets = UIEdgeInsets(top: 72, left: 72, bottom: 72, right: 72)
        printController.printFormatter = formatter

        printController.present(animated: true) { _, completed, error in
            if completed {
                batchLogger.info("Print job completed successfully")
            } else if let error = error {
                batchLogger.error("Print error: \(error.localizedDescription)")
            }
        }
    }

    private func buildPrintableHTML() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .full
        dateFormatter.timeStyle = .short

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                    line-height: 1.6;
                    color: #333;
                    max-width: 800px;
                    margin: 0 auto;
                }
                .header {
                    border-bottom: 1px solid #e0e0e0;
                    padding-bottom: 16px;
                    margin-bottom: 24px;
                }
                .subject {
                    font-size: 24px;
                    font-weight: bold;
                    margin-bottom: 16px;
                }
                .meta {
                    font-size: 14px;
                    color: #666;
                }
                .meta-row {
                    margin-bottom: 4px;
                }
                .meta-label {
                    font-weight: 600;
                    display: inline-block;
                    width: 60px;
                }
                .body {
                    font-size: 16px;
                }
                img {
                    max-width: 100%;
                    height: auto;
                }
                @media print {
                    body { font-size: 12pt; }
                    .no-print { display: none; }
                }
            </style>
        </head>
        <body>
            <div class="header">
                <div class="subject">\(escapeHTML(email.subject))</div>
                <div class="meta">
                    <div class="meta-row">
                        <span class="meta-label">From:</span>
                        \(escapeHTML(email.from))
                    </div>
                    <div class="meta-row">
                        <span class="meta-label">To:</span>
                        \(escapeHTML(email.to.joined(separator: ", ")))
                    </div>
                    \(email.cc.isEmpty ? "" : """
                    <div class="meta-row">
                        <span class="meta-label">Cc:</span>
                        \(escapeHTML(email.cc.joined(separator: ", ")))
                    </div>
                    """)
                    <div class="meta-row">
                        <span class="meta-label">Date:</span>
                        \(dateFormatter.string(from: email.date))
                    </div>
                </div>
            </div>
            <div class="body">
                \(email.body)
            </div>
        </body>
        </html>
        """
    }

    private func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Print Extension for EmailDetailView

extension EmailDetailViewModel {
    func printCurrentEmail() {
        guard let lastMessage = messages.last else { return }

        let printController = UIPrintInteractionController.shared

        let printInfo = UIPrintInfo(dictionary: nil)
        printInfo.outputType = .general
        printInfo.jobName = lastMessage.subject
        printController.printInfo = printInfo

        let html = buildPrintableHTML(for: lastMessage)
        let formatter = UIMarkupTextPrintFormatter(markupText: html)
        formatter.perPageContentInsets = UIEdgeInsets(top: 72, left: 72, bottom: 72, right: 72)
        printController.printFormatter = formatter

        printController.present(animated: true, completionHandler: nil)
    }

    private func buildPrintableHTML(for email: EmailDetail) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .full
        dateFormatter.timeStyle = .short

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <style>
                body { font-family: -apple-system, sans-serif; line-height: 1.6; color: #333; }
                .header { border-bottom: 1px solid #e0e0e0; padding-bottom: 16px; margin-bottom: 24px; }
                .subject { font-size: 20px; font-weight: bold; margin-bottom: 12px; }
                .meta { font-size: 12px; color: #666; }
                img { max-width: 100%; }
            </style>
        </head>
        <body>
            <div class="header">
                <div class="subject">\(email.subject)</div>
                <div class="meta">
                    <div>From: \(email.from)</div>
                    <div>To: \(email.to.joined(separator: ", "))</div>
                    <div>Date: \(dateFormatter.string(from: email.date))</div>
                </div>
            </div>
            <div>\(email.body)</div>
        </body>
        </html>
        """
    }
}
