import SwiftUI

/// A compact row displaying a Gmail bucket (Promotions/Updates/Social) with unseen count semantics.
struct CategoryBundleRow: View {
    let model: BucketRowModel
    let onTap: () -> Void

    private var category: GmailCategory { model.bucket.category }

    private var hasUnseen: Bool {
        model.unseenCount > 0
    }

    private var previewText: String {
        guard let email = model.latestEmail else { return "" }
        let sender = email.senderName.isEmpty ? email.senderEmail : email.senderName
        return "\(sender) - \(email.displaySubject)"
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Category icon with colored background
                ZStack {
                    Circle()
                        .fill(category.color.opacity(0.14))
                        .frame(width: 36, height: 36)

                    Image(systemName: category.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(category.color)
                }

                // Content
                VStack(alignment: .leading, spacing: 3) {
                    // Top row: category name + unread badge + chevron
                    HStack(spacing: 8) {
                        Text(category.displayName)
                            .font(.subheadline.weight(hasUnseen ? .semibold : .medium))
                            .foregroundStyle(.primary)

                        if hasUnseen {
                            Text("\(model.unseenCount) new")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(category.color)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(category.color.opacity(0.12))
                                )
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }

                    // Preview text
                    if !previewText.isEmpty {
                        Text(previewText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color(.systemBackground))
    }
}

/// A section containing all category bundles for the Primary tab
struct CategoryBundlesSection: View {
    let bundles: [BucketRowModel]
    let onTapBundle: (GmailBucket) -> Void

    var body: some View {
        if !bundles.isEmpty {
            VStack(spacing: 0) {
                ForEach(bundles) { bundle in
                    CategoryBundleRow(model: bundle) {
                        onTapBundle(bundle.bucket)
                    }

                    if bundle.id != bundles.last?.id {
                        Divider()
                            .padding(.leading, 64)
                    }
                }
            }
        }
    }
}

/// Header shown when viewing a specific category (after tapping a bundle)
struct CategoryViewingHeader: View {
    let category: GmailCategory
    let onBack: () -> Void

    var body: some View {
        Button {
            onBack()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(category.color)

                ZStack {
                    Circle()
                        .fill(category.color.opacity(0.15))
                        .frame(width: 32, height: 32)

                    Image(systemName: category.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(category.color)
                }

                Text(category.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer()

                Text("Back to Primary")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(category.color.opacity(0.3), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
