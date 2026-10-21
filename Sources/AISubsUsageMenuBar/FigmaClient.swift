import Foundation

// Figma AI credits via the Figma Desktop web session (no API token needed).
// Same Chromium-cookie recipe as ClaudeWebSession, different app dir:
//  1. ~/Library/Application Support/Figma/DesktopProfile/*/Cookies (newest profile first)
//  2. Keychain "Figma Safe Storage" -> PBKDF2-SHA1("saltysalt", 1003) -> AES-128 key
//  3. AES-128-CBC decrypt (IV = 16 spaces), strip "v10" + 32-byte prefix
// REST (undocumented internals, reverse-engineered from the web app):
//  GET /api/shared_with_you/plan_filter_options?resource_type[]=file -> plans + plan_record_id
//  GET /api/plans/{record_id}/ai_credits/plan_user_balance_summary -> seat monthly/daily balance
enum FigmaClient {
    struct Result {
        var buckets: [UsageBucket]
        var monthlyTotal: Double? // seat monthly quota — drives ordering (bigger plans first)
    }

    /// One Figma plan (team), e.g. "Acme".
    struct Account {
        var key: String // "figma:{userID}:{planID}" — stable across renames
        var displayName: String
        var result: Result?
        var error: String?
    }

    /// Balance summary for every owned plan, every Desktop account.
    /// One cookie jar can hold several Figma logins: authn maps userID->token,
    /// so each user gets a scoped session (single-entry authn) — otherwise the
    /// API blends accounts and shared-file teams leak in.
    static func fetchAll() async -> [Account] {
        let sessions: [Session]
        do {
            sessions = try candidateSessions()
        } catch {
            return [Account(key: "figma", displayName: "Figma", result: nil, error: error.localizedDescription)]
        }
        var accounts: [Account] = []
        var lastError = "No Figma login found — open Figma Desktop."
        for session in sessions {
            do {
                let allPlans = try await planFilters(session: session)
                // Keep only my own teams/orgs: plan_filter_options also returns
                // plans from merely-shared files (no team membership there).
                // Fail-open: if the teams list can't be read, show everything.
                let own = try? await ownPlanIDs(session: session)
                let plans = allPlans.filter { own?.contains($0.plan_id) ?? true }
                if plans.isEmpty { continue }
                // Account (email) for "account · team" naming.
                let email = (try? await accountEmail(session: session)) ?? session.userID
                for p in plans {
                    accounts.append(await fetchOne(session: session, plan: p, email: email))
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
        if accounts.isEmpty {
            return [Account(key: "figma", displayName: "Figma", result: nil, error: lastError)]
        }
        // Bigger monthly quotas first (Main before Free), ties alphabetical.
        // Stable across refreshes (API order isn't).
        return accounts.sorted {
            switch ($0.result?.monthlyTotal, $1.result?.monthlyTotal) {
            case let (a?, b?) where a != b: return a > b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.displayName < $1.displayName
            }
        }
    }

    private static func displayName(plan: Plan, email: String?) -> String {
        guard let email, !email.isEmpty else { return plan.label }
        return "\(email) · \(plan.label)"
    }

    private static func fetchOne(session: Session, plan: Plan, email: String?) async -> Account {
        let name = displayName(plan: plan, email: email)
        let key = "figma:\(session.userID):\(plan.plan_id)"
        do {
            return Account(key: key, displayName: name, result: try await fetchBalance(session: session, plan: plan), error: nil)
        } catch {
            return Account(key: key, displayName: name, result: nil, error: error.localizedDescription)
        }
    }

    // MARK: - REST

    private static let base = "https://www.figma.com"
    private static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

    private static func get(path: String, session: Session) async throws -> Data {
        var req = URLRequest(url: URL(string: base + path)!, timeoutInterval: 20)
        req.httpMethod = "GET"
        req.setValue(session.cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw UsageError.network("No HTTP response") }
        switch http.statusCode {
        case 200: return data
        case 401, 403:
            throw UsageError.unauthorized("Figma session expired — reopen Figma Desktop, then Refresh.")
        default:
            throw UsageError.network("Figma API HTTP \(http.statusCode)")
        }
    }

    private static func planFilters(session: Session) async throws -> [Plan] {
        let data = try await get(path: "/api/shared_with_you/plan_filter_options?resource_type[]=file", session: session)
        let decoded = try JSONDecoder().decode(PlanFiltersResponse.self, from: data)
        return decoded.meta?.plan_filters ?? []
    }

    /// IDs of my own teams/orgs (team-level membership). Plans outside this
    /// set come from shared files, not from my teams — excluded.
    private static func ownPlanIDs(session: Session) async throws -> Set<String> {
        let data = try await get(path: "/api/user/state", session: session)
        let decoded = try JSONDecoder().decode(UserStateResponse.self, from: data)
        var ids = Set((decoded.meta?.teams ?? []).map(\.id))
        ids.formUnion((decoded.meta?.orgs ?? []).map(\.id))
        return ids
    }

    /// Login email for "account · team" naming (this scoped session's user).
    private static func accountEmail(session: Session) async throws -> String? {
        let data = try await get(path: "/api/session/state", session: session)
        let decoded = try JSONDecoder().decode(SessionStateResponse.self, from: data)
        let users = decoded.meta?.users ?? []
        return users.first { $0.id == session.userID }?.email ?? users.first?.email
    }

    private static func fetchBalance(session: Session, plan: Plan) async throws -> Result {
        let data = try await get(path: "/api/plans/\(plan.plan_record_id)/ai_credits/plan_user_balance_summary", session: session)
        return try parseBalance(data, planID: plan.plan_record_id)
    }

    /// plan_user_balance_summary JSON -> monthly/daily buckets (testable seam).
    static func parseBalance(_ data: Data, planID: String) throws -> Result {
        map(try JSONDecoder().decode(BalanceResponse.self, from: data).meta, planID: planID)
    }

    private static func map(_ meta: BalanceResponse.Meta?, planID: String) -> Result {
        var buckets: [UsageBucket] = []
        if let m = meta?.monthly_summary, m.total ?? 0 > 0 {
            buckets.append(UsageBucket(
                id: "figma-monthly-\(planID)",
                title: "Monthly",
                percent: usedPercent(total: m.total, available: m.available),
                resetsAt: FlexibleDate.parse(m.resets_at),
                detail: leftText(available: m.available, total: m.total)
            ))
        }
        if let d = meta?.daily_summary, d.total ?? 0 > 0 {
            buckets.append(UsageBucket(
                id: "figma-daily-\(planID)",
                title: "Daily",
                percent: usedPercent(total: d.total, available: d.available),
                resetsAt: FlexibleDate.parse(d.resets_at),
                detail: leftText(available: d.available, total: d.total)
            ))
        }
        return Result(buckets: buckets, monthlyTotal: meta?.monthly_summary?.total)
    }

    /// Utilization %, like every other provider (0 = nothing consumed).
    private static func usedPercent(total: Double?, available: Double?) -> Double? {
        guard let total, total > 0, let available else { return nil }
        return min(max((total - available) / total * 100, 0), 100)
    }

    private static func leftText(available: Double?, total: Double?) -> String? {
        guard let available, let total else { return nil }
        return "\(fmtNum(available))/\(fmtNum(total)) left"
    }

    private static func fmtNum(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(format: "%.1f", v)
    }

    // MARK: - Session (Desktop cookies)

    struct Session {
        var userID: String
        var cookieHeader: String
    }

    struct Plan: Codable {
        var label: String
        var plan_id: String
        var plan_type: String?
        var plan_record_id: String

        private enum CodingKeys: String, CodingKey {
            case label, plan_id, plan_type, plan_record_id
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // label/ids always present on success; default defensively.
            label = (try? c.decode(String.self, forKey: .label)) ?? "Figma"
            plan_id = (try? c.decode(String.self, forKey: .plan_id)) ?? ""
            plan_type = try? c.decode(String.self, forKey: .plan_type)
            plan_record_id = (try? c.decode(String.self, forKey: .plan_record_id)) ?? ""
        }
    }

    private struct PlanFiltersResponse: Codable {
        var meta: FiltersMeta?
        struct FiltersMeta: Codable {
            var plan_filters: [Plan]?
        }
    }

    private struct UserStateResponse: Codable {
        var meta: Meta?
        struct Meta: Codable {
            var teams: [IDItem]?
            var orgs: [IDItem]?
        }
        struct IDItem: Codable {
            var id: String
        }
    }

    private struct SessionStateResponse: Codable {
        var meta: Meta?
        struct Meta: Codable {
            var users: [User]?
        }
        struct User: Codable {
            var id: String?
            var email: String?
        }
    }

    private struct BalanceResponse: Codable {
        var meta: Meta?
        struct Meta: Codable {
            var monthly_summary: Summary?
            var daily_summary: Summary?
        }
        struct Summary: Codable {
            var total: Double?
            var available: Double?
            var resets_at: String?
        }
    }

    private static var cachedPassword: String?

    /// One scoped session per logged-in Figma user, newest profile first.
    /// The authn cookie maps userID -> token; scoping it to a single entry
    /// pins the API to that account (dead tokens 401 and get skipped later).
    /// Falls back to the whole jar if no authn map is found.
    private static func candidateSessions() throws -> [Session] {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Figma/DesktopProfile").path
        let dirs = ((try? FileManager.default.contentsOfDirectory(atPath: base)) ?? [])
            .filter { $0.hasPrefix("v") }.sorted(by: >)
        if dirs.isEmpty { throw UsageError.notSignedIn("No Figma login found — open Figma Desktop.") }
        let password = try keychainPassword()
        var sessions: [Session] = []
        var seen = Set<String>()
        for dir in dirs {
            let db = base + "/" + dir + "/Cookies"
            guard FileManager.default.fileExists(atPath: db) else { continue }
            guard let parts = cookieParts(db: db, password: password), !parts.isEmpty else { continue }
            let others = parts.filter { $0.0 != "__Host-figma.authn" }
            if let authn = parts.first(where: { $0.0 == "__Host-figma.authn" })?.1,
               let map = try? JSONDecoder().decode([String: String].self,
                                                   from: Data(urlDecoded(authn).utf8)),
               !map.isEmpty
            {
                for (uid, token) in map where !seen.contains(uid) {
                    seen.insert(uid)
                    let single = singleEntryAuthn(userID: uid, token: token)
                    let header = ((["__Host-figma.authn=\(single)"] + others.map { "\($0.0)=\($0.1)" }))
                        .joined(separator: "; ")
                    sessions.append(Session(userID: uid, cookieHeader: header))
                }
            } else {
                // No usable authn map: whole-jar session, best effort.
                let header = parts.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
                sessions.append(Session(userID: "", cookieHeader: header))
            }
        }
        guard !sessions.isEmpty else {
            throw UsageError.notSignedIn("No Figma login found — open Figma Desktop.")
        }
        return sessions
    }

    /// All decrypted www.figma.com cookies as (name, value) pairs.
    private static func cookieParts(db: String, password: String) -> [(String, String)]? {
        guard let rows = sqliteRows(db: db), !rows.isEmpty else { return nil }
        var parts: [(String, String)] = []
        for (name, hex) in rows {
            guard let value = ChromiumCookie.decrypt(hex: hex, password: password), !value.isEmpty else { continue }
            parts.append((name, value))
        }
        return parts.isEmpty ? nil : parts
    }

    /// `{"uid":"token"}` percent-encoded like the stored cookie value.
    private static func singleEntryAuthn(userID: String, token: String) -> String {        let json = "{\"\(userID)\":\"\(token)\"}"
        return json.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? json
    }

    private static func urlDecoded(_ s: String) -> String {
        s.removingPercentEncoding ?? s
    }

    private static func sqliteRows(db: String) -> [(String, String)]? {
        guard let dbQ = db.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        // Plain snapshot first, immutable snapshot fallback if the app holds a lock.
        let sql = "SELECT name, hex(encrypted_value) FROM cookies WHERE host_key IN ('www.figma.com','.figma.com') AND length(encrypted_value) > 3;"
        if let out = runSqlite(db: db, sql: sql) { return parse(out) }
        if let out = runSqlite(db: "file:\(dbQ)?immutable=1", sql: sql) { return parse(out) }
        return nil
    }

    private static func parse(_ out: String) -> [(String, String)] {
        out.split(separator: "\n").compactMap { line -> (String, String)? in
            let s = String(line)
            guard let sep = s.firstIndex(of: "|") else { return nil }
            return (String(s[..<sep]), String(s[s.index(after: sep)...]))
        }
    }

    private static func runSqlite(db: String, sql: String) -> String? {
        let out = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        proc.arguments = ["-separator", "|", db, sql]
        proc.standardOutput = out
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? nil : s
    }

    private static func keychainPassword() throws -> String {
        if let p = cachedPassword { return p }
        let out = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", "Figma Safe Storage", "-w"]
        proc.standardOutput = out
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            if proc.terminationStatus == 51 { throw CredentialsStore.ClaudeCredsError.accessDenied }
            throw UsageError.notSignedIn("No Figma login found — open Figma Desktop.")
        }
        let pw = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !pw.isEmpty else { throw UsageError.notSignedIn("No Figma login found — open Figma Desktop.") }
        cachedPassword = pw
        return pw
    }
}
