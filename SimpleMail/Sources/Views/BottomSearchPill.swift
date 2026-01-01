import SwiftUI

struct BottomSearchPill: View {
    @Binding var text: String
    @FocusState.Binding var focused: Bool
    var onSubmit: (() -> Void)?

    @StateObject private var speechRecognizer = SpeechRecognizer()

    var body: some View {
        HStack(spacing: 8) {
            // Search pill
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.secondary)

                TextField("Search", text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($focused)
                    .onSubmit {
                        onSubmit?()
                    }

                // Voice or Clear button
                if speechRecognizer.isListening {
                    Button {
                        speechRecognizer.stopListening()
                    } label: {
                        Image(systemName: "waveform")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.red)
                            .symbolEffect(.pulse)
                    }
                    .buttonStyle(.plain)
                } else if !text.isEmpty {
                    Button {
                        let generator = UIImpactFeedbackGenerator(style: .light)
                        generator.impactOccurred()
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16, weight: .regular))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .transition(.scale.combined(with: .opacity))
                } else {
                    Button {
                        let generator = UIImpactFeedbackGenerator(style: .light)
                        generator.impactOccurred()
                        speechRecognizer.startListening()
                        focused = true
                    } label: {
                        Image(systemName: "mic")
                            .font(.system(size: 16, weight: .regular))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: Capsule())
            .contentShape(Capsule())
            .onTapGesture { focused = true }

            // Cancel button when focused or has text
            if focused || !text.isEmpty {
                Button {
                    let generator = UIImpactFeedbackGenerator(style: .light)
                    generator.impactOccurred()
                    text = ""
                    focused = false
                    speechRecognizer.stopListening()
                } label: {
                    Text("Cancel")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: focused)
        .animation(.easeInOut(duration: 0.2), value: text.isEmpty)
        .animation(.easeInOut(duration: 0.2), value: speechRecognizer.isListening)
        .onChange(of: speechRecognizer.transcript) { _, newValue in
            if !newValue.isEmpty {
                text = newValue
            }
        }
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
