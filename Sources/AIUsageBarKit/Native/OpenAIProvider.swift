import Foundation

/// Native OpenAI Codex fetcher — ports `src/openai/fetch.rs`. Reads
/// `~/.codex/auth.json` → refreshes via the Codex OAuth flow → GETs the Codex
/// usage endpoint → caches, falling back to the last good payload on failure.
public enum OpenAIProvider {
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    public static func fetch(config: AppConfig, now: Date = Date()) async -> VendorUsage {
        let path = CodexCreds.defaultPath(config.codexAuthPath)
        guard let creds = try? CodexCreds.read(path: path) else {
            return .unavailable(.openai)
        }
        let cache = DiskCache(vendor: "openai")

        let planHint = creds.planType
        if let bytes = cache.freshPayload(ttl: DiskCache.defaultTTL) {
            return render(bytes, planHint: planHint, now: now)
        }

        // Read-only on credentials: never refresh the OAuth token ourselves.
        // Codex rotates refresh tokens, so refreshing here would invalidate the
        // copy the `codex` CLI holds in memory and log the user out (see
        // writeBack/CodexOAuth, kept for reference but intentionally not
        // invoked). We let `codex` own token rotation and ride along with
        // whatever access token it has persisted. If that token is expired the
        // live fetch below 401s and we fall back to cache / unavailable until
        // the CLI refreshes it.

        do {
            var headers = [
                "Authorization": "Bearer \(creds.accessToken)",
                "User-Agent": "codex-cli",
            ]
            if let aid = creds.accountId { headers["ChatGPT-Account-Id"] = aid }
            let resp = try await HTTP.get(usageURL, headers: headers)
            guard resp.isSuccess else { throw FetchError.http(status: resp.status, body: "") }
            cache.writePayload(resp.body)
            return render(resp.body, planHint: planHint, now: now)
        } catch {
            if let bytes = cache.maybePayload() { return render(bytes, planHint: planHint, now: now) }
            return .unavailable(.openai)
        }
    }

    private static func render(_ bytes: Data, planHint: String?, now: Date) -> VendorUsage {
        guard let doc = JSON.object(bytes) else { return .unavailable(.openai) }
        let planType = JSON.string(doc["plan_type"]) ?? planHint ?? "Unknown"
        let plan = "ChatGPT \(Support.capitalizeFirst(planType))"
        let rl = JSON.dict(doc["rate_limit"]) ?? [:]
        let session = window(JSON.dict(rl["primary_window"]), now: now)
        let weekly = window(JSON.dict(rl["secondary_window"]), now: now)
        let codeReview = window(JSON.dict(JSON.dict(doc["code_review_rate_limit"])?["primary_window"]), now: now)

        let headline = "\(session.pct)% · \(Support.countdown(session.reset, now: now))"
        let gauges = [
            UsageGauge(label: "Session", percent: Double(session.pct),
                       caption: "resets \(Support.countdown(session.reset, now: now))"),
            UsageGauge(label: "Weekly", percent: Double(weekly.pct),
                       caption: "resets \(Support.countdown(weekly.reset, now: now))"),
        ]
        let maxPct = max(session.pct, weekly.pct, codeReview.pct)

        return VendorUsage(
            vendor: .openai,
            plan: plan,
            headline: headline,
            gauges: gauges,
            severity: Support.severity(for: maxPct),
            available: true
        )
    }

    private static func window(_ w: [String: Any]?, now: Date) -> Window {
        guard let w else { return Window(pct: 0, reset: nil) }
        let pct = min(max(JSON.int(w["used_percent"]) ?? 0, 0), 100)
        var reset: Date?
        if let secs = JSON.int(w["reset_at"]) {
            reset = Date(timeIntervalSince1970: TimeInterval(secs))
        } else if let after = JSON.int(w["reset_after_seconds"]) {
            reset = now.addingTimeInterval(TimeInterval(after))
        }
        return Window(pct: pct, reset: reset)
    }
}
