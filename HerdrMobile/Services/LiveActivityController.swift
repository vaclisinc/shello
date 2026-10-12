import ActivityKit
import Foundation
import HerdrKit

/// Keeps one Live Activity in sync with the open sessions: it appears with the first
/// connection, shows each host's agents, and ends when nothing is connected anymore.
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    private var activity: Activity<ShelloActivityAttributes>?
    private var lastState: ShelloActivityAttributes.ContentState?

    private init() {
        // A fresh launch has no connections yet, so anything left from a previous run
        // (e.g. after iOS ended the app) is stale: remove it rather than show a fake session.
        for leftover in Activity<ShelloActivityAttributes>.activities {
            Task { await leftover.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func update(sessions: [TerminalSession]) {
        let wanted = sessions.filter(\.wantsConnection)
        guard !wanted.isEmpty else {
            end()
            return
        }
        let state = ShelloActivityAttributes.ContentState(hosts: wanted.map { session in
            let agents = session.snapshot?.agents ?? []
            return ShelloActivityAttributes.Host(
                name: session.profile.displayName,
                connected: session.state == .connected,
                working: agents.filter { $0.agentStatus == .working }.count,
                waiting: agents.filter { $0.agentStatus == .blocked }.count
            )
        })
        guard state != lastState else { return }
        lastState = state
        let content = ActivityContent(state: state, staleDate: nil)

        if let activity, activity.activityState == .active {
            Task { await activity.update(content) }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            activity = try? Activity.request(attributes: ShelloActivityAttributes(), content: content)
        }
    }

    #if DEBUG
    /// `-liveActivityDemo`: show the activity with sample hosts.
    func demo() {
        let state = ShelloActivityAttributes.ContentState(hosts: [
            .init(name: "BAIR", connected: true, working: 1, waiting: 1),
            .init(name: "NTU2", connected: true, working: 0, waiting: 0),
        ])
        do {
            activity = try Activity.request(attributes: ShelloActivityAttributes(), content: ActivityContent(state: state, staleDate: nil))
            NSLog("SHELLO-LA started \(activity?.id ?? "-") enabled=\(ActivityAuthorizationInfo().areActivitiesEnabled)")
        } catch {
            NSLog("SHELLO-LA failed \(error) enabled=\(ActivityAuthorizationInfo().areActivitiesEnabled)")
        }
    }
    #endif

    func end() {
        lastState = nil
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
