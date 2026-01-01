import SwiftUI

struct BottomSearchPill: View {
    @Binding var text: String
    @FocusState.Binding var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.secondary)

            TextField("Search", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)

            Button(action: {}) {
                Image(systemName: "mic")
                    .font(.system(size: 16, weight: .regular))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { focused = true }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var text = ""
        @FocusState private var focused: Bool

        var body: some View {
            BottomSearchPill(text: $text, focused: $focused)
                .padding()
        }
    }
    return PreviewWrapper()
}
