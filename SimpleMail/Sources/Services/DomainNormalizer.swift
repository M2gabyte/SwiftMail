import Foundation

// MARK: - Domain Normalizer

struct NormalizedEmail: Sendable {
    let rawEmail: String
    let normalizedEmail: String
    let domain: String
    let rootDomain: String
    let brandDomain: String?
}

enum DomainNormalizer {
    static func normalize(from raw: String, registry: BrandRegistry = .shared) -> NormalizedEmail? {
        guard let email = extractEmail(from: raw) else {
            return nil
        }

        let lower = email.lowercased()
        guard let atIndex = lower.lastIndex(of: "@") else { return nil }
        let localPart = String(lower[..<atIndex])
        let domainPart = String(lower[lower.index(after: atIndex)...])

        let normalizedLocal: String
        if domainPart == "gmail.com" || domainPart == "googlemail.com" {
            normalizedLocal = localPart.split(separator: "+").first.map(String.init) ?? localPart
        } else {
            normalizedLocal = localPart
        }

        let normalizedEmail = "\(normalizedLocal)@\(domainPart)"

        let aliasedDomain = registry.aliasedDomain(domainPart)
        let rootDomain = rootDomain(from: aliasedDomain, registry: registry)
        let normalizedRoot = registry.aliasedDomain(rootDomain)

        let brandDomain: String?
        if registry.isPersonalDomain(domainPart) || registry.isPersonalDomain(normalizedRoot) {
            brandDomain = nil
        } else {
            brandDomain = normalizedRoot
        }

        return NormalizedEmail(
            rawEmail: lower,
            normalizedEmail: normalizedEmail,
            domain: aliasedDomain,
            rootDomain: rootDomain,
            brandDomain: brandDomain
        )
    }

    static func extractEmail(from raw: String) -> String? {
        if let match = raw.range(of: "<([^>]+)>", options: .regularExpression) {
            let value = raw[match]
                .replacingOccurrences(of: "<", with: "")
                .replacingOccurrences(of: ">", with: "")
            return value
        }
        if raw.contains("@") {
            return raw
        }
        return nil
    }

    static func initials(name: String, email: String) -> String {
        let words = name.split(separator: " ")
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        if !name.isEmpty {
            return String(name.prefix(1)).uppercased()
        }
        if let atIndex = email.firstIndex(of: "@") {
            return String(email[..<atIndex].prefix(1)).uppercased()
        }
        return "?"
    }

    private static func rootDomain(from domain: String, registry: BrandRegistry) -> String {
        let parts = domain.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return domain }

        if let suffix = longestPublicSuffix(in: domain, registry: registry) {
            let suffixParts = suffix.split(separator: ".").count
            let needed = min(parts.count, suffixParts + 1)
            return parts.suffix(needed).joined(separator: ".")
        }

        return parts.suffix(2).joined(separator: ".")
    }

    private static func longestPublicSuffix(in domain: String, registry: BrandRegistry) -> String? {
        let labels = domain.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }

        var best: String?
        for i in 1..<labels.count {
            let suffix = labels.suffix(i).joined(separator: ".")
            if registry.publicSuffixes.contains(suffix) {
                best = suffix
            }
        }
        return best
    }
}
