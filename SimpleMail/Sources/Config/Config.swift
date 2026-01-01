import Foundation

/// Configuration errors that can occur when required settings are missing
enum ConfigurationError: LocalizedError {
    case missingClientId
    case missingRedirectUri
    case multipleErrors([ConfigurationError])

    var errorDescription: String? {
        switch self {
        case .missingClientId:
            return "Google Client ID is not configured"
        case .missingRedirectUri:
            return "Google Redirect URI is not configured"
        case .multipleErrors(let errors):
            return errors.map { $0.localizedDescription }.joined(separator: "\n")
        }
    }

    var recoverySuggestion: String? {
        "Please reinstall the app or contact support if this issue persists."
    }
}

/// Centralized configuration loaded from Info.plist
/// OAuth credentials should be set via build configuration, not hardcoded
enum Config {

    // MARK: - Configuration Validation

    /// Validates all required configuration is present
    /// Returns nil if valid, or ConfigurationError if invalid
    static func validate() -> ConfigurationError? {
        var errors: [ConfigurationError] = []

        if _googleClientId == nil {
            errors.append(.missingClientId)
        }
        if _googleRedirectUri == nil {
            errors.append(.missingRedirectUri)
        }

        if errors.isEmpty {
            return nil
        } else if errors.count == 1 {
            return errors[0]
        } else {
            return .multipleErrors(errors)
        }
    }

    /// Whether the app is properly configured
    static var isConfigured: Bool {
        validate() == nil
    }

    // MARK: - OAuth Configuration (Internal with fallbacks)

    private static let _googleClientId: String? = {
        if let id = Bundle.main.object(forInfoDictionaryKey: "GOOGLE_CLIENT_ID") as? String,
           !id.isEmpty {
            return id
        }
        #if DEBUG
        // Fallback for development - should be configured in Info.plist for production
        return "328102220939-s1mjoq2mpsc1dh4c3kkudq3npmg8vusb.apps.googleusercontent.com"
        #else
        return nil
        #endif
    }()

    private static let _googleRedirectUri: String? = {
        if let uri = Bundle.main.object(forInfoDictionaryKey: "GOOGLE_REDIRECT_URI") as? String,
           !uri.isEmpty {
            return uri
        }
        #if DEBUG
        // Fallback for development
        return "com.googleusercontent.apps.328102220939-s1mjoq2mpsc1dh4c3kkudq3npmg8vusb:/oauth2callback"
        #else
        return nil
        #endif
    }()

    // MARK: - Public OAuth Configuration

    /// Google OAuth Client ID
    /// - Precondition: Config.isConfigured must be true before accessing
    static var googleClientId: String {
        guard let id = _googleClientId else {
            // This should never happen if Config.validate() was checked at app launch
            assertionFailure("Accessed googleClientId before validating configuration")
            return ""
        }
        return id
    }

    /// Google OAuth Redirect URI
    /// - Precondition: Config.isConfigured must be true before accessing
    static var googleRedirectUri: String {
        guard let uri = _googleRedirectUri else {
            // This should never happen if Config.validate() was checked at app launch
            assertionFailure("Accessed googleRedirectUri before validating configuration")
            return ""
        }
        return uri
    }

    /// OAuth callback scheme derived from redirect URI (the part before "://")
    static var googleOAuthCallbackScheme: String {
        if let schemeEnd = googleRedirectUri.range(of: "://") {
            return String(googleRedirectUri[..<schemeEnd.lowerBound])
        }
        // Fallback: extract scheme from client ID (reversed domain format)
        let clientIdParts = googleClientId.components(separatedBy: ".apps.googleusercontent.com")
        if let clientNumber = clientIdParts.first {
            return "com.googleusercontent.apps.\(clientNumber)"
        }
        return googleRedirectUri
    }

    // MARK: - API Configuration

    static let gmailAPIBaseURL = "https://gmail.googleapis.com/gmail/v1"
    static let peopleAPIBaseURL = "https://people.googleapis.com/v1"
    static let oauthTokenURL = "https://oauth2.googleapis.com/token"
    static let userInfoURL = "https://www.googleapis.com/oauth2/v2/userinfo"

    // MARK: - App Configuration

    static let keychainService = "com.simplemail.app"
    static let appBundleId = "com.simplemail.app"
}
