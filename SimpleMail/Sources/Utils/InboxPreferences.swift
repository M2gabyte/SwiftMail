import Foundation

extension Notification.Name {
    static let inboxPreferencesDidChange = Notification.Name("inboxPreferencesDidChange")
}

enum InboxPreferences {
    private static let initializedKey = "inboxPrefsInitialized"
    private static let pinnedTabKey = "pinnedTabOption"

    static func ensureDefaultsInitialized() {
        guard !AccountDefaults.bool(for: initializedKey, accountEmail: nil) else {
            return
        }

        setPinnedTabOption(.other, notify: false)
        for rule in PrimaryRule.allCases {
            setPrimaryRuleEnabled(rule, rule.defaultEnabled, notify: false)
        }
        AccountDefaults.setBool(true, for: initializedKey, accountEmail: nil)
        notifyChange()
    }

    static func getPinnedTabOption() -> PinnedTabOption {
        if let raw = AccountDefaults.string(for: pinnedTabKey, accountEmail: nil),
           let option = PinnedTabOption(rawValue: raw) {
            return option
        }
        return .other
    }

    static func setPinnedTabOption(_ option: PinnedTabOption) {
        setPinnedTabOption(option, notify: true)
    }

    static func isPrimaryRuleEnabled(_ rule: PrimaryRule) -> Bool {
        if AccountDefaults.bool(for: rule.defaultsKey, accountEmail: nil) {
            return true
        }
        return false
    }

    static func setPrimaryRuleEnabled(_ rule: PrimaryRule, _ enabled: Bool) {
        setPrimaryRuleEnabled(rule, enabled, notify: true)
    }

    private static func setPinnedTabOption(_ option: PinnedTabOption, notify: Bool) {
        AccountDefaults.setString(option.rawValue, for: pinnedTabKey, accountEmail: nil)
        if notify {
            notifyChange()
        }
    }

    private static func setPrimaryRuleEnabled(_ rule: PrimaryRule, _ enabled: Bool, notify: Bool) {
        AccountDefaults.setBool(enabled, for: rule.defaultsKey, accountEmail: nil)
        if notify {
            notifyChange()
        }
    }

    private static func notifyChange() {
        NotificationCenter.default.post(name: .inboxPreferencesDidChange, object: nil)
    }
}
