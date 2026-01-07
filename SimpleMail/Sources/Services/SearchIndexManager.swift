import Foundation
import SQLite3
import OSLog

private let searchLogger = Logger(subsystem: "com.simplemail.app", category: "SearchIndex")
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private let SQLITE_TRANSIENT = sqliteTransient

actor SearchIndexManager {
    static let shared = SearchIndexManager()

    private var databases: [String: OpaquePointer] = [:]
    private var didWarmup: Set<String> = []
    private let schemaVersion = 1
    private let schemaVersionKeyBase = "searchIndexSchemaVersion"

    private init() {
    }

    func prewarmIfNeeded(accountEmail: String?) async {
        let accountKey = accountKey(for: accountEmail)
        guard !didWarmup.contains(accountKey) else { return }
        didWarmup.insert(accountKey)
        _ = try? await search(query: "test", accountEmail: accountEmail)
    }

    func index(emails: [EmailDTO]) async {
        guard !emails.isEmpty else { return }
        let grouped = Dictionary(grouping: emails) { accountKey(for: $0.accountEmail) }
        for (accountKey, accountEmails) in grouped {
            guard let db = openDatabase(for: accountKey) else { continue }
            sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
            defer { sqlite3_exec(db, "COMMIT", nil, nil, nil) }

            let deleteSQL = "DELETE FROM email_fts WHERE id = ?"
            let insertSQL = "INSERT INTO email_fts (id, accountEmail, subject, snippet, sender) VALUES (?, ?, ?, ?, ?)"

            for email in accountEmails {
                var deleteStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStmt, nil) == SQLITE_OK {
                    bindText(deleteStmt, 1, email.id)
                    sqlite3_step(deleteStmt)
                }
                sqlite3_finalize(deleteStmt)

                var insertStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK {
                    bindText(insertStmt, 1, email.id)
                    bindText(insertStmt, 2, email.accountEmail ?? "")
                    bindText(insertStmt, 3, email.subject)
                    bindText(insertStmt, 4, email.snippet)
                    bindText(insertStmt, 5, email.from)
                    sqlite3_step(insertStmt)
                }
                sqlite3_finalize(insertStmt)
            }
        }
    }

    func remove(ids: [String], accountEmail: String?) async {
        guard !ids.isEmpty else { return }
        let accountKeys = await accountKeysForOperation(accountEmail: accountEmail)

        for accountKey in accountKeys {
            guard let db = openDatabase(for: accountKey) else { continue }
            sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
            defer { sqlite3_exec(db, "COMMIT", nil, nil, nil) }

            let deleteSQL = "DELETE FROM email_fts WHERE id = ?"
            for id in ids {
                var deleteStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStmt, nil) == SQLITE_OK {
                    bindText(deleteStmt, 1, id)
                    sqlite3_step(deleteStmt)
                }
                sqlite3_finalize(deleteStmt)
            }
        }
    }

    func rebuildIndex(with emails: [Email]) async {
        let dtos = emails.map { EmailDTO(email: $0) }
        let grouped = Dictionary(grouping: dtos) { accountKey(for: $0.accountEmail) }
        for (accountKey, accountEmails) in grouped {
            guard let db = openDatabase(for: accountKey) else { continue }
            sqlite3_exec(db, "DELETE FROM email_fts", nil, nil, nil)
            await index(emails: accountEmails)
        }
    }

    func clearIndex(accountEmail: String?) async {
        let accountKeys = await accountKeysForOperation(accountEmail: accountEmail)

        for accountKey in accountKeys {
            guard let db = openDatabase(for: accountKey) else { continue }
            if let accountEmail {
                let sql = "DELETE FROM email_fts WHERE accountEmail = ?"
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    bindText(stmt, 1, accountEmail)
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
            } else {
                sqlite3_exec(db, "DELETE FROM email_fts", nil, nil, nil)
            }
        }
    }

    func search(query rawQuery: String, accountEmail: String?) async throws -> [String] {
        let query = buildQuery(rawQuery)
        guard !query.isEmpty else { return [] }
        if let accountEmail {
            return searchInAccount(query: query, accountEmail: accountEmail)
        }

        let accounts = await MainActor.run {
            AuthService.shared.accounts.map { $0.email.lowercased() }
        }

        var ids: [String] = []
        for account in accounts {
            ids.append(contentsOf: searchInAccount(query: query, accountEmail: account))
        }
        return ids
    }

    // MARK: - Private

    private func openDatabase(for accountKey: String) -> OpaquePointer? {
        if let existing = databases[accountKey] {
            return existing
        }
        let url = databaseURL(for: accountKey)
        var db: OpaquePointer?
        if sqlite3_open(url.path, &db) != SQLITE_OK {
            searchLogger.error("Failed to open search database for \(accountKey, privacy: .public)")
            return nil
        }
        databases[accountKey] = db
        createSchemaIfNeeded(db: db)
        migrateIfNeeded(db: db, accountKey: accountKey)
        return db
    }

    private func createSchemaIfNeeded(db: OpaquePointer?) {
        guard let db else { return }
        let createSQL = """
        CREATE VIRTUAL TABLE IF NOT EXISTS email_fts USING fts5(
            id, accountEmail, subject, snippet, sender,
            tokenize='unicode61'
        );
        """
        sqlite3_exec(db, createSQL, nil, nil, nil)
    }

    private func migrateIfNeeded(db: OpaquePointer?, accountKey: String) {
        guard let db else { return }
        let currentVersion = UserDefaults.standard.integer(forKey: schemaVersionKey(accountKey: accountKey))
        guard currentVersion < schemaVersion else { return }
        sqlite3_exec(db, "DROP TABLE IF EXISTS email_fts", nil, nil, nil)
        createSchemaIfNeeded(db: db)
        UserDefaults.standard.set(schemaVersion, forKey: schemaVersionKey(accountKey: accountKey))
        searchLogger.info("Search index schema migrated to v\(self.schemaVersion) for \(accountKey, privacy: .public)")
    }

    private func databaseURL(for accountKey: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base
            .appendingPathComponent("SearchIndex", isDirectory: true)
            .appendingPathComponent(accountKey, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("email_search.sqlite")
    }

    private func buildQuery(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let tokens = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .map { token in
                token.replacingOccurrences(of: "\"", with: "").lowercased()
            }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return "" }
        return tokens.map { "\($0)*" }.joined(separator: " AND ")
    }

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, sqliteTransient) }
    }

    private func accountKey(for accountEmail: String?) -> String {
        let raw = (accountEmail?.lowercased() ?? "unknown")
        return raw
            .replacingOccurrences(of: "@", with: "_at_")
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private func schemaVersionKey(accountKey: String) -> String {
        "\(schemaVersionKeyBase)::\(accountKey)"
    }

    private func searchInAccount(query: String, accountEmail: String) -> [String] {
        let accountKey = accountKey(for: accountEmail)
        guard let db = openDatabase(for: accountKey) else { return [] }

        var ids: [String] = []
        let sql = "SELECT id FROM email_fts WHERE email_fts MATCH ? AND accountEmail = ? ORDER BY bm25(email_fts) LIMIT 100"

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            bindText(stmt, 1, query)
            bindText(stmt, 2, accountEmail)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cString = sqlite3_column_text(stmt, 0) {
                    ids.append(String(cString: cString))
                }
            }
        }
        sqlite3_finalize(stmt)
        return ids
    }

    private func accountKeysForOperation(accountEmail: String?) async -> [String] {
        if let accountEmail {
            return [accountKey(for: accountEmail)]
        }
        let accounts = await MainActor.run {
            AuthService.shared.accounts.map { $0.email.lowercased() }
        }
        let keys = accounts.map { accountKey(for: $0) }
        return keys.isEmpty ? Array(databases.keys) : keys
    }
}

private extension EmailDTO {
    init(email: Email) {
        self.init(
            id: email.id,
            threadId: email.threadId,
            snippet: email.snippet,
            subject: email.subject,
            from: email.from,
            date: email.date,
            isUnread: email.isUnread,
            isStarred: email.isStarred,
            hasAttachments: email.hasAttachments,
            labelIds: email.labelIds,
            messagesCount: email.messagesCount,
            accountEmail: email.accountEmail,
            listUnsubscribe: email.listUnsubscribe,
            listId: email.listId,
            precedence: email.precedence,
            autoSubmitted: email.autoSubmitted
        )
    }
}
