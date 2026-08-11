import CryptoKit
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

    /// Countdown squeezed to its leading unit for the menu bar title
    /// (mirrors the upstream v0.18 bar title): "4d", "2h", "5m", "now".
    public static func shortCountdown(_ reset: Date?, now: Date = Date()) -> String {
        guard let reset else { return "" }
        let secs = Int(reset.timeIntervalSince(now))
        if secs <= 0 { return "now" }
        if secs >= 86_400 { return "\(secs / 86_400)d" }
        if secs >= 3_600 { return "\(secs / 3_600)h" }
        return "\(max(secs / 60, 1))m"
    }

    // MARK: - Pacing (mirrors src/pacing.rs `calc_pacing` elapsed math)

    /// Fraction (0–1) of a window that has elapsed, from its reset time and
    /// total duration. Nil when there is no reset — a marker there would be a
    /// guess (upstream suppresses it too).
    public static func elapsedFraction(reset: Date?, window: TimeInterval, now: Date = Date()) -> Double? {
        guard let reset, window > 0 else { return nil }
        let remaining = reset.timeIntervalSince(now)
        return max(0, min((window - remaining) / window, 1))
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

    /// Shared USD balance thresholds for the balance-only vendors (Kilo,
    /// Novita, Grok): below $1 the APIs start answering 402.
    public static func balanceSeverity(_ balance: Double) -> Severity {
        if balance < 1 { return .critical }
        if balance < 5 { return .high }
        if balance < 20 { return .mid }
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

    /// Format an amount in minor units with its own currency and scale
    /// (mirrors upstream `usage::fmt_minor`). Known codes get their symbol;
    /// anything else renders as "AMOUNT CODE", which is still truthful.
    public static func fmtMinor(_ minor: Int64, decimalPlaces: Int, currency: String?) -> String {
        let sign = minor < 0 ? "-" : ""
        let abs = minor.magnitude
        let number: String
        if decimalPlaces == 0 {
            number = "\(abs)"
        } else {
            let scale = UInt64(pow(10, Double(decimalPlaces)))
            number = "\(abs / scale)." + String(format: "%0\(decimalPlaces)llu", abs % scale)
        }
        switch currency {
        case nil, "USD": return "\(sign)$\(number)"
        case "BRL":      return "\(sign)R$\(number)"
        case "EUR":      return "\(sign)€\(number)"
        case "GBP":      return "\(sign)£\(number)"
        case "JPY", "CNY": return "\(sign)¥\(number)"
        case let other?: return "\(sign)\(number) \(other)"
        }
    }

    /// A currency whose minor-unit exponent the wire did not report: state the
    /// raw value rather than guessing a scale (mirrors `fmt_minor_units`).
    public static func fmtMinorUnits(_ minor: Int64, currency: String) -> String {
        let sign = minor < 0 ? "-" : ""
        return "\(sign)\(minor.magnitude) minor units \(currency)"
    }

    /// True for a plausible ISO 4217 alpha code (exactly 3 ASCII letters).
    /// Anything else is drift — and a potential injection vector, since these
    /// strings reach rendered UI (upstream gates the same way).
    public static func isValidCurrencyCode(_ s: String) -> Bool {
        s.count == 3 && s.allSatisfy { $0.isASCII && $0.isLetter }
    }

    /// Strip control characters (including ESC for ANSI sequences) from text
    /// that came off the wire before it reaches the UI (upstream v0.20.1).
    public static func sanitizeDisplay(_ s: String) -> String {
        String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
    }

    /// Short stable fingerprint of a secret for cache-target strings — never
    /// the secret itself. SHA-256 hex, first 16 chars.
    public static func keyFingerprint(_ secret: String) -> String {
        let digest = SHA256.hash(data: Data(secret.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
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

    /// True when both URLs share scheme, host, and effective port. Vendor
    /// requests carry non-standard credential headers (`x-api-key`,
    /// `Authorization` without cookies) that URLSession would forward on a
    /// redirect, so cross-origin hops are refused (upstream v0.20.1).
    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        func effectivePort(_ u: URL) -> Int {
            if let p = u.port { return p }
            switch u.scheme?.lowercased() {
            case "https": return 443
            case "http": return 80
            default: return -1
            }
        }
        return a.scheme?.lowercased() == b.scheme?.lowercased()
            && a.host?.lowercased() == b.host?.lowercased()
            && effectivePort(a) == effectivePort(b)
    }

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let original = task.originalRequest?.url, let target = request.url,
                  HTTP.sameOrigin(original, target)
            else {
                // Refuse the hop: the 3xx response itself is returned, so no
                // credential header ever crosses the origin boundary.
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }

    private static let session = URLSession(
        configuration: .ephemeral,
        delegate: RedirectGuard(),
        delegateQueue: nil
    )

    private static func send(_ req: URLRequest) async throws -> Response {
        do {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return Response(status: status, body: data)
        } catch {
            throw FetchError.transport(error.localizedDescription)
        }
    }
}
