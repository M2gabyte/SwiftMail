import SwiftUI
import QuickLook
import UniformTypeIdentifiers
import OSLog

private let attachmentLogger = Logger(subsystem: "com.simplemail.app", category: "Attachments")

// MARK: - Attachment Model

struct EmailAttachment: Identifiable {
    let id: String
    let messageId: String
    let filename: String
    let mimeType: String
    let size: Int

    var icon: String {
        switch mimeType.lowercased() {
        case let type where type.contains("pdf"):
            return "doc.fill"
        case let type where type.contains("image"):
            return "photo.fill"
        case let type where type.contains("video"):
            return "video.fill"
        case let type where type.contains("audio"):
            return "music.note"
        case let type where type.contains("zip") || type.contains("compressed"):
            return "doc.zipper"
        case let type where type.contains("spreadsheet") || type.contains("excel"):
            return "tablecells.fill"
        case let type where type.contains("presentation") || type.contains("powerpoint"):
            return "rectangle.stack.fill"
        case let type where type.contains("word") || type.contains("document"):
            return "doc.text.fill"
        default:
            return "doc.fill"
        }
    }

    var iconColor: Color {
        switch mimeType.lowercased() {
        case let type where type.contains("pdf"):
            return .red
        case let type where type.contains("image"):
            return .blue
        case let type where type.contains("video"):
            return .purple
        case let type where type.contains("audio"):
            return .pink
        case let type where type.contains("zip"):
            return .yellow
        case let type where type.contains("spreadsheet") || type.contains("excel"):
            return .green
        case let type where type.contains("presentation"):
            return .orange
        default:
            return .gray
        }
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

// MARK: - Attachments List View

struct AttachmentsListView: View {
    let attachments: [EmailAttachment]
    @StateObject private var viewModel = AttachmentViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "paperclip")
                    .foregroundStyle(.secondary)
                Text("\(attachments.count) Attachment\(attachments.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(attachments) { attachment in
                        AttachmentCard(
                            attachment: attachment,
                            isDownloading: viewModel.downloadingIds.contains(attachment.id),
                            progress: viewModel.downloadProgress[attachment.id] ?? 0,
                            onTap: {
                                Task {
                                    await viewModel.downloadAndPreview(attachment)
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .quickLookPreview($viewModel.previewURL)
    }
}

// MARK: - Attachment Card

struct AttachmentCard: View {
    let attachment: EmailAttachment
    let isDownloading: Bool
    let progress: Double
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(attachment.iconColor.opacity(0.15))
                        .frame(width: 60, height: 60)

                    if isDownloading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                    } else {
                        Image(systemName: attachment.icon)
                            .font(.title2)
                            .foregroundStyle(attachment.iconColor)
                    }
                }

                VStack(spacing: 2) {
                    Text(attachment.filename)
                        .font(.caption)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)

                    Text(attachment.formattedSize)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 80)
            .padding(8)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .disabled(isDownloading)
    }
}

// MARK: - Attachment ViewModel

@MainActor
class AttachmentViewModel: ObservableObject {
    @Published var downloadingIds: Set<String> = []
    @Published var downloadProgress: [String: Double] = [:]
    @Published var previewURL: URL?
    @Published var error: Error?

    private var downloadedFiles: [String: URL] = [:]

    func downloadAndPreview(_ attachment: EmailAttachment) async {
        // Check if already downloaded
        if let cachedURL = downloadedFiles[attachment.id],
           FileManager.default.fileExists(atPath: cachedURL.path) {
            previewURL = cachedURL
            return
        }

        downloadingIds.insert(attachment.id)
        downloadProgress[attachment.id] = 0

        do {
            // Download attachment data
            let data = try await GmailService.shared.fetchAttachment(
                messageId: attachment.messageId,
                attachmentId: attachment.id
            )

            downloadProgress[attachment.id] = 0.8

            // Save to temp directory
            let tempDir = FileManager.default.temporaryDirectory
            let fileURL = tempDir.appendingPathComponent(attachment.filename)

            try data.write(to: fileURL)

            downloadProgress[attachment.id] = 1.0
            downloadedFiles[attachment.id] = fileURL

            // Open preview
            previewURL = fileURL

        } catch {
            self.error = error
            attachmentLogger.error("Download failed: \(error.localizedDescription)")
        }

        downloadingIds.remove(attachment.id)
    }

    func shareAttachment(_ attachment: EmailAttachment) async -> URL? {
        if let cachedURL = downloadedFiles[attachment.id] {
            return cachedURL
        }

        do {
            let data = try await GmailService.shared.fetchAttachment(
                messageId: attachment.messageId,
                attachmentId: attachment.id
            )

            let tempDir = FileManager.default.temporaryDirectory
            let fileURL = tempDir.appendingPathComponent(attachment.filename)
            try data.write(to: fileURL)

            downloadedFiles[attachment.id] = fileURL
            return fileURL
        } catch {
            self.error = error
            return nil
        }
    }

    func clearCache() {
        for (_, url) in downloadedFiles {
            try? FileManager.default.removeItem(at: url)
        }
        downloadedFiles.removeAll()
    }
}

// MARK: - QuickLook Preview

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
        context.coordinator.url = url
        uiViewController.reloadData()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as QLPreviewItem
        }
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Attachment Parsing Helper

extension GmailService {
    func parseAttachments(from message: MessageResponse) -> [EmailAttachment] {
        var attachments: [EmailAttachment] = []

        func extractFromParts(_ parts: [Part]?, messageId: String) {
            guard let parts = parts else { return }

            for part in parts {
                if let filename = part.filename, !filename.isEmpty,
                   let attachmentId = part.body?.attachmentId {
                    attachments.append(EmailAttachment(
                        id: attachmentId,
                        messageId: messageId,
                        filename: filename,
                        mimeType: part.mimeType ?? "application/octet-stream",
                        size: part.body?.size ?? 0
                    ))
                }

                // Check nested parts
                extractFromParts(part.parts, messageId: messageId)
            }
        }

        extractFromParts(message.payload?.parts, messageId: message.id)
        return attachments
    }
}
