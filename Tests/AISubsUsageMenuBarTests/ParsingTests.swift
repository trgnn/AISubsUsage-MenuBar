import Foundation
import Testing
@testable import AISubsUsageMenuBar

// Fixtures mirror the undocumented responses' shape with made-up values.

@Suite struct AnthropicParsing {
    let json = """
    {
      "five_hour": {"utilization": 35, "resets_at": "2026-10-21T18:00:00Z"},
      "seven_day": {"utilization": 13, "resets_at": "2026-10-26T10:00:00.123Z"},
      "seven_day_opus": null,
      "seven_day_omelette": {"utilization": 5},
      "iguana_necktie": {"utilization": 0, "resets_at": "2026-11-04T00:00:00Z"},
      "limits": [
        {"kind": "session", "percent": 35},
        {"kind": "weekly_scoped", "percent": 7, "scope": {"model": {"display_name": "Fable"}}},
        {"kind": "promo_x", "percent": 10}
      ],
      "extra_usage": {"is_enabled": true, "monthly_limit": 5000, "used_credits": 1234}
    }
    """

    @Test func namedBucketsOnly() throws {
        let r = try AnthropicClient.parseUsage(Data(json.utf8))
        #expect(r.buckets.map(\.title) == ["Session", "Weekly", "Weekly Opus", "Weekly Fable"])
        #expect(r.buckets.map(\.percent) == [35, 13, 5, 7])
    }

    @Test func resetDatesParse() throws {
        let r = try AnthropicClient.parseUsage(Data(json.utf8))
        #expect(r.buckets[0].resetsAt == ISO8601DateFormatter().date(from: "2026-10-21T18:00:00Z"))
        #expect(r.buckets[1].resetsAt != nil) // fractional seconds
    }

    @Test func extraUsageInDollars() throws {
        let r = try AnthropicClient.parseUsage(Data(json.utf8))
        #expect(r.extraUsageText == "Extra $12.34 / $50.00")
    }

    @Test func sessionIdDrivesMenubar() throws {
        // main.swift picks the menubar value by the "-5h" id suffix.
        let r = try AnthropicClient.parseUsage(Data(json.utf8))
        #expect(r.buckets.first?.id.hasSuffix("-5h") == true)
    }

    @Test func emptyResponse() throws {
        let r = try AnthropicClient.parseUsage(Data("{}".utf8))
        #expect(r.buckets.isEmpty)
        #expect(r.extraUsageText == nil)
    }
}

@Suite struct ClaudePlanLabel {
    @Test(arguments: [
        (["chat"], nil, "Free"),
        (["chat", "claude_pro"], nil, "Pro"),
        (["chat", "claude_max"], "default_claude_max_20x", "Max 20x"),
        (["chat", "claude_max"], "default_claude_max_5x", "Max 5x"),
        (["chat", "claude_max"], nil, "Max"),
        (["chat", "raven"], nil, "Team"),
    ] as [([String], String?, String)])
    func fromCapabilities(caps: [String], tier: String?, expected: String) {
        var org: [String: Any] = ["capabilities": caps]
        if let tier { org["rate_limit_tier"] = tier }
        #expect(AnthropicClient.planLabel(org) == expected)
    }

    @Test func ravenTypeWins() {
        #expect(AnthropicClient.planLabel(["capabilities": ["raven"], "raven_type": "enterprise"]) == "Enterprise")
    }

    @Test func unknownIsNil() {
        #expect(AnthropicClient.planLabel(["capabilities": ["api"]]) == nil)
        #expect(AnthropicClient.planLabel([:]) == nil)
    }
}

@Suite struct OpenAIParsing {
    @Test func windowsCreditsAndPlan() throws {
        let json = """
        {
          "plan_type": "free_workspace", "email": "me@example.com",
          "rate_limit": {
            "primary_window": {"used_percent": 42, "limit_window_seconds": 18000, "reset_at": 1790000000},
            "secondary_window": {"used_percent": 120, "limit_window_seconds": 604800}
          },
          "credits": {"balance": "210.1204142500"},
          "rate_limit_reset_credits": {"available_count": 0}
        }
        """
        let r = try OpenAIClient.parse(Data(json.utf8))
        #expect(r.plan == "free_workspace")
        #expect(r.email == "me@example.com")
        #expect(r.buckets.map(\.title) == ["5-hour", "Weekly"])
        #expect(r.buckets.map(\.percent) == [42, 100]) // clamped
        #expect(r.buckets[0].resetsAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(r.creditsText == "Credits: 210.12")
        #expect(r.resetCredits == 0)
    }

    @Test func nonNumericBalanceKeptAsIs() throws {
        let r = try OpenAIClient.parse(Data(#"{"credits": {"balance": "$4.20"}}"#.utf8))
        #expect(r.creditsText == "Credits: $4.20")
    }

    @Test func unlimitedCredits() throws {
        let r = try OpenAIClient.parse(Data(#"{"credits": {"unlimited": true}}"#.utf8))
        #expect(r.creditsText == "Credits: unlimited")
    }
}

@Suite struct FigmaParsing {
    @Test func monthlyAndDaily() throws {
        let json = """
        {"meta": {
          "monthly_summary": {"total": 3000, "available": 2418, "resets_at": "2026-10-30T00:00:00Z"},
          "daily_summary": {"total": 150, "available": 150}
        }}
        """
        let r = try FigmaClient.parseBalance(Data(json.utf8), planID: "p1")
        #expect(r.buckets.map(\.title) == ["Monthly", "Daily"])
        #expect(abs((r.buckets[0].percent ?? -1) - 19.4) < 0.01)
        #expect(r.buckets[0].detail == "2418/3000 left")
        #expect(r.buckets[1].percent == 0)
        #expect(r.monthlyTotal == 3000)
    }

    @Test func zeroTotalSkipped() throws {
        let r = try FigmaClient.parseBalance(Data(#"{"meta": {"monthly_summary": {"total": 0, "available": 0}}}"#.utf8), planID: "p1")
        #expect(r.buckets.isEmpty)
    }
}
