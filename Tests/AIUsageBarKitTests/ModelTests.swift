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
}
