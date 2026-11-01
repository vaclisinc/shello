import ActivityKit
import Foundation
import HerdrKit
import UIKit

/// Keeps one Live Activity in sync with the open sessions: it appears with the first
/// connection, shows each host's agents, and ends when nothing is connected anymore.
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    private var activity: Activity<ShelloActivityAttributes>?
    private var lastState: ShelloActivityAttributes.ContentState?
    private var heartbeat: Task<Void, Never>?

    /// With no update for this long the activity shows as not monitoring: the app was
    /// suspended or killed and can no longer watch agents or post alerts.
    private static let staleAfter: TimeInterval = 15 * 60
    /// Pushes the stale date forward while the app is still running.
    private static let heartbeatInterval: Duration = .seconds(5 * 60)

    private init() {
        // A fresh launch has no connections yet, so anything left from a previous run
        // (e.g. after iOS ended the app) is stale: remove it rather than show a fake session.
        for leftover in Activity<ShelloActivityAttributes>.activities {
            Task { await leftover.end(nil, dismissalPolicy: .immediate) }
        }
        // Swiping the app away while it runs in the background (e.g. kept alive by location)
        // lands here; once it's gone nothing would update or end the activity.
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LiveActivityController.shared.endBeforeTermination() }
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
        push(state)
    }

    private func push(_ state: ShelloActivityAttributes.ContentState) {
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter))
        if let activity, activity.activityState == .active {
            Task { await activity.update(content) }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            activity = try? Activity.request(attributes: ShelloActivityAttributes(), content: content)
        }
        startHeartbeat()
    }

    /// Only runs while the app does, so a suspended or killed app lets the activity go stale.
    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                guard !Task.isCancelled, let self, let state = self.lastState else { return }
                self.push(state)
            }
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
        heartbeat?.cancel()
        heartbeat = nil
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// The process exits right after `willTerminate`, so wait (briefly) for the end to go through.
    private func endBeforeTermination() {
        let activities = Activity<ShelloActivityAttributes>.activities
        end()
        guard !activities.isEmpty else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for activity in activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }
}
