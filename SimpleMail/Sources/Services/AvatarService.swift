import Foundation
import OSLog

// MARK: - Avatar Service Logger

private let logger = Logger(subsystem: "com.simplemail.app", category: "AvatarService")

// MARK: - Avatar Service

/// Service for managing avatar image sources with intelligent fallback chain
actor AvatarService {
    static let shared = AvatarService()

    private let registry = BrandRegistry.shared
    private let cacheTTL: TimeInterval = 7 * 24 * 60 * 60
    private let maxCacheEntries = 1000

    // In-memory caches
    private var resolutionCache: [String: CachedResolution] = [:]
    private var inFlightTasks: [String: Task<AvatarResolution, Never>] = [:]
    private var brandLogoStatus: [String: Bool] = [:]  // domain -> loaded successfully

    // MARK: - Models

    struct AvatarResolution: Sendable {
        let email: String
        let initials: String
        let backgroundColorHex: String
        let brandLogoURL: URL?
        let contactPhotoURL: URL?
        let brandDomain: String?
        let source: AvatarSource
    }

    enum AvatarSource: String, Sendable {
        case contactPhoto
        case brandLogo
        case initials
    }

    private struct CachedResolution: Sendable {
        var resolution: AvatarResolution
        var fetchedAt: Date
        var lastAccessed: Date
    }

    // MARK: - Resolve

    func resolveAvatar(email: String, name: String, accountEmail: String? = nil) async -> AvatarResolution {
        let accountKey = await currentAccountKey(override: accountEmail)

        guard let normalized = DomainNormalizer.normalize(from: email, registry: registry) else {
            return AvatarResolution(
                email: email,
                initials: DomainNormalizer.initials(name: name, email: email),
                backgroundColorHex: AvatarService.avatarColorHex(for: email),
                brandLogoURL: nil,
                contactPhotoURL: nil,
                brandDomain: nil,
                source: .initials
            )
        }

        let cacheKey = "\(accountKey)|\(normalized.normalizedEmail)"

        if let cached = resolutionCache[cacheKey], !isExpired(cached) {
            var updated = cached
            updated.lastAccessed = Date()
            resolutionCache[cacheKey] = updated
            return cached.resolution
        }

        if let existingTask = inFlightTasks[cacheKey] {
            return await existingTask.value
        }

        let task = Task { [registry] in
            let initials = DomainNormalizer.initials(name: name, email: normalized.normalizedEmail)
            let brandDomain = normalized.brandDomain

            var brandLogoURL: URL?
            var brandColorHex: String?

            if let domain = brandDomain?.lowercased(), brandLogoStatus[domain] != false {
                brandLogoURL = registry.logoURL(for: domain)
                brandColorHex = registry.brandColorHex(for: domain)
            }

            let backgroundHex = brandColorHex ?? AvatarService.avatarColorHex(for: normalized.normalizedEmail)
            let contactPhotoURL = await PeopleService.shared.getPhotoURL(for: normalized.normalizedEmail)

            let source: AvatarSource
            if contactPhotoURL != nil {
                source = .contactPhoto
            } else if brandLogoURL != nil {
                source = .brandLogo
            } else {
                source = .initials
            }

            let resolution = AvatarResolution(
                email: normalized.normalizedEmail,
                initials: initials,
                backgroundColorHex: backgroundHex,
                brandLogoURL: brandLogoURL,
                contactPhotoURL: contactPhotoURL,
                brandDomain: brandDomain,
                source: source
            )

            cacheResolution(resolution, for: cacheKey)
            return resolution
        }

        inFlightTasks[cacheKey] = task
        let result = await task.value
        inFlightTasks[cacheKey] = nil
        return result
    }

    func prefetch(contacts: [(email: String, name: String)], accountEmail: String? = nil) {
        for contact in contacts {
            Task {
                _ = await resolveAvatar(email: contact.email, name: contact.name, accountEmail: accountEmail)
            }
        }
    }

    // MARK: - Brand Logo Status

    func markBrandLogoLoaded(_ domain: String, success: Bool) {
        let normalized = domain.lowercased()
        brandLogoStatus[normalized] = success
        if success == false {
            removeBrandLogoFromCache(domain: normalized)
        }
    }

    // MARK: - Cache

    private func cacheResolution(_ resolution: AvatarResolution, for key: String) {
        let cached = CachedResolution(resolution: resolution, fetchedAt: Date(), lastAccessed: Date())
        resolutionCache[key] = cached
        evictIfNeeded()
    }

    private func isExpired(_ cached: CachedResolution) -> Bool {
        Date().timeIntervalSince(cached.fetchedAt) > cacheTTL
    }

    private func evictIfNeeded() {
        guard resolutionCache.count > maxCacheEntries else { return }
        let sorted = resolutionCache.sorted { $0.value.lastAccessed < $1.value.lastAccessed }
        let toRemove = sorted.prefix(resolutionCache.count - maxCacheEntries)
        for entry in toRemove {
            resolutionCache.removeValue(forKey: entry.key)
        }
    }

    private func removeBrandLogoFromCache(domain: String) {
        for (key, cached) in resolutionCache {
            if cached.resolution.brandDomain == domain {
                let updated = AvatarResolution(
                    email: cached.resolution.email,
                    initials: cached.resolution.initials,
                    backgroundColorHex: cached.resolution.backgroundColorHex,
                    brandLogoURL: nil,
                    contactPhotoURL: cached.resolution.contactPhotoURL,
                    brandDomain: cached.resolution.brandDomain,
                    source: cached.resolution.contactPhotoURL != nil ? .contactPhoto : .initials
                )
                resolutionCache[key] = CachedResolution(
                    resolution: updated,
                    fetchedAt: cached.fetchedAt,
                    lastAccessed: Date()
                )
            }
        }
    }

    private func currentAccountKey(override: String?) async -> String {
        if let override = override, !override.isEmpty {
            return override.lowercased()
        }

        return await MainActor.run {
            AuthService.shared.currentAccount?.email.lowercased() ?? "default"
        }
    }

    // MARK: - Deterministic Color

    nonisolated static func avatarColorHex(for email: String) -> String {
        let palette = [
            "#1a73e8", "#ea4335", "#34a853", "#fbbc04", "#673ab7",
            "#e91e63", "#00acc1", "#ff5722", "#607d8b", "#795548"
        ]

        var hash: Int32 = 0
        for char in email.utf8 {
            hash = Int32(char) &+ ((hash << 5) &- hash)
        }
        let index = abs(Int(hash)) % palette.count
        return palette[index]
    }

    // MARK: - Clear Cache

    func clearCache() {
        resolutionCache = [:]
        inFlightTasks = [:]
        brandLogoStatus = [:]
        logger.info("Avatar cache cleared")
    }
}
