#if DEBUG
import HerdrKit
import SwiftUI

/// Launch with `-agentDetailHarness` (add `-focusPrompt` to raise the keyboard) to see the
/// agent sheet in the simulator without a server.
struct AgentDetailHarness: View {
    let app: AppModel
    @State private var showing = false
    @State private var host = HostProfile(name: "Harness", hostname: "localhost", username: "me")

    var body: some View {
        let session = app.session(for: host)
        Color(Theme.paper)
            .ignoresSafeArea()
            .onAppear {
                if ProcessInfo.processInfo.arguments.contains("-liveActivityDemo") {
                    LiveActivityController.shared.demo()
                }
                let json = #"{"agents":[{"terminal_id":"t1","agent":"claude","agent_status":"done","workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","focused":false,"cwd":"/tmp"}],"workspaces":[],"tabs":[],"panes":[],"version":"","protocol":0}"#
                if let snapshot = try? HerdrResponse.decoder().decode(SessionSnapshot.self, from: Data(json.utf8)) {
                    session.debugSetSnapshot(snapshot)
                }
                showing = true
            }
            .overlay {
                // Same path as the app: session screen (terminal holds the keyboard), then the
                // Agents tab opens the agent sheet.
                if showing {
                    NavigationStack { SessionView(session: session) }
                        .environmentObject(app)
                        .onAppear {
                            let args = ProcessInfo.processInfo.arguments
                            if args.contains("-lateNotificationTap") {
                                // Agents tab already open with an unchanged list, then a tap arrives.
                                session.requestedAgentPane = "nonexistent"
                                Task {
                                    try? await Task.sleep(for: .seconds(3))
                                    session.requestedAgentPane = "w1:p1"
                                }
                            } else if !args.contains("-terminalOnly") {
                                session.requestedAgentPane = "w1:p1"
                            }
                        }
                }
            }
    }
}
#endif
