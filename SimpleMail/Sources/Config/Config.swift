import Foundation

/// Centralized configuration loaded from Info.plist
/// OAuth credentials should be set via build configuration, not hardcoded
enum Config {

    // MARK: - OAuth Configuration

    static let googleClientId: String = {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "GOOGLE_CLIENT_ID") as? String,
              !id.isEmpty else {
            #if DEBUG
            // Fallback for development - should be configured in Info.plist for production
            return "328102220939-s1mjoq2mpsc1dh4c3kkudq3npmg8vusb.apps.googleusercontent.com"
            #else
            fatalError("GOOGLE_CLIENT_ID not configured in Info.plist")
            #endif
        }
        return id
    }()

    static let googleRedirectUri: String = {
        guard let uri = Bundle.main.object(forInfoDictionaryKey: "GOOGLE_REDIRECT_URI") as? String,
              !uri.isEmpty else {
            #if DEBUG
            // Fallback for development
            return "com.googleusercontent.apps.328102220939-s1mjoq2mpsc1dh4c3kkudq3npmg8vusb:/oauth2callback"
            #else
            fatalError("GOOGLE_REDIRECT_URI not configured in Info.plist")
            #endif
        }
        return uri
    }()

    // MARK: - API Configuration

    static let gmailAPIBaseURL = "https://gmail.googleapis.com/gmail/v1"
    static let peopleAPIBaseURL = "https://people.googleapis.com/v1"
    static let oauthTokenURL = "https://oauth2.googleapis.com/token"
    static let userInfoURL = "https://www.googleapis.com/oauth2/v2/userinfo"

    // MARK: - App Configuration

    static let keychainService = "com.simplemail.app"
    static let appBundleId = "com.simplemail.app"
}
