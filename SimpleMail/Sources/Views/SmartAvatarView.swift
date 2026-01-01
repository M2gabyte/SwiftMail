import SwiftUI

// MARK: - Smart Avatar View

/// Avatar with intelligent fallback chain matching React Native implementation:
/// 1. Contact Photo (from Google People API) - highest priority
/// 2. Brand Logo (for business domains) with white background
/// 3. Initials + Deterministic Color (fallback)
struct SmartAvatarView: View {
    let email: String
    let name: String
    var size: CGFloat = 40

    @State private var resolution: AvatarService.AvatarResolution?

    var body: some View {
        ZStack {
            // Layer 1: Colored circle with initials (always present as base)
            initialsView

            // Layer 2: Brand logo (for business emails)
            if let logoURL = resolution?.brandLogoURL, let domain = resolution?.brandDomain {
                brandLogoView(url: logoURL, domain: domain)
            }

            // Layer 3: Contact photo (highest priority)
            if let photoURL = resolution?.contactPhotoURL {
                AsyncImage(url: photoURL) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: size, height: size)
                            .clipShape(Circle())
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .task(id: email) {
            await resolveAvatar()
        }
    }

    // MARK: - Initials View

    private var initialsView: some View {
        ZStack {
            Circle()
                .fill(backgroundColor)

            Text(initials)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    // MARK: - Brand Logo View

    @ViewBuilder
    private func brandLogoView(url logoURL: URL, domain: String) -> some View {
        // White background circle
        Circle()
            .fill(.white)
            .frame(width: size, height: size)

        AsyncImage(url: logoURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.75, height: size * 0.75)
                    .onAppear {
                        Task { await AvatarService.shared.markBrandLogoLoaded(domain, success: true) }
                    }
            case .failure:
                Color.clear
                    .onAppear {
                        Task {
                            await AvatarService.shared.markBrandLogoLoaded(domain, success: false)
                            await resolveAvatar()
                        }
                    }
            case .empty:
                // Loading - white circle shows, which is fine
                EmptyView()
            @unknown default:
                EmptyView()
            }
        }
    }

    // MARK: - Computed Properties

    private var initials: String {
        if let initials = resolution?.initials, !initials.isEmpty {
            return initials
        }
        return DomainNormalizer.initials(name: name, email: email)
    }

    private var backgroundColor: Color {
        if let hex = resolution?.backgroundColorHex, let color = Color(hex: hex) {
            return color
        }
        return Color(hex: AvatarService.avatarColorHex(for: email)) ?? .gray
    }

    // MARK: - Load Avatar Data

    @MainActor
    private func resolveAvatar() async {
        let result = await AvatarService.shared.resolveAvatar(email: email, name: name)
        resolution = result
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 16) {
        HStack(spacing: 16) {
            SmartAvatarView(email: "john@gmail.com", name: "John Doe", size: 50)
            SmartAvatarView(email: "jane@outlook.com", name: "Jane Smith", size: 50)
        }
        HStack(spacing: 16) {
            SmartAvatarView(email: "support@apple.com", name: "Apple", size: 50)
            SmartAvatarView(email: "jobs@linkedin.com", name: "LinkedIn", size: 50)
            SmartAvatarView(email: "news@bloomberg.com", name: "Bloomberg", size: 50)
        }
    }
    .padding()
}
