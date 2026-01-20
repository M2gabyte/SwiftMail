import SwiftUI

/// Apple Mail-style bottom command bar (iOS 26).
/// Left: hamburger menu, Center: search, Right: compose button.
struct BottomCommandSurface: View {
    var searchMode: SearchMode = .idle
    var showSearchField: Bool = true
    @Binding var searchText: String
    @Binding var searchFocused: Bool
    let onSubmitSearch: () -> Void
    let onTapSearch: () -> Void
    let onCancelSearch: () -> Void
    let onTapMenu: () -> Void
    let onTapCompose: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var fieldBackground: Color {
        colorScheme == .dark ? Color(white: 0.15) : Color(.secondarySystemBackground)
    }

    var body: some View {
        let isSearchActive = (searchMode == .editing) || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isEditing = searchMode == .editing
        HStack(spacing: isEditing ? 6 : 8) {
            if !isEditing {
                menuButton
            }

            centerSearchContent
                .frame(maxWidth: .infinity)
                .id("searchField")

            if isEditing {
                Button(action: { onCancelSearch() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(GlassTokens.surfaceMaterial))
                        .glassStroke(Circle())
                }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("Cancel search")
            } else {
                composeButton
            }
        }
        .padding(.horizontal, isEditing ? 8 : 12)
        .padding(.vertical, 2)
        .padding(.bottom, isEditing ? 10 : -2) // add space above keyboard QuickType bar when editing
        .animation(.snappy(duration: 0.22), value: isSearchActive)
    }

    private var menuButton: some View {
        Button(action: onTapMenu) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(GlassTokens.chromeMaterial))
                .glassStroke(Circle())
                .glassShadow()
        }
        .buttonStyle(.plain)
        .frame(width: 50, height: 50)
        .contentShape(Rectangle())
        .accessibilityLabel("Mailboxes")
        .accessibilityHint("Double tap to open mailboxes and settings")
    }

    private var composeButton: some View {
        Button(action: onTapCompose) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Circle().fill(GlassTokens.chromeMaterial))
                .glassStroke(Circle())
                .glassShadow()
        }
        .buttonStyle(.plain)
        .frame(width: 50, height: 50)
        .contentShape(Rectangle())
        .accessibilityLabel("Compose new email")
        .accessibilityHint("Double tap to write a new message")
    }

    @ViewBuilder
    private var centerSearchContent: some View {
        MailSearchField(
            text: $searchText,
            isFocused: $searchFocused,
            onSubmit: onSubmitSearch,
            onBeginEditing: onTapSearch
        )
        .frame(height: 44)
        .background(Capsule().fill(fieldBackground))
        .glassStroke(Capsule())
        .opacity(showSearchField ? 1 : 0)
        .allowsHitTesting(showSearchField)
        .accessibilityHidden(!showSearchField)
        .accessibilityLabel("Search emails")
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
                        searchMode: .idle,
                        showSearchField: true,
                        searchText: $searchText,
                        searchFocused: $searchFocused,
                        onSubmitSearch: { },
                        onTapSearch: { },
                        onCancelSearch: { },
                        onTapMenu: { },
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
