import SwiftUI

struct BottomSearchPill: View {
    @Binding var text: String
    @FocusState.Binding var focused: Bool
    var onSubmit: (() -> Void)?

    @StateObject private var speechRecognizer = SpeechRecognizer()
    @State private var showVoiceError = false

    var body: some View {
        HStack(spacing: 8) {
            // Search pill
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                if speechRecognizer.isListening {
                    Text("Listening...")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("Search", text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .focused($focused)
                        .onSubmit {
                            onSubmit?()
                        }
                        .accessibilityLabel("Search emails")
                }

                // Voice or Clear button
                if speechRecognizer.isListening {
                    Button {
                        speechRecognizer.stopListening()
                    } label: {
                        Image(systemName: "waveform")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.red)
                            .symbolEffect(.variableColor.iterative)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop listening")
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
                    .accessibilityLabel("Clear search")
                } else {
                    Button {
                        let generator = UIImpactFeedbackGenerator(style: .medium)
                        generator.impactOccurred()
                        speechRecognizer.startListening()
                        focused = true
                    } label: {
                        Image(systemName: "mic")
                            .font(.system(size: 16, weight: .regular))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Voice search")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(.thinMaterial)
                    .overlay(
                        speechRecognizer.isListening ?
                        Capsule().strokeBorder(Color.red.opacity(0.5), lineWidth: 2) : nil
                    )
            )
            .contentShape(Capsule())
            .onTapGesture { focused = true }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Search")

            // Cancel button when focused or has text
            if focused || !text.isEmpty || speechRecognizer.isListening {
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
                .accessibilityLabel("Cancel search")
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
        .onChange(of: speechRecognizer.error) { _, newValue in
            if newValue != nil {
                showVoiceError = true
            }
        }
        .alert("Voice Search", isPresented: $showVoiceError) {
            Button("OK") {
                speechRecognizer.error = nil
            }
        } message: {
            Text(speechRecognizer.error ?? "Unable to access microphone. Please check Settings > Privacy > Microphone.")
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
