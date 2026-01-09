import Foundation
import OSLog

// MARK: - People Service Logger

private let logger = Logger(subsystem: "com.simplemail.app", category: "PeopleService")

// MARK: - People Service

/// Service for Google People API - provides contact autocomplete functionality
actor PeopleService {
    static let shared = PeopleService()

    private let baseURL = "https://people.googleapis.com/v1"
    private let requestTimeout: TimeInterval = TimeoutConfig.peopleAPI

    /// Cached contacts for faster autocomplete
    private var cachedContactsByAccount: [String: [Contact]] = [:]
    private var lastCacheTimeByAccount: [String: Date] = [:]
    private let cacheExpiryInterval: TimeInterval = TimeoutConfig.contactCacheExpiry

    // MARK: - Contact Model

    struct Contact: Identifiable, Hashable {
        let id: String
        let name: String
        let email: String
        let photoURL: String?

        var displayName: String {
            name.isEmpty ? email : name
        }

        var initials: String {
            let words = name.split(separator: " ")
            if words.count >= 2 {
                return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
            }
            if !name.isEmpty {
                return String(name.prefix(2)).uppercased()
            }
            if let atIndex = email.firstIndex(of: "@") {
                return String(email[..<atIndex].prefix(2)).uppercased()
            }
            return "?"
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(email.lowercased())
        }

        static func == (lhs: Contact, rhs: Contact) -> Bool {
            lhs.email.lowercased() == rhs.email.lowercased()
        }
    }

    // MARK: - Get Access Token

    private func getAccessToken() async throws -> String {
        guard let account = await AuthService.shared.currentAccount else {
            throw PeopleError.notAuthenticated
        }

        let refreshedAccount = try await AuthService.shared.refreshTokenIfNeeded(for: account)
        return refreshedAccount.accessToken
    }

    private func currentAccountKey() async -> String? {
        await AuthService.shared.currentAccount?.email.lowercased()
    }

    // MARK: - Fetch Contacts

    /// Fetches all contacts with email addresses from Google People API
    func fetchContacts(forceRefresh: Bool = false) async throws -> [Contact] {
        guard let accountKey = await currentAccountKey() else {
            throw PeopleError.notAuthenticated
        }

        // Check cache
        if !forceRefresh,
           let lastCache = lastCacheTimeByAccount[accountKey],
           Date().timeIntervalSince(lastCache) < cacheExpiryInterval,
           let cached = cachedContactsByAccount[accountKey],
           !cached.isEmpty {
            return cached
        }

        logger.info("Fetching contacts from People API")

        let token = try await getAccessToken()

        var allContacts: [Contact] = []
        var nextPageToken: String?

        // Paginate through all contacts
        repeat {
            let (contacts, pageToken) = try await fetchContactsPage(token: token, pageToken: nextPageToken)
            allContacts.append(contentsOf: contacts)
            nextPageToken = pageToken
        } while nextPageToken != nil

        // Also fetch "other contacts" (people you've emailed but aren't in contacts)
        let otherContacts = try await fetchOtherContacts(token: token)
        allContacts.append(contentsOf: otherContacts)

        // Deduplicate by email
        let uniqueContacts = Array(Set(allContacts))

        // Sort by name
        let sorted = uniqueContacts.sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
        cachedContactsByAccount[accountKey] = sorted
        lastCacheTimeByAccount[accountKey] = Date()

        logger.info("Cached \(sorted.count) contacts")

        return sorted
    }

    private func fetchContactsPage(token: String, pageToken: String?) async throws -> (contacts: [Contact], nextPageToken: String?) {
        guard var components = URLComponents(string: "\(baseURL)/people/me/connections") else {
            throw PeopleError.invalidURL
        }
        var queryItems = [
            URLQueryItem(name: "personFields", value: "names,emailAddresses,photos"),
            URLQueryItem(name: "pageSize", value: "100")
        ]

        if let pageToken = pageToken {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw PeopleError.invalidURL
        }

        let response: ConnectionsResponse = try await request(url: url, token: token)

        let contacts = parseContacts(from: response.connections ?? [])
        return (contacts, response.nextPageToken)
    }

    /// Fetches "other contacts" - people you've interacted with but aren't saved contacts
    private func fetchOtherContacts(token: String) async throws -> [Contact] {
        guard var components = URLComponents(string: "\(baseURL)/otherContacts") else {
            throw PeopleError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "readMask", value: "names,emailAddresses,photos"),
            URLQueryItem(name: "pageSize", value: "100")
        ]

        guard let url = components.url else {
            throw PeopleError.invalidURL
        }

        do {
            let response: OtherContactsResponse = try await request(url: url, token: token)
            return parseOtherContacts(from: response.otherContacts ?? [])
        } catch {
            // Other contacts may not be available for all accounts
            logger.warning("Could not fetch other contacts: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Search Contacts

    /// Searches contacts by name or email
    func searchContacts(query: String) async -> [Contact] {
        let lowercasedQuery = query.lowercased().trimmingCharacters(in: .whitespaces)

        guard !lowercasedQuery.isEmpty else {
            return []
        }

        guard let accountKey = await currentAccountKey() else {
            return []
        }

        // If cache is empty, try to fetch contacts
        if cachedContactsByAccount[accountKey]?.isEmpty ?? true {
            do {
                _ = try await fetchContacts()
            } catch {
                logger.warning("Failed to fetch contacts for search: \(error.localizedDescription)")
                // Continue with empty cache - user may need to re-authenticate
            }
        }

        // Search in cached contacts
        let cached = cachedContactsByAccount[accountKey] ?? []
        return cached.filter { contact in
            contact.name.lowercased().contains(lowercasedQuery) ||
            contact.email.lowercased().contains(lowercasedQuery)
        }
    }

    /// Preloads contacts in the background
    func preloadContacts() async {
        do {
            guard await AuthService.shared.isAuthenticated else { return }
            _ = try await fetchContacts()
            logger.info("Contacts preloaded successfully")
        } catch {
            logger.warning("Failed to preload contacts: \(error.localizedDescription)")
        }
    }

    // MARK: - Photo Lookup

    /// Gets the photo URL for a specific email address
    func getPhotoURL(for email: String) async -> URL? {
        let lowercasedEmail = email.lowercased()

        // Try to get from cached contacts
        guard let accountKey = await currentAccountKey() else {
            return nil
        }

        // If cache is empty, try to fetch contacts
        if cachedContactsByAccount[accountKey]?.isEmpty ?? true {
            do {
                _ = try await fetchContacts()
            } catch {
                logger.warning("Failed to fetch contacts for photo lookup: \(error.localizedDescription)")
            }
        }

        // Find matching contact
        let cached = cachedContactsByAccount[accountKey] ?? []
        if let contact = cached.first(where: { $0.email.lowercased() == lowercasedEmail }) {
            if let photoURLString = contact.photoURL, let url = URL(string: photoURLString) {
                return url
            }
        }

        return nil
    }

    /// Gets photo URLs for multiple email addresses (batch lookup)
    func getPhotoURLs(for emails: [String]) async -> [String: URL] {
        var results: [String: URL] = [:]

        guard let accountKey = await currentAccountKey() else {
            return results
        }

        // If cache is empty, try to fetch contacts
        if cachedContactsByAccount[accountKey]?.isEmpty ?? true {
            do {
                _ = try await fetchContacts()
            } catch {
                logger.warning("Failed to fetch contacts for batch photo lookup: \(error.localizedDescription)")
            }
        }

        let cached = cachedContactsByAccount[accountKey] ?? []
        let lowercasedEmails = Set(emails.map { $0.lowercased() })

        for contact in cached {
            let lowerEmail = contact.email.lowercased()
            if lowercasedEmails.contains(lowerEmail) {
                if let photoURLString = contact.photoURL, let url = URL(string: photoURLString) {
                    results[lowerEmail] = url
                }
            }
        }

        return results
    }

    // MARK: - Parsing

    private func parseContacts(from persons: [Person]) -> [Contact] {
        var contacts: [Contact] = []

        for person in persons {
            guard let emails = person.emailAddresses, !emails.isEmpty else {
                continue
            }

            let name = person.names?.first?.displayName ?? ""
            let photoURL = person.photos?.first?.url

            for email in emails {
                if let emailValue = email.value {
                    contacts.append(Contact(
                        id: person.resourceName ?? UUID().uuidString,
                        name: name,
                        email: emailValue,
                        photoURL: photoURL
                    ))
                }
            }
        }

        return contacts
    }

    private func parseOtherContacts(from otherContacts: [OtherContact]) -> [Contact] {
        var contacts: [Contact] = []

        for otherContact in otherContacts {
            guard let emails = otherContact.emailAddresses, !emails.isEmpty else {
                continue
            }

            let name = otherContact.names?.first?.displayName ?? ""
            let photoURL = otherContact.photos?.first?.url

            for email in emails {
                if let emailValue = email.value {
                    contacts.append(Contact(
                        id: otherContact.resourceName ?? UUID().uuidString,
                        name: name,
                        email: emailValue,
                        photoURL: photoURL
                    ))
                }
            }
        }

        return contacts
    }

    // MARK: - Request Helper

    private func request<T: Decodable>(url: URL, token: String) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = requestTimeout

        // Use retry logic for transient network failures
        let frozenRequest = request
        let (data, response) = try await NetworkRetry.withRetry(maxAttempts: 3) {
            try await URLSession.shared.data(for: frozenRequest)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Invalid response type from \(url.path)")
            throw PeopleError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            do {
                return try JSONCoding.decoder.decode(T.self, from: data)
            } catch {
                logger.error("JSON decode error for \(T.self): \(error.localizedDescription)")
                throw PeopleError.invalidResponse
            }
        case 401:
            logger.warning("Authentication required for \(url.path)")
            throw PeopleError.notAuthenticated
        case 403:
            logger.warning("Permission denied - contacts scope may not be granted")
            throw PeopleError.permissionDenied
        case 429:
            logger.warning("Rate limited on \(url.path)")
            throw PeopleError.rateLimited
        default:
            logger.error("Server error \(httpResponse.statusCode) on \(url.path)")
            throw PeopleError.serverError(httpResponse.statusCode)
        }
    }

    // MARK: - Clear Cache

    func clearCache() {
        cachedContactsByAccount = [:]
        lastCacheTimeByAccount = [:]
    }
}

// MARK: - People Errors

enum PeopleError: LocalizedError {
    case notAuthenticated
    case invalidResponse
    case invalidURL
    case permissionDenied
    case rateLimited
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Please sign in to continue"
        case .invalidResponse: return "Invalid response from server"
        case .invalidURL: return "Invalid URL configuration"
        case .permissionDenied: return "Contacts permission not granted. Please sign out and sign in again."
        case .rateLimited: return "Too many requests. Please wait a moment."
        case .serverError(let code): return "Server error (\(code))"
        }
    }
}

// MARK: - API Response Types

private struct ConnectionsResponse: Codable {
    let connections: [Person]?
    let nextPageToken: String?
    let totalPeople: Int?
    let totalItems: Int?
}

private struct OtherContactsResponse: Codable {
    let otherContacts: [OtherContact]?
    let nextPageToken: String?
}

private struct Person: Codable {
    let resourceName: String?
    let names: [PersonName]?
    let emailAddresses: [EmailAddress]?
    let photos: [Photo]?
}

private struct OtherContact: Codable {
    let resourceName: String?
    let names: [PersonName]?
    let emailAddresses: [EmailAddress]?
    let photos: [Photo]?
}

private struct PersonName: Codable {
    let displayName: String?
    let givenName: String?
    let familyName: String?
}

private struct EmailAddress: Codable {
    let value: String?
    let type: String?
    let formattedType: String?
}

private struct Photo: Codable {
    let url: String?
    let default_: Bool?

    enum CodingKeys: String, CodingKey {
        case url
        case default_ = "default"
    }
}
