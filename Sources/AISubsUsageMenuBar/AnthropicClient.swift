import Foundation

// Claude subscription usage via the Claude Desktop web session
// (GET https://claude.ai/api/organizations/{org}/usage) — no CLI needed.
enum AnthropicClient {
    struct Result {
        var buckets: [UsageBucket]
        var extraUsageText: String?
        var spendText: String?
        var subscriptionType: String?
    }

    /// One logged-in Claude account (one Desktop data dir).
    struct Account {
        var key: String // "claude:{Desktop dir label}" — stable across org renames
        var displayName: String // org name ("Acme") or dir label fallback
        var result: Result?
        var error: String?
    }

    static func fetch() async throws -> Result {
        let accounts = await fetchAll()
        if let first = accounts.first(where: { $0.result != nil }) {
            return first.result!
        }
        throw UsageError.network(accounts.first?.error ?? "No Claude login found — open Claude Desktop.")
    }

    /// Usage for EVERY Claude Desktop session on this Mac; the Claude Code
    /// CLI login when there is none. `refreshOrgs` re-reads org names/plans
    /// (startup and manual Refresh); otherwise the cached ones are used.
    static func fetchAll(refreshOrgs: Bool = true) async -> [Account] {
        let sessions: [ClaudeWebSession.Session]
        do {
            // Debug: AISUBS_FORCE_CLAUDE_CODE=1 skips Desktop to exercise the fallback.
            if ProcessInfo.processInfo.environment["AISUBS_FORCE_CLAUDE_CODE"] != nil {
                throw CredentialsStore.ClaudeCredsError.notFound
            }
            sessions = try ClaudeWebSession.loadAll()
        } catch {
            if let cli = await fetchClaudeCode() { return [cli] }
            return [Account(key: "claude", displayName: "Claude", result: nil, error: error.localizedDescription)]
        }
        return await withTaskGroup(of: (Int, Account).self, returning: [Account].self) { group in
            for (i, s) in sessions.enumerated() {
                group.addTask { (i, await fetchOne(s, refreshOrgs: refreshOrgs)) }
            }
            var ordered = [(Int, Account)]()
            for await pair in group { ordered.append(pair) }
            return ordered.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    private static func fetchOne(_ session: ClaudeWebSession.Session, refreshOrgs: Bool) async -> Account {
        let org = await orgInfo(for: session, refresh: refreshOrgs)
        let name = (org.name ?? session.label) + (org.plan.map { " (\($0))" } ?? "")
        let key = "claude:\(session.label)"
        do {
            var result = try await fetchWeb(session: session)
            result.subscriptionType = org.plan
            return Account(key: key, displayName: name, result: result, error: nil)
        } catch {
            return Account(key: key, displayName: name, result: nil, error: error.localizedDescription)
        }
    }

    private static let orgNamesKey = "claudeOrgNames"
    private static let orgPlansKey = "claudeOrgPlans"

    /// Organization name and plan for menu headers, cached in UserDefaults
    /// (orgID -> name / plan). Re-read from /api/organizations only when
    /// `refresh` is set (startup, manual Refresh) or nothing is cached yet.
    private static func orgInfo(for session: ClaudeWebSession.Session, refresh: Bool) async -> (name: String?, plan: String?) {
        let d = UserDefaults.standard
        let names = d.dictionary(forKey: orgNamesKey) as? [String: String] ?? [:]
        let plans = d.dictionary(forKey: orgPlansKey) as? [String: String] ?? [:]
        if !refresh, let name = names[session.orgID] {
            return (name, plans[session.orgID])
        }
        guard let orgs = try? await getJSON(path: "/api/organizations", session: session),
              let list = orgs as? [[String: Any]]
        else { return (names[session.orgID], plans[session.orgID]) }
        var newNames = names, newPlans = plans
        for o in list {
            guard let uuid = o["uuid"] as? String else { continue }
            if let n = o["name"] as? String {
                newNames[uuid] = n.replacingOccurrences(of: "'s Organization", with: "")
            }
            newPlans[uuid] = planLabel(o)
        }
        d.set(newNames, forKey: orgNamesKey)
        d.set(newPlans, forKey: orgPlansKey)
        return (newNames[session.orgID], newPlans[session.orgID])
    }

    /// Plan from a claude.ai organization object (undocumented fields):
    /// `capabilities` ("chat", "claude_pro", "claude_max", "raven" = Team/
    /// Enterprise) and `rate_limit_tier` (e.g. "default_claude_max_20x").
    /// → "Free", "Pro", "Max 5x", "Max 20x", "Team", "Enterprise"; nil if unknown.
    static func planLabel(_ org: [String: Any]) -> String? {
        let caps = Set(org["capabilities"] as? [String] ?? [])
        let tier = (org["rate_limit_tier"] as? String ?? "").lowercased()
        if caps.contains("raven") || tier.contains("raven") {
            return (org["raven_type"] as? String).map(Formatters.planName) ?? "Team"
        }
        if caps.contains("claude_max") || tier.contains("max") {
            let mult = tier.range(of: #"\d+x$"#, options: .regularExpression).map { " " + tier[$0] } ?? ""
            return "Max" + mult
        }
        if caps.contains("claude_pro") || tier.contains("pro") { return "Pro" }
        if caps.contains("chat") { return "Free" }
        return nil
    }

    private static func getJSON(path: String, session: ClaudeWebSession.Session) async throws -> Any {
        var req = URLRequest(url: URL(string: "https://claude.ai\(path)")!, timeoutInterval: 20)
        req.httpMethod = "GET"
        req.setValue(cookieHeader(session), forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw UsageError.network("Claude orgs HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard !isHTML(data) else { throw UsageError.network("Cloudflare check — retrying…") }
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func cookieHeader(_ s: ClaudeWebSession.Session) -> String {
        // NOTE: do NOT send cf_clearance — a stale one triggers Cloudflare
        // challenges instead of bypassing them.
        "sessionKey=\(s.sessionKey); lastActiveOrg=\(s.orgID)"
    }

    /// Cloudflare managed challenges return HTTP 200 + HTML: never JSON-decode those.
    private static func isHTML(_ data: Data) -> Bool {
        let prefix = data.prefix(256)
        guard let s = String(bytes: prefix, encoding: .ascii) else { return false }
        return s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("<!doctype")
            || s.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<html")
    }

    // MARK: - CLI path (Claude Code OAuth login)

    /// Nil when Claude Code has no login on this Mac.
    private static func fetchClaudeCode() async -> Account? {
        guard var creds = ClaudeCodeCredentials.load() else { return nil }
        if creds.isExpired {
            // Claude Code may have renewed it since the cached read.
            ClaudeCodeCredentials.reset()
            guard let fresh = ClaudeCodeCredentials.load() else { return nil }
            creds = fresh
        }
        let name = "Claude Code" + (creds.subscriptionType.map { " (\(Formatters.planName($0)))" } ?? "")
        guard !creds.isExpired else {
            return Account(key: "claude:code", displayName: name, result: nil,
                           error: "Claude Code login expired — run `claude` to renew, then Refresh.")
        }
        do {
            var result = try await fetchOAuth(token: creds.accessToken)
            result.subscriptionType = creds.subscriptionType
            return Account(key: "claude:code", displayName: name, result: result, error: nil)
        } catch {
            ClaudeCodeCredentials.reset()
            return Account(key: "claude:code", displayName: name, result: nil, error: error.localizedDescription)
        }
    }

    private static func fetchOAuth(token: String) async throws -> Result {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 20)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw UsageError.network("No HTTP response") }
        switch http.statusCode {
        case 200: break
        case 401, 403:
            throw UsageError.unauthorized("Claude Code login expired — run `claude` to renew, then Refresh.")
        case 429:
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init) ?? 300
            throw UsageError.network("Claude rate-limited (429). Retry in \(retry)s.")
        default:
            throw UsageError.network("Claude usage HTTP \(http.statusCode)")
        }
        return try parseUsage(data)
    }

    // MARK: - Web path (Claude Desktop app cookies)

    static func fetchWeb(session: ClaudeWebSession.Session) async throws -> Result {
        // One retry: Cloudflare occasionally answers the first call with a
        // managed-challenge page (HTTP 200 + HTML) instead of JSON.
        var lastError: Error = UsageError.network("Claude usage failed")
        for attempt in 0..<2 {
            do {
                return try await fetchWebOnce(session: session)
            } catch {
                lastError = error
                if attempt == 0 { try? await Task.sleep(for: .seconds(2)) }
            }
        }
        throw lastError
    }

    private static func fetchWebOnce(session: ClaudeWebSession.Session) async throws -> Result {
        let url = URL(string: "https://claude.ai/api/organizations/\(session.orgID)/usage")!
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "GET"
        req.setValue(cookieHeader(session), forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw UsageError.network("No HTTP response") }
        switch http.statusCode {
        case 200: break
        case 401, 403:
            throw UsageError.unauthorized("Claude web session expired — reopen Claude Desktop, then Refresh.")
        case 429:
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init) ?? 300
            throw UsageError.network("Claude rate-limited (429). Retry in \(retry)s.")
        default:
            throw UsageError.network("Claude usage HTTP \(http.statusCode)")
        }
        if isHTML(data) { throw UsageError.network("Cloudflare check — retrying…") }
        return try parseUsage(data)
    }

    /// Usage JSON (claude.ai web and oauth/usage share the shape) -> buckets.
    static func parseUsage(_ data: Data) throws -> Result {
        map(try JSONDecoder().decode(AnthropicUsageResponse.self, from: data))
    }

    private static func expiryText(_ date: Date?) -> String? {
        guard let date else { return nil }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return "Expires \(f.string(from: date))"
    }

    private static func map(_ r: AnthropicUsageResponse) -> Result {
        var buckets: [UsageBucket] = []
        func add(_ id: String, _ title: String, _ b: AnthropicBucket?) {
            guard let b, b.utilization != nil else { return }
            buckets.append(UsageBucket(id: id, title: title, percent: b.utilization,
                                       resetsAt: b.resetDate, detail: expiryText(b.expiryDate)))
        }
        add("claude-5h", "Session", r.five_hour)
        add("claude-7d", "Weekly", r.seven_day)
        add("claude-sonnet", "Weekly Sonnet", r.seven_day_sonnet)
        // Opus weekly may appear as seven_day_opus or seven_day_omelette (internal codename)
        if r.seven_day_opus?.utilization != nil {
            add("claude-opus", "Weekly Opus", r.seven_day_opus)
        } else if r.seven_day_omelette?.utilization != nil {
            add("claude-opus", "Weekly Opus", r.seven_day_omelette)
        }
        add("claude-cowork", "Cowork", r.seven_day_cowork)
        // limits[]: model-scoped weeklies only (e.g. Fable). Other window kinds
        // and unknown top-level fields are internal codenames/promos
        // ("Iguana Necktie"…) — deliberately not shown.
        for lim in r.limits ?? [] where lim.kind == "weekly_scoped" && lim.percent != nil {
            let name = lim.scope?.model?.display_name ?? "Model"
            buckets.append(UsageBucket(
                id: "claude-weekly-\(name.lowercased())", title: "Weekly \(name)",
                percent: lim.percent, resetsAt: lim.resetDate, detail: expiryText(lim.expiryDate)
            ))
        }

        var extraText: String?
        if let e = r.extra_usage, e.is_enabled == true {
            // monthly_limit / used_credits are in cents
            if let lim = e.monthly_limit, let used = e.used_credits {
                extraText = String(format: "Extra $%.2f / $%.2f", used / 100, lim / 100)
            } else if let u = e.utilization {
                extraText = String(format: "Extra %.0f%%", u)
            } else {
                extraText = "Extra usage on"
            }
        }
        return Result(buckets: buckets, extraUsageText: extraText, spendText: spendText(r.spend), subscriptionType: nil)
    }

    /// "Spend $x.xx" when credits are enabled or anything was spent.
    private static func spendText(_ s: AnthropicUsageResponse.SpendInfo?) -> String? {
        guard let s else { return nil }
        let minor = s.used?.amount_minor ?? 0
        guard s.enabled == true || minor > 0 else { return nil }
        let exp = s.used?.exponent ?? 2
        let cur = s.used?.currency ?? "USD"
        let sym = cur == "USD" ? "$" : cur + " "
        return String(format: "Spend %@%.2f", sym, minor / pow(10, Double(exp)))
    }
}
