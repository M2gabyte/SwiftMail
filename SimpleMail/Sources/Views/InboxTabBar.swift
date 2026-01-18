import SwiftUI

struct InboxTabBar: View {
    let selectedTab: InboxTab
    let customLaneTitle: String
    var isPickerOpen: Bool = false

    let onTapAll: () -> Void
    let onTapPrimary: () -> Void
    let onTapCustom: () -> Void

    @State private var customLabelScale: CGFloat = 1.0

    var body: some View {
        HStack(spacing: 0) {
            // "All" - short, no special handling needed
            segmentAll(isSelected: selectedTab == .all, action: onTapAll)

            // "Primary" - medium priority
            segmentPrimary(isSelected: selectedTab == .primary, action: onTapPrimary)

            // Custom lane (e.g., "Newsletters") - highest priority, never truncate
            segmentCustom(title: customLaneTitle, isSelected: selectedTab == .custom, action: {
                if selectedTab == .custom {
                    // Spring animation on re-tap
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
                        customLabelScale = 0.92
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
                            customLabelScale = 1.0
                        }
                    }
                    // Haptic on open
                    let generator = UIImpactFeedbackGenerator(style: .light)
                    generator.impactOccurred()
                }
                onTapCustom()
            })
        }
        .padding(GlassTokens.containerPadding)
        .background(
            RoundedRectangle(cornerRadius: GlassTokens.radiusMedium, style: .continuous)
                .fill(GlassTokens.secondaryFill)
        )
        .glassStroke(RoundedRectangle(cornerRadius: GlassTokens.radiusMedium, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
    }

    // MARK: - "All" segment (short, default handling)
    private func segmentAll(isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("All")
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selectionBackground(isSelected: isSelected))
        .clipShape(RoundedRectangle(cornerRadius: GlassTokens.radiusSmall - 1, style: .continuous))
        .accessibilityLabel("All")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - "Primary" segment (medium priority)
    private func segmentPrimary(isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Primary")
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .allowsTightening(true)
                .minimumScaleFactor(0.9)
                .layoutPriority(1)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selectionBackground(isSelected: isSelected))
        .clipShape(RoundedRectangle(cornerRadius: GlassTokens.radiusSmall - 1, style: .continuous))
        .accessibilityLabel("Primary")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Custom segment (picker-style, highest priority, NEVER truncate)
    private func segmentCustom(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        let segmentShape = RoundedRectangle(cornerRadius: GlassTokens.radiusSmall - 1, style: .continuous)

        return Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .allowsTightening(true)
                    .minimumScaleFactor(0.85)
                    .layoutPriority(2)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isPickerOpen ? -180 : 0))
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isPickerOpen)
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .frame(maxWidth: .infinity, minHeight: 28)
            .contentShape(Rectangle())
            .scaleEffect(customLabelScale)
        }
        .buttonStyle(.plain)
        .background(selectionBackground(isSelected: isSelected))
        .clipShape(segmentShape)
        .accessibilityLabel("\(title), configurable tab")
        .accessibilityHint("Double tap to switch. Double tap again while selected to choose a different lane.")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private func selectionBackground(isSelected: Bool) -> some View {
        if isSelected {
            RoundedRectangle(cornerRadius: GlassTokens.radiusSmall - 1, style: .continuous)
                .fill(GlassTokens.systemBackground)
                .shadow(
                    color: GlassTokens.shadowColor.opacity(GlassTokens.shadowOpacity),
                    radius: 1,
                    y: 1
                )
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
            isPickerOpen: true,
            onTapAll: {},
            onTapPrimary: {},
            onTapCustom: {}
        )
        .padding(.horizontal)
    }
}
