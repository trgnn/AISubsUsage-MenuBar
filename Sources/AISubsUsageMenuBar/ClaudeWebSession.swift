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
        guard let password = try ChromiumCookie.keychainPassword(service: "Claude Safe Storage") else {
            throw CredentialsStore.ClaudeCredsError.notFound
        }
        let cookies = Dictionary(ChromiumCookie.cookies(db: db, hosts: [".claude.ai"], password: password),
                                 uniquingKeysWith: { first, _ in first })
        guard let sk = cookies["sessionKey"], let org = cookies["lastActiveOrg"],
              sk.hasPrefix("sk-ant-"), !org.isEmpty
        else { return nil } // DB exists but no login cookies — not an error, skip it
        return Session(label: label, sessionKey: sk, orgID: org)
    }
}
