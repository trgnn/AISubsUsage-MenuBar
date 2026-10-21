import Foundation
import Testing
@testable import AISubsUsageMenuBar

@Suite struct CookieDecryption {
    // Generated offline: PBKDF2-SHA1("test-password", "saltysalt", 1003) key,
    // AES-128-CBC (IV = 16 spaces) of 32×"A" + "sk-ant-sid01-example", "v10" prefix.
    let vector = "763130aada9758fa04490a8781e89708528109025aec45fbe3638ab8c6b45899506dcf60bb3cfec17640b2a554633d1af8f8d9b49d112f871aea9027b6a596bbfbb604"

    @Test func decryptsKnownVector() {
        #expect(ChromiumCookie.decrypt(hex: vector, password: "test-password") == "sk-ant-sid01-example")
    }

    @Test func wrongPasswordFails() {
        #expect(ChromiumCookie.decrypt(hex: vector, password: "nope") != "sk-ant-sid01-example")
    }

    @Test func rejectsMissingPrefixAndBadHex() {
        #expect(ChromiumCookie.decrypt(hex: String(vector.dropFirst(6)), password: "test-password") == nil)
        #expect(ChromiumCookie.decrypt(hex: "763130zz", password: "test-password") == nil)
        #expect(ChromiumCookie.decrypt(hex: "", password: "test-password") == nil)
    }
}

@Suite struct AccountOrdering {
    let keys = ["claude:A", "claude:B", "openai", "figma:C"]

    @Test func defaultOrderWithoutSaved() {
        #expect(AccountOrder.sorted(keys, key: { $0 }, saved: []) == keys)
    }

    @Test func savedFirstUnknownAfterInDefaultOrder() {
        let out = AccountOrder.sorted(keys, key: { $0 }, saved: ["figma:C", "claude:B"])
        #expect(out == ["figma:C", "claude:B", "claude:A", "openai"])
    }

    @Test func moveUpAndDown() {
        #expect(AccountOrder.moving("figma:C", by: -1, in: keys, saved: []) == ["claude:A", "claude:B", "figma:C", "openai"])
        #expect(AccountOrder.moving("claude:A", by: 1, in: keys, saved: []) == ["claude:B", "claude:A", "openai", "figma:C"])
    }

    @Test func cannotMovePastEnds() {
        #expect(AccountOrder.moving("claude:A", by: -1, in: keys, saved: []) == nil)
        #expect(AccountOrder.moving("figma:C", by: 1, in: keys, saved: []) == nil)
        #expect(AccountOrder.moving("missing", by: 1, in: keys, saved: []) == nil)
    }

    @Test func absentAccountsKeepTheirSavedPlace() {
        let saved = ["claude:Gone", "claude:A", "openai"]
        let out = AccountOrder.moving("openai", by: -1, in: ["claude:A", "openai"], saved: saved)
        #expect(out == ["openai", "claude:A", "claude:Gone"])
        // When it comes back it sorts by that saved rank.
        let back = AccountOrder.sorted(["claude:A", "claude:Gone", "openai"], key: { $0 }, saved: out!)
        #expect(back == ["openai", "claude:A", "claude:Gone"])
    }
}

@Suite struct Formatting {
    @Test(arguments: [("free", "Free"), ("plus", "Plus"), ("free_workspace", "Free Workspace"), ("max", "Max")])
    func planName(raw: String, expected: String) {
        #expect(Formatters.planName(raw) == expected)
    }

    @Test func percent() {
        #expect(Formatters.percent(nil) == "—")
        #expect(Formatters.percent(41.6) == "42%")
        #expect(Formatters.percent(140) == "100%")
        #expect(Formatters.percent(-3) == "0%")
    }

    @Test func countdown() {
        let now = Date()
        #expect(Formatters.countdown(to: nil) == "—")
        #expect(Formatters.countdown(to: now.addingTimeInterval(11 * 60 + 5)) == "11m")
        #expect(Formatters.countdown(to: now.addingTimeInterval(3 * 3600 + 20 * 60 + 5)) == "3h 20m")
        #expect(Formatters.countdown(to: now.addingTimeInterval(4 * 86400 + 7 * 3600 + 60)) == "4d 7h")
        #expect(Formatters.countdown(to: now.addingTimeInterval(-60)) == "resetting…")
    }

    @Test func windowLabel() {
        #expect(Formatters.windowLabel(seconds: 18000) == "5-hour")
        #expect(Formatters.windowLabel(seconds: 604_800) == "Weekly")
        #expect(Formatters.windowLabel(seconds: 172_800) == "2d window")
        #expect(Formatters.windowLabel(seconds: nil) == "Limit")
    }

    @Test func flexibleDates() {
        #expect(FlexibleDate.parse("2026-10-21T18:00:00Z") != nil)
        #expect(FlexibleDate.parse("2026-10-21T18:00:00.123Z") != nil)
        #expect(FlexibleDate.parse("1790000000") == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(FlexibleDate.parse("1790000000000") == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(FlexibleDate.parse("not a date") == nil)
        #expect(FlexibleDate.parse(nil) == nil)
    }
}
