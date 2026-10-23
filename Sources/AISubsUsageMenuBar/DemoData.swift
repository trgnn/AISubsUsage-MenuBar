import Foundation

// Demo mode for screenshots and recordings, only when launched with `--demo`
// (`open -a AISubsUsage-MenuBar --args --demo`): fake accounts, no logins
// read, no requests made, separate settings. Never persists: a normal launch
// is a normal app.
enum DemoData {
    static let isEnabled = CommandLine.arguments.contains("--demo")

    /// Settings in demo mode live in their own domain, so clicks during a
    /// capture never touch the real ones. Two values in the menu bar by
    /// default so the item fits beside the notch.
    static let settings: UserDefaults = {
        let d = UserDefaults(suiteName: "com.aisubsusage.menubar.demo") ?? .standard
        d.register(defaults: ["hiddenFromBarAccounts": ["claude:me", "figma:design"]])
        return d
    }()

    static func accounts(now: Date = Date())
        -> (claude: [AnthropicClient.Account], openAI: OpenAIClient.Result, figma: [FigmaClient.Account])
    {
        let h: TimeInterval = 3600, d: TimeInterval = 86400
        func b(_ id: String, _ t: String, _ p: Double, _ r: TimeInterval, _ detail: String? = nil) -> UsageBucket {
            UsageBucket(id: id, title: t, percent: p, resetsAt: now.addingTimeInterval(r + 30), detail: detail)
        }
        let claude = [
            AnthropicClient.Account(key: "claude:work", displayName: "Acme (Enterprise)", result: .init(
                buckets: [b("claude-5h", "Session", 35, 2 * h + 10 * 60), b("claude-7d", "Weekly", 13, 4 * d + 7 * h)],
                extraUsageText: nil, spendText: nil, subscriptionType: "enterprise"), error: nil),
            AnthropicClient.Account(key: "claude:me", displayName: "me@example.com (Max 5x)", result: .init(
                buckets: [b("claude-5h", "Session", 62, 48 * 60), b("claude-7d", "Weekly", 41, 2 * d + 3 * h)],
                extraUsageText: nil, spendText: nil, subscriptionType: "max"), error: nil),
        ]
        let openAI = OpenAIClient.Result(
            plan: "plus", email: "me@example.com",
            buckets: [b("openai-primary", "5-hour", 18, 3 * h + 5 * 60), b("openai-secondary", "Weekly", 27, 5 * d + 2 * h)],
            resetCredits: nil, creditsText: nil, rawAllowed: nil, limitReached: nil)
        let figma = [FigmaClient.Account(key: "figma:design", displayName: "me@example.com · Design", result: .init(
            buckets: [b("figma-monthly", "Monthly", 19, 9 * d + 4 * h, "2418/3000 left")], monthlyTotal: 3000), error: nil)]
        return (claude, openAI, figma)
    }
}
