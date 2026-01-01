import Foundation
import OSLog

private let logger = Logger(subsystem: "com.simplemail.app", category: "BrandRegistry")

// MARK: - Brand Registry

struct BrandRegistry: Sendable {
    static let shared = BrandRegistry()

    let personalDomains: Set<String>
    let domainAliases: [String: String]
    let logoOverrides: [String: String]
    let brandColors: [String: String]
    let publicSuffixes: Set<String>

    init() {
        if let data = BrandRegistry.loadRegistryData() {
            personalDomains = Set(data.personalDomains.map { $0.lowercased() })
            domainAliases = data.domainAliases.reduce(into: [:]) { result, pair in
                result[pair.key.lowercased()] = pair.value.lowercased()
            }
            logoOverrides = data.logoOverrides.reduce(into: [:]) { result, pair in
                result[pair.key.lowercased()] = pair.value
            }
            brandColors = data.brandColors.reduce(into: [:]) { result, pair in
                result[pair.key.lowercased()] = pair.value
            }
            publicSuffixes = Set(data.publicSuffixes.map { $0.lowercased() })
        } else {
            personalDomains = []
            domainAliases = [:]
            logoOverrides = [:]
            brandColors = [:]
            publicSuffixes = []
        }
    }

    func isPersonalDomain(_ domain: String) -> Bool {
        personalDomains.contains(domain.lowercased())
    }

    func aliasedDomain(_ domain: String) -> String {
        domainAliases[domain.lowercased()] ?? domain.lowercased()
    }

    func logoURL(for domain: String) -> URL? {
        if let override = logoOverrides[domain.lowercased()] {
            return URL(string: override)
        }
        return URL(
            string: "https://t3.gstatic.com/faviconV2?client=SOCIAL&type=FAVICON&fallback_opts=TYPE,SIZE,URL&url=http://\(domain)&size=256"
        )
    }

    func brandColorHex(for domain: String) -> String? {
        brandColors[domain.lowercased()]
    }

    // MARK: - Load

    private static func loadRegistryData() -> RegistryData? {
        let bundle = BundleLocator.bundle
        guard let url = bundle.url(forResource: "brand_registry", withExtension: "json") else {
            logger.warning("brand_registry.json not found in bundle")
            return nil
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            logger.error("Failed to read brand_registry.json: \(error.localizedDescription)")
            return nil
        }

        do {
            return try JSONDecoder().decode(RegistryData.self, from: data)
        } catch {
            logger.error("Failed to decode brand_registry.json: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - Registry Data

private struct RegistryData: Codable {
    let personalDomains: [String]
    let domainAliases: [String: String]
    let logoOverrides: [String: String]
    let brandColors: [String: String]
    let publicSuffixes: [String]
}

private enum BundleLocator {
    static var bundle: Bundle {
#if SWIFT_PACKAGE
        return .module
#else
        return .main
#endif
    }
}
