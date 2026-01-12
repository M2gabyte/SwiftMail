import SwiftUI

/// A compact row displaying a collapsed Gmail category bundle.
/// Shows category icon, name, unread count, and preview of latest email.
struct CategoryBundleRow: View {
    let bundle: CategoryBundle
    let onTap: () -> Void

    private var hasUnread: Bool {
        bundle.unreadCount > 0
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Category icon with colored background
                ZStack {
                    Circle()
                        .fill(bundle.category.color.opacity(0.14))
                        .frame(width: 36, height: 36)

                    Image(systemName: bundle.category.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(bundle.category.color)
                }

                // Content
                VStack(alignment: .leading, spacing: 3) {
                    // Top row: category name + unread badge
                    HStack(spacing: 8) {
                        Text(bundle.category.displayName)
                            .font(.subheadline.weight(hasUnread ? .semibold : .medium))
                            .foregroundStyle(.primary)

                        if hasUnread {
                            Text("\(bundle.unreadCount) new")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(bundle.category.color)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(bundle.category.color.opacity(0.12))
                                )
                        }

                        Spacer()

                        // Total count
                        Text("\(bundle.totalCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }

                    // Preview text
                    if !bundle.previewText.isEmpty {
                        Text(bundle.previewText)
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
    let bundles: [CategoryBundle]
    let onTapBundle: (GmailCategory) -> Void

    var body: some View {
        if !bundles.isEmpty {
            VStack(spacing: 0) {
                ForEach(bundles) { bundle in
                    CategoryBundleRow(bundle: bundle) {
                        onTapBundle(bundle.category)
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
