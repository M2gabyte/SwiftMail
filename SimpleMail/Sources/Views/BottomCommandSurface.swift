import SwiftUI

/// Apple Mail-style bottom command bar (iOS 26).
/// Left: filter/menu button, Center: search, Right: compose button.
struct BottomCommandSurface: View {
    let isFilterActive: Bool
    let activeFilterLabel: String?
    let activeFilterCount: Int?
    var searchMode: SearchMode = .idle
    var showSearchField: Bool = true
    @Binding var searchText: String
    @Binding var searchFocused: Bool
    let onSubmitSearch: () -> Void
    let onTapSearch: () -> Void
    let onCancelSearch: () -> Void
    let onTapFilter: () -> Void
    let onTapCompose: () -> Void

    var body: some View {
        let isSearchActive = (searchMode == .editing) || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isEditing = searchMode == .editing
        HStack(spacing: isEditing ? 6 : 8) {
            if !isEditing {
                leftButton
                    .frame(width: 48, height: 48)
            }

            centerSearchContent
                .frame(maxWidth: .infinity)
                .id("searchField")

            if isEditing {
                Button(action: { onCancelSearch() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
                .accessibilityLabel("Cancel search")
            } else {
                rightButton
            }
        }
        .padding(.horizontal, isEditing ? 8 : 12)
        .padding(.vertical, 6)
        .padding(.bottom, 0)
        .animation(.snappy(duration: 0.22), value: isSearchActive)
    }

    private var leftButton: some View {
        Button(action: onTapFilter) {
            Image(systemName: isFilterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(isFilterActive ? Color.accentColor : .secondary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(.regularMaterial))
                .overlay(
                    Circle()
                        .stroke(Color(.separator).opacity(0.22), lineWidth: 0.5)
                )
                .overlay(alignment: .topTrailing) {
                    if isFilterActive {
                        FilterActiveBadge(count: activeFilterCount)
                            .offset(x: 6, y: -6)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFilterActive)
        }
        .buttonStyle(.plain)
        .frame(width: 50, height: 50)
        .contentShape(Rectangle())
        .accessibilityLabel(filterAccessibilityLabel)
        .accessibilityHint(isFilterActive ? "Double tap to change or clear filter" : "Double tap to add a filter")
    }

    private var rightButton: some View {
        ZStack {
            Button(action: onTapCompose) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.regularMaterial))
                    .overlay(
                        Circle()
                            .stroke(Color(.separator).opacity(0.22), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .frame(width: 50, height: 50)
            .contentShape(Rectangle())
            .accessibilityLabel("Compose new email")
            .accessibilityHint("Double tap to write a new message")

        }
    }

    @ViewBuilder
    private var centerSearchContent: some View {
        MailSearchField(
            text: $searchText,
            isFocused: $searchFocused,
            onSubmit: onSubmitSearch,
            onBeginEditing: onTapSearch
        )
        .frame(height: 42)
        .background(
            Capsule()
                .fill(.regularMaterial)
        )
        .overlay(
            Capsule()
                .stroke(Color(.separator).opacity(0.14), lineWidth: 0.5)
        )
        .opacity(showSearchField ? 1 : 0)
        .allowsHitTesting(showSearchField)
        .accessibilityHidden(!showSearchField)
        .accessibilityLabel("Search emails")
    }

    private var filterAccessibilityLabel: String {
        guard isFilterActive else {
            return "Filter"
        }
        let label = activeFilterLabel ?? "active"
        if let count = activeFilterCount, count > 0 {
            return "Filter: \(label), \(count) messages"
        }
        return "Filter: \(label)"
    }
}

private struct FilterActiveBadge: View {
    let count: Int?

    var body: some View {
        if let count, count > 0 {
            Text("\(count)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor))
        } else {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)
        }
    }
}

enum SearchMode: Equatable {
    case idle
    case editing
}

#Preview("Mail Bottom Bar") {
    struct BottomBarPreview: View {
        @State private var searchText = ""
        @State private var searchFocused = false

        var body: some View {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()
                VStack {
                    Spacer()
                    BottomCommandSurface(
                        isFilterActive: false,
                        activeFilterLabel: nil,
                        activeFilterCount: nil,
                        searchMode: .idle,
                        showSearchField: true,
                        searchText: $searchText,
                        searchFocused: $searchFocused,
                        onSubmitSearch: { },
                        onTapSearch: { },
                        onCancelSearch: { },
                        onTapFilter: { },
                        onTapCompose: { }
                    )
                }
            }
        }
    }

    return BottomBarPreview()
}

// MARK: - SwiftUI Search Field

private struct MailSearchField: View {
    @Binding var text: String
    @Binding var isFocused: Bool
    let onSubmit: () -> Void
    let onBeginEditing: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.secondary)

            TextField("Search", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .font(.system(size: 17))
                .foregroundStyle(.primary)
                .focused($focused)
                .submitLabel(.search)
                .onSubmit { onSubmit() }

            if text.isEmpty {
                Image(systemName: "mic.fill")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            if !focused {
                focused = true
            }
            if !isFocused {
                isFocused = true
            }
            onBeginEditing()
        }
        .onChange(of: focused) { _, newValue in
            if isFocused != newValue {
                isFocused = newValue
            }
            if newValue {
                onBeginEditing()
            }
        }
        .onChange(of: isFocused) { _, newValue in
            if focused != newValue {
                focused = newValue
            }
        }
    }
}
