import SwiftUI

// MARK: - Smart Avatar View

/// Avatar with intelligent fallback chain:
/// 1. Contact Photo (from Google People API) - highest priority
/// 2. Brand Logo (for business domains)
/// 3. Initials + Deterministic Color (fallback)
struct SmartAvatarView: View {
    let email: String
    let name: String
    var size: CGFloat = 40

    @State private var contactPhotoURL: URL?
    @State private var brandLogoFailed = false
    @State private var isLoading = true

    var body: some View {
        ZStack {
            // Layer 1: Colored circle with initials (always present as base)
            InitialsAvatarView(
                name: name,
                email: email,
                size: size
            )

            // Layer 2: Brand logo (if business domain and not failed)
            if !isPersonalDomain && !brandLogoFailed, let brandURL = brandLogoURL {
                AsyncImage(url: brandURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .onAppear {
                                Task {
                                    await AvatarService.shared.markBrandLogoLoaded(domain, success: true)
                                }
                            }
                    case .failure:
                        Color.clear
                            .onAppear {
                                brandLogoFailed = true
                                Task {
                                    await AvatarService.shared.markBrandLogoLoaded(domain, success: false)
                                }
                            }
                    case .empty:
                        Color.clear
                    @unknown default:
                        Color.clear
                    }
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
            }

            // Layer 3: Contact photo (highest priority, overlays everything)
            if let photoURL = contactPhotoURL {
                AsyncImage(url: photoURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure, .empty:
                        Color.clear
                    @unknown default:
                        Color.clear
                    }
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .task {
            await loadContactPhoto()
        }
    }

    // MARK: - Computed Properties

    private var domain: String {
        guard let atIndex = email.lastIndex(of: "@") else { return "" }
        return String(email[email.index(after: atIndex)...]).lowercased()
    }

    private var isPersonalDomain: Bool {
        Task.detached { @MainActor in
            await AvatarService.shared.isPersonalDomain(domain)
        }
        // For the sync check, use a simple list
        let personalDomains: Set<String> = [
            "gmail.com", "googlemail.com", "outlook.com", "hotmail.com",
            "live.com", "msn.com", "yahoo.com", "ymail.com", "icloud.com",
            "me.com", "mac.com", "aol.com", "protonmail.com", "proton.me"
        ]
        return personalDomains.contains(domain)
    }

    private var brandLogoURL: URL? {
        guard !domain.isEmpty else { return nil }
        return URL(string: "https://t3.gstatic.com/faviconV2?client=SOCIAL&type=FAVICON&fallback_opts=TYPE,SIZE,URL&url=http://\(domain)&size=256")
    }

    // MARK: - Load Contact Photo

    private func loadContactPhoto() async {
        // Check cache first
        if let cached = await AvatarService.shared.getCachedPhoto(for: email) {
            contactPhotoURL = cached
            isLoading = false
            return
        }

        // Check if already cached (even if nil)
        if await AvatarService.shared.hasPhotoCache(for: email) {
            isLoading = false
            return
        }

        // Look up in People service
        if let photoURL = await PeopleService.shared.getPhotoURL(for: email) {
            await AvatarService.shared.cachePhoto(email: email, url: photoURL)
            contactPhotoURL = photoURL
        } else {
            await AvatarService.shared.cachePhoto(email: email, url: nil)
        }

        isLoading = false
    }
}

// MARK: - Initials Avatar View

/// Simple initials avatar with deterministic background color
struct InitialsAvatarView: View {
    let name: String
    let email: String
    var size: CGFloat = 40

    private let colors: [Color] = [
        .blue, .green, .orange, .purple, .pink, .teal, .indigo, .cyan
    ]

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundColor)

            Text(initials)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }

    private var initials: String {
        // Try to get initials from name
        let words = name.split(separator: " ")
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        if !name.isEmpty {
            return String(name.prefix(2)).uppercased()
        }

        // Fall back to email
        if let atIndex = email.firstIndex(of: "@") {
            return String(email[..<atIndex].prefix(2)).uppercased()
        }
        return "?"
    }

    private var backgroundColor: Color {
        let index = AvatarService.colorIndex(for: email)
        return colors[index]
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        // Personal email - should show initials only
        SmartAvatarView(email: "john.doe@gmail.com", name: "John Doe", size: 60)

        // Business email - should show brand logo
        SmartAvatarView(email: "support@apple.com", name: "Apple Support", size: 60)

        // Unknown domain - should show initials
        SmartAvatarView(email: "someone@randomdomain.xyz", name: "Someone", size: 60)
    }
    .padding()
}
