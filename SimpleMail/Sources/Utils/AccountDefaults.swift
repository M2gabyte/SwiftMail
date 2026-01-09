import Foundation

@MainActor
enum AccountDefaults {
    static func scopedKey(_ key: String, accountEmail: String?) -> String {
        guard let email = accountEmail?.lowercased(), !email.isEmpty else {
            return key
        }
        return "\(key)::\(email)"
    }

    // MARK: - String

    static func string(for key: String, accountEmail: String?) -> String? {
        UserDefaults.standard.string(forKey: scopedKey(key, accountEmail: accountEmail))
    }

    static func setString(_ value: String?, for key: String, accountEmail: String?) {
        UserDefaults.standard.set(value, forKey: scopedKey(key, accountEmail: accountEmail))
    }

    // MARK: - Data

    static func data(for key: String, accountEmail: String?) -> Data? {
        UserDefaults.standard.data(forKey: scopedKey(key, accountEmail: accountEmail))
    }

    static func setData(_ data: Data?, for key: String, accountEmail: String?) {
        UserDefaults.standard.set(data, forKey: scopedKey(key, accountEmail: accountEmail))
    }

    // MARK: - String Array

    static func stringArray(for key: String, accountEmail: String?) -> [String] {
        UserDefaults.standard.stringArray(forKey: scopedKey(key, accountEmail: accountEmail)) ?? []
    }

    static func setStringArray(_ value: [String], for key: String, accountEmail: String?) {
        UserDefaults.standard.set(value, forKey: scopedKey(key, accountEmail: accountEmail))
    }

    // MARK: - Bool

    static func bool(for key: String, accountEmail: String?) -> Bool {
        UserDefaults.standard.bool(forKey: scopedKey(key, accountEmail: accountEmail))
    }

    static func setBool(_ value: Bool, for key: String, accountEmail: String?) {
        UserDefaults.standard.set(value, forKey: scopedKey(key, accountEmail: accountEmail))
    }

    // MARK: - Date

    static func date(for key: String, accountEmail: String?) -> Date? {
        UserDefaults.standard.object(forKey: scopedKey(key, accountEmail: accountEmail)) as? Date
    }

    static func setDate(_ value: Date?, for key: String, accountEmail: String?) {
        UserDefaults.standard.set(value, forKey: scopedKey(key, accountEmail: accountEmail))
    }

    // MARK: - Remove

    static func remove(key: String, accountEmail: String?) {
        UserDefaults.standard.removeObject(forKey: scopedKey(key, accountEmail: accountEmail))
    }
}
