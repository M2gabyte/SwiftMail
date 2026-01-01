import Foundation
import OSLog

// MARK: - Avatar Service Logger

private let logger = Logger(subsystem: "com.simplemail.app", category: "AvatarService")

// MARK: - Avatar Service

/// Service for managing avatar image sources with intelligent fallback chain
actor AvatarService {
    static let shared = AvatarService()

    // In-memory caches
    private var photoCache: [String: URL?] = [:]  // email -> photo URL
    private var brandLogoStatus: [String: Bool] = [:]  // domain -> loaded successfully

    // Personal domains that skip brand logos
    private let personalDomains: Set<String> = [
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

    // Domain aliases - map alternate sending domains to primary brand
    private let domainAliases: [String: String] = [
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
        "uber.com": "uber.com",
        "lyft.com": "lyft.com",
        "em.lyft.com": "lyft.com",
        "doordash.com": "doordash.com",
        "mail.doordash.com": "doordash.com",
        "postmates.com": "postmates.com",
        "email.grubhub.com": "grubhub.com"
    ]

    // MARK: - Contact Photo

    /// Get cached contact photo URL for an email
    func getCachedPhoto(for email: String) -> URL?? {
        let key = email.lowercased()
        return photoCache[key]
    }

    /// Cache a contact photo URL (or nil for no photo)
    func cachePhoto(email: String, url: URL?) {
        let key = email.lowercased()
        photoCache[key] = url
    }

    /// Check if we have already cached a photo lookup (even if nil)
    func hasPhotoCache(for email: String) -> Bool {
        let key = email.lowercased()
        return photoCache.keys.contains(key)
    }

    // MARK: - Brand Logo

    /// Get brand logo URL for an email domain
    func getBrandLogoURL(for email: String) -> URL? {
        let domain = extractDomain(from: email)

        guard !isPersonalDomain(domain) else {
            return nil
        }

        // Check if we've tried and failed before
        if brandLogoStatus[domain] == false {
            return nil
        }

        // Use domain alias if available
        let effectiveDomain = domainAliases[domain] ?? domain

        // Use Google's high-quality favicon service
        return URL(string: "https://t3.gstatic.com/faviconV2?client=SOCIAL&type=FAVICON&fallback_opts=TYPE,SIZE,URL&url=http://\(effectiveDomain)&size=256")
    }

    /// Mark whether a brand logo loaded successfully
    func markBrandLogoLoaded(_ domain: String, success: Bool) {
        brandLogoStatus[domain] = success
    }

    /// Check if a brand logo has been marked as failed
    func hasBrandLogoFailed(for email: String) -> Bool {
        let domain = extractDomain(from: email)
        return brandLogoStatus[domain] == false
    }

    // MARK: - Domain Helpers

    /// Check if domain is a personal email provider (skip brand logo)
    func isPersonalDomain(_ domain: String) -> Bool {
        personalDomains.contains(domain.lowercased())
    }

    /// Extract domain from email address
    private func extractDomain(from email: String) -> String {
        guard let atIndex = email.lastIndex(of: "@") else {
            return ""
        }
        return String(email[email.index(after: atIndex)...]).lowercased()
    }

    // MARK: - Deterministic Color

    /// Get a deterministic color index for an email (for initials avatar background)
    static func colorIndex(for email: String) -> Int {
        let hash = email.lowercased().hashValue
        return abs(hash) % 8
    }

    // MARK: - Clear Cache

    func clearCache() {
        photoCache = [:]
        brandLogoStatus = [:]
        logger.info("Avatar cache cleared")
    }
}
