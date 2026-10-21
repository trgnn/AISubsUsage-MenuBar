import Foundation

// Reads the OAuth token written by `codex login`.
// Claude uses the Desktop app web session instead (see ClaudeWebSession) —
// no CLI credentials needed.

enum CredentialsStore {
    struct OpenAICreds {
        var accessToken: String
        var accountID: String?
        var refreshToken: String?
    }

    enum ClaudeCredsError: LocalizedError {
        case notFound
        case accessDenied

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "No Claude login found — open Claude Desktop."
            case .accessDenied:
                return "Keychain access denied — click Always Allow, then Refresh."
            }
        }
    }

    static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    // MARK: OpenAI — ~/.codex/auth.json
    // { "tokens": { "access_token": "...", "refresh_token": "...", "account_id": "..." } }
    static func loadOpenAI() -> OpenAICreds? {
        let url = URL(fileURLWithPath: home).appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let at = tokens["access_token"] as? String, !at.isEmpty
        else { return nil }
        return OpenAICreds(
            accessToken: at,
            accountID: tokens["account_id"] as? String,
            refreshToken: tokens["refresh_token"] as? String
        )
    }
}
