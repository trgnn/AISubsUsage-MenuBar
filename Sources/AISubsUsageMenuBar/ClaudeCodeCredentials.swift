import Foundation

// Fallback when no Claude Desktop session exists: the Claude Code CLI login.
// macOS Keychain item "Claude Code-credentials" first, then
// ~/.claude/.credentials.json (written when the Keychain is unavailable).
// { "claudeAiOauth": { "accessToken": "...", "expiresAt": <ms>, "subscriptionType": "max" } }
// Read-only: never refreshes the token (that would rotate Claude Code's own login).
enum ClaudeCodeCredentials {
    struct Creds {
        var accessToken: String
        var expiresAt: Date?
        var subscriptionType: String?

        var isExpired: Bool { expiresAt.map { $0 < Date() } ?? false }
    }

    // Cached in memory so macOS only prompts once per launch.
    private static var cachedJSON: Data?

    static func load() -> Creds? {
        if cachedJSON == nil {
            cachedJSON = keychainJSON() ?? fileJSON()
        }
        guard let data = cachedJSON,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        let expires = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return Creds(accessToken: token, expiresAt: expires, subscriptionType: oauth["subscriptionType"] as? String)
    }

    /// Drop the cache so the next load picks up a renewed login.
    static func reset() { cachedJSON = nil }

    private static func keychainJSON() -> Data? {
        let out = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        proc.standardOutput = out
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return data.isEmpty ? nil : data
    }

    private static func fileJSON() -> Data? {
        let url = URL(fileURLWithPath: CredentialsStore.home).appendingPathComponent(".claude/.credentials.json")
        return try? Data(contentsOf: url)
    }
}
