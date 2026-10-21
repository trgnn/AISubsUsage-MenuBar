import Foundation

// GET https://chatgpt.com/backend-api/wham/usage
// Headers: Authorization: Bearer <access_token>, ChatGPT-Account-Id, Origin, Referer
enum OpenAIClient {
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    struct Result {
        var plan: String?
        var email: String?
        var buckets: [UsageBucket]
        var resetCredits: Int?
        var creditsText: String?
        var rawAllowed: Bool?
        var limitReached: Bool?
    }

    static func fetch() async throws -> Result {
        guard let creds = CredentialsStore.loadOpenAI() else {
            throw UsageError.notSignedIn("Sign in once with `codex login` — ~/.codex/auth.json not found.")
        }
        var req = URLRequest(url: endpoint, timeoutInterval: 20)
        req.httpMethod = "GET"
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        if let acct = creds.accountID {
            req.setValue(acct, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        req.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw UsageError.network("No HTTP response") }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 { throw UsageError.unauthorized("OpenAI token expired — run `codex login` again.") }
            throw UsageError.network("OpenAI wham/usage HTTP \(http.statusCode)")
        }
        return try parse(data)
    }

    /// wham/usage JSON -> buckets, credits, plan (testable seam).
    static func parse(_ data: Data) throws -> Result {
        map(try JSONDecoder().decode(OpenAIUsageResponse.self, from: data))
    }

    private static func map(_ r: OpenAIUsageResponse) -> Result {
        var buckets: [UsageBucket] = []
        if let rl = r.rate_limit {
            if let w = rl.primary_window {
                buckets.append(UsageBucket(
                    id: "openai-primary",
                    title: Formatters.windowLabel(seconds: w.limit_window_seconds),
                    percent: clamp(w.used_percent),
                    resetsAt: w.resetDate,
                    detail: nil
                ))
            }
            if let w = rl.secondary_window {
                buckets.append(UsageBucket(
                    id: "openai-secondary",
                    title: Formatters.windowLabel(seconds: w.limit_window_seconds),
                    percent: clamp(w.used_percent),
                    resetsAt: w.resetDate,
                    detail: nil
                ))
            }
        }
        // Per-model caps (e.g. Codex Spark 5h/weekly) — show top 3 to avoid clutter
        if let extra = r.additional_rate_limits?.prefix(3) {
            for lim in extra {
                if let w = lim.primary_window {
                    buckets.append(UsageBucket(
                        id: "openai-\(lim.id ?? lim.title ?? UUID().uuidString)",
                        title: lim.title ?? lim.id ?? "Model cap",
                        percent: clamp(w.used_percent),
                        resetsAt: w.resetDate,
                        detail: nil
                    ))
                }
            }
        }
        return Result(
            plan: r.plan_type,
            email: r.email,
            buckets: buckets,
            resetCredits: r.rate_limit_reset_credits?.available_count,
            creditsText: creditsText(r.credits),
            rawAllowed: r.rate_limit?.allowed,
            limitReached: r.rate_limit?.limit_reached
        )
    }

    /// Human line for the credits block (balance / unlimited / overage) when present.
    private static func creditsText(_ c: OpenAIUsageResponse.OpenAICredits?) -> String? {
        guard let c else { return nil }
        if c.unlimited == true { return "Credits: unlimited" }
        if let b = c.balance, !b.isEmpty {
            // API sends "210.1204142500": two decimals are plenty.
            return "Credits: " + (Double(b).map { String(format: "%.2f", $0) } ?? b)
        }
        if c.overage_limit_reached == true { return "Overage limit reached" }
        if c.has_credits == true { return "Credits available" }
        return nil
    }

    private static func clamp(_ p: Double?) -> Double? {
        guard let p else { return nil }
        return min(max(p, 0), 100)
    }
}

enum UsageError: LocalizedError {
    case notSignedIn(String)
    case unauthorized(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn(let s), .unauthorized(let s), .network(let s): return s
        }
    }
}
