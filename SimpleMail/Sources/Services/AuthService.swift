import Foundation
import AuthenticationServices
import CryptoKit
import UIKit

// MARK: - Auth Service

@MainActor
final class AuthService: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = AuthService()

    @Published var isAuthenticated = false
    @Published var currentAccount: Account?
    @Published var accounts: [Account] = []

    private let keychain = KeychainServiceSync.shared
    private let clientId = "328102220939-s1mjoq2mpsc1dh4c3kkudq3npmg8vusb.apps.googleusercontent.com"
    private let redirectUri = "com.googleusercontent.apps.328102220939-s1mjoq2mpsc1dh4c3kkudq3npmg8vusb:/oauth2callback"

    private var codeVerifier: String?

    // MARK: - Account Model

    struct Account: Identifiable, Codable, Equatable {
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
        // Must dispatch to main thread synchronously to access UIApplication
        return DispatchQueue.main.sync {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = windowScene.windows.first else {
                return ASPresentationAnchor()
            }
            return window
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
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: [
                "https://www.googleapis.com/auth/gmail.readonly",
                "https://www.googleapis.com/auth/gmail.send",
                "https://www.googleapis.com/auth/gmail.modify",
                "https://www.googleapis.com/auth/userinfo.email",
                "https://www.googleapis.com/auth/userinfo.profile"
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
                callbackURLScheme: "com.googleusercontent.apps.328102220939-s1mjoq2mpsc1dh4c3kkudq3npmg8vusb"
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

        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
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

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

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
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(UserInfo.self, from: data)
    }

    // MARK: - Token Refresh

    func refreshTokenIfNeeded(for account: Account) async throws -> Account {
        guard account.isExpired, let refreshToken = account.refreshToken else {
            return account
        }

        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
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

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

        var updatedAccount = account
        updatedAccount.accessToken = tokenResponse.accessToken
        updatedAccount.expiresAt = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))

        updateAccount(updatedAccount)

        return updatedAccount
    }

    // MARK: - Account Management

    func addAccount(_ account: Account) {
        accounts.removeAll { $0.email == account.email }
        accounts.append(account)
        currentAccount = account
        isAuthenticated = true
        saveAccounts()
    }

    func updateAccount(_ account: Account) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
            if currentAccount?.id == account.id {
                currentAccount = account
            }
            saveAccounts()
        }
    }

    func removeAccount(_ account: Account) {
        accounts.removeAll { $0.id == account.id }
        if currentAccount?.id == account.id {
            currentAccount = accounts.first
        }
        isAuthenticated = !accounts.isEmpty
        saveAccounts()
    }

    func switchAccount(to account: Account) {
        currentAccount = account
        saveAccounts()
    }

    func signOut() {
        accounts.removeAll()
        currentAccount = nil
        isAuthenticated = false
        keychain.delete(key: "accounts")
    }

    // MARK: - Persistence

    private func loadAccounts() {
        guard let data = keychain.read(key: "accounts"),
              let savedAccounts = try? JSONDecoder().decode([Account].self, from: data) else {
            return
        }
        accounts = savedAccounts
        currentAccount = savedAccounts.first
        isAuthenticated = !savedAccounts.isEmpty
    }

    private func saveAccounts() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        keychain.save(key: "accounts", data: data)
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

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid authorization URL"
        case .noCallback: return "No callback received"
        case .noAuthCode: return "No authorization code in callback"
        case .noCodeVerifier: return "Missing code verifier"
        case .tokenExchangeFailed: return "Failed to exchange authorization code"
        case .tokenRefreshFailed: return "Failed to refresh access token"
        case .sessionStartFailed: return "Failed to start authentication session"
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
        let data = try JSONEncoder().encode(value)
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
            return try JSONDecoder().decode(type, from: data)
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

/// Synchronous wrapper for KeychainService for use in @MainActor contexts
/// Use sparingly - prefer async access when possible
final class KeychainServiceSync {
    static let shared = KeychainServiceSync()
    private init() {}

    func save(key: String, data: Data) {
        Task {
            try? await KeychainService.shared.save(key: key, data: data)
        }
    }

    func read(key: String) -> Data? {
        // For synchronous read, we need to use the underlying Security APIs directly
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.simplemail.app",
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return status == errSecSuccess ? result as? Data : nil
    }

    func delete(key: String) {
        Task {
            await KeychainService.shared.delete(key: key)
        }
    }
}
