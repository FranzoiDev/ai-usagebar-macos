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
    private static let service = "Claude Code-credentials"

    private static var account: String {
        ProcessInfo.processInfo.environment["USER"] ?? ""
    }

    /// Read the raw credentials JSON, or nil when no such item exists (so the
    /// caller can fall through to a "run `claude`" message).
    public static func readRaw() -> String? {
        var args = ["find-generic-password", "-s", service, "-w"]
        if !account.isEmpty { args.append(contentsOf: ["-a", account]) }
        guard let out = runSecurity(args) else { return nil }
        let value = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Persist updated credentials back into the same item (`-U` updates in
    /// place), so the app and Claude Code keep sharing one source of truth.
    @discardableResult
    public static func writeRaw(_ json: String) -> Bool {
        runSecurity([
            "add-generic-password", "-U",
            "-s", service,
            "-a", account,
            "-w", json,
        ]) != nil
    }

    private static func runSecurity(_ arguments: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = arguments
        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = Pipe()
        do {
            try proc.run()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return nil
        }
    }
}
