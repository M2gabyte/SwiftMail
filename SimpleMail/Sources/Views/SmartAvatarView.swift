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
    @State private var showBrandLogo = false

    var body: some View {
        ZStack {
            // Layer 1: Colored circle with initials (always present as base)
            InitialsAvatarView(
                name: name,
                email: email,
                size: size
            )

            // Layer 2: Brand logo (if business domain and loaded successfully)
            if showBrandLogo && !brandLogoFailed, let brandURL = brandLogoURL {
                // White background circle to handle transparent favicons
                Circle()
                    .fill(.white)
                    .frame(width: size, height: size)

                AsyncImage(url: brandURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .clipShape(Circle())
                            .frame(width: size, height: size)
                    case .failure:
                        Color.clear
                            .onAppear {
                                brandLogoFailed = true
                            }
                    case .empty:
                        // Loading - show nothing, initials visible underneath
                        Color.clear
                    @unknown default:
                        Color.clear
                    }
                }
                .frame(width: size, height: size)
            }

            // Layer 3: Contact photo (highest priority, overlays everything)
            if let photoURL = contactPhotoURL {
                AsyncImage(url: photoURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: size, height: size)
                            .clipShape(Circle())
                    case .failure, .empty:
                        Color.clear
                    @unknown default:
                        Color.clear
                    }
                }
                .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            // Determine if we should try to load brand logo
            showBrandLogo = !isPersonalDomain && !domain.isEmpty
        }
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
        let personalDomains: Set<String> = [
            "gmail.com", "googlemail.com",
            "outlook.com", "hotmail.com", "live.com", "msn.com",
            "yahoo.com", "ymail.com",
            "icloud.com", "me.com", "mac.com",
            "aol.com",
            "protonmail.com", "proton.me",
            "zoho.com",
            "fastmail.com",
            "hey.com",
            "tutanota.com", "tutamail.com"
        ]
        return personalDomains.contains(domain)
    }

    private var brandLogoURL: URL? {
        guard !domain.isEmpty else { return nil }
        // Use domain aliases if available
        let effectiveDomain = domainAliases[domain] ?? domain
        return URL(string: "https://t3.gstatic.com/faviconV2?client=SOCIAL&type=FAVICON&fallback_opts=TYPE,SIZE,URL&url=http://\(effectiveDomain)&size=128")
    }

    // Common domain aliases for better brand recognition
    private var domainAliases: [String: String] {
        [
            "vzw.com": "verizon.com",
            "vtext.com": "verizon.com",
            "bloomberglp.com": "bloomberg.com",
            "e.flyspirit.com": "spirit.com",
            "mail.capitalone.com": "capitalone.com",
            "email.capitalone.com": "capitalone.com",
            "alerts.chase.com": "chase.com",
            "chaseonline.com": "chase.com",
            "em.bankofamerica.com": "bankofamerica.com",
            "ealerts.bankofamerica.com": "bankofamerica.com",
            "email.americanexpress.com": "americanexpress.com",
            "welcome.aexp.com": "americanexpress.com",
            "alerts.comcast.net": "xfinity.com",
            "comcast.net": "xfinity.com",
            "facebookmail.com": "facebook.com",
            "mail.instagram.com": "instagram.com",
            "email.uber.com": "uber.com",
            "em.lyft.com": "lyft.com",
            "mail.doordash.com": "doordash.com",
            "email.grubhub.com": "grubhub.com"
        ]
    }

    // MARK: - Load Contact Photo

    private func loadContactPhoto() async {
        // Check cache first
        if let cached = await AvatarService.shared.getCachedPhoto(for: email) {
            contactPhotoURL = cached
            return
        }

        // Check if already cached (even if nil)
        if await AvatarService.shared.hasPhotoCache(for: email) {
            return
        }

        // Look up in People service
        if let photoURL = await PeopleService.shared.getPhotoURL(for: email) {
            await AvatarService.shared.cachePhoto(email: email, url: photoURL)
            contactPhotoURL = photoURL
        } else {
            await AvatarService.shared.cachePhoto(email: email, url: nil)
        }
    }
}

// MARK: - Initials Avatar View

/// Simple initials avatar with deterministic background color
struct InitialsAvatarView: View {
    let name: String
    let email: String
    var size: CGFloat = 40

    private let colors: [Color] = [
        Color(red: 0.2, green: 0.5, blue: 0.9),   // Blue
        Color(red: 0.2, green: 0.7, blue: 0.4),   // Green
        Color(red: 0.95, green: 0.5, blue: 0.2),  // Orange
        Color(red: 0.6, green: 0.3, blue: 0.8),   // Purple
        Color(red: 0.9, green: 0.3, blue: 0.5),   // Pink
        Color(red: 0.2, green: 0.6, blue: 0.6),   // Teal
        Color(red: 0.3, green: 0.3, blue: 0.7),   // Indigo
        Color(red: 0.2, green: 0.7, blue: 0.8)    // Cyan
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
        // Use a stable hash based on email
        var hash = 0
        for char in email.lowercased() {
            hash = 31 &* hash &+ Int(char.asciiValue ?? 0)
        }
        let index = abs(hash) % colors.count
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

        // LinkedIn
        SmartAvatarView(email: "jobs@linkedin.com", name: "LinkedIn", size: 60)

        // Unknown domain - should show initials
        SmartAvatarView(email: "someone@randomdomain.xyz", name: "Someone", size: 60)
    }
    .padding()
}
