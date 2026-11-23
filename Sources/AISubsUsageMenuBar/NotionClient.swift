import Foundation

// Notion AI usage via the Notion Desktop web session (no API token needed).
// Same Chromium-cookie recipe as Claude and Figma:
//  ~/Library/Application Support/Notion/Partitions/notion/Cookies, Keychain "Notion Safe Storage"
// REST (undocumented internals, reverse-engineered from the web app):
//  POST /api/v3/getSpaces {} -> {userID: {notion_user, space}} for every signed-in user
//  POST /api/v3/getAIUsageEligibilityV2 {spaceId} -> included AI allowance + Notion credits
enum NotionClient {
    struct Result {
        var buckets: [UsageBucket]
    }

    /// One Notion workspace, e.g. "me@example.com · Acme (Business)".
    struct Account {
        var key: String // "notion:{userID}:{spaceID}" — stable across renames
        var displayName: String
        var result: Result?
        var error: String?
    }

    static func fetchAll() async -> [Account] {
        let session: Session
        do {
            session = try loadSession()
        } catch {
            return [Account(key: "notion", displayName: "Notion", result: nil, error: error.localizedDescription)]
        }
        let workspaces: [Workspace]
        do {
            workspaces = try parseSpaces(try await post("getSpaces", body: [:], userID: session.userID, session: session))
        } catch {
            return [Account(key: "notion", displayName: "Notion", result: nil, error: error.localizedDescription)]
        }
        var accounts: [Account] = []
        for w in workspaces {
            let key = "notion:\(w.userID):\(w.spaceID)"
            do {
                let data = try await post("getAIUsageEligibilityV2", body: ["spaceId": w.spaceID], userID: w.userID, session: session)
                accounts.append(Account(key: key, displayName: w.displayName, result: try parseUsage(data, spaceID: w.spaceID), error: nil))
            } catch {
                accounts.append(Account(key: key, displayName: w.displayName, result: nil, error: error.localizedDescription))
            }
        }
        if accounts.isEmpty {
            return [Account(key: "notion", displayName: "Notion", result: nil, error: "No Notion workspace found.")]
        }
        return accounts
    }

    // MARK: - Parsing (testable seams)

    struct Workspace: Equatable {
        var userID: String
        var spaceID: String
        var displayName: String
    }

    /// getSpaces -> one workspace per (user, space), named "email · space (Tier)".
    /// Records come wrapped as {value: {...}} or {value: {value: {...}}}.
    static func parseSpaces(_ data: Data) throws -> [Workspace] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        func record(_ any: Any?) -> [String: Any]? {
            guard let outer = (any as? [String: Any])?["value"] as? [String: Any] else { return nil }
            return outer["value"] as? [String: Any] ?? outer
        }
        var out: [Workspace] = []
        for userID in root.keys.sorted() {
            guard let tables = root[userID] as? [String: Any] else { continue }
            let email = record((tables["notion_user"] as? [String: Any])?[userID])?["email"] as? String
            let spaces = tables["space"] as? [String: Any] ?? [:]
            for spaceID in spaces.keys.sorted() {
                let space = record(spaces[spaceID])
                let name = space?["name"] as? String ?? "Notion"
                let tier = (space?["subscription_tier"] as? String).map { " (\(Formatters.planName($0)))" } ?? ""
                let label = [email, name + tier].compactMap { $0 }.joined(separator: " · ")
                out.append(Workspace(userID: userID, spaceID: spaceID, displayName: label))
            }
        }
        return out
    }

    /// getAIUsageEligibilityV2 -> "AI" (included allowance, this member) and
    /// "Credits" (purchased Notion credits) buckets; zero limits are skipped.
    static func parseUsage(_ data: Data, spaceID: String) throws -> Result {
        let r = try JSONDecoder().decode(UsageResponse.self, from: data)
        var buckets: [UsageBucket] = []
        if let b = r.basicCredits, let limit = b.userLimit, limit > 0 {
            let used = (b.userUsage ?? 0)
            buckets.append(UsageBucket(id: "notion-ai-\(spaceID)", title: "AI", percent: min(used / limit * 100, 100),
                                       resetsAt: nil, detail: "\(fmtNum(max(limit - used, 0)))/\(fmtNum(limit)) left"))
        }
        let sources = r.premiumCredits?.perSource?.values.map { $0 } ?? []
        let limit = sources.compactMap(\.limit).reduce(0, +)
        if limit > 0 {
            let used = sources.compactMap(\.usageTotal).reduce(0, +)
            buckets.append(UsageBucket(id: "notion-credits-\(spaceID)", title: "Credits", percent: min(used / limit * 100, 100),
                                       resetsAt: nil, detail: "\(fmtNum(max(limit - used, 0)))/\(fmtNum(limit)) left"))
        }
        return Result(buckets: buckets)
    }

    private static func fmtNum(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(format: "%.1f", v)
    }

    private struct UsageResponse: Codable {
        var basicCredits: Basic?
        var premiumCredits: Premium?

        struct Basic: Codable {
            var userUsage: Double?
            var userLimit: Double?
        }

        struct Premium: Codable {
            var perSource: [String: Source]?
        }

        struct Source: Codable {
            var usageTotal: Double?
            var limit: Double?
        }
    }

    // MARK: - REST

    private static let base = "https://app.notion.com/api/v3/"
    private static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

    private static func post(_ endpoint: String, body: [String: String], userID: String, session: Session) async throws -> Data {
        var req = URLRequest(url: URL(string: base + endpoint)!, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue(session.cookieHeader, forHTTPHeaderField: "Cookie")
        // Picks the account when several users share the Desktop session.
        req.setValue(userID, forHTTPHeaderField: "x-notion-active-user-header")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw UsageError.network("No HTTP response") }
        switch http.statusCode {
        case 200: return data
        case 401, 403: throw UsageError.unauthorized("Notion session expired — reopen Notion, then Refresh.")
        default: throw UsageError.network("Notion API HTTP \(http.statusCode)")
        }
    }

    // MARK: - Session (Desktop cookies)

    private struct Session {
        var userID: String
        var cookieHeader: String
    }

    private static let notSignedIn = UsageError.notSignedIn("No Notion login found — open Notion.")

    private static func loadSession() throws -> Session {
        let db = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Notion/Partitions/notion/Cookies").path
        guard FileManager.default.fileExists(atPath: db),
              let password = try ChromiumCookie.keychainPassword(service: "Notion Safe Storage")
        else { throw notSignedIn }
        let cookies = Dictionary(ChromiumCookie.cookies(db: db, hosts: [".notion.com", ".app.notion.com", "app.notion.com"],
                                                        password: password),
                                 uniquingKeysWith: { first, _ in first })
        guard let token = cookies["token_v2"], let userID = cookies["notion_user_id"] else { throw notSignedIn }
        return Session(userID: userID, cookieHeader: "token_v2=\(token); notion_user_id=\(userID)")
    }
}
