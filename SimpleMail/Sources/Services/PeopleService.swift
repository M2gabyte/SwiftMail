import Foundation
import OSLog
import Contacts
import Foundation

// MARK: - People Service Logger

private let logger = Logger(subsystem: "com.simplemail.app", category: "PeopleService")

// MARK: - People Service

/// Service for Google People API - provides contact autocomplete functionality
actor PeopleService {
    static let shared = PeopleService()
    // (placeholder retained for API compatibility; no-op)
    static func sharedDisplayName(for email: String) -> String? { nil }

    private let baseURL = "https://people.googleapis.com/v1"
    private let requestTimeout: TimeInterval = TimeoutConfig.peopleAPI

    /// Cached contacts for faster autocomplete
    private var cachedContactsByAccount: [String: [Contact]] = [:]
    private var lastCacheTimeByAccount: [String: Date] = [:]
    private let cacheExpiryInterval: TimeInterval = TimeoutConfig.contactCacheExpiry
    /// Once a permission error is seen, avoid hammering the API for the rest of the session.
    private var disableContactsForSession = false
    private var didLogPermissionDenied = false
    /// Deduplicate concurrent fetches per account.
    private var inflightFetchByAccount: [String: Task<[Contact], Error>] = [:]
    /// Single-flight preload task to prevent repeated API calls
    private var preloadTask: Task<Void, Never>?
    /// Simple in-memory display-name lookup (lowercased email -> name) for quick reuse.
    private var displayNameCache: [String: String] = [:]

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
        if disableContactsForSession { return [] }
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

        // Deduplicate concurrent fetches
        if let inflight = inflightFetchByAccount[accountKey] {
            return try await inflight.value
        }

        let task = Task<[Contact], Error> {
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

        inflightFetchByAccount[accountKey] = task
        defer { inflightFetchByAccount[accountKey] = nil }
        return try await task.value
    }

    private func markPermissionDeniedIfNeeded(_ error: Error) {
        if let peopleError = error as? PeopleError, case .permissionDenied = peopleError {
            disableContactsForSession = true
        }
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
        if disableContactsForSession { return [] }
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
                markPermissionDeniedIfNeeded(error)
                logger.warning("Failed to fetch contacts for search: \(error.localizedDescription)")
                // Continue with empty cache - user may need to re-authenticate
            }
        }

        // Merge Google + local contacts, then rank
        let myEmail = await AuthService.shared.currentAccount?.email.lowercased()
        let merged = await mergedContacts(query: lowercasedQuery, accountKey: accountKey, myEmail: myEmail)
        let recent = await RecentRecipientStore.shared.recent(accountEmail: await AuthService.shared.currentAccount?.email)
        let recentMap: [String: Date] = Dictionary(uniqueKeysWithValues: recent.map { ($0.email, $0.lastUsed) })

        // Filter: if query includes '@', restrict to email matches only
        let filtered = merged.filter { contact in
            let email = contact.email.lowercased()
            if lowercasedQuery.contains("@") {
                return email.contains(lowercasedQuery)
            }
            return contact.name.lowercased().contains(lowercasedQuery) || email.contains(lowercasedQuery)
        }

        func score(_ contact: Contact) -> Int {
            let name = contact.name.lowercased()
            let email = contact.email.lowercased()
            var s = 0
            let now = Date()

            // Email priority
            if email == lowercasedQuery { s += 1_000_000 }
            else if email.hasPrefix(lowercasedQuery) { s += 900_000 }
            else if let at = email.firstIndex(of: "@") {
                let local = email[..<at]
                if local.hasPrefix(lowercasedQuery) { s += 850_000 }
            }

            // Name priority
            if name.hasPrefix(lowercasedQuery) { s += 800_000 }
            else if let range = name.range(of: lowercasedQuery) {
                let dist = name.distance(from: name.startIndex, to: range.lowerBound)
                s += max(760_000 - dist * 5, 0)
            }

            // Email substring fallback
            if let range = email.range(of: lowercasedQuery) {
                let dist = email.distance(from: email.startIndex, to: range.lowerBound)
                s += max(700_000 - dist * 5, 0)
            }

            // Prefer contacts with display names
            if !contact.name.isEmpty { s += 5_000 }

            // Slight boost for self email so it surfaces quickly
            if let myEmail, email == myEmail { s += 20_000 }

            // Recency boost (recent send/receive)
            if let used = recentMap[email] {
                let age = now.timeIntervalSince(used)
                // 0-7 days strong, 7-30 medium, beyond minimal
                if age < 7 * 86_400 { s += 120_000 }
                else if age < 30 * 86_400 { s += 70_000 }
                else if age < 90 * 86_400 { s += 25_000 }
            }

            // Domain affinity boost: match account domain when query hints at email
            if let myEmail, let myDomain = myEmail.split(separator: "@").last {
                if let domain = email.split(separator: "@").last {
                    if domain == myDomain {
                        s += 30_000
                    }
                }
            }

            return s
        }

        let ranked = filtered.sorted {
            let sa = score($0)
            let sb = score($1)
            if sa != sb { return sa > sb }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.email < $1.email
        }

        return Array(ranked.prefix(50))
    }

    // MARK: - Display name helper
    func cachedDisplayName(for lowercasedEmail: String) -> String? {
        displayNameCache[lowercasedEmail]
    }

    // MARK: - Local Contacts Integration

    /// Merge Google contacts with local device contacts (email-only), preferring local when equal.
    /// Returns combined list (deduped by email, case-insensitive).
    private func mergedContacts(query: String, accountKey: String, myEmail: String?) async -> [Contact] {
        let google = cachedContactsByAccount[accountKey] ?? []
        let local = await LocalContactsService.shared.search(query: query)

        var bestByEmail: [String: Contact] = [:]

        func upsert(_ contact: Contact, isLocal: Bool) {
            let key = contact.email.lowercased()
            if let existing = bestByEmail[key] {
                // Prefer local over google; prefer one with a name
                let existingHasName = !existing.name.isEmpty
                let incomingHasName = !contact.name.isEmpty
                if isLocal && !existingHasName && incomingHasName {
                    bestByEmail[key] = contact
                } else if isLocal && !existingHasName {
                    bestByEmail[key] = contact
                } else if incomingHasName && !existingHasName {
                    bestByEmail[key] = contact
                }
            } else {
                bestByEmail[key] = contact
            }
        }

        google.forEach { upsert($0, isLocal: false) }
        local.forEach {
            let c = Contact(
                id: "local-\($0.id)",
                name: $0.name,
                email: $0.email,
                photoURL: nil
            )
            upsert(c, isLocal: true)
        }

        // Optional: small boost for self email to ensure it's kept even if no name
        if let myEmail {
            let norm = myEmail.lowercased()
            if let existing = bestByEmail[norm] {
                bestByEmail[norm] = Contact(
                    id: existing.id,
                    name: existing.name,
                    email: existing.email,
                    photoURL: existing.photoURL
                )
            }
        }

        return Array(bestByEmail.values)
    }

    /// Preloads contacts in the background (single-flight)
    func preloadContacts() async {
        // Already disabled for session (permission denied)
        if disableContactsForSession { return }
        // Already running a preload task
        guard preloadTask == nil else { return }

        preloadTask = Task {
            defer { preloadTask = nil }

            do {
                guard await AuthService.shared.isAuthenticated else { return }
                _ = try await fetchContacts()
                logger.info("Contacts preloaded successfully")
            } catch {
                markPermissionDeniedIfNeeded(error)
                if disableContactsForSession {
                    logger.warning("Contacts scope denied; disabling contacts fetch for this session.")
                } else {
                    logger.warning("Failed to preload contacts: \(error.localizedDescription)")
                }
            }
        }
        await preloadTask?.value
    }

    // MARK: - Photo Lookup

    /// Gets the photo URL for a specific email address.
    /// CACHE-ONLY: does not fetch contacts on-demand (Inbox avatar rendering must not cause network).
    func getPhotoURL(for email: String) async -> URL? {
        if disableContactsForSession { return nil }
        let lowercasedEmail = email.lowercased()

        guard let accountKey = await currentAccountKey() else {
            return nil
        }

        // Cache-only: return nil if contacts not yet loaded
        guard let contacts = cachedContactsByAccount[accountKey], !contacts.isEmpty else {
            return nil
        }

        // Find matching contact
        if let contact = contacts.first(where: { $0.email.lowercased() == lowercasedEmail }) {
            if let photoURLString = contact.photoURL, let url = URL(string: photoURLString) {
                return url
            }
        }

        return nil
    }

    /// Gets photo URLs for multiple email addresses (batch lookup).
    /// CACHE-ONLY: does not fetch contacts on-demand.
    func getPhotoURLs(for emails: [String]) async -> [String: URL] {
        if disableContactsForSession { return [:] }
        var results: [String: URL] = [:]

        guard let accountKey = await currentAccountKey() else {
            return results
        }

        // Cache-only: return empty if contacts not yet loaded
        guard let contacts = cachedContactsByAccount[accountKey], !contacts.isEmpty else {
            return results
        }

        let lowercasedEmails = Set(emails.map { $0.lowercased() })

        for contact in contacts {
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
            if !disableContactsForSession && !didLogPermissionDenied {
                logger.warning("Permission denied - contacts scope may not be granted")
                didLogPermissionDenied = true
            }
            disableContactsForSession = true
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

// MARK: - Local Contacts (inline to avoid target wiring)

actor LocalContactsService {
    static let shared = LocalContactsService()
    private let store = CNContactStore()
    private let logger = Logger(subsystem: "com.simplemail.app", category: "LocalContactsService")
    private let cacheTTL: TimeInterval = 60 * 30
    private var cached: [LocalContact] = []
    private var lastFetch: Date?

    struct LocalContact: Hashable {
        let id: String
        let name: String
        let email: String
    }

    func search(query: String) async -> [LocalContact] {
        guard await ensureAccess() else { return [] }
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let contacts = await loadIfNeeded()
        return contacts.filter { c in
            let name = c.name.lowercased()
            let email = c.email.lowercased()
            if q.contains("@") { return email.contains(q) }
            return name.contains(q) || email.contains(q)
        }
    }

    private func ensureAccess() async -> Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: return true
        case .notDetermined:
            do { return try await store.requestAccess(for: .contacts) }
            catch {
                logger.warning("Contacts permission failed: \(error.localizedDescription)")
                return false
            }
        default: return false
        }
    }

    private func loadIfNeeded() async -> [LocalContact] {
        if let lastFetch, Date().timeIntervalSince(lastFetch) < cacheTTL, !cached.isEmpty {
            return cached
        }
        do {
            let keys: [CNKeyDescriptor] = [
                CNContactIdentifierKey as CNKeyDescriptor,
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactMiddleNameKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor,
                // Required for CNContactFormatter to avoid "property not requested" warnings
                CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
            ]
            let request = CNContactFetchRequest(keysToFetch: keys)
            var results: [LocalContact] = []
            var seen: Set<String> = []
            try store.enumerateContacts(with: request) { contact, _ in
                guard !contact.emailAddresses.isEmpty else { return }
                let name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
                for emailValue in contact.emailAddresses {
                    let email = (emailValue.value as String).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard !email.isEmpty else { continue }
                    if seen.contains(email) { continue }
                    seen.insert(email)
                    results.append(LocalContact(id: contact.identifier + "-" + email, name: name, email: email))
                }
            }
            cached = results
            lastFetch = Date()
            logger.info("Loaded \(results.count) local contacts with email addresses.")
            return results
        } catch {
            logger.warning("Failed to load local contacts: \(error.localizedDescription)")
            cached = []
            return []
        }
    }
}

// MARK: - Recent Recipients (inline store)

actor RecentRecipientStore {
    static let shared = RecentRecipientStore()
    private let logger = Logger(subsystem: "com.simplemail.app", category: "RecentRecipientStore")
    private let maxEntries = 200
    private let userDefaults = UserDefaults.standard
    private let keyPrefix = "recentRecipients:"

    struct Entry: Codable {
        let email: String
        let name: String?
        let lastUsed: Date
    }

    func record(email: String, name: String?, accountEmail: String?) {
        guard let accountEmail else { return }
        let norm = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !norm.isEmpty else { return }
        var entries = load(accountEmail: accountEmail)
        entries.removeAll { $0.email == norm }
        entries.insert(Entry(email: norm, name: name, lastUsed: Date()), at: 0)
        if entries.count > maxEntries { entries = Array(entries.prefix(maxEntries)) }
        save(entries, accountEmail: accountEmail)
    }

    func recent(accountEmail: String?) -> [Entry] {
        guard let accountEmail else { return [] }
        return load(accountEmail: accountEmail)
    }

    private func storageKey(for account: String) -> String { "\(keyPrefix)\(account.lowercased())" }

    private func load(accountEmail: String) -> [Entry] {
        let key = storageKey(for: accountEmail)
        guard let data = userDefaults.data(forKey: key) else { return [] }
        do { return try JSONDecoder().decode([Entry].self, from: data) }
        catch {
            logger.warning("Decode recent recipients failed: \(error.localizedDescription)")
            return []
        }
    }

    private func save(_ entries: [Entry], accountEmail: String) {
        let key = storageKey(for: accountEmail)
        do { userDefaults.set(try JSONEncoder().encode(entries), forKey: key) }
        catch { logger.warning("Save recent recipients failed: \(error.localizedDescription)") }
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
