import Foundation

/// Native Anthropic fetcher — ports `src/anthropic/fetch.rs`. Reads creds →
/// refreshes if near expiry → GETs the undocumented OAuth usage endpoint →
/// caches the payload, falling back to the last good payload on failure.
public enum AnthropicProvider {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let usageBeta = "oauth-2025-04-20"

    public static func fetch(config: AppConfig, now: Date = Date()) async -> VendorUsage {
        let path = AnthropicCreds.defaultPath(config.anthropicCredentialsPath)
        guard var creds = try? AnthropicCreds.read(path: path) else {
            return .unavailable(.anthropic)
        }
        let planLabel = creds.planLabel
        let cache = DiskCache(vendor: "anthropic")

        // Fast path: serve a fresh cached payload.
        if let bytes = cache.freshPayload(ttl: DiskCache.defaultTTL) {
            return render(bytes, plan: planLabel, now: now)
        }

        // Maybe refresh the access token.
        let nowSecs = Int64(now.timeIntervalSince1970)
        if AnthropicOAuth.needsRefresh(expiresAtSecs: creds.expiresAtSecs, now: nowSecs) {
            do {
                let r = try await AnthropicOAuth.refresh(refreshToken: creds.refreshToken)
                creds.accessToken = r.accessToken
                if let rt = r.refreshToken { creds.refreshToken = rt }
                creds.expiresAtMs = Int64(now.timeIntervalSince1970 * 1000) + r.expiresInSecs * 1000
                creds.writeBack(path: path)
            } catch {
                // Refresh failed — reuse cache if we have any, else unavailable.
                if let bytes = cache.maybePayload() { return render(bytes, plan: planLabel, now: now) }
                return .unavailable(.anthropic)
            }
        }

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
            return render(resp.body, plan: planLabel, now: now)
        } catch {
            if let bytes = cache.maybePayload() { return render(bytes, plan: planLabel, now: now) }
            return .unavailable(.anthropic)
        }
    }

    // MARK: - Rendering

    private static func render(_ bytes: Data, plan: String, now: Date) -> VendorUsage {
        guard let doc = JSON.object(bytes) else { return .unavailable(.anthropic) }

        let session = window(JSON.dict(doc["five_hour"]))
        let weekly = window(JSON.dict(doc["seven_day"]))
        let sonnet = doc["seven_day_sonnet"] != nil ? window(JSON.dict(doc["seven_day_sonnet"])) : nil

        var extraPct: Int?
        var extraAtCapRelevant = false
        if let extra = JSON.dict(doc["extra_usage"]), JSON.bool(extra["is_enabled"]) {
            let limit = JSON.int(extra["monthly_limit"]) ?? 0
            let spent = JSON.int(extra["used_credits"]) ?? 0
            extraPct = limit <= 0 ? 0 : (spent * 100) / limit
            extraAtCapRelevant = true
        }

        let headline = "\(session.pct)% · \(Support.countdown(session.reset, now: now))"
        let gauges = [
            UsageGauge(label: "Session", percent: Double(session.pct),
                       caption: "resets \(Support.countdown(session.reset, now: now))"),
            UsageGauge(label: "Weekly", percent: Double(weekly.pct),
                       caption: "resets \(Support.countdown(weekly.reset, now: now))"),
        ]

        // Worst-of severity (mirrors usage::anthropic_severity).
        var maxPct = max(session.pct, weekly.pct)
        if let s = sonnet { maxPct = max(maxPct, s.pct) }
        let anyAtCap = session.pct >= 100 || weekly.pct >= 100 || (sonnet?.pct ?? 0) >= 100
        if anyAtCap && extraAtCapRelevant, let ep = extraPct { maxPct = max(maxPct, ep) }

        return VendorUsage(
            vendor: .anthropic,
            plan: "Claude \(plan)",
            headline: headline,
            gauges: gauges,
            severity: Support.severity(for: maxPct),
            available: true
        )
    }

    private static func window(_ w: [String: Any]?) -> (pct: Int, reset: Date?) {
        guard let w else { return (0, nil) }
        let pct = Int((JSON.double(w["utilization"]) ?? 0).rounded())
        return (pct, Support.parseRFC3339(JSON.string(w["resets_at"])))
    }
}
