import Foundation
import SQLite3
import OSLog

private let searchLogger = Logger(subsystem: "com.simplemail.app", category: "SearchIndex")
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

actor SearchIndexManager {
    static let shared = SearchIndexManager()

    private var db: OpaquePointer?
    private var didWarmup = false
    private let schemaVersion = 1
    private let schemaVersionKey = "searchIndexSchemaVersion"

    private init() {
    }

    func prewarmIfNeeded() async {
        guard !didWarmup else { return }
        didWarmup = true
        _ = try? search(query: "test", accountEmail: nil)
    }

    func index(emails: [EmailDTO]) async {
        guard !emails.isEmpty else { return }
        openDatabase()
        guard let db else { return }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
        defer { sqlite3_exec(db, "COMMIT", nil, nil, nil) }

        let deleteSQL = "DELETE FROM email_fts WHERE id = ?"
        let insertSQL = "INSERT INTO email_fts (id, accountEmail, subject, snippet, sender) VALUES (?, ?, ?, ?, ?)"

        for email in emails {
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

    func remove(ids: [String]) async {
        guard !ids.isEmpty else { return }
        openDatabase()
        guard let db else { return }

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

    func rebuildIndex(with emails: [Email]) async {
        openDatabase()
        guard let db else { return }

        sqlite3_exec(db, "DELETE FROM email_fts", nil, nil, nil)
        let dtos = emails.map { EmailDTO(email: $0) }
        await index(emails: dtos)
    }

    func clearIndex(accountEmail: String?) async {
        openDatabase()
        guard let db else { return }

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

    func search(query rawQuery: String, accountEmail: String?) throws -> [String] {
        let query = buildQuery(rawQuery)
        guard !query.isEmpty else { return [] }

        openDatabase()
        guard let db else { return [] }

        var ids: [String] = []
        let sql: String
        if accountEmail == nil {
            sql = "SELECT id FROM email_fts WHERE email_fts MATCH ? ORDER BY bm25(email_fts) LIMIT 100"
        } else {
            sql = "SELECT id FROM email_fts WHERE email_fts MATCH ? AND accountEmail = ? ORDER BY bm25(email_fts) LIMIT 100"
        }

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            bindText(stmt, 1, query)
            if let accountEmail {
                bindText(stmt, 2, accountEmail)
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cString = sqlite3_column_text(stmt, 0) {
                    ids.append(String(cString: cString))
                }
            }
        }
        sqlite3_finalize(stmt)
        return ids
    }

    // MARK: - Private

    private func openDatabase() {
        guard db == nil else { return }
        let url = databaseURL()
        if sqlite3_open(url.path, &db) != SQLITE_OK {
            searchLogger.error("Failed to open search database")
            db = nil
        } else {
            createSchemaIfNeeded()
            migrateIfNeeded()
        }
    }

    private func createSchemaIfNeeded() {
        guard let db else { return }
        let createSQL = """
        CREATE VIRTUAL TABLE IF NOT EXISTS email_fts USING fts5(
            id, accountEmail, subject, snippet, sender,
            tokenize='unicode61'
        );
        """
        sqlite3_exec(db, createSQL, nil, nil, nil)
    }

    private func migrateIfNeeded() {
        guard let db else { return }
        let currentVersion = UserDefaults.standard.integer(forKey: schemaVersionKey)
        guard currentVersion < schemaVersion else { return }
        sqlite3_exec(db, "DROP TABLE IF EXISTS email_fts", nil, nil, nil)
        createSchemaIfNeeded()
        UserDefaults.standard.set(schemaVersion, forKey: schemaVersionKey)
        searchLogger.info("Search index schema migrated to v\(self.schemaVersion)")
    }

    private func databaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("SearchIndex", isDirectory: true)
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
