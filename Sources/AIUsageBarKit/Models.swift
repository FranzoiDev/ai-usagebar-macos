import Foundation

/// Usage-severity buckets (`low`/`mid`/`high`/`critical`), derived from each
/// vendor's pacing/threshold math in `Native/`.
public enum Severity: String, Sendable {
    case low
    case mid
    case high
    case critical
}

/// A single progress bar: a label, its percentage, and a caption underneath.
public struct UsageGauge: Identifiable, Sendable {
    public let label: String
    /// 0–100. May exceed 100 when a window is over its limit.
    public let percent: Double
    public let caption: String
    /// How much of the gauge's time window has elapsed (0–1), or nil for
    /// windows with no reset — drives the pace marker (upstream's "meta
    /// reference"): fill up to the marker is on-pace, past it is overshoot.
    public let elapsedFraction: Double?

    public var id: String { label }

    /// Clamped 0–1 value for `ProgressView`.
    public var fraction: Double { max(0, min(percent / 100, 1)) }

    /// Pace rendering: fill up to the marker stays in the calm color, only the
    /// overshoot past it (how far ahead of pace the window is) is painted in
    /// the warning color. Nil when the window has no reset.
    public var paceSplit: (calm: Double, overshoot: Double)? {
        guard let elapsed = elapsedFraction else { return nil }
        return (min(fraction, elapsed), max(0, fraction - elapsed))
    }

    public init(label: String, percent: Double, caption: String, elapsedFraction: Double? = nil) {
        self.label = label
        self.percent = percent
        self.caption = caption
        self.elapsedFraction = elapsedFraction.map { max(0, min($0, 1)) }
    }
}

/// A vendor's resolved usage, ready to render.
public struct VendorUsage: Identifiable, Sendable {
    public let vendor: Vendor
    /// Plan label including the brand + tier, e.g. "Claude Pro", "ChatGPT Plus",
    /// "GLM Coding Pro" — shown as the row title (mirrors the waybar tooltip
    /// header). Falls back to `vendor.displayName` when empty.
    public let plan: String
    /// Compact one-liner (also feeds the menu bar title).
    public let headline: String
    /// Progress bars to draw (empty for balance-only vendors like DeepSeek).
    public let gauges: [UsageGauge]
    public let severity: Severity
    /// False when the vendor is disabled, unauthenticated, or the fetch failed
    /// with no usable cache — the UI filters these rows out.
    public let available: Bool
    /// Extra caption under the gauges (e.g. Anthropic's pay-as-you-go spend:
    /// "Extra: R$141.57 / R$500.00").
    public let footnote: String?
    /// Compact summary for the menu bar title ("42% 2h"); falls back to
    /// `headline` when nil.
    public let compactHeadline: String?
    /// Distinguishes rows of the same vendor (named Anthropic accounts,
    /// Claude Desktop profiles). Empty for the default single-account row.
    public let accountLabel: String
    /// True when this row is a preserved last-good snapshot after a failed
    /// refresh (the UI marks it instead of dropping the row).
    public var isStale: Bool

    public var id: String { accountLabel.isEmpty ? vendor.id : "\(vendor.id)@\(accountLabel)" }

    /// The row title: the plan label, or the vendor's display name as a fallback.
    public var title: String {
        let base = plan.isEmpty ? vendor.displayName : plan
        return accountLabel.isEmpty ? base : "\(base) · \(accountLabel)"
    }

    public init(vendor: Vendor, plan: String = "", headline: String, gauges: [UsageGauge],
                severity: Severity, available: Bool, footnote: String? = nil,
                compactHeadline: String? = nil, accountLabel: String = "", isStale: Bool = false) {
        self.vendor = vendor
        self.plan = plan
        self.headline = headline
        self.gauges = gauges
        self.severity = severity
        self.available = available
        self.footnote = footnote
        self.compactHeadline = compactHeadline
        self.accountLabel = accountLabel
        self.isStale = isStale
    }
}
