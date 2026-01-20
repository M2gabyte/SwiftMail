import SwiftUI

/// Single-line top bar: hamburger | segmented tabs | gear
struct InboxTopBar: View {
    let selectedTab: InboxTab
    let customLaneTitle: String
    var isPickerOpen: Bool = false
    let onTapAll: () -> Void
    let onTapPrimary: () -> Void
    let onTapCustom: () -> Void
    let onTapMailbox: () -> Void
    let onTapSettings: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            // LEFT: Hamburger (mailbox picker)
            Button(action: onTapMailbox) {
                GlassIconButton(systemName: "line.3.horizontal")
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .accessibilityLabel("Mailboxes")

            // CENTER: Tabs expand to fill (must be flexible)
            InboxTabBar(
                selectedTab: selectedTab,
                customLaneTitle: customLaneTitle,
                isPickerOpen: isPickerOpen,
                onTapAll: onTapAll,
                onTapPrimary: onTapPrimary,
                onTapCustom: onTapCustom
            )
            .frame(maxWidth: .infinity)

            // RIGHT: Settings gear
            Button(action: onTapSettings) {
                GlassIconButton(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }
}

#Preview {
    VStack {
        InboxTopBar(
            selectedTab: .primary,
            customLaneTitle: "Newsletters",
            onTapAll: {},
            onTapPrimary: {},
            onTapCustom: {},
            onTapMailbox: {},
            onTapSettings: {}
        )
        Spacer()
    }
    .background(Color(.systemGroupedBackground))
}
