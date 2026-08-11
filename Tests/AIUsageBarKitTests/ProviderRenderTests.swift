import XCTest
@testable import AIUsageBarKit

/// Rendering tests for the Anthropic and OpenAI payload projections, with
/// fixtures ported from the upstream Rust tests (`src/anthropic/types.rs`,
/// `src/openai/fetch.rs`).
final class ProviderRenderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_779_500_000)

    private func data(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - Anthropic: full legacy shape still parses

    func testAnthropicFullResponse() {
        let raw = #"""
        {
            "five_hour":         {"utilization": 42.7, "resets_at": "2026-05-23T17:30:00Z"},
            "seven_day":         {"utilization": 27.0, "resets_at": "2026-05-30T12:00:00Z"},
            "seven_day_sonnet":  {"utilization":  4.2, "resets_at": "2026-05-30T12:00:00Z"},
            "extra_usage":       {"is_enabled": true, "monthly_limit": 5000, "used_credits": 250}
        }
        """#
        let usage = AnthropicProvider.render(data(raw), plan: "Max 5x", now: now)
        XCTAssertTrue(usage.available)
        XCTAssertEqual(usage.gauges.map(\.label), ["Session", "Weekly", "Sonnet only"])
        XCTAssertEqual(usage.gauges[0].percent, 43) // rounded
        XCTAssertEqual(usage.gauges[1].percent, 27)
        XCTAssertEqual(usage.footnote, "Extra: $2.50 / $50.00 · 5%")
    }

    // MARK: - Anthropic: model-scoped weekly limits (Fable)

    func testAnthropicScopedFableWindow() {
        let raw = #"""
        {
            "five_hour": {"utilization": 10, "resets_at": "2026-05-23T17:30:00Z"},
            "seven_day": {"utilization": 55, "resets_at": "2026-05-30T12:00:00Z"},
            "seven_day_sonnet": null,
            "limits": [
                {"kind": "five_hour", "group": "session", "percent": 10},
                {"kind": "weekly_scoped", "group": "weekly", "percent": 84,
                 "resets_at": "2026-05-30T12:00:00Z",
                 "scope": {"model": {"display_name": "Fable"}}}
            ]
        }
        """#
        let usage = AnthropicProvider.render(data(raw), plan: "Max 20x", now: now)
        XCTAssertEqual(usage.gauges.map(\.label), ["Session", "Weekly", "Fable"])
        XCTAssertEqual(usage.gauges[2].percent, 84)
        // The 84% Fable week drives severity even with the overall weekly at 55%.
        XCTAssertEqual(usage.severity, .high)
    }

    func testAnthropicMissingLimitsArrayYieldsNoScopedGauges() {
        let raw = #"{"five_hour": {"utilization": 1}, "seven_day": {"utilization": 2}}"#
        let usage = AnthropicProvider.render(data(raw), plan: "Pro", now: now)
        XCTAssertEqual(usage.gauges.map(\.label), ["Session", "Weekly"])
    }

    func testAnthropicScopedEntryWithoutPercentIsDroppedNotZeroed() {
        let scoped = AnthropicProvider.scopedWindows([
            ["kind": "weekly_scoped", "percent": NSNull(),
             "scope": ["model": ["display_name": "Fable"]]],
        ])
        XCTAssertTrue(scoped.isEmpty)
    }

    func testAnthropicScopedOutOfRangePercentIsRejected() {
        let scoped = AnthropicProvider.scopedWindows([
            ["kind": "weekly_scoped", "percent": 420,
             "scope": ["model": ["display_name": "Fable"]]],
        ])
        XCTAssertTrue(scoped.isEmpty)
    }

    func testAnthropicScopedEntryWithoutDisplayNameIsDropped() {
        let scoped = AnthropicProvider.scopedWindows([
            ["kind": "weekly_scoped", "percent": 50, "scope": ["model": [:]]],
        ])
        XCTAssertTrue(scoped.isEmpty)
    }

    // MARK: - Anthropic: extra usage (null cap, currency)

    func testExtraUsageNullLimitShowsSpendWithoutPercent() {
        let extra = AnthropicProvider.extraUsage([
            "is_enabled": true, "monthly_limit": NSNull(), "used_credits": 250,
        ])
        XCTAssertEqual(extra?.line, "$2.50 (no cap)")
        XCTAssertEqual(extra?.percent, 0)
    }

    func testExtraUsageBRLCurrency() {
        // The #30 payload: R$ 141.57 as an integral float.
        let extra = AnthropicProvider.extraUsage([
            "is_enabled": true, "monthly_limit": NSNull(),
            "used_credits": 14157.0, "currency": "BRL", "decimal_places": 2,
        ])
        XCTAssertEqual(extra?.line, "R$141.57 (no cap)")
    }

    func testExtraUsageCurrencyWithoutScaleStaysInMinorUnits() {
        let extra = AnthropicProvider.extraUsage([
            "is_enabled": true, "used_credits": 500, "currency": "KRW",
        ])
        XCTAssertEqual(extra?.line, "500 minor units KRW (no cap)")
    }

    func testExtraUsageMissingSpendDropsBlock() {
        XCTAssertNil(AnthropicProvider.extraUsage(["is_enabled": true, "monthly_limit": 5000]))
    }

    func testExtraUsageMalformedCurrencyOrScaleDropsBlock() {
        XCTAssertNil(AnthropicProvider.extraUsage([
            "is_enabled": true, "used_credits": 1, "currency": "R$",
        ]))
        XCTAssertNil(AnthropicProvider.extraUsage([
            "is_enabled": true, "used_credits": 1, "decimal_places": 100,
        ]))
    }

    func testExtraUsagePromotesSeverityOnlyAtCap() {
        // Weekly at cap + extra at 96% of its monthly limit → critical.
        let raw = #"""
        {"five_hour": {"utilization": 10}, "seven_day": {"utilization": 100},
         "extra_usage": {"is_enabled": true, "monthly_limit": 10000, "used_credits": 9600}}
        """#
        XCTAssertEqual(AnthropicProvider.render(data(raw), plan: "Pro", now: now).severity, .critical)
        // No window at cap → the same spend does not promote severity.
        let calm = #"""
        {"five_hour": {"utilization": 10}, "seven_day": {"utilization": 20},
         "extra_usage": {"is_enabled": true, "monthly_limit": 10000, "used_credits": 9600}}
        """#
        XCTAssertEqual(AnthropicProvider.render(data(calm), plan: "Pro", now: now).severity, .low)
    }

    // MARK: - OpenAI: window classification by duration

    func testOpenAIBothWindowsKeepLayout() {
        let raw = #"""
        {"plan_type": "plus", "rate_limit": {
            "primary_window":   {"used_percent": 1,  "limit_window_seconds": 18000,  "reset_at": 1779597324},
            "secondary_window": {"used_percent": 66, "limit_window_seconds": 604800, "reset_at": 1780184124}
        }}
        """#
        let usage = OpenAIProvider.render(data(raw), planHint: nil, now: now)
        XCTAssertEqual(usage.gauges.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(usage.gauges[0].percent, 1)
        XCTAssertEqual(usage.gauges[1].percent, 66)
    }

    func testOpenAIWeeklyOnlyInPrimarySlotIsLabeledWeekly() {
        // July 2026 rollout: the 7d window arrives in `primary_window` and
        // `secondary_window` is omitted.
        let raw = #"""
        {"plan_type": "plus", "rate_limit": {
            "primary_window": {"used_percent": 66, "limit_window_seconds": 604800, "reset_at": 1785261834}
        }}
        """#
        let usage = OpenAIProvider.render(data(raw), planHint: nil, now: now)
        XCTAssertEqual(usage.gauges.map(\.label), ["Weekly"], "no fabricated 0% session gauge")
        XCTAssertEqual(usage.gauges[0].percent, 66)
        XCTAssertTrue(usage.headline.hasPrefix("66%"))
    }

    func testOpenAIUnknownDurationFallsBackToSlotPosition() {
        let raw = #"""
        {"plan_type": "pro", "rate_limit": {
            "primary_window":   {"used_percent": 37},
            "secondary_window": {"used_percent": 12}
        }}
        """#
        let usage = OpenAIProvider.render(data(raw), planHint: nil, now: now)
        XCTAssertEqual(usage.gauges.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(usage.gauges[0].percent, 37)
    }

    func testOpenAIDuplicateWindowKindIsDrift() {
        let raw = #"""
        {"plan_type": "pro", "rate_limit": {
            "primary_window":   {"used_percent": 1, "limit_window_seconds": 604800},
            "secondary_window": {"used_percent": 2, "limit_window_seconds": 604800}
        }}
        """#
        XCTAssertFalse(OpenAIProvider.render(data(raw), planHint: nil, now: now).available)
    }

    // MARK: - Support helpers

    func testFmtMinor() {
        XCTAssertEqual(Support.fmtMinor(14157, decimalPlaces: 2, currency: "BRL"), "R$141.57")
        XCTAssertEqual(Support.fmtMinor(250, decimalPlaces: 2, currency: nil), "$2.50")
        XCTAssertEqual(Support.fmtMinor(500, decimalPlaces: 0, currency: "JPY"), "¥500")
        XCTAssertEqual(Support.fmtMinor(1234, decimalPlaces: 3, currency: "KWD"), "1.234 KWD")
        XCTAssertEqual(Support.fmtMinor(-150, decimalPlaces: 2, currency: "EUR"), "-€1.50")
        XCTAssertEqual(Support.fmtMinor(5, decimalPlaces: 2, currency: nil), "$0.05")
    }

    func testShortCountdown() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(Support.shortCountdown(nil, now: base), "")
        XCTAssertEqual(Support.shortCountdown(base.addingTimeInterval(-5), now: base), "now")
        XCTAssertEqual(Support.shortCountdown(base.addingTimeInterval(90), now: base), "1m")
        XCTAssertEqual(Support.shortCountdown(base.addingTimeInterval(7200), now: base), "2h")
        XCTAssertEqual(Support.shortCountdown(base.addingTimeInterval(4 * 86_400 + 3600), now: base), "4d")
    }

    func testElapsedFraction() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        // 2h into a 5h window → reset is 3h away.
        let f = Support.elapsedFraction(reset: base.addingTimeInterval(3 * 3600),
                                        window: 5 * 3600, now: base)
        XCTAssertEqual(f!, 0.4, accuracy: 0.001)
        XCTAssertNil(Support.elapsedFraction(reset: nil, window: 5 * 3600, now: base))
        // Reset further away than the window length clamps to 0; past clamps to 1.
        XCTAssertEqual(Support.elapsedFraction(reset: base.addingTimeInterval(10 * 3600),
                                               window: 5 * 3600, now: base), 0)
        XCTAssertEqual(Support.elapsedFraction(reset: base.addingTimeInterval(-60),
                                               window: 5 * 3600, now: base), 1)
    }

    func testSanitizeDisplay() {
        XCTAssertEqual(Support.sanitizeDisplay("ok\u{1B}[31mred"), "ok[31mred")
        XCTAssertEqual(Support.sanitizeDisplay("a\u{0007}b\nc"), "abc")
        XCTAssertEqual(Support.sanitizeDisplay("plain"), "plain")
    }
}
