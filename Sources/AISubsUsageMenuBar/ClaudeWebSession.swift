import Foundation

// Reads Claude Desktop web sessions (no Claude Code CLI needed).
// Supports MULTIPLE Claude instances: every ~/Library/Application Support/Claude*/Cookies
// database (e.g. "Claude" and "Claude-Compte2") yields one session.
// Same recipe as the claude-web-usage project:
//  1. Keychain password ("Claude Safe Storage") -> PBKDF2-SHA1("saltysalt", 1003) -> AES-128 key
//  2. Cookies SQLite DB (Chromium): sessionKey + lastActiveOrg (+ cf_clearance)
//  3. AES-128-CBC decrypt (IV = 16 spaces), strip "v10" + 32-byte prefix -> sk-ant-sid...
enum ClaudeWebSession {
    struct Session {
        var label: String // app-support dir name, e.g. "Claude", "Claude-Compte2"
        var sessionKey: String
        var orgID: String
    }

    // Cached in memory so macOS only prompts once per launch.
    private static var cachedPassword: String?

    /// All logged-in Claude Desktop sessions on this Mac (usually one).
    static func loadAll() throws -> [Session] {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support").path
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: support)) ?? []
        // "Claude" first, then the rest alphabetically ("Claude-Beta", "Claude-Compte2", …).
        let claudeDirs = dirs.filter {
            $0 == "Claude" || ($0.hasPrefix("Claude-") && !$0.contains("."))
        }.sorted { a, b in
            if a == "Claude" { return true }
            if b == "Claude" { return false }
            return a < b
        }
        var sessions: [Session] = []
        var firstError: Error?
        for dir in claudeDirs {
            do {
                if let s = try loadOne(dir: support + "/" + dir, label: dir) {
                    sessions.append(s)
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if sessions.isEmpty { throw firstError ?? CredentialsStore.ClaudeCredsError.notFound }
        return sessions
    }

    /// Convenience for single-account setups.
    static func load() throws -> Session {
        try loadAll()[0]
    }

    private static func loadOne(dir: String, label: String) throws -> Session? {
        let db = dir + "/Cookies"
        guard FileManager.default.fileExists(atPath: db) else { return nil }
        let password = try keychainPassword()
        guard let skHex = sqliteHex(db: db, cookie: "sessionKey"),
              let orgHex = sqliteHex(db: db, cookie: "lastActiveOrg"),
              let sk = ChromiumCookie.decrypt(hex: skHex, password: password),
              let org = ChromiumCookie.decrypt(hex: orgHex, password: password),
              sk.hasPrefix("sk-ant-"), !org.isEmpty
        else { return nil } // DB exists but no login cookies — not an error, skip it
        return Session(label: label, sessionKey: sk, orgID: org)
    }

    // MARK: - Keychain (via `security` CLI: same access path as the reference tools)

    private static func keychainPassword() throws -> String {
        if let p = cachedPassword { return p }
        let out = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", "Claude Safe Storage", "-w"]
        proc.standardOutput = out
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            // status 51 = user clicked Deny (or item missing and no prompt path)
            if proc.terminationStatus == 51 { throw CredentialsStore.ClaudeCredsError.accessDenied }
            throw CredentialsStore.ClaudeCredsError.notFound
        }
        let pw = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !pw.isEmpty else { throw CredentialsStore.ClaudeCredsError.notFound }
        cachedPassword = pw
        return pw
    }

    // MARK: - SQLite (via system `sqlite3` CLI; immutable snapshot avoids lock issues)

    private static func sqliteHex(db: String, cookie: String) -> String? {
        guard cookie.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil else { return nil }
        let sql = "SELECT hex(encrypted_value) FROM cookies WHERE host_key='.claude.ai' AND name='\(cookie)' LIMIT 1;"
        if let hex = runSqlite(db: db, sql: sql), !hex.isEmpty { return hex }
        // Fallback: immutable snapshot if the DB is locked by the running app
        return runSqlite(db: "file:\(db)?immutable=1", sql: sql).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func runSqlite(db: String, sql: String) -> String? {
        let out = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        proc.arguments = [db, sql]
        proc.standardOutput = out
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
