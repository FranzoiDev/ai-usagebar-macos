import Foundation

/// Native OpenAI Codex fetcher — ports `src/openai/fetch.rs`. Reads
/// `~/.codex/auth.json` → GETs the Codex usage endpoint → caches, falling back
/// to the last good payload on failure.
public enum OpenAIProvider {
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    /// `limit_window_seconds` the Codex API reports for the 5h / 7d windows.
    static let sessionWindowSecs = 18_000
    static let weeklyWindowSecs = 604_800

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
            if let bytes = cache.maybePayload() {
                var row = render(bytes, planHint: planHint, now: now)
                row.isStale = true
                return row
            }
            return .unavailable(.openai)
        }
    }

    static func render(_ bytes: Data, planHint: String?, now: Date) -> VendorUsage {
        guard let doc = JSON.object(bytes) else { return .unavailable(.openai) }
        let planType = JSON.string(doc["plan_type"]) ?? planHint ?? "Unknown"
        let plan = Support.sanitizeDisplay("ChatGPT \(Support.capitalizeFirst(planType))")

        // Wire position is not semantic: during the July 2026 rollout OpenAI
        // moved the 7d window into `primary_window` and omitted
        // `secondary_window` (openai/codex#32707). Classify each window by its
        // `limit_window_seconds`, falling back to position only when the
        // duration is unknown; absent windows stay absent instead of becoming
        // a fabricated 0% gauge. A duplicate kind is schema drift.
        guard let (session, weekly) = classify(JSON.dict(doc["rate_limit"]) ?? [:], now: now) else {
            return .unavailable(.openai)
        }
        let codeReview = JSON.dict(JSON.dict(doc["code_review_rate_limit"])?["primary_window"])
            .map { window($0, now: now) }

        let lead = session ?? weekly
        let headline: String
        let compact: String
        if let lead {
            headline = "\(lead.pct)% · \(Support.countdown(lead.reset, now: now))"
            let c = Support.shortCountdown(lead.reset, now: now)
            compact = "\(lead.pct)%" + (c.isEmpty ? "" : " \(c)")
        } else {
            headline = "—"
            compact = "—"
        }

        var gauges: [UsageGauge] = []
        if let session {
            gauges.append(UsageGauge(
                label: "Session", percent: Double(session.pct),
                caption: "resets \(Support.countdown(session.reset, now: now))",
                elapsedFraction: Support.elapsedFraction(
                    reset: session.reset, window: TimeInterval(sessionWindowSecs), now: now)
            ))
        }
        if let weekly {
            gauges.append(UsageGauge(
                label: "Weekly", percent: Double(weekly.pct),
                caption: "resets \(Support.countdown(weekly.reset, now: now))",
                elapsedFraction: Support.elapsedFraction(
                    reset: weekly.reset, window: TimeInterval(weeklyWindowSecs), now: now)
            ))
        }
        let maxPct = max(session?.pct ?? 0, weekly?.pct ?? 0, codeReview?.pct ?? 0)

        return VendorUsage(
            vendor: .openai,
            plan: plan,
            headline: headline,
            gauges: gauges,
            severity: Support.severity(for: maxPct),
            available: true,
            compactHeadline: compact
        )
    }

    /// (session, weekly) from the two wire slots, classified semantically.
    /// Nil means drift (two windows of the same kind).
    static func classify(_ rateLimit: [String: Any], now: Date) -> (Window?, Window?)? {
        var session: Window?
        var weekly: Window?
        for (slot, fallbackIsSession) in [("primary_window", true), ("secondary_window", false)] {
            guard let w = JSON.dict(rateLimit[slot]) else { continue }
            let secs = JSON.int(w["limit_window_seconds"])
            let isSession: Bool
            if secs == sessionWindowSecs { isSession = true }
            else if secs == weeklyWindowSecs { isSession = false }
            else { isSession = fallbackIsSession }
            if isSession {
                guard session == nil else { return nil }
                session = window(w, now: now)
            } else {
                guard weekly == nil else { return nil }
                weekly = window(w, now: now)
            }
        }
        return (session, weekly)
    }

    private static func window(_ w: [String: Any], now: Date) -> Window {
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
