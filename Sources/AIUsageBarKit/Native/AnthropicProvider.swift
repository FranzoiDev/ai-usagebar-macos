import Foundation

/// Native Anthropic fetcher — ports `src/anthropic/fetch.rs`. Reads creds →
/// refreshes if near expiry → GETs the undocumented OAuth usage endpoint →
/// caches the payload, falling back to the last good payload on failure.
public enum AnthropicProvider {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let usageBeta = "oauth-2025-04-20"

    static let sessionWindow: TimeInterval = 5 * 3600
    static let weeklyWindow: TimeInterval = 7 * 24 * 3600

    /// Default (unnamed) account, or a named `[[anthropic.accounts]]` /
    /// `accounts_dir` account. Each named account keeps its own cache under
    /// `anthropic/<label>/` and its own dir-hashed Keychain item.
    public static func fetch(
        config: AppConfig, account: AnthropicAccount? = nil, now: Date = Date()
    ) async -> VendorUsage {
        let creds: AnthropicCreds?
        if let account {
            creds = try? AnthropicCreds.readNamed(account)
        } else {
            creds = try? AnthropicCreds.read(path: AnthropicCreds.defaultPath(config.anthropicCredentialsPath))
        }
        guard let creds else { return .unavailable(.anthropic, accountLabel: account?.label ?? "") }
        let cache = DiskCache(vendor: account.map { "anthropic/\($0.label)" } ?? "anthropic")
        return await fetchWithCreds(creds, cache: cache, accountLabel: account?.label ?? "", now: now)
    }

    /// Shared fetch core, also used by the Claude Desktop path (which supplies
    /// creds decrypted from the app's safeStorage blob and its own cache).
    static func fetchWithCreds(
        _ creds: AnthropicCreds, cache: DiskCache, accountLabel: String, now: Date
    ) async -> VendorUsage {
        let planLabel = creds.planLabel

        // Fast path: serve a fresh cached payload.
        if let bytes = cache.freshPayload(ttl: DiskCache.defaultTTL) {
            return render(bytes, plan: planLabel, accountLabel: accountLabel, now: now)
        }

        // Read-only on credentials: never refresh the OAuth token ourselves.
        // Anthropic rotates refresh tokens, so refreshing here would invalidate
        // the copy Claude Code holds in memory and log the user out of the CLI
        // (see writeBack/AnthropicOAuth, kept for reference but intentionally
        // not invoked). We let `claude` own token rotation and just ride along
        // with whatever access token it has persisted. If that token is expired
        // the live fetch below 401s and we fall back to cache / unavailable
        // until the CLI refreshes it.

        // Live fetch.
        do {
            let resp = try await HTTP.get(usageURL, headers: [
                "Authorization": "Bearer \(creds.accessToken)",
                "anthropic-beta": usageBeta,
            ])
            guard resp.isSuccess else {
                throw FetchError.http(status: resp.status, body: "")
            }
            cache.writePayload(resp.body)
            return render(resp.body, plan: planLabel, accountLabel: accountLabel, now: now)
        } catch {
            if let bytes = cache.maybePayload() {
                var row = render(bytes, plan: planLabel, accountLabel: accountLabel, now: now)
                row.isStale = true
                return row
            }
            return .unavailable(.anthropic, accountLabel: accountLabel)
        }
    }

    // MARK: - Rendering

    static func render(_ bytes: Data, plan: String, accountLabel: String = "", now: Date) -> VendorUsage {
        guard let doc = JSON.object(bytes) else {
            return .unavailable(.anthropic, accountLabel: accountLabel)
        }

        let session = window(JSON.dict(doc["five_hour"]))
        let weekly = window(JSON.dict(doc["seven_day"]))
        let sonnet = JSON.dict(doc["seven_day_sonnet"]).map { window($0) }

        // Model-scoped weekly windows (e.g. the Fable weekly cap) exist only in
        // the newer `limits[]` array — there is no `seven_day_<model>` field,
        // and `seven_day_sonnet` is null on current payloads.
        let scoped = scopedWindows(doc["limits"])

        let extra = extraUsage(doc["extra_usage"])

        let headline = "\(session.pct)% · \(Support.countdown(session.reset, now: now))"
        let compact = "\(session.pct)%" + {
            let c = Support.shortCountdown(session.reset, now: now)
            return c.isEmpty ? "" : " \(c)"
        }()

        var gauges = [
            gauge("Session", session, windowDuration: sessionWindow, now: now),
            gauge("Weekly", weekly, windowDuration: weeklyWindow, now: now),
        ]
        if let sonnet {
            gauges.append(gauge("Sonnet only", sonnet, windowDuration: weeklyWindow, now: now))
        }
        for sw in scoped {
            gauges.append(gauge(sw.label, sw.window, windowDuration: weeklyWindow, now: now))
        }

        // Worst-of severity (mirrors usage::anthropic_severity): scoped windows
        // participate; extra spend only promotes once a window is at its cap.
        var maxPct = max(session.pct, weekly.pct)
        if let s = sonnet { maxPct = max(maxPct, s.pct) }
        for sw in scoped { maxPct = max(maxPct, sw.window.pct) }
        let anyAtCap = session.pct >= 100 || weekly.pct >= 100
            || (sonnet?.pct ?? 0) >= 100 || scoped.contains { $0.window.pct >= 100 }
        if anyAtCap, let extra { maxPct = max(maxPct, extra.percent) }

        return VendorUsage(
            vendor: .anthropic,
            plan: Support.sanitizeDisplay("Claude \(plan)"),
            headline: headline,
            gauges: gauges,
            severity: Support.severity(for: maxPct),
            available: true,
            footnote: extra.map { "Extra: \($0.line)" },
            compactHeadline: compact,
            accountLabel: accountLabel
        )
    }

    private static func gauge(_ label: String, _ w: Window, windowDuration: TimeInterval, now: Date) -> UsageGauge {
        UsageGauge(
            label: label,
            percent: Double(w.pct),
            caption: "resets \(Support.countdown(w.reset, now: now))",
            elapsedFraction: Support.elapsedFraction(reset: w.reset, window: windowDuration, now: now)
        )
    }

    private static func window(_ w: [String: Any]?) -> Window {
        guard let w else { return Window(pct: 0, reset: nil) }
        let pct = min(max(Int((JSON.double(w["utilization"]) ?? 0).rounded()), 0), 100)
        return Window(pct: pct, reset: Support.parseRFC3339(JSON.string(w["resets_at"])))
    }

    struct ScopedWindow {
        let label: String
        let window: Window
    }

    /// Lift `weekly_scoped` entries out of `limits[]`. An entry without a model
    /// display name or a percentage is dropped, not defaulted — a confident
    /// "Fable 0%" the API never sent is worse than no bar at all. Percentages
    /// far outside 0–100 are drift and drop the entry too.
    static func scopedWindows(_ raw: Any?) -> [ScopedWindow] {
        (JSON.array(raw) ?? []).compactMap { entry in
            guard let l = JSON.dict(entry),
                  JSON.string(l["kind"]) == "weekly_scoped",
                  let label = JSON.dict(JSON.dict(l["scope"])?["model"])
                      .flatMap({ JSON.string($0["display_name"]) }),
                  !label.isEmpty,
                  let percent = JSON.double(l["percent"]),
                  (0...101).contains(percent)
            else { return nil }
            return ScopedWindow(
                label: Support.sanitizeDisplay(label),
                window: Window(
                    pct: min(max(Int(percent.rounded()), 0), 100),
                    reset: Support.parseRFC3339(JSON.string(l["resets_at"]))
                )
            )
        }
    }

    struct ExtraUsage {
        let percent: Int
        let line: String
    }

    /// Pay-as-you-go spend. `monthly_limit: null` is semantic ("no cap", e.g.
    /// Claude Pro), not drift — the spend still renders, with no percentage
    /// invented. A block without `used_credits`, or with a malformed currency
    /// or scale, is dropped: without a truthful amount there is nothing to
    /// show (mirrors upstream v0.15).
    static func extraUsage(_ raw: Any?) -> ExtraUsage? {
        guard let extra = JSON.dict(raw), JSON.bool(extra["is_enabled"]),
              let spentRaw = JSON.double(extra["used_credits"]), spentRaw >= 0
        else { return nil }
        let spent = Int64(spentRaw.rounded())

        var limit: Int64?
        if extra["monthly_limit"] != nil, !(extra["monthly_limit"] is NSNull) {
            guard let l = JSON.double(extra["monthly_limit"]), l >= 0 else { return nil }
            limit = Int64(l.rounded())
        }

        var currency: String?
        if let c = JSON.string(extra["currency"]) {
            guard Support.isValidCurrencyCode(c) else { return nil }
            currency = c.uppercased()
        }
        var decimalPlaces: Int?
        if extra["decimal_places"] != nil, !(extra["decimal_places"] is NSNull) {
            guard let dp = JSON.int(extra["decimal_places"]), (0...6).contains(dp) else { return nil }
            decimalPlaces = dp
        }

        func amount(_ v: Int64) -> String {
            switch (decimalPlaces, currency) {
            case let (dp?, cur):    return Support.fmtMinor(v, decimalPlaces: dp, currency: cur)
            // Legacy payloads predate both fields and were always cents/USD.
            case (nil, nil):        return Support.fmtMinor(v, decimalPlaces: 2, currency: nil)
            // A code alone doesn't determine its minor-unit exponent — state
            // the raw value rather than corrupting the amount with a guess.
            case (nil, let cur?):   return Support.fmtMinorUnits(v, currency: cur)
            }
        }

        let percent = (limit.map { $0 > 0 ? Int((spent * 100) / $0) : 0 }) ?? 0
        let line: String
        if let limit {
            line = "\(amount(spent)) / \(amount(limit)) · \(percent)%"
        } else {
            line = "\(amount(spent)) (no cap)"
        }
        return ExtraUsage(percent: percent, line: line)
    }
}
