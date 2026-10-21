import Foundation

// MARK: - Shared bucket

struct UsageBucket: Identifiable, Equatable {
    var id: String
    var title: String
    var percent: Double? // 0...100, nil = unavailable
    var resetsAt: Date?
    var detail: String?
}

// MARK: - OpenAI wham/usage (undocumented, unstable)

struct OpenAIWindow: Codable {
    var used_percent: Double?
    var limit_window_seconds: Int?
    var reset_after_seconds: Double?
    var reset_at: Double? // unix seconds

    var resetDate: Date? {
        if let r = reset_at { return Date(timeIntervalSince1970: r) }
        return nil
    }
}

struct OpenAIRateLimit: Codable {
    var allowed: Bool?
    var limit_reached: Bool?
    var primary_window: OpenAIWindow?
    var secondary_window: OpenAIWindow?
}

struct OpenAIAdditionalLimit: Codable {
    var id: String?
    var title: String?
    var primary_window: OpenAIWindow?
    var secondary_window: OpenAIWindow?
}

struct OpenAIUsageResponse: Codable {
    var plan_type: String?
    var email: String?
    var rate_limit: OpenAIRateLimit?
    var additional_rate_limits: [OpenAIAdditionalLimit]?
    var rate_limit_reset_credits: RateResetCredits?
    var credits: OpenAICredits?

    struct RateResetCredits: Codable {
        var available_count: Int?
    }

    // "balance" is a string like "$4.20" or null; other fields flag overage state.
    struct OpenAICredits: Codable {
        var has_credits: Bool?
        var unlimited: Bool?
        var overage_limit_reached: Bool?
        var balance: String?
    }
}

// MARK: - Anthropic oauth/usage (undocumented)

struct AnthropicBucket: Codable {
    var utilization: Double?
    var resets_at: String?
    var reset_at: String?
    var expires_at: String?

    var resetDate: Date? {
        FlexibleDate.parse(resets_at ?? reset_at)
    }

    var expiryDate: Date? {
        FlexibleDate.parse(expires_at)
    }
}

struct AnthropicExtraUsage: Codable {
    var is_enabled: Bool?
    var monthly_limit: Double?
    var used_credits: Double?
    var utilization: Double?
    var currency: String?
}

struct AnthropicUsageResponse: Codable {
    var five_hour: AnthropicBucket?
    var seven_day: AnthropicBucket?
    var seven_day_sonnet: AnthropicBucket?
    var seven_day_opus: AnthropicBucket?
    var seven_day_omelette: AnthropicBucket?
    var seven_day_oauth_apps: AnthropicBucket?
    var seven_day_cowork: AnthropicBucket?
    var extra_usage: AnthropicExtraUsage?
    var limits: [WebLimit]? // claude.ai web endpoint: per-window list incl. model-scoped weeklies
    var spend: SpendInfo?

    /// "Spend" block (usage-credits account). Only meaningful when enabled or spent > 0.
    struct SpendInfo: Codable {
        var enabled: Bool?
        var percent: Double?
        var used: SpendAmount?

        struct SpendAmount: Codable {
            var amount_minor: Double?
            var currency: String?
            var exponent: Int?
        }
    }
}

struct WebLimit: Codable {
    var kind: String? // "session" | "weekly_all" | "weekly_scoped" | promo kinds…
    var group: String?
    var percent: Double?
    var severity: String?
    var resets_at: String?
    var expires_at: String?
    var scope: WebLimitScope?
    var is_active: Bool?

    var resetDate: Date? { FlexibleDate.parse(resets_at) }
    var expiryDate: Date? { FlexibleDate.parse(expires_at) }
}

struct WebLimitScope: Codable {
    var model: WebLimitModel?
    var surface: String?
}

struct WebLimitModel: Codable {
    var id: String?
    var display_name: String?
}

// MARK: - Flexible date parsing

enum FlexibleDate {
    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        // ISO8601 with/without fractional seconds
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        // unix seconds / ms as string or number
        if let v = Double(s) {
            if v > 1e12 { return Date(timeIntervalSince1970: v / 1000) }
            if v > 1e10 { return Date(timeIntervalSince1970: v / 1000) }
            return Date(timeIntervalSince1970: v)
        }
        return nil
    }
}

// MARK: - Formatters

enum Formatters {
    static func countdown(to date: Date?) -> String {
        guard let date else { return "—" }
        let interval = max(0, date.timeIntervalSince(Date()))
        if interval <= 0 { return "resetting…" }
        let h = Int(interval) / 3600
        let m = (Int(interval) % 3600) / 60
        if h >= 24 {
            let d = h / 24
            return "\(d)d \(h % 24)h"
        }
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(Int(interval))s"
    }

    /// Raw plan id from any provider ("free", "plus", "free_workspace",
    /// "max") → "Free", "Plus", "Free Workspace", "Max".
    static func planName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func percent(_ p: Double?) -> String {
        guard let p else { return "—" }
        return String(format: "%.0f%%", min(max(p, 0), 100))
    }

    static func windowLabel(seconds: Int?) -> String {
        guard let s = seconds else { return "Limit" }
        switch s {
        case 3600: return "Hourly"
        case 18000: return "5-hour"
        case 86400: return "Daily"
        case 604800: return "Weekly"
        case 2592000: return "Monthly"
        default:
            if s > 0, s % 86400 == 0 { return "\(s / 86400)d window" }
            if s > 0, s % 3600 == 0 { return "\(s / 3600)h window" }
            return "\(s)s window"
        }
    }
}
