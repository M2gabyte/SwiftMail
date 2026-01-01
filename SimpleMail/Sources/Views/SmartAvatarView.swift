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

    @State private var contactPhotoURL: URL?
    @State private var brandLogoError = false

    private var brandDomain: String? {
        BrandAssets.getBrandDomain(from: "\(name) <\(email)>")
    }

    var body: some View {
        ZStack {
            // Layer 1: Colored circle with initials (always present as base)
            initialsView

            // Layer 2: Brand logo (for business emails)
            if let domain = brandDomain, !brandLogoError {
                brandLogoView(for: domain)
            }

            // Layer 3: Contact photo (highest priority)
            if let photoURL = contactPhotoURL {
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
        .task {
            await loadContactPhoto()
        }
    }

    // MARK: - Initials View

    private var initialsView: some View {
        ZStack {
            Circle()
                .fill(brandDomain != nil ? BrandAssets.getBrandColor(brandDomain!) ?? backgroundColor : backgroundColor)

            Text(initials)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    // MARK: - Brand Logo View

    @ViewBuilder
    private func brandLogoView(for domain: String) -> some View {
        let logoURL = BrandAssets.getBrandLogoUrl(domain)

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
            case .failure:
                Color.clear
                    .onAppear { brandLogoError = true }
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
        let words = name.split(separator: " ")
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        // Match React: single letter for single names
        if !name.isEmpty {
            return String(name.prefix(1)).uppercased()
        }
        if let atIndex = email.firstIndex(of: "@") {
            return String(email[..<atIndex].prefix(1)).uppercased()
        }
        return "?"
    }

    /// Avatar colors - exact match to React's AVATAR_COLORS array
    private static let avatarColors: [Color] = [
        Color(hex: "#1a73e8")!,  // Blue
        Color(hex: "#ea4335")!,  // Red
        Color(hex: "#34a853")!,  // Green
        Color(hex: "#fbbc04")!,  // Yellow
        Color(hex: "#673ab7")!,  // Deep Purple
        Color(hex: "#e91e63")!,  // Pink
        Color(hex: "#00acc1")!,  // Cyan
        Color(hex: "#ff5722")!,  // Deep Orange
        Color(hex: "#607d8b")!,  // Blue Grey
        Color(hex: "#795548")!,  // Brown
    ]

    private var backgroundColor: Color {
        // Match React's hash algorithm exactly:
        // let hash = 0;
        // for (let i = 0; i < email.length; i++) {
        //   hash = email.charCodeAt(i) + ((hash << 5) - hash);
        // }
        var hash: Int32 = 0
        for char in email.utf8 {
            hash = Int32(char) &+ ((hash << 5) &- hash)
        }
        let index = abs(Int(hash)) % Self.avatarColors.count
        return Self.avatarColors[index]
    }

    // MARK: - Load Contact Photo

    private func loadContactPhoto() async {
        if let cached = await AvatarService.shared.getCachedPhoto(for: email) {
            contactPhotoURL = cached
            return
        }

        if await AvatarService.shared.hasPhotoCache(for: email) {
            return
        }

        if let photoURL = await PeopleService.shared.getPhotoURL(for: email) {
            await AvatarService.shared.cachePhoto(email: email, url: photoURL)
            contactPhotoURL = photoURL
        } else {
            await AvatarService.shared.cachePhoto(email: email, url: nil)
        }
    }
}

// MARK: - Brand Assets (ported from React Native)

enum BrandAssets {
    // Direct logo URLs for brands with poor Google favicons
    private static let logoOverrides: [String: String] = [
        "capitalone.com": "https://www.capitalone.com/apple-touch-icon.png",
        "sofi.com": "https://d1kag2khia5c8r.cloudfront.net/apple-touch-icon.png",
        "vanguard.com": "https://www.vanguard.com/apple-touch-icon.png",
        "southwest.com": "https://www.southwest.com/apple-touch-icon.png",
        "spirit.com": "https://www.spirit.com/apple-touch-icon.png",
    ]

    // Map alternate sending domains to their parent brand
    private static let domainAliases: [String: String] = [
        // Verizon
        "vzw.com": "verizon.com",
        "vtext.com": "verizon.com",
        "verizonwireless.com": "verizon.com",
        // Bloomberg
        "bloomberglp.com": "bloomberg.com",
        "bloom.bg": "bloomberg.com",
        // Capital One
        "capitalone-email.com": "capitalone.com",
        "cofemail.com": "capitalone.com",
        // Chase
        "chase-email.com": "chase.com",
        "jpmorgan.com": "chase.com",
        // Amazon
        "amazonses.com": "amazon.com",
        // Google
        "youtube.com": "google.com",
        "googlemail.com": "google.com",
        // Meta
        "facebookmail.com": "facebook.com",
        "fb.com": "facebook.com",
        "instagrammail.com": "instagram.com",
        // Microsoft
        "microsoftonline.com": "microsoft.com",
        "office365.com": "microsoft.com",
        // Apple
        "apple.news": "apple.com",
        // PayPal
        "paypal.de": "paypal.com",
        // LinkedIn
        "linkedin-email.com": "linkedin.com",
        "e.linkedin.com": "linkedin.com",
        // Airlines
        "email.aa.com": "aa.com",
        "americanairlines.com": "aa.com",
        "email.spirit.com": "spirit.com",
        // WSJ
        "dowjones.com": "wsj.com",
    ]

    // Brand colors for background while loading
    private static let brandColors: [String: Color] = [
        "airbnb.com": Color(hex: "#FF5A5F")!,
        "amazon.com": Color(hex: "#FF9900")!,
        "apple.com": Color(hex: "#000000")!,
        "bloomberg.com": Color(hex: "#000000")!,
        "google.com": Color(hex: "#4285F4")!,
        "github.com": Color(hex: "#24292E")!,
        "netflix.com": Color(hex: "#E50914")!,
        "spotify.com": Color(hex: "#1DB954")!,
        "linkedin.com": Color(hex: "#0A66C2")!,
        "slack.com": Color(hex: "#4A154B")!,
        "twitter.com": Color(hex: "#000000")!,
        "x.com": Color(hex: "#000000")!,
        "stripe.com": Color(hex: "#635BFF")!,
        "uber.com": Color(hex: "#000000")!,
        "facebook.com": Color(hex: "#1877F2")!,
        "instagram.com": Color(hex: "#E4405F")!,
        "microsoft.com": Color(hex: "#00A4EF")!,
        "verizon.com": Color(hex: "#CD040B")!,
        "chase.com": Color(hex: "#117ACA")!,
        "paypal.com": Color(hex: "#003087")!,
        "aa.com": Color(hex: "#0078D2")!,
        "delta.com": Color(hex: "#DA291C")!,
        "united.com": Color(hex: "#005DAA")!,
        "southwest.com": Color(hex: "#304CB2")!,
        "spirit.com": Color(hex: "#FFEC00")!,
        "wsj.com": Color(hex: "#000000")!,
    ]

    // Personal email domains (no brand logo)
    private static let personalDomains: Set<String> = [
        "gmail.com", "yahoo.com", "hotmail.com", "outlook.com",
        "aol.com", "icloud.com", "me.com", "mac.com",
        "protonmail.com", "proton.me", "fastmail.com",
        "live.com", "msn.com", "ymail.com",
    ]

    /// Extract domain from "Name <email>" format
    static func getBrandDomain(from: String) -> String? {
        // Extract email from angle brackets if present
        let email: String
        if let match = from.range(of: "<([^>]+)>", options: .regularExpression) {
            email = String(from[match]).replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
        } else if from.contains("@") {
            email = from
        } else {
            return nil
        }

        // Get domain part
        guard let atIndex = email.lastIndex(of: "@") else { return nil }
        var domain = String(email[email.index(after: atIndex)...]).lowercased()

        // Check aliases first
        if let aliased = domainAliases[domain] {
            domain = aliased
        }

        // Extract root domain (e.g., mail.google.com -> google.com)
        let parts = domain.split(separator: ".")
        if parts.count >= 2 {
            domain = parts.suffix(2).joined(separator: ".")
        }

        // Apply aliases again for root domain
        if let aliased = domainAliases[domain] {
            domain = aliased
        }

        // Skip personal email domains
        if personalDomains.contains(domain) {
            return nil
        }

        return domain
    }

    /// Get logo URL for domain
    static func getBrandLogoUrl(_ domain: String) -> URL? {
        // Check for override
        if let override = logoOverrides[domain] {
            return URL(string: override)
        }
        // Use Google's favicon service
        return URL(string: "https://t3.gstatic.com/faviconV2?client=SOCIAL&type=FAVICON&fallback_opts=TYPE,SIZE,URL&url=http://\(domain)&size=256")
    }

    /// Get brand color for loading state
    static func getBrandColor(_ domain: String) -> Color? {
        return brandColors[domain]
    }
}

// Note: Color.init(hex:) is defined in SettingsView.swift

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
