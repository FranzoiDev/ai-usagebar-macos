import XCTest
@testable import AIUsageBarKit

/// Tests for the vendors added in the v0.8–v0.22 upstream port, with fixtures
/// copied from the upstream Rust tests.
final class NewVendorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_779_500_000)

    private func data(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - Kimi

    func testKimiSampleWithStringNumbers() {
        let raw = #"""
        {
            "user": { "membership": { "level": "LEVEL_INTERMEDIATE" } },
            "usage": { "limit": "100", "used": "26", "remaining": "74", "resetTime": "2026-02-11T17:32:50.757941Z" },
            "limits": [
                { "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" },
                  "detail": { "limit": "100", "used": "15", "remaining": "85", "resetTime": "2026-02-07T12:32:50.757941Z" } }
            ]
        }
        """#
        let usage = KimiProvider.render(data(raw), now: now)
        XCTAssertTrue(usage.available)
        XCTAssertEqual(usage.plan, "Kimi LEVEL_INTERMEDIATE")
        XCTAssertEqual(usage.gauges.map(\.label), ["Weekly", "Rolling (5h)"])
        XCTAssertEqual(usage.gauges[0].percent, 26)
        XCTAssertEqual(usage.gauges[1].percent, 15)
    }

    func testKimiDerivesUsedFromRemaining() {
        let block = KimiProvider.block(["limit": 500, "remaining": 377])
        XCTAssertEqual(block?.used, 123)
        XCTAssertEqual(block?.pct, 25)
    }

    func testKimiMissingUsageBlockIsDrift() {
        XCTAssertFalse(KimiProvider.render(data(#"{"limits": []}"#), now: now).available)
    }

    func testKimiMissingBothCountersIsDropped() {
        XCTAssertNil(KimiProvider.block(["limit": 100]))
    }

    func testKimiHourWindowRecognition() {
        let hours = KimiProvider.fiveHourBlock([
            ["window": ["duration": 5, "timeUnit": "TIME_UNIT_HOUR"],
             "detail": ["limit": 10, "used": 5]],
        ])
        XCTAssertEqual(hours?.pct, 50)
        let unknown = KimiProvider.fiveHourBlock([
            ["window": ["duration": 60, "timeUnit": "TIME_UNIT_MINUTE"],
             "detail": ["limit": 10, "used": 5]],
        ])
        XCTAssertNil(unknown)
    }

    // MARK: - MiniMax

    private let minimaxLive = #"""
    {
        "model_remains": [
            { "start_time": 1785164400000, "end_time": 1785182400000,
              "model_name": "general",
              "weekly_start_time": 1785110400000, "weekly_end_time": 1785715200000,
              "current_interval_status": 1, "current_interval_remaining_percent": 99,
              "current_weekly_status": 1, "current_weekly_remaining_percent": 99 },
            { "start_time": 1785110400000, "end_time": 1785196800000,
              "model_name": "video",
              "weekly_start_time": 1785110400000, "weekly_end_time": 1785715200000,
              "current_interval_remaining_percent": 100,
              "current_weekly_remaining_percent": 100 }
        ],
        "base_resp": { "status_code": 0, "status_msg": "success" }
    }
    """#

    func testMinimaxInvertsRemainingPercentages() {
        let usage = MinimaxProvider.render(data(minimaxLive), now: now)
        XCTAssertTrue(usage.available)
        XCTAssertEqual(usage.plan, "MiniMax Token Plan")
        XCTAssertEqual(usage.gauges[0].percent, 1) // 99 remaining → 1 consumed
        XCTAssertEqual(usage.gauges[1].percent, 1)
        XCTAssertEqual(usage.footnote, "Video: session 0% · weekly 0%")
    }

    func testMinimaxInBandAuthFailureIsNotAZeroQuota() {
        let raw = #"{"base_resp":{"status_code":1004,"status_msg":"login fail"}}"#
        XCTAssertFalse(MinimaxProvider.render(data(raw), now: now).available)
    }

    func testMinimaxConsumedPctClamps() {
        XCTAssertEqual(MinimaxProvider.consumedPct(150), 0)
        XCTAssertEqual(MinimaxProvider.consumedPct(-5), 100)
        XCTAssertEqual(MinimaxProvider.consumedPct(99), 1)
    }

    // MARK: - Kilo / Novita / Moonshot / Grok

    func testKiloBalance() {
        let usage = KiloProvider.render(data(#"{"balance":8.42}"#))
        XCTAssertEqual(usage.headline, "$8.42")
        XCTAssertEqual(usage.severity, .mid)
        XCTAssertFalse(KiloProvider.render(data(#"{"error":"forbidden"}"#)).available,
                       "a 200 error envelope must never become $0.00")
    }

    func testNovitaTenThousandthsScale() {
        let raw = #"""
        {"availableBalance":"1000000","cashBalance":"800000","creditLimit":"200000",
         "pendingCharges":"0","outstandingInvoices":"0"}
        """#
        let usage = NovitaProvider.render(data(raw))
        XCTAssertEqual(usage.headline, "$100.00")
        XCTAssertEqual(usage.footnote, "top-up $80.00 · credit limit $20.00")
        XCTAssertFalse(NovitaProvider.render(data(#"{"availableBalance":"1"}"#)).available,
                       "partial body is drift, not zero")
    }

    func testMoonshotEnvelopeAndCurrency() {
        let raw = #"""
        {"code":0,"data":{"available_balance":49.58894,"voucher_balance":46.58893,"cash_balance":3.00001},
         "scode":"0x0","status":true}
        """#
        let usage = MoonshotProvider.render(data(raw), currency: "USD")
        XCTAssertEqual(usage.headline, "$49.59")
        let fail = #"{"code":40100,"data":{"available_balance":0.0,"voucher_balance":0.0,"cash_balance":0.0},"status":false}"#
        XCTAssertFalse(MoonshotProvider.render(data(fail), currency: "USD").available)
        // status true with non-zero code is still a failure.
        let sneaky = #"{"code":40100,"data":{"available_balance":1.0,"voucher_balance":0,"cash_balance":1},"status":true}"#
        XCTAssertFalse(MoonshotProvider.render(data(sneaky), currency: "USD").available)
    }

    func testMoonshotSeverityScalesWithCurrency() {
        XCTAssertEqual(MoonshotProvider.severity(available: 0, currency: "USD"), .critical)
        XCTAssertEqual(MoonshotProvider.severity(available: 6, currency: "CNY"), .critical)
        XCTAssertEqual(MoonshotProvider.severity(available: 6, currency: "USD"), .mid)
        XCTAssertEqual(MoonshotProvider.severity(available: 150, currency: "CNY"), .low)
    }

    func testGrokInvertedLedger() {
        let usage = GrokProvider.render(data(#"{"changes":[],"total":{"val":"-2500"}}"#))
        XCTAssertEqual(usage.headline, "$25.00")
        XCTAssertEqual(usage.severity, .low)
        XCTAssertFalse(GrokProvider.render(data(#"{"total":{"val":"n/a"}}"#)).available)
        XCTAssertFalse(GrokProvider.render(data(#"{}"#)).available)
    }

    func testGrokTeamResolution() {
        XCTAssertEqual(GrokProvider.resolvedTeam(data(#"{"scopeId":"team-xyz","teamId":"team-xyz"}"#)), "team-xyz")
        // Organization-scoped keys must not adopt scopeId (it's an org id).
        XCTAssertNil(GrokProvider.resolvedTeam(data(#"{"scope":"SCOPE_ORGANIZATION","scopeId":"org-77"}"#)))
        XCTAssertEqual(GrokProvider.resolvedTeam(data(#"{"scopeId":null,"teamId":"team-x"}"#)), "team-x")
        XCTAssertNil(GrokProvider.resolvedTeam(data(#"{"scope":"SCOPE_FUTURE","scopeId":"x"}"#)))
    }

    // MARK: - Anthropic Admin API

    func testAnthropicAPIParsePage() throws {
        let raw = #"""
        { "data": [
            { "starting_at": "2026-07-01T00:00:00Z", "ending_at": "2026-07-02T00:00:00Z",
              "results": [
                { "amount": "100.0", "currency": "USD", "cost_type": "tokens" },
                { "amount": "34.5", "currency": "USD", "cost_type": "web_search" } ] } ],
          "has_more": false, "next_page": null }
        """#
        let (cents, hasMore, next) = try AnthropicAPIProvider.parsePage(data(raw))
        XCTAssertEqual(cents, 134.5)
        XCTAssertFalse(hasMore)
        XCTAssertNil(next)
    }

    func testAnthropicAPIEmptyDataIsLegitimateZero() throws {
        let (cents, hasMore, _) = try AnthropicAPIProvider.parsePage(
            data(#"{"data":[],"has_more":false,"next_page":null}"#))
        XCTAssertEqual(cents, 0)
        XCTAssertFalse(hasMore)
    }

    func testAnthropicAPIMalformedEnvelopeIsNotZeroSpend() {
        XCTAssertThrowsError(try AnthropicAPIProvider.parsePage(data("{}")))
        XCTAssertThrowsError(try AnthropicAPIProvider.parsePage(
            data(#"{"data":[{}],"has_more":false}"#)), "bucket without results")
        XCTAssertThrowsError(try AnthropicAPIProvider.parsePage(
            data(#"{"data":[{"results":[{"amount":"1","currency":"EUR"}]}],"has_more":false}"#)),
            "non-USD currency")
        XCTAssertThrowsError(try AnthropicAPIProvider.parsePage(
            data(#"{"error":{"message":"invalid x-api-key"}}"#)))
    }

    func testAnthropicAPIMonthStartAndHeadlines() {
        XCTAssertEqual(
            AnthropicAPIProvider.monthStartRFC3339(Date(timeIntervalSince1970: 1_784_732_880)),
            "2026-07-01T00:00:00Z")
        XCTAssertEqual(AnthropicAPIProvider.render(spent: 1.345, limit: 1000).headline,
                       "$1.34 / $1000 · 0%")
        XCTAssertEqual(AnthropicAPIProvider.render(spent: 1.345, limit: nil).headline, "$1.34/mo")
        XCTAssertEqual(AnthropicAPIProvider.render(spent: 1.345, limit: nil).severity, .low)
    }

    // MARK: - Cursor

    private let cursorSample = #"""
    {
        "billingCycleStart": "2026-07-04T00:35:51.000Z",
        "billingCycleEnd": "2099-08-04T00:35:51.000Z",
        "membershipType": "ultra",
        "limitType": "user",
        "isUnlimited": false,
        "autoModelSelectedDisplayMessage": "You've used 98% of your included total usage",
        "namedModelSelectedDisplayMessage": "You've used 100% of your included API usage",
        "individualUsage": {
            "plan": { "enabled": true, "used": 40000, "limit": 40000, "remaining": 0,
                      "autoPercentUsed": 98.109, "apiPercentUsed": 100, "totalPercentUsed": 98.5128 },
            "onDemand": { "enabled": false, "used": 0, "limit": null, "remaining": null }
        },
        "teamUsage": {}
    }
    """#

    func testCursorPersonalAccount() {
        let usage = CursorProvider.render(data(cursorSample), now: now)
        XCTAssertTrue(usage.available)
        XCTAssertEqual(usage.plan, "Cursor Ultra")
        XCTAssertEqual(usage.gauges.map(\.label), ["Cursor Models", "Other Models"])
        XCTAssertEqual(usage.gauges[0].percent, 98)
        XCTAssertEqual(usage.gauges[1].percent, 100)
        XCTAssertEqual(usage.severity, .critical)
    }

    func testCursorTeamFallbackNeedsBothMessages() {
        let team = #"""
        { "billingCycleEnd": "2099-08-04T00:35:51.000Z", "membershipType": "team", "isUnlimited": false,
          "autoModelSelectedDisplayMessage": "You've used 42% of your included total usage",
          "namedModelSelectedDisplayMessage": "You've used 15% of your included API usage",
          "teamUsage": { "onDemand": { "enabled": true } } }
        """#
        let usage = CursorProvider.render(data(team), now: now)
        XCTAssertEqual(usage.plan, "Cursor Team (team)")
        XCTAssertEqual(usage.gauges[0].percent, 42)
        XCTAssertEqual(usage.gauges[1].percent, 15)
        // teamUsage present but no parseable messages → drift, never 0%.
        let broken = #"{"billingCycleEnd": "2099-08-04T00:00:00Z", "membershipType": "team", "teamUsage": {}}"#
        XCTAssertFalse(CursorProvider.render(data(broken), now: now).available)
    }

    func testCursorOverHundredIsNotClamped() {
        let raw = #"""
        { "billingCycleEnd": "2099-08-04T00:00:00Z", "membershipType": "pro",
          "individualUsage": { "plan": { "autoPercentUsed": 142.7, "apiPercentUsed": 5, "totalPercentUsed": 80 } } }
        """#
        XCTAssertEqual(CursorProvider.render(data(raw), now: now).gauges[0].percent, 143)
    }

    func testCursorUnlimitedPlan() {
        let raw = #"{"billingCycleEnd": "2099-08-04T00:00:00Z", "membershipType": "enterprise", "isUnlimited": true}"#
        let usage = CursorProvider.render(data(raw), now: now)
        XCTAssertEqual(usage.headline, "unlimited")
        XCTAssertEqual(usage.severity, .low)
        XCTAssertTrue(usage.gauges.isEmpty)
    }

    func testCursorPastBillingCycleIsRefused() {
        let raw = #"""
        { "billingCycleEnd": "2026-08-04T00:00:00Z", "membershipType": "pro",
          "individualUsage": { "plan": { "autoPercentUsed": 1, "apiPercentUsed": 1, "totalPercentUsed": 1 } } }
        """#
        let past = Date(timeIntervalSince1970: 1_786_500_000) // 2026-08-11
        XCTAssertFalse(CursorProvider.render(data(raw), now: past).available)
    }

    func testCursorDisplayMessageParser() {
        XCTAssertEqual(CursorProvider.displayMessagePct("You've used 98% of your included total usage"), 98)
        XCTAssertEqual(CursorProvider.displayMessagePct("You've used 100% of your included API usage"), 100)
        XCTAssertNil(CursorProvider.displayMessagePct("no percent here"))
        XCTAssertNil(CursorProvider.displayMessagePct("unavailable"))
    }

    func testCursorUserIdFromJWT() {
        func b64url(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let jwt = "\(b64url("{}")).\(b64url(#"{"sub":"auth0|user_abc123"}"#)).sig"
        XCTAssertEqual(CursorProvider.userId(fromJWT: jwt), "user_abc123")
        XCTAssertNil(CursorProvider.userId(fromJWT: "\(b64url("{}")).\(b64url(#"{"sub":"weird"}"#)).sig"))
    }

    // MARK: - Antigravity

    func testAntigravityLsofParser() {
        XCTAssertEqual(
            AntigravityProvider.parseLsofPCN(
                "p74101\ncagy\nf10\nn127.0.0.1:8829\nf11\nn127.0.0.1:61289\nf12\nn127.0.0.1:61290\np200\ncsshd\nf5\nn*:22\n"),
            [8829, 61289, 61290])
        XCTAssertEqual(AntigravityProvider.parseLsofPCN("p900\ncAntigravity\nf7\nn127.0.0.1:54321\n"), [54321])
        XCTAssertEqual(AntigravityProvider.parseLsofPCN("p1\ncagy\nf3\nn127.0.0.1:9000\nf4\nn127.0.0.1:9000\n"), [9000])
        XCTAssertEqual(AntigravityProvider.parseLsofPCN(""), [])
    }

    func testAntigravityProcessPredicate() {
        XCTAssertTrue(AntigravityProvider.isAntigravityProcess("language_server"))
        XCTAssertTrue(AntigravityProvider.isAntigravityProcess("agy"))
        XCTAssertTrue(AntigravityProvider.isAntigravityProcess("Antigravity"))
        XCTAssertFalse(AntigravityProvider.isAntigravityProcess("sshd"))
        XCTAssertFalse(AntigravityProvider.isAntigravityProcess("legacy"))
        XCTAssertFalse(AntigravityProvider.isAntigravityProcess(""))
    }

    func testAntigravityQuotaClassificationAndInversion() throws {
        let quota = #"""
        { "response": { "groups": [
            { "displayName": "Gemini Models", "buckets": [
                {"bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.9191212,
                 "resetTime": "2099-07-28T17:39:58Z"},
                {"bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.5672253,
                 "resetTime": "2099-07-22T17:47:00Z"} ] },
            { "displayName": "Claude and GPT models", "buckets": [
                {"bucketId": "3p-weekly", "window": "weekly", "remainingFraction": 1,
                 "resetTime": "2099-07-29T12:47:00Z"},
                {"bucketId": "3p-5h", "window": "5h", "remainingFraction": 0.25,
                 "resetTime": "2099-07-22T17:47:00Z"} ] } ] } }
        """#
        let snapshot = try XCTUnwrap(AntigravityProvider.snapshotJSON(data(quota), plan: "Google AI Pro"))
        let usage = AntigravityProvider.render(snapshot, now: now)
        XCTAssertTrue(usage.available)
        XCTAssertEqual(usage.plan, "Google AI Pro")
        XCTAssertEqual(usage.gauges.map(\.label),
                       ["Gemini 5h", "Gemini Weekly", "Claude & GPT 5h", "Claude & GPT Weekly"])
        XCTAssertEqual(usage.gauges.map(\.percent), [43, 8, 75, 0])
        XCTAssertEqual(usage.severity, .high) // worst of all four (75)
    }

    func testAntigravityInvalidFractionRejectsSnapshot() {
        for bad in ["-0.01", "1.01", "\"oops\"", "null"] {
            let quota = """
            { "groups": [ { "displayName": "Gemini Models", "buckets": [
                {"bucketId": "gemini-5h", "window": "5h", "remainingFraction": \(bad)},
                {"bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.5} ] } ] }
            """
            XCTAssertNil(AntigravityProvider.snapshotJSON(data(quota), plan: "P"), "fraction \(bad)")
        }
    }

    func testAntigravityDuplicateBucketIsDrift() {
        let quota = #"""
        { "groups": [ { "displayName": "Gemini Models", "buckets": [
            {"bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.5},
            {"bucketId": "gemini-5h-copy", "window": "5h", "remainingFraction": 0.6},
            {"bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.5} ] } ] }
        """#
        XCTAssertNil(AntigravityProvider.snapshotJSON(data(quota), plan: "P"))
    }

    func testAntigravityExpiredWindowIsRefused() throws {
        let quota = #"""
        { "groups": [ { "displayName": "Gemini Models", "buckets": [
            {"bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.5,
             "resetTime": "2026-01-01T00:00:00Z"},
            {"bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.5} ] } ] }
        """#
        let snapshot = try XCTUnwrap(AntigravityProvider.snapshotJSON(data(quota), plan: "P"))
        XCTAssertFalse(AntigravityProvider.render(snapshot, now: now).available,
                       "a window past its reset is a previous period")
    }

    func testAntigravityCSRFScrape() {
        XCTAssertEqual(AntigravityProvider.scrapeCSRF(html: #"<script>x={"csrfToken":"abc123"}</script>"#), "abc123")
        XCTAssertNil(AntigravityProvider.scrapeCSRF(html: "<html>no token</html>"))
    }

    // MARK: - Multi-account config

    func testAnthropicAccountsParsing() {
        let toml = """
        [anthropic]
        enabled = true
        accounts_dir = "~/accounts"
        show_default_account = false

        [[anthropic.accounts]]
        label = "work"
        credentials_path = "~/accounts/work/.credentials.json"

        [[anthropic.accounts]]
        label = "personal"
        credentials_path = "/x/personal/.credentials.json"

        [openai]
        enabled = false
        """
        let cfg = AppConfig.parse(toml)
        XCTAssertEqual(cfg.anthropicAccounts.map(\.label), ["work", "personal"])
        XCTAssertTrue(cfg.anthropicAccounts[0].credentialsPath.hasPrefix("/"), "tilde expanded")
        XCTAssertFalse(cfg.anthropicShowDefaultAccount)
        XCTAssertFalse(cfg.isEnabled(.openai), "sections after array tables still parse")
        XCTAssertEqual(cfg.anthropicAccounts[1].configDir, "/x/personal")
    }

    func testAccountLabelValidation() {
        for bad in ["", ".", "..", "a/b", "a\\b", "usage.json", ".stale", ".last_error", ".fetch.lock", "a\nb"] {
            XCTAssertFalse(AnthropicAccount.isValidLabel(bad), bad)
        }
        XCTAssertTrue(AnthropicAccount.isValidLabel("work"))
    }

    func testShowsDefaultRowRule() {
        var cfg = AppConfig()
        XCTAssertTrue(cfg.showsDefaultAnthropicRow(hasNamedRows: false))
        cfg.anthropicShowDefaultAccount = false
        XCTAssertTrue(cfg.showsDefaultAnthropicRow(hasNamedRows: false),
                      "ignored when there are no named accounts")
        XCTAssertFalse(cfg.showsDefaultAnthropicRow(hasNamedRows: true))
    }

    func testKeychainServiceNameHash() {
        // shasum -a 256 of the literal path string, first 8 hex chars.
        XCTAssertEqual(Keychain.serviceName(forConfigDir: "/Users/gfb/accounts/work"),
                       "Claude Code-credentials-02f333ec")
    }

    func testNewVendorConfigRoundTrip() {
        var cfg = AppConfig()
        cfg.kimiEnabled = true
        cfg.kimiApiKey = "sk-kimi"
        cfg.minimaxEnabled = true
        cfg.minimaxRegion = "cn"
        cfg.grokTeamId = "team-1"
        cfg.anthropicAPIMonthlyLimit = 1000
        cfg.cursorEnabled = true
        cfg.antigravityEnabled = true
        cfg.anthropicAccounts = [AnthropicAccount(label: "work", credentialsPath: "/a/work/.credentials.json")]

        let back = AppConfig.parse(cfg.serialize())
        XCTAssertTrue(back.kimiEnabled)
        XCTAssertEqual(back.kimiApiKey, "sk-kimi")
        XCTAssertEqual(back.minimaxRegion, "cn")
        XCTAssertEqual(back.grokTeamId, "team-1")
        XCTAssertEqual(back.anthropicAPIMonthlyLimit, 1000)
        XCTAssertTrue(back.cursorEnabled)
        XCTAssertTrue(back.antigravityEnabled)
        XCTAssertEqual(back.anthropicAccounts, cfg.anthropicAccounts)
    }

    // MARK: - safeStorage (Claude Desktop)

    func testSafeStorageGoldenVectors() {
        // Upstream golden: derive_key(b"not-a-real-secret").
        let key = SafeStorage.deriveKey(secret: Data("not-a-real-secret".utf8))
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(),
                       "9ba5a28a3239fece3c5ae570d6523dcc")
        // Upstream golden: encrypt(key, b"same") — decrypt must invert it.
        let plain = SafeStorage.decrypt(key: key, valueB64: "djEwykc2I53A+doQo9OF96du2A==")
        XCTAssertEqual(plain.flatMap { String(data: $0, encoding: .utf8) }, "same")
        // Missing v10 prefix and bad base64 fail cleanly.
        XCTAssertNil(SafeStorage.decrypt(key: key, valueB64: Data("not-v10-data".utf8).base64EncodedString()))
        XCTAssertNil(SafeStorage.decrypt(key: key, valueB64: "@@@not base64@@@"))
        // Wrong key → padding failure, not garbage.
        let wrongKey = SafeStorage.deriveKey(secret: Data("other".utf8))
        XCTAssertNil(SafeStorage.decrypt(key: wrongKey, valueB64: "djEwykc2I53A+doQo9OF96du2A=="))
    }

    func testDesktopInferenceEntrySelection() {
        let map: [String: Any] = [
            "a473d7bb:org:https://api.anthropic.com:user:profile": [
                "token": "sk-ant-oat01-PROFILE-ONLY", "refreshToken": "r", "expiresAt": 111,
            ],
            "9d1c250a:org:https://api.anthropic.com:user:inference user:profile": [
                "token": "sk-ant-oat01-REAL", "refreshToken": "sk-ant-ort01-REAL", "expiresAt": 111,
                "subscriptionType": "max", "rateLimitTier": "default_claude_max_20x",
            ],
        ]
        let creds = ClaudeDesktop.inferenceEntry(map)
        XCTAssertEqual(creds?.accessToken, "sk-ant-oat01-REAL")
        XCTAssertEqual(creds?.refreshToken, "", "read-only: never carry a refresh token")
        XCTAssertEqual(creds?.planLabel, "Max 20x")
        XCTAssertNil(ClaudeDesktop.inferenceEntry([
            "x:user:profile": ["token": "t"],
        ]), "profile-only cache has no usable entry")
    }

    func testDesktopCacheKeyIsFullSha1() {
        XCTAssertEqual(ClaudeDesktop.sha1Hex("account-a"),
                       "3bef308ed317769e8f67f213bfc6a6ff7c87a3a1")
        XCTAssertNotEqual(ClaudeDesktop.sha1Hex("account-a"), ClaudeDesktop.sha1Hex("account-b"))
    }
}
