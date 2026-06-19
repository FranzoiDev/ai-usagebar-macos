import SwiftUI
import AppKit
import AIUsageBarKit

/// The dropdown shown when the menu bar item is clicked.
struct MenuContentView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var loginItem: LoginItemManager

    /// Lazily created on first gear click; owns the desktop settings window.
    @State private var settingsController: SettingsWindowController?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.rows.isEmpty {
                if store.isRefreshing {
                    Text("Loading…")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    NotSignedInView()
                }
            } else {
                ForEach(store.rows) { usage in
                    VendorRowView(usage: usage)
                }
            }

            Divider()
            footer
        }
        .padding(12)
        .frame(width: 320)
    }

    private var footer: some View {
        HStack {
            Button {
                Task { await store.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(store.isRefreshing)

            Spacer()

            if let updated = store.lastUpdated {
                Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
            }
            .help("Settings")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
        }
    }

    /// Open (or focus) the settings window, creating its controller on first use.
    private func openSettings() {
        let controller = settingsController
            ?? SettingsWindowController(loginItem: loginItem, onSaved: { store.reloadConfig() })
        settingsController = controller
        controller.show()
    }
}

/// One vendor row: name + compact headline, then a colored progress bar per
/// gauge (Session / Weekly / …).
struct VendorRowView: View {
    let usage: VendorUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(usage.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(usage.headline)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ForEach(usage.gauges) { gauge in
                GaugeBarView(gauge: gauge)
            }
        }
    }
}

/// A single labeled progress bar, colored by how full it is.
struct GaugeBarView: View {
    let gauge: UsageGauge

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(gauge.label)
                    .font(.caption)
                Spacer()
                Text("\(Int(gauge.percent.rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(tint)
            }
            ProgressView(value: gauge.fraction)
                .tint(tint)
                .controlSize(.small)
            if !gauge.caption.isEmpty {
                Text(gauge.caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Local thresholds so each bar colors independently — the CLI's single
    /// `class` is an overall severity, not per-window.
    private var tint: Color {
        switch gauge.percent {
        case ..<60:  return .green
        case ..<80:  return .yellow
        case ..<95:  return .orange
        default:     return .red
        }
    }
}

/// Shown when no vendor is authenticated/configured, so there's nothing to show.
struct NotSignedInView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("No usage data", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.subheadline.weight(.semibold))
            Text("Sign in with the official CLIs once so the credentials exist:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("claude        # Anthropic")
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Text("codex login   # OpenAI")
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Text("Z.AI / OpenRouter / DeepSeek use API keys via env vars or config.toml.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
