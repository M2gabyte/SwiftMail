import SwiftUI

/// Single anchored bottom surface for inbox navigation (Apple Mail-style).
/// Contains filter, search, and compose controls in a unified command surface.
struct BottomCommandSurface: View {
    let isFilterActive: Bool
    let activeFilterLabel: String?
    var showSearchPill: Bool = true
    let onTapFilter: () -> Void
    let onTapSearch: () -> Void
    let onTapCompose: () -> Void

    @State private var searchPillPressed = false

    // MARK: - Computed Properties

    private var filterButtonWidth: CGFloat {
        if !showSearchPill {
            // When search is hidden, filter chip can be wider
            return isFilterActive ? 200 : 44
        }
        return isFilterActive ? 180 : 44
    }

    var body: some View {
        HStack(spacing: 12) {
            // Left: Filter button/chip
            filterControl
                .frame(width: filterButtonWidth, alignment: .leading)

            // Center: Search pill (expands to fill) - hidden when search placement is pull-down
            if showSearchPill {
                searchPill
                    .frame(maxWidth: .infinity)
            } else {
                Spacer()
            }

            // Right: Compose button
            composeButton
                .frame(width: 44)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isFilterActive)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: showSearchPill)
    }

    // MARK: - Filter Control

    @ViewBuilder
    private var filterControl: some View {
        Button(action: onTapFilter) {
            HStack(spacing: 6) {
                Image(systemName: isFilterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isFilterActive ? .blue : .primary)

                if isFilterActive, let label = activeFilterLabel {
                    Text("Filtered: \(label)")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, isFilterActive ? 12 : 0)
            .padding(.vertical, 8)
            .frame(height: 40)
            .background(
                Group {
                    if isFilterActive {
                        Capsule()
                            .fill(Color.blue.opacity(0.12))
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.blue.opacity(0.25), lineWidth: 1)
                            )
                    }
                }
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFilterActive ? "Filter: \(activeFilterLabel ?? "active")" : "Filter")
        .accessibilityHint("Opens filter options")
    }

    // MARK: - Search Pill

    @ViewBuilder
    private var searchPill: some View {
        Button(action: onTapSearch) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isFilterActive ? .secondary : .primary.opacity(0.7))

                Text("Search")
                    .font(.subheadline)
                    .foregroundStyle(isFilterActive ? .secondary : .primary.opacity(0.6))

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(height: 40)
            .background(
                Capsule()
                    .fill(Color(.systemGray5).opacity(isFilterActive ? 0.5 : 0.8))
            )
            .opacity(isFilterActive ? 0.7 : 1.0)
            .scaleEffect(searchPillPressed ? 0.97 : 1.0)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in searchPillPressed = true }
                .onEnded { _ in searchPillPressed = false }
        )
        .accessibilityLabel("Search emails")
    }

    // MARK: - Compose Button

    @ViewBuilder
    private var composeButton: some View {
        Button(action: onTapCompose) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.blue)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Compose new email")
    }
}

// MARK: - Preview

#Preview("Default State") {
    ZStack {
        Color(.systemGroupedBackground)
            .ignoresSafeArea()

        VStack {
            Spacer()
            BottomCommandSurface(
                isFilterActive: false,
                activeFilterLabel: nil,
                onTapFilter: { print("Filter tapped") },
                onTapSearch: { print("Search tapped") },
                onTapCompose: { print("Compose tapped") }
            )
        }
    }
}

#Preview("Filter Active") {
    ZStack {
        Color(.systemGroupedBackground)
            .ignoresSafeArea()

        VStack {
            Spacer()
            BottomCommandSurface(
                isFilterActive: true,
                activeFilterLabel: "Unread",
                onTapFilter: { print("Filter tapped") },
                onTapSearch: { print("Search tapped") },
                onTapCompose: { print("Compose tapped") }
            )
        }
    }
}
