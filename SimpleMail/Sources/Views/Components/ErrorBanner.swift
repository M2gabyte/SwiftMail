import SwiftUI

/// Reusable error banner for displaying errors to users
struct ErrorBanner: View {
    let error: Error
    let onDismiss: () -> Void
    let onRetry: (() -> Void)?

    init(error: Error, onDismiss: @escaping () -> Void, onRetry: (() -> Void)? = nil) {
        self.error = error
        self.onDismiss = onDismiss
        self.onRetry = onRetry
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Something went wrong")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)

                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
            }

            Spacer()

            if let onRetry {
                Button {
                    onRetry()
                } label: {
                    Text("Retry")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.2))
                        .clipShape(Capsule())
                }
                .accessibilityLabel("Retry the failed operation")
            }

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .accessibilityLabel("Dismiss error")
        }
        .padding()
        .background(Color.red.gradient)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(errorMessage)")
        .accessibilityAddTraits(.isStaticText)
    }

    private var errorMessage: String {
        // Provide user-friendly error messages
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return "No internet connection. Check your network and try again."
            case .timedOut:
                return "Request timed out. Please try again."
            case .networkConnectionLost:
                return "Network connection lost. Please try again."
            default:
                return "Network error. Please try again later."
            }
        }

        // Handle app-specific errors
        let description = error.localizedDescription
        if description.count > 100 {
            return String(description.prefix(97)) + "..."
        }
        return description
    }
}

/// View modifier to show error banner
struct ErrorBannerModifier: ViewModifier {
    @Binding var error: Error?
    let onRetry: (() -> Void)?

    func body(content: Content) -> some View {
        ZStack(alignment: .top) {
            content

            if let error = error {
                ErrorBanner(
                    error: error,
                    onDismiss: { self.error = nil },
                    onRetry: onRetry
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(100)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: error != nil)
    }
}

extension View {
    /// Shows an error banner when the error binding is non-nil
    func errorBanner(_ error: Binding<Error?>, onRetry: (() -> Void)? = nil) -> some View {
        modifier(ErrorBannerModifier(error: error, onRetry: onRetry))
    }
}

// MARK: - Preview

#Preview {
    VStack {
        ErrorBanner(
            error: URLError(.notConnectedToInternet),
            onDismiss: {},
            onRetry: {}
        )

        Spacer()
    }
    .padding(.top)
}
