import SwiftUI

struct InboxTabBar: View {
    let selectedTab: InboxTab
    let customLaneTitle: String

    let onTapAll: () -> Void
    let onTapPrimary: () -> Void
    let onTapCustom: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            segment(title: "All", isSelected: selectedTab == .all, action: onTapAll)
            segment(title: "Primary", isSelected: selectedTab == .primary, action: onTapPrimary)
            segmentCustom(title: customLaneTitle, isSelected: selectedTab == .custom, action: onTapCustom)
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.secondarySystemFill))
        )
        .accessibilityElement(children: .contain)
    }

    private func segment(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selectionBackground(isSelected: isSelected))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func segmentCustom(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .frame(maxWidth: .infinity, minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selectionBackground(isSelected: isSelected))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityLabel("\(title), configurable tab")
        .accessibilityHint("Double tap to switch. Double tap again while selected to choose a different lane.")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private func selectionBackground(isSelected: Bool) -> some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
        } else {
            Color.clear
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        InboxTabBar(
            selectedTab: .primary,
            customLaneTitle: "Money",
            onTapAll: {},
            onTapPrimary: {},
            onTapCustom: {}
        )
        .padding(.horizontal)

        InboxTabBar(
            selectedTab: .custom,
            customLaneTitle: "Newsletters",
            onTapAll: {},
            onTapPrimary: {},
            onTapCustom: {}
        )
        .padding(.horizontal)
    }
}
