import Foundation
import AuthenticationServices
import CryptoKit
import UIKit
import OSLog

private let logger = Logger(subsystem: "com.simplemail.app", category: "AuthService")

extension Notification.Name {
    static let accountDidChange = Notification.Name("accountDidChange")
}

// MARK: - Auth Service

@MainActor
final class AuthService: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = AuthService()

    @Published var isAuthenticated = false
    @Published var currentAccount: Account?
    @Published var accounts: [Account] = []

    private let keychain = KeychainServiceSync.shared
    private let clientId = Config.googleClientId
    private let redirectUri = Config.googleRedirectUri

    private var codeVerifier: String?

    /// Tracks in-progress token refresh tasks to prevent concurrent refreshes for same account
    private var refreshTasks: [String: Task<Account, Error>] = [:]

    // MARK: - Account Model

    struct Account: Identifiable, Codable, Equatable, Sendable {
        let id: String
        let email: String
        let name: String
        let photoURL: String?
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?

        var isExpired: Bool {
            guard let expiresAt = expiresAt else { return true }
            return Date() >= expiresAt.addingTimeInterval(-300) // 5 min buffer
        }
    }

    // MARK: - Init

    private override init() {
        super.init()
        loadAccounts()
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // ASWebAuthenticationSession guarantees this delegate method is called on the main thread.
        // Use MainActor.assumeIsolated to safely access UIApplication.
        // Note: We avoid DispatchQueue.main.sync as it risks deadlocks if the assumption ever breaks.
        MainActor.assumeIsolated {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
                preconditionFailure("No window scene available for auth presentation.")
            }
            return windowScene.windows.first ?? UIWindow(windowScene: windowScene)
        }
    }

    // MARK: - Demo Mode (for testing without OAuth)

    func signInDemo() {
        let demoAccount = Account(
            id: "demo-user",
            email: "demo@simplemail.app",
            name: "Demo User",
            photoURL: nil,
            accessToken: "demo-token",
            refreshToken: nil,
            expiresAt: Date().addingTimeInterval(3600)
        )
        addAccount(demoAccount)
    }

    // MARK: - OAuth Flow

    func signIn() async throws {
        // Generate PKCE code verifier and challenge
        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(from: verifier)
        self.codeVerifier = verifier

        // Build authorization URL
        guard var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth") else {
            throw AuthError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: [
                "https://www.googleapis.com/auth/gmail.readonly",
                "https://www.googleapis.com/auth/gmail.send",
                "https://www.googleapis.com/auth/gmail.modify",
                "https://www.googleapis.com/auth/userinfo.email",
                "https://www.googleapis.com/auth/userinfo.profile",
                "https://www.googleapis.com/auth/contacts.readonly"
            ].joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]

        guard let authURL = components.url else {
            throw AuthError.invalidURL
        }

        // Open in ASWebAuthenticationSession
        let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: Config.googleOAuthCallbackScheme
            ) { callbackURL, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let callbackURL = callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: AuthError.noCallback)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false

            if !session.start() {
                continuation.resume(throwing: AuthError.sessionStartFailed)
            }
        }

        // Extract authorization code
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw AuthError.noAuthCode
        }

        // Exchange code for tokens
        try await exchangeCodeForTokens(code)
    }

    private func exchangeCodeForTokens(_ code: String) async throws {
        guard let verifier = codeVerifier else {
            throw AuthError.noCodeVerifier
        }

        guard let tokenURL = URL(string: "https://oauth2.googleapis.com/token") else {
            throw AuthError.invalidURL
        }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id": clientId,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectUri
        ].map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
         .joined(separator: "&")

        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AuthError.tokenExchangeFailed
        }

        let tokenResponse = try JSONCoding.decoder.decode(TokenResponse.self, from: data)

        // Fetch user info
        let userInfo = try await fetchUserInfo(accessToken: tokenResponse.accessToken)

        // Create account
        let account = Account(
            id: userInfo.id,
            email: userInfo.email,
            name: userInfo.name,
            photoURL: userInfo.picture,
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        )

        // Save account
        addAccount(account)

        self.codeVerifier = nil
    }

    private func fetchUserInfo(accessToken: String) async throws -> UserInfo {
        guard let url = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo") else {
            throw AuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw AuthError.userInfoFetchFailed(httpResponse.statusCode)
        }

        return try JSONCoding.decoder.decode(UserInfo.self, from: data)
    }

    // MARK: - Token Refresh

    func refreshTokenIfNeeded(for account: Account) async throws -> Account {
        guard account.isExpired, let refreshToken = account.refreshToken else {
            return account
        }

        // Check if there's already a refresh in progress for this account
        if let existingTask = refreshTasks[account.id] {
            return try await existingTask.value
        }

        // Create new refresh task and store it
        let refreshTask = Task<Account, Error> { [weak self] in
            guard let self = self else { throw AuthError.tokenRefreshFailed }
            return try await self.performTokenRefresh(for: account, refreshToken: refreshToken)
        }

        refreshTasks[account.id] = refreshTask

        // Await the result and clean up synchronously afterward
        // This ensures the task reference is removed before returning,
        // preventing stale task references from being awaited by other callers
        do {
            let result = try await refreshTask.value
            refreshTasks.removeValue(forKey: account.id)
            return result
        } catch {
            refreshTasks.removeValue(forKey: account.id)
            throw error
        }
    }

    /// Performs the actual token refresh network call
    private func performTokenRefresh(for account: Account, refreshToken: String) async throws -> Account {
        guard let tokenURL = URL(string: "https://oauth2.googleapis.com/token") else {
            throw AuthError.invalidURL
        }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id": clientId,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ].map { "\($0.key)=\($0.value)" }.joined(separator: "&")

        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AuthError.tokenRefreshFailed
        }

        let tokenResponse = try JSONCoding.decoder.decode(TokenResponse.self, from: data)

        var updatedAccount = account
        updatedAccount.accessToken = tokenResponse.accessToken
        updatedAccount.expiresAt = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))

        updateAccount(updatedAccount)

        return updatedAccount
    }

    // MARK: - Account Management

    func addAccount(_ account: Account) {
        // Atomic update - create new array in single operation to avoid race conditions
        var updatedAccounts = accounts.filter { $0.email != account.email }
        updatedAccounts.append(account)
        accounts = updatedAccounts
        currentAccount = account
        isAuthenticated = true
        saveAccounts()
        NotificationCenter.default.post(name: .accountDidChange, object: nil)
    }

    func updateAccount(_ account: Account) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
            if currentAccount?.id == account.id {
                currentAccount = account
            }
            saveAccounts()
            NotificationCenter.default.post(name: .accountDidChange, object: nil)
        }
    }

    func removeAccount(_ account: Account) {
        accounts.removeAll { $0.id == account.id }
        if currentAccount?.id == account.id {
            currentAccount = accounts.first
        }
        isAuthenticated = !accounts.isEmpty
        saveAccounts()
        NotificationCenter.default.post(name: .accountDidChange, object: nil)
    }

    func switchAccount(to account: Account) {
        let previousAccount = currentAccount
        currentAccount = account
        saveAccounts()

        // Clear account-specific caches to prevent data bleed
        // Note: Email cache is already scoped by accountEmail, but avatar/contact
        // caches may show stale data briefly during switch
        if previousAccount?.email.lowercased() != account.email.lowercased() {
            Task {
                // Clear avatar cache for immediate visual refresh
                await AvatarService.shared.clearCache()
                // PeopleService contacts are account-scoped, but clear for fresh data
                await PeopleService.shared.clearCache()
                // Prewarm the next likely account when idle
                await AccountWarmupCoordinator.shared.schedulePrewarmNext()
            }
        }

        NotificationCenter.default.post(name: .accountDidChange, object: nil)
    }

    func signOut() {
        accounts.removeAll()
        currentAccount = nil
        isAuthenticated = false
        keychain.delete(key: "accounts")

        // Clear all app caches to prevent data bleed between accounts
        clearAllCaches()
        Task { @MainActor in
            AccountSnapshotStore.shared.clear(accountEmail: nil)
            InboxViewModel.shared.reset()
        }
        NotificationCenter.default.post(name: .accountDidChange, object: nil)
    }

    /// Clear all cached data on sign-out to prevent data bleed between accounts
    private func clearAllCaches() {
        // 1. Clear SwiftData cache (emails, email details)
        EmailCacheManager.shared.clearCache()

        // 2. Clear UserDefaults entries related to user data
        let defaults = UserDefaults.standard

        // User-specific settings and data
        let userDataKeys = [
            "vipSenders",
            "blockedSenders",
            "appSettings",
            "recentSearches",
            "lastEmailSync",
            "notificationKeyTimestamps"
        ]

        let allKeys = defaults.dictionaryRepresentation().keys
        for key in allKeys {
            for baseKey in userDataKeys where key == baseKey || key.hasPrefix("\(baseKey)::") {
                defaults.removeObject(forKey: key)
                break
            }
        }

        // Clear notification de-dupe keys (prefixed with "notified_")
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("notified_") {
            defaults.removeObject(forKey: key)
        }

        // Clear snoozed emails data
        defaults.removeObject(forKey: "snoozedEmails")

        // 3. Clear any in-memory caches
        // AvatarService clears on dealloc, but force clear if needed
        Task {
            await AvatarService.shared.clearCache()
        }

        // 4. Notify observers that caches were cleared
        NotificationCenter.default.post(name: .cachesDidClear, object: nil)
    }

    // MARK: - Persistence

    private func loadAccounts() {
        guard let data = keychain.read(key: "accounts") else {
            logger.debug("No accounts found in keychain")
            return
        }

        do {
            let savedAccounts = try JSONCoding.decoder.decode([Account].self, from: data)
            accounts = savedAccounts
            currentAccount = savedAccounts.first
            isAuthenticated = !savedAccounts.isEmpty
            logger.info("Loaded \(savedAccounts.count) accounts from keychain")
        } catch {
            logger.error("Failed to decode accounts from keychain: \(error.localizedDescription)")
        }
    }

    private func saveAccounts() {
        do {
            let data = try JSONCoding.encoder.encode(accounts)
            let keychain = self.keychain
            // Move expensive keychain write off main thread
            Task.detached(priority: .utility) {
                keychain.save(key: "accounts", data: data)
            }
            logger.debug("Saved \(self.accounts.count) accounts to keychain")
        } catch {
            logger.error("Failed to encode accounts for keychain: \(error.localizedDescription)")
        }
    }

    // MARK: - PKCE Helpers

    private func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Response Types

private struct TokenResponse: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}

private struct UserInfo: Codable {
    let id: String
    let email: String
    let name: String
    let picture: String?
}

// MARK: - Auth Errors

enum AuthError: LocalizedError {
    case invalidURL
    case noCallback
    case noAuthCode
    case noCodeVerifier
    case tokenExchangeFailed
    case tokenRefreshFailed
    case sessionStartFailed
    case invalidResponse
    case userInfoFetchFailed(Int)
    case invalidRefreshToken
    case refreshTokenRevoked
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid authorization URL"
        case .noCallback: return "No callback received"
        case .noAuthCode: return "No authorization code in callback"
        case .noCodeVerifier: return "Missing code verifier"
        case .tokenExchangeFailed: return "Failed to exchange authorization code"
        case .tokenRefreshFailed: return "Failed to refresh access token"
        case .sessionStartFailed: return "Failed to start authentication session"
        case .invalidResponse: return "Invalid response from server"
        case .userInfoFetchFailed(let code): return "Failed to fetch user info (HTTP \(code))"
        case .invalidRefreshToken: return "Refresh token is invalid"
        case .refreshTokenRevoked: return "Access has been revoked. Please sign in again."
        case .rateLimited: return "Too many requests. Please wait a moment."
        }
    }
}

// MARK: - Keychain Service (Actor for Thread Safety)

import OSLog

private let keychainLogger = Logger(subsystem: "com.simplemail.app", category: "Keychain")

/// Thread-safe keychain wrapper using Swift actor
actor KeychainService {
    static let shared = KeychainService()

    private let service = "com.simplemail.app"

    private init() {}

    // MARK: - Keychain Errors

    enum KeychainError: LocalizedError {
        case saveFailed(OSStatus)
        case readFailed(OSStatus)
        case deleteFailed(OSStatus)
        case dataConversionFailed

        var errorDescription: String? {
            switch self {
            case .saveFailed(let status):
                return "Failed to save to keychain: \(status)"
            case .readFailed(let status):
                return "Failed to read from keychain: \(status)"
            case .deleteFailed(let status):
                return "Failed to delete from keychain: \(status)"
            case .dataConversionFailed:
                return "Failed to convert data"
            }
        }
    }

    // MARK: - Save

    /// Save data to keychain (thread-safe via actor)
    func save(key: String, data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)

        guard status == errSecSuccess else {
            keychainLogger.error("Save failed for key '\(key)': \(status)")
            throw KeychainError.saveFailed(status)
        }

        keychainLogger.debug("Saved data for key '\(key)'")
    }

    /// Save Codable object to keychain
    func save<T: Encodable>(key: String, value: T) throws {
        let data = try JSONCoding.encoder.encode(value)
        try save(key: key, data: data)
    }

    // MARK: - Read

    /// Read data from keychain (thread-safe via actor)
    func read(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                keychainLogger.warning("Read failed for key '\(key)': \(status)")
            }
            return nil
        }

        return result as? Data
    }

    /// Read and decode Codable object from keychain
    func read<T: Decodable>(key: String, as type: T.Type) -> T? {
        guard let data = read(key: key) else { return nil }
        do {
            return try JSONCoding.decoder.decode(type, from: data)
        } catch {
            keychainLogger.error("Decode failed for key '\(key)': \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Delete

    /// Delete item from keychain (thread-safe via actor)
    func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)

        if status != errSecSuccess && status != errSecItemNotFound {
            keychainLogger.warning("Delete failed for key '\(key)': \(status)")
        } else {
            keychainLogger.debug("Deleted key '\(key)'")
        }
    }

    // MARK: - Check Existence

    /// Check if key exists in keychain
    func exists(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: false
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    // MARK: - Clear All

    /// Delete all items for this service
    func clearAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]

        let status = SecItemDelete(query as CFDictionary)
        keychainLogger.info("Cleared all keychain items: \(status)")
    }
}

// MARK: - Synchronous Keychain Wrapper (for MainActor contexts)

/// Thread-safe synchronous wrapper for Keychain access.
///
/// ## Thread Safety Justification for @unchecked Sendable
/// This class is marked `@unchecked Sendable` because:
/// 1. All mutable state access is protected by `NSLock` (lines 645, 672, 690)
/// 2. The Security framework APIs (SecItemAdd, SecItemCopyMatching, SecItemDelete)
///    are thread-safe per Apple's documentation
/// 3. All instance properties are either immutable (`service`) or synchronized (`lock`)
/// 4. The class uses direct Security framework calls instead of fire-and-forget Tasks
///
/// The lock ensures atomicity of keychain operations across concurrent calls from any thread.
final class KeychainServiceSync: @unchecked Sendable {
    static let shared = KeychainServiceSync()

    private let lock = NSLock()
    private let service = "com.simplemail.app"

    private init() {}

    func save(key: String, data: Data) {
        lock.lock()
        defer { lock.unlock() }

        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new item
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            keychainLogger.error("KeychainServiceSync save failed for key '\(key)': \(status)")
        }
    }

    func read(key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return status == errSecSuccess ? result as? Data : nil
    }

    func delete(key: String) {
        lock.lock()
        defer { lock.unlock() }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            keychainLogger.warning("KeychainServiceSync delete failed for key '\(key)': \(status)")
        }
    }
}
