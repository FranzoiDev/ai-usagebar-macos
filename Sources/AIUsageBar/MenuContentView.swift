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
                    VendorRowView(
                        usage: usage,
                        showPaceMarker: store.showPaceMarker,
                        indicatorStyle: store.indicatorStyle,
                        isHidden: store.isHidden(usage.id),
                        onToggleHidden: { store.toggleHidden(usage.id) }
                    )
                    .opacity(store.isHidden(usage.id) ? 0.45 : 1)
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

/// One vendor row: name + compact headline, then a colored indicator per
/// gauge (Session / Weekly / Fable / …) and an optional footnote.
struct VendorRowView: View {
    let usage: VendorUsage
    let showPaceMarker: Bool
    let indicatorStyle: IndicatorStyle
    let isHidden: Bool
    let onToggleHidden: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(usage.title)
                    .font(.subheadline.weight(.semibold))
                if usage.isStale {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("Refresh failed — showing the last good data")
                }
                Spacer()
                Text(usage.headline)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(action: onToggleHidden) {
                    Image(systemName: isHidden ? "eye.slash" : "eye")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(isHidden ? "Show in the menu bar title" : "Hide from the menu bar title")
            }
            if indicatorStyle == .ring && !usage.gauges.isEmpty {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(usage.gauges) { gauge in
                        GaugeRingView(gauge: gauge, showPaceMarker: showPaceMarker)
                    }
                }
            } else {
                ForEach(usage.gauges) { gauge in
                    GaugeBarView(gauge: gauge, showPaceMarker: showPaceMarker)
                }
            }
            if let footnote = usage.footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Severity tint shared by the bar and ring styles. Local thresholds so each
/// gauge colors independently — the CLI's single `class` is an overall
/// severity, not per-window.
private func gaugeTint(_ percent: Double) -> Color {
    switch percent {
    case ..<60:  return .green
    case ..<80:  return .yellow
    case ..<95:  return .orange
    default:     return .red
    }
}

/// A single labeled progress bar, colored by how full it is, with the pace
/// marker: a tick at the elapsed-time position; fill up to it stays calm,
/// only the overshoot past it is painted in the warning color.
struct GaugeBarView: View {
    let gauge: UsageGauge
    var showPaceMarker: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(gauge.label)
                    .font(.caption)
                Spacer()
                Text("\(Int(gauge.percent.rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(gaugeTint(gauge.percent))
            }
            PaceBarView(
                fraction: gauge.fraction,
                elapsed: showPaceMarker ? gauge.elapsedFraction : nil,
                tint: gaugeTint(gauge.percent)
            )
            if !gauge.caption.isEmpty {
                Text(gauge.caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The bar itself. Without a marker it is a plain filled capsule; with one,
/// the fill splits at the marker into calm + overshoot segments.
struct PaceBarView: View {
    let fraction: Double
    let elapsed: Double?
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                if let elapsed {
                    let calm = min(fraction, elapsed)
                    let overshoot = max(0, fraction - elapsed)
                    if calm > 0 {
                        Rectangle().fill(tint).frame(width: w * calm)
                    }
                    if overshoot > 0 {
                        Rectangle().fill(Color.orange)
                            .frame(width: w * overshoot)
                            .offset(x: w * calm)
                    }
                    Rectangle().fill(Color.blue)
                        .frame(width: 1.5)
                        .offset(x: min(w * elapsed, w - 1.5))
                } else if fraction > 0 {
                    Rectangle().fill(tint).frame(width: w * fraction)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 5)
    }
}

/// Ring variant (upstream v0.17's "Estilo do indicador"): the usage fraction
/// as a severity-colored arc over a faint track, honoring the pace marker the
/// same way the bar does.
struct GaugeRingView: View {
    let gauge: UsageGauge
    var showPaceMarker: Bool = true

    private var tint: Color { gaugeTint(gauge.percent) }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.12), lineWidth: 4)
                if let split = showPaceMarker ? gauge.paceSplit : nil {
                    Circle()
                        .trim(from: 0, to: split.calm)
                        .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                    if split.overshoot > 0 {
                        Circle()
                            .trim(from: split.calm, to: split.calm + split.overshoot)
                            .stroke(Color.orange, style: StrokeStyle(lineWidth: 4, lineCap: .butt))
                            .rotationEffect(.degrees(-90))
                    }
                    if let elapsed = gauge.elapsedFraction {
                        Rectangle()
                            .fill(Color.blue)
                            .frame(width: 1.5, height: 6)
                            .offset(y: -14)
                            .rotationEffect(.degrees(elapsed * 360))
                    }
                } else {
                    Circle()
                        .trim(from: 0, to: gauge.fraction)
                        .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text("\(Int(gauge.percent.rounded()))")
                    .font(.caption2.monospacedDigit())
            }
            .frame(width: 28, height: 28)
            Text(gauge.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help("\(gauge.label): \(Int(gauge.percent.rounded()))% · \(gauge.caption)")
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
            Text("Other vendors use API keys via env vars or config.toml.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
