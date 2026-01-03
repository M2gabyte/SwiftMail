import Foundation

/// Centralized timeout configuration
/// All network and timer-related timeouts in one place for easy tuning
enum TimeoutConfig {

    // MARK: - Network Timeouts

    /// Gmail API request timeout
    static let gmailAPI: TimeInterval = 20

    /// People API request timeout
    static let peopleAPI: TimeInterval = 15

    /// OAuth token exchange timeout
    static let tokenExchange: TimeInterval = 30

    // MARK: - Token Management

    /// Buffer time before token expiry to trigger refresh (5 minutes)
    static let tokenExpiryBuffer: TimeInterval = 300

    // MARK: - Cache Configuration

    /// Contact cache expiry interval (5 minutes)
    static let contactCacheExpiry: TimeInterval = 300

    /// Avatar cache expiry interval (1 hour)
    static let avatarCacheExpiry: TimeInterval = 3600

    // MARK: - Background Tasks

    /// Background sync interval (15 minutes)
    static let backgroundSyncInterval: TimeInterval = 900

    /// Background notification check interval (5 minutes)
    static let notificationCheckInterval: TimeInterval = 300

    /// Background summary processing interval (30 minutes)
    static let summaryProcessingInterval: TimeInterval = 1800

    // MARK: - User Interface

    /// Snooze check polling interval (60 seconds)
    static let snoozePollInterval: TimeInterval = 60

    /// Undo action window (4 seconds)
    static let undoWindow: TimeInterval = 4

    /// Debounce interval for search input (300ms)
    static let searchDebounce: TimeInterval = 0.3
}
