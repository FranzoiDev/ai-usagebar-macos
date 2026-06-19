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

    public var id: String { label }

    /// Clamped 0–1 value for `ProgressView`.
    public var fraction: Double { max(0, min(percent / 100, 1)) }

    public init(label: String, percent: Double, caption: String) {
        self.label = label
        self.percent = percent
        self.caption = caption
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

    public var id: String { vendor.id }

    /// The row title: the plan label, or the vendor's display name as a fallback.
    public var title: String { plan.isEmpty ? vendor.displayName : plan }

    public init(vendor: Vendor, plan: String = "", headline: String, gauges: [UsageGauge], severity: Severity, available: Bool) {
        self.vendor = vendor
        self.plan = plan
        self.headline = headline
        self.gauges = gauges
        self.severity = severity
        self.available = available
    }
}
