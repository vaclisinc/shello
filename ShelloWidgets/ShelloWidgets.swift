import ActivityKit
import SwiftUI
import WidgetKit

@main
struct ShelloWidgets: WidgetBundle {
    var body: some Widget {
        ConnectionActivity()
    }
}

/// Shello's colors, kept local so the extension doesn't pull in the app's theme.
private enum Palette {
    static let yellow = Color(red: 0xFD / 255, green: 0xBE / 255, blue: 0x3B / 255)
    static let coral = Color(red: 1, green: 0x71 / 255, blue: 0x69 / 255)
    static let sky = Color(red: 0x6F / 255, green: 0xC2 / 255, blue: 1)
    static let mint = Color(red: 0x38 / 255, green: 0xC9 / 255, blue: 0x8B / 255)
}

struct ConnectionActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ShelloActivityAttributes.self) { context in
            LockScreenView(state: context.shown, title: context.title, stale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.35))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.shown
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Prompt().padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Counts(state: state).padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.title).font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HostRows(hosts: state.hosts, limit: 3, stale: context.isStale).padding(.top, 4)
                }
            } compactLeading: {
                Prompt()
            } compactTrailing: {
                if state.waiting > 0 {
                    Text("\(state.waiting)")
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(Palette.coral)
                } else if state.working > 0 {
                    Image(systemName: "ellipsis").foregroundStyle(Palette.sky)
                } else {
                    Circle().fill(state.connections > 0 ? Palette.mint : .gray).frame(width: 8, height: 8)
                }
            } minimal: {
                Prompt()
            }
            .keylineTint(Palette.yellow)
        }
    }
}

private extension ActivityViewContext where Attributes == ShelloActivityAttributes {
    /// Past its stale date the app stopped updating (suspended or killed), so the last
    /// counts and connections are no longer true: show the hosts as unwatched.
    var shown: ShelloActivityAttributes.ContentState {
        guard isStale else { return state }
        return .init(hosts: state.hosts.map { .init(name: $0.name, connected: false, working: 0, waiting: 0) })
    }

    var title: String { isStale ? "Not monitoring" : state.title }
}

/// The `>_` mark from the app icon.
private struct Prompt: View {
    var body: some View {
        Text(">_")
            .font(.system(.body, design: .monospaced).weight(.heavy))
            .foregroundStyle(Palette.yellow)
    }
}

private struct Counts: View {
    let state: ShelloActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 8) {
            if state.waiting > 0 {
                Label("\(state.waiting)", systemImage: "hand.raised.fill").foregroundStyle(Palette.coral)
            }
            if state.working > 0 {
                Label("\(state.working)", systemImage: "gearshape.2").foregroundStyle(Palette.sky)
            }
        }
        .font(.caption.monospacedDigit().bold())
        .labelStyle(.titleAndIcon)
    }
}

private struct HostRows: View {
    let hosts: [ShelloActivityAttributes.Host]
    let limit: Int
    var stale = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(hosts.prefix(limit).enumerated()), id: \.offset) { _, host in
                HStack(spacing: 8) {
                    Rectangle()
                        .fill(host.connected ? Palette.mint : .gray)
                        .frame(width: 8, height: 8)
                    Text(host.name).font(.subheadline.weight(.medium)).lineLimit(1)
                    Spacer()
                    if host.waiting > 0 {
                        Text("\(host.waiting) waiting").font(.caption.bold()).foregroundStyle(Palette.coral)
                    } else if host.working > 0 {
                        Text("\(host.working) working").font(.caption.bold()).foregroundStyle(Palette.sky)
                    } else if !host.connected {
                        Text(stale ? "open Shello" : "reconnecting").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if hosts.count > limit {
                Text("+\(hosts.count - limit) more").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct LockScreenView: View {
    let state: ShelloActivityAttributes.ContentState
    let title: String
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(">_")
                    .font(.system(size: 15, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.black)
                    .frame(width: 30, height: 30)
                    .background(Palette.yellow)
                    .overlay(Rectangle().strokeBorder(.white.opacity(0.8), lineWidth: 1.5))
                Text(title).font(.headline)
                Spacer()
                Counts(state: state)
            }
            HostRows(hosts: state.hosts, limit: 4, stale: stale)
        }
        .foregroundStyle(.white)
        .padding(16)
    }
}
