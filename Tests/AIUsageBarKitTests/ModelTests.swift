import XCTest
@testable import AIUsageBarKit

final class ModelTests: XCTestCase {
    func testSeverityRawValues() {
        XCTAssertEqual(Severity(rawValue: "mid"), .mid)
        XCTAssertEqual(Severity(rawValue: "critical"), .critical)
        XCTAssertNil(Severity(rawValue: "nope"))
    }

    func testVendorShortCodeRoundTrip() {
        for vendor in Vendor.allCases {
            XCTAssertEqual(Vendor.from(shortCode: vendor.shortCode), vendor)
        }
    }

    func testGaugeFractionIsClamped() {
        XCTAssertEqual(UsageGauge(label: "x", percent: 150, caption: "").fraction, 1)
        XCTAssertEqual(UsageGauge(label: "x", percent: -5, caption: "").fraction, 0)
        XCTAssertEqual(UsageGauge(label: "x", percent: 50, caption: "").fraction, 0.5)
    }

    func testPaceSplit() {
        // 41% used, 20% elapsed → calm 20%, overshoot 21% (the red tail).
        let ahead = UsageGauge(label: "x", percent: 41, caption: "", elapsedFraction: 0.2)
        XCTAssertEqual(ahead.paceSplit!.calm, 0.2, accuracy: 0.0001)
        XCTAssertEqual(ahead.paceSplit!.overshoot, 0.21, accuracy: 0.0001)
        // Under pace → all calm, no overshoot.
        let under = UsageGauge(label: "x", percent: 10, caption: "", elapsedFraction: 0.5)
        XCTAssertEqual(under.paceSplit!.calm, 0.1, accuracy: 0.0001)
        XCTAssertEqual(under.paceSplit!.overshoot, 0)
        // No reset → no marker.
        XCTAssertNil(UsageGauge(label: "x", percent: 10, caption: "").paceSplit)
    }

    func testStaleRowKeepsIdentityAndTitle() {
        var row = VendorUsage(vendor: .anthropic, plan: "Claude Pro", headline: "1%",
                              gauges: [], severity: .low, available: true)
        row.isStale = true
        XCTAssertEqual(row.id, "anthropic")
        XCTAssertEqual(row.title, "Claude Pro")
        let named = VendorUsage(vendor: .anthropic, plan: "Claude Max 20x", headline: "1%",
                                gauges: [], severity: .low, available: true, accountLabel: "work")
        XCTAssertEqual(named.id, "anthropic@work")
        XCTAssertEqual(named.title, "Claude Max 20x · work")
    }
}
