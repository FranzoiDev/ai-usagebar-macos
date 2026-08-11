import CryptoKit
import Foundation

/// macOS login-Keychain access for the Claude Code OAuth blob, ported from
/// upstream `src/anthropic/keychain.rs`.
///
/// Recent Claude Code builds store the same `{ "claudeAiOauth": …, "mcpOAuth":
/// … }` JSON as a generic-password item (service `Claude Code-credentials`)
/// instead of writing `~/.claude/.credentials.json`. We shell out to the
/// built-in `security(1)` tool — the same approach the upstream CLI took — so
/// no extra entitlements or Security.framework glue are required.
public enum Keychain {
    public static let service = "Claude Code-credentials"

    /// `security(1)` exit code for `errSecItemNotFound`.
    static let itemNotFoundExit: Int32 = 44

    /// Outcome of a Keychain read. A locked Keychain or a denied ACL is not
    /// the same as "not logged in" — only exit code 44 means the item is
    /// genuinely absent; anything else surfaces so the user isn't told to
    /// re-authenticate over credentials that are sitting there intact.
    public enum ReadResult {
        case found(String)
        case notFound
        case failure(String)
    }

    private static var account: String {
        ProcessInfo.processInfo.environment["USER"] ?? ""
    }

    /// Per-account service name for a `CLAUDE_CONFIG_DIR`-scoped login:
    /// `Claude Code-credentials-<hash8>` where hash8 is the first 8 hex chars
    /// of SHA-256 over the directory path string. Deliberately NO path
    /// normalization (no symlink resolution, no standardization) — Claude
    /// Code hashes the literal string, and the names must match.
    public static func serviceName(forConfigDir dir: String) -> String {
        let digest = SHA256.hash(data: Data(dir.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(service)-\(hex.prefix(8))"
    }

    /// Read an arbitrary generic password selected by service alone (no `-a`),
    /// e.g. Claude Desktop's `Claude Safe Storage` key.
    public static func readPassword(service: String) -> String? {
        let run = runSecurity(["find-generic-password", "-s", service, "-w"])
        guard run.status == 0 else { return nil }
        let value = run.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Read the raw credentials JSON from a specific service item.
    public static func read(service: String = service) -> ReadResult {
        var args = ["find-generic-password", "-s", service, "-w"]
        if !account.isEmpty { args.append(contentsOf: ["-a", account]) }
        let run = runSecurity(args)
        guard run.status == 0 else {
            if run.status == itemNotFoundExit { return .notFound }
            let detail = run.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(
                "could not read the Claude credentials from the macOS Keychain "
                + "(security exited \(run.status)): \(detail). If the login Keychain is "
                + "locked, unlock it and retry; if access was denied, allow AI UsageBar when prompted."
            )
        }
        let value = run.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? .notFound : .found(value)
    }

    /// Back-compat convenience: the raw JSON, or nil when absent or unreadable.
    public static func readRaw() -> String? {
        if case .found(let raw) = read() { return raw }
        return nil
    }

    /// Persist updated credentials back into the same item (`-U` updates in
    /// place), so the app and Claude Code keep sharing one source of truth.
    @discardableResult
    public static func writeRaw(_ json: String, service: String = service) -> Bool {
        var args = ["add-generic-password", "-U", "-s", service]
        if !account.isEmpty { args.append(contentsOf: ["-a", account]) }
        args.append(contentsOf: ["-w", json])
        return runSecurity(args).status == 0
    }

    private struct RunResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private static func runSecurity(_ arguments: [String]) -> RunResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        do {
            try proc.run()
            let out = stdout.fileHandleForReading.readDataToEndOfFile()
            let err = stderr.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return RunResult(
                status: proc.terminationStatus,
                stdout: String(data: out, encoding: .utf8) ?? "",
                stderr: String(data: err, encoding: .utf8) ?? ""
            )
        } catch {
            return RunResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }
    }
}
