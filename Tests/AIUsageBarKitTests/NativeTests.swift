import XCTest
@testable import AIUsageBarKit

/// Tests for the native data layer that replaced the `ai-usagebar` subprocess.
/// All hermetic: pure functions and in-memory parsing, no network or real
/// `$HOME` access.
final class NativeTests: XCTestCase {
    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    // MARK: - Countdown (mirrors src/countdown.rs)

    func testCountdown() {
        let now = at(2026, 5, 23, 12, 0)
        XCTAssertEqual(Support.countdown(nil, now: now), "—")
        XCTAssertEqual(Support.countdown(at(2026, 5, 23, 11, 0), now: now), "now")
        XCTAssertEqual(Support.countdown(now, now: now), "now")
        XCTAssertEqual(Support.countdown(at(2026, 5, 23, 13, 5), now: now), "1h 05m")
        XCTAssertEqual(Support.countdown(at(2026, 5, 24, 11, 59), now: now), "23h 59m")
        XCTAssertEqual(Support.countdown(at(2026, 5, 24, 13, 30), now: now), "1d 1h")
    }

    // MARK: - Severity thresholds (mirrors src/pango.rs severity_for)

    func testSeverityThresholds() {
        XCTAssertEqual(Support.severity(for: 49), .low)
        XCTAssertEqual(Support.severity(for: 50), .mid)
        XCTAssertEqual(Support.severity(for: 74), .mid)
        XCTAssertEqual(Support.severity(for: 75), .high)
        XCTAssertEqual(Support.severity(for: 89), .high)
        XCTAssertEqual(Support.severity(for: 90), .critical)
    }

    func testMoneyFormatting() {
        XCTAssertEqual(Support.money(74.5), "$74.50")
        XCTAssertEqual(Support.money(-1.5), "-$1.50")
        XCTAssertEqual(Support.money(20, currency: "CNY"), "¥20.00")
        XCTAssertEqual(Support.money(5, currency: "USD"), "$5.00")
    }

    // MARK: - Config parsing (mirrors src/config.rs)

    func testConfigDefaults() {
        let c = AppConfig()
        XCTAssertTrue(c.isEnabled(.anthropic))
        XCTAssertTrue(c.isEnabled(.openai))
        XCTAssertTrue(c.isEnabled(.zai))
        XCTAssertTrue(c.isEnabled(.openrouter))
        XCTAssertFalse(c.isEnabled(.deepseek)) // disabled by default
    }

    func testConfigParse() {
        let toml = """
        [ui]
        primary = "openrouter"

        [openai]
        enabled = false   # codex disabled

        [zai]
        api_key = "sk-zai-inline"
        plan_tier = "pro"

        [deepseek]
        enabled = true
        api_key = "sk-ds"
        """
        let c = AppConfig.parse(toml)
        XCTAssertEqual(c.primary, .openrouter)
        XCTAssertFalse(c.isEnabled(.openai))
        XCTAssertEqual(c.zaiApiKey, "sk-zai-inline")
        XCTAssertEqual(c.zaiPlanTier, "pro")
        XCTAssertTrue(c.isEnabled(.deepseek))
        XCTAssertEqual(c.deepseekApiKey, "sk-ds")
    }

    func testConfigSerializeRoundTrips() {
        var c = AppConfig()
        c.primary = .zai
        c.openaiEnabled = false
        c.deepseekEnabled = true
        c.zaiApiKey = "sk-zai-inline"
        c.zaiPlanTier = "pro"
        c.deepseekApiKey = "sk-ds"

        let back = AppConfig.parse(c.serialize())
        XCTAssertEqual(back.primary, .zai)
        XCTAssertFalse(back.isEnabled(.openai))
        XCTAssertTrue(back.isEnabled(.deepseek))
        XCTAssertEqual(back.zaiApiKey, "sk-zai-inline")
        XCTAssertEqual(back.zaiPlanTier, "pro")
        XCTAssertEqual(back.deepseekApiKey, "sk-ds")
    }

    func testConfigSerializeEscapesSpecialCharacters() {
        var c = AppConfig()
        // A value with a quote and a backslash must survive the round-trip.
        c.zaiApiKey = #"a\b"c"#
        let back = AppConfig.parse(c.serialize())
        XCTAssertEqual(back.zaiApiKey, #"a\b"c"#)
    }

    func testConfigOmitsEmptyInlineKeys() {
        let c = AppConfig() // no inline keys set
        let text = c.serialize()
        XCTAssertFalse(text.contains("api_key ="), "empty inline keys should not be written")
    }

    func testResolveKeyPrefersEnv() {
        XCTAssertEqual(AppConfig.resolveKey(env: "", inline: "inline"), "inline")
        XCTAssertNil(AppConfig.resolveKey(env: "AIUB_TEST_MISSING_VAR_XYZ", inline: nil))
    }

    // MARK: - Anthropic credentials (mirrors src/anthropic/creds.rs)

    func testAnthropicCredsParseAndPlanLabel() {
        let raw = #"""
        {"claudeAiOauth":{
            "accessToken":"AT","refreshToken":"RT",
            "expiresAt": 1735000000000,
            "subscriptionType":"max","rateLimitTier":"default_claude_max_5x"
        }}
        """#
        let creds = AnthropicCreds.parse(raw)!
        XCTAssertEqual(creds.accessToken, "AT")
        XCTAssertEqual(creds.expiresAtMs, 1735000000000)
        XCTAssertEqual(creds.planLabel, "Max 5x")
    }

    func testAnthropicPlanLabelVariants() {
        func label(_ sub: String, _ tier: String) -> String {
            AnthropicCreds(accessToken: "", refreshToken: "", expiresAtMs: 0,
                           subscriptionType: sub, rateLimitTier: tier).planLabel
        }
        XCTAssertEqual(label("pro", ""), "Pro")
        XCTAssertEqual(label("max", "default_claude_max_20x"), "Max 20x")
        XCTAssertEqual(label("", ""), "Unknown")
    }

    func testAnthropicAcceptsFloatExpiresAt() {
        let raw = #"{"claudeAiOauth":{"accessToken":"A","refreshToken":"R","expiresAt":5000.0,"subscriptionType":"pro","rateLimitTier":""}}"#
        XCTAssertEqual(AnthropicCreds.parse(raw)?.expiresAtMs, 5000)
    }

    func testRefreshBuffer() {
        let now: Int64 = 1_000_000
        XCTAssertTrue(AnthropicOAuth.needsRefresh(expiresAtSecs: now + 100, now: now))
        XCTAssertFalse(AnthropicOAuth.needsRefresh(expiresAtSecs: now + 1000, now: now))
        XCTAssertTrue(AnthropicOAuth.needsRefresh(expiresAtSecs: now - 1, now: now))
    }

    func testOAuthErrorBodyShapes() {
        XCTAssertEqual(AnthropicOAuth.parseErrorBody(#"{"error":"invalid_grant","error_description":"expired"}"#), "expired")
        XCTAssertEqual(AnthropicOAuth.parseErrorBody(#"{"error":{"type":"x","message":"bad"}}"#), "bad")
        XCTAssertEqual(AnthropicOAuth.parseErrorBody(#"{"error":"oops"}"#), "oops")
        XCTAssertNil(AnthropicOAuth.parseErrorBody("not json"))
    }

    // MARK: - Codex JWT (mirrors src/openai/creds.rs)

    func testCodexJWTExpAndPlan() {
        // Build a fake JWT: header.payload.sig (URL-safe base64, no padding).
        func b64url(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let payload = #"{"exp":1234567890,"https://api.openai.com/auth":{"chatgpt_plan_type":"plus"}}"#
        let jwt = "\(b64url("{}")).\(b64url(payload)).sig"
        let creds = CodexCreds(accessToken: "A", refreshToken: "R", idToken: jwt, accountId: "acc")
        XCTAssertEqual(creds.expiresAtSecs, 1234567890)
        XCTAssertEqual(creds.planType, "plus")
    }

    func testCodexMalformedJWTReturnsZero() {
        let creds = CodexCreds(accessToken: "A", refreshToken: "R", idToken: "not.a.jwt", accountId: nil)
        XCTAssertEqual(creds.expiresAtSecs, 0)
        XCTAssertNil(creds.planType)
    }
}
