import Foundation

extension VendorUsage {
    /// A row for a vendor that is disabled, unauthenticated, or whose fetch
    /// failed with no usable cache. `UsageStore` filters these out.
    static func unavailable(_ vendor: Vendor, accountLabel: String = "") -> VendorUsage {
        VendorUsage(vendor: vendor, headline: "—", gauges: [], severity: .low,
                    available: false, accountLabel: accountLabel)
    }
}

/// A usage window projected from a vendor response: integer percent + reset.
struct Window {
    var pct: Int
    var reset: Date?
}
