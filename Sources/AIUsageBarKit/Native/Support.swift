import Foundation

/// Shared primitives ported from the upstream `ai-usagebar` Rust crate so the
/// data collection runs entirely in-process (no subprocess). These mirror
/// `countdown.rs`, `pango::severity_for`, and the small format helpers.
public enum Support {
    // MARK: - Countdown (mirrors src/countdown.rs)

    /// Human-readable countdown between `now` and `reset`.
    ///   nil reset → "—"; past → "now"; ≥1d → "{d}d {h}h"; else "{h}h {mm}m".
    public static func countdown(_ reset: Date?, now: Date = Date()) -> String {
        guard let reset else { return "—" }
        let secs = Int(reset.timeIntervalSince(now))
        if secs <= 0 { return "now" }
        let days = secs / 86_400
        let hours = (secs % 86_400) / 3_600
        let mins = (secs % 3_600) / 60
        if days > 0 {
            return "\(days)d \(hours)h"
        }
        return "\(hours)h \(String(format: "%02d", mins))m"
    }

    // MARK: - Severity (mirrors src/pango.rs `severity_for`)

    /// Map a usage percentage to a severity tier:
    ///   ≥90 critical · ≥75 high · ≥50 mid · else low.
    public static func severity(for pct: Int) -> Severity {
        if pct >= 90 { return .critical }
        if pct >= 75 { return .high }
        if pct >= 50 { return .mid }
        return .low
    }

    /// Uppercase the first character only ("pro" → "Pro", "" → "").
    public static func capitalizeFirst(_ s: String) -> String {
        guard let first = s.first else { return "" }
        return first.uppercased() + s.dropFirst()
    }

    // MARK: - Money

    /// `$D.CC`, with a leading sign for negatives ("-$1.50", never "$-1.50").
    public static func money(_ v: Double) -> String {
        if v < 0 { return String(format: "-$%.2f", -v) }
        return String(format: "$%.2f", v)
    }

    /// Currency-aware money used by DeepSeek (USD `$`, CNY `¥`, else suffix).
    public static func money(_ v: Double, currency: String) -> String {
        switch currency {
        case "USD": return String(format: "$%.2f", v)
        case "CNY": return String(format: "¥%.2f", v)
        default:    return String(format: "%.2f %@", v, currency)
        }
    }

    // MARK: - Date parsing

    private static let rfc3339: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let rfc3339Frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Parse an RFC3339 timestamp like "2026-05-23T17:30:00Z" → Date (nil on
    /// failure), accepting an optional fractional-seconds component.
    public static func parseRFC3339(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return rfc3339.date(from: s) ?? rfc3339Frac.date(from: s)
    }
}

// MARK: - Lenient JSON accessors

/// Helpers that mirror serde's "accept int or float / null → default" leniency
/// when reading the undocumented vendor responses with `JSONSerialization`.
public enum JSON {
    public static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public static func dict(_ v: Any?) -> [String: Any]? { v as? [String: Any] }
    public static func array(_ v: Any?) -> [Any]? { v as? [Any] }

    public static func string(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    public static func double(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    public static func int(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let d = double(v) { return Int(d) }
        return nil
    }

    public static func bool(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        return false
    }
}

// MARK: - HTTP

/// Errors surfaced by the native fetchers. `http` carries a status + short body
/// (used to decide stale-cache fallback); `transport` is a network/timeout
/// failure; `credentials` means the user must re-authenticate.
public enum FetchError: Error {
    case http(status: Int, body: String)
    case transport(String)
    case credentials(String)
    case schema(String)

    /// True for failures that should silently reuse cache (no error surfaced).
    var isTransient: Bool {
        switch self {
        case .transport: return true
        default: return false
        }
    }
}

/// Minimal async URLSession wrapper with a per-request timeout.
public enum HTTP {
    public struct Response: Sendable {
        public let status: Int
        public let body: Data
        public var isSuccess: Bool { (200..<300).contains(status) }
    }

    public static func get(
        _ url: URL,
        headers: [String: String],
        timeout: TimeInterval = 10
    ) async throws -> Response {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return try await send(req)
    }

    public static func postJSON(
        _ url: URL,
        headers: [String: String],
        body: [String: Any],
        timeout: TimeInterval = 25
    ) async throws -> Response {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    private static func send(_ req: URLRequest) async throws -> Response {
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return Response(status: status, body: data)
        } catch {
            throw FetchError.transport(error.localizedDescription)
        }
    }
}
