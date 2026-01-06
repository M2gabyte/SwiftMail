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
        HStack(spacing: 10) {
            leftButton

            centerSearchContent
                .frame(maxWidth: .infinity)

            rightButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .padding(.bottom, 2)
        .animation(.snappy(duration: 0.22), value: isSearchActive)
    }

    private var leftButton: some View {
        Button(action: onTapFilter) {
            Image(systemName: isFilterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(isFilterActive ? .blue : .secondary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(
                    Circle()
                        .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
                )
                .overlay(alignment: .topTrailing) {
                    if isFilterActive {
                        FilterActiveBadge(count: activeFilterCount)
                            .offset(x: 6, y: -6)
                    }
                }
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .opacity(searchMode == .editing ? 0 : 1)
        .allowsHitTesting(searchMode != .editing)
        .accessibilityLabel(filterAccessibilityLabel)
    }

    private var rightButton: some View {
        ZStack {
            Button(action: onTapCompose) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.blue)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(.ultraThinMaterial))
                    .overlay(
                        Circle()
                            .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Compose new email")
            .opacity(searchMode == .editing ? 0 : 1)
            .allowsHitTesting(searchMode != .editing)

            Button(action: onCancelSearch) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Cancel search")
            .opacity(searchMode == .editing ? 1 : 0)
            .allowsHitTesting(searchMode == .editing)
        }
    }

    @ViewBuilder
    private var centerSearchContent: some View {
        MailSearchBar(
            text: $searchText,
            isFocused: $searchFocused,
            onSubmit: onSubmitSearch,
            onBeginEditing: onTapSearch
        )
        .frame(height: 32)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
        )
        .overlay(
            Capsule()
                .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
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

// MARK: - UIKit Search Bar

struct MailSearchBar: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let onSubmit: () -> Void
    let onBeginEditing: () -> Void

    func makeUIView(context: Context) -> UISearchBar {
        let searchBar = UISearchBar(frame: .zero)
        searchBar.searchBarStyle = .minimal
        searchBar.placeholder = "Search"
        searchBar.autocapitalizationType = .none
        searchBar.autocorrectionType = .no
        searchBar.returnKeyType = .search
        searchBar.enablesReturnKeyAutomatically = true
        searchBar.isTranslucent = true
        searchBar.backgroundColor = .clear
        searchBar.barTintColor = .clear
        searchBar.delegate = context.coordinator

        let textField = searchBar.searchTextField
        textField.textColor = .label
        textField.tintColor = .systemBlue
        textField.clearButtonMode = .whileEditing
        textField.backgroundColor = .clear

        let mic = UIImageView(image: UIImage(systemName: "mic.fill"))
        mic.tintColor = .secondaryLabel
        mic.contentMode = .scaleAspectFit
        mic.frame = CGRect(x: 0, y: 0, width: 18, height: 18)
        textField.rightView = mic
        textField.rightViewMode = .always

        searchBar.backgroundImage = UIImage()
        searchBar.setBackgroundImage(UIImage(), for: .any, barMetrics: .default)
        searchBar.setSearchFieldBackgroundImage(UIImage(), for: .normal)
        return searchBar
    }

    func updateUIView(_ uiView: UISearchBar, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        let textField = uiView.searchTextField
        textField.rightView?.isHidden = isFocused
        if isFocused && !textField.isFirstResponder {
            textField.becomeFirstResponder()
        } else if !isFocused && textField.isFirstResponder {
            textField.resignFirstResponder()
        }
        if let rightView = textField.rightView as? UIImageView {
            rightView.alpha = isFocused ? 0.25 : 1.0
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused, onSubmit: onSubmit, onBeginEditing: onBeginEditing)
    }

    final class Coordinator: NSObject, UISearchBarDelegate {
        @Binding var text: String
        @Binding var isFocused: Bool
        let onSubmit: () -> Void
        let onBeginEditing: () -> Void

        init(text: Binding<String>, isFocused: Binding<Bool>, onSubmit: @escaping () -> Void, onBeginEditing: @escaping () -> Void) {
            _text = text
            _isFocused = isFocused
            self.onSubmit = onSubmit
            self.onBeginEditing = onBeginEditing
        }

        func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
            text = searchText
        }

        func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
            isFocused = true
            onBeginEditing()
        }

        func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
            isFocused = false
        }

        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
            onSubmit()
            searchBar.searchTextField.resignFirstResponder()
        }
    }
}
