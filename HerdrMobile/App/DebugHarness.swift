#if DEBUG
import HerdrKit
import SwiftUI

/// Launch with `-agentDetailHarness` (add `-focusPrompt` to raise the keyboard) to see the
/// agent sheet in the simulator without a server.
struct AgentDetailHarness: View {
    let app: AppModel
    @State private var showing = false
    @State private var host = ReadmeDemo.isOn
        ? HostProfile(name: "devbox", hostname: "devbox.local", username: "me")
        : HostProfile(name: "Harness", hostname: "localhost", username: "me")

    var body: some View {
        let session = app.session(for: host)
        Color(Theme.paper)
            .ignoresSafeArea()
            .onAppear {
                if ProcessInfo.processInfo.arguments.contains("-liveActivityDemo") {
                    LiveActivityController.shared.demo()
                }
                let json = #"{"agents":[{"terminal_id":"t1","agent":"claude","agent_status":"done","workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","focused":false,"cwd":"/tmp"}],"workspaces":[],"tabs":[],"panes":[],"version":"","protocol":0}"#
                if ReadmeDemo.isOn, let snapshot = ReadmeDemo.snapshot {
                    session.debugSetSnapshot(snapshot)
                    session.connect()
                } else if let snapshot = try? HerdrResponse.decoder().decode(SessionSnapshot.self, from: Data(json.utf8)) {
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
                            if ReadmeDemo.isOn {
                                // Stays on the Agents tab.
                            } else if args.contains("-lateNotificationTap") {
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

#if DEBUG
/// Launch the harness with `-readmeDemo` for the README screenshots: a made-up herdr session
/// on the Agents tab; add `-demoChat` to open the Claude agent's chat.
enum ReadmeDemo {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-readmeDemo") }
    static var opensChat: Bool { ProcessInfo.processInfo.arguments.contains("-demoChat") }

    static var snapshot: SessionSnapshot? {
        func workspace(_ id: String, _ number: Int, _ label: String, _ status: String) -> String {
            #"{"workspace_id":"\#(id)","number":\#(number),"label":"\#(label)","focused":false,"pane_count":1,"tab_count":1,"active_tab_id":"\#(id):t1","agent_status":"\#(status)"}"#
        }
        func tab(_ ws: String, _ label: String, _ status: String) -> String {
            #"{"tab_id":"\#(ws):t1","workspace_id":"\#(ws)","number":1,"label":"\#(label)","focused":false,"pane_count":1,"agent_status":"\#(status)"}"#
        }
        func agent(_ ws: String, _ kind: String, _ status: String, _ title: String, _ cwd: String) -> String {
            #"{"terminal_id":"\#(ws)-term","agent":"\#(kind)","title":"\#(title)","agent_status":"\#(status)","workspace_id":"\#(ws)","tab_id":"\#(ws):t1","pane_id":"\#(ws):p1","focused":false,"cwd":"\#(cwd)"}"#
        }
        let json = """
        {"version":"0.7.1","protocol":1,
         "workspaces":[\(workspace("w1", 1, "shello", "working")),\(workspace("w2", 2, "api-server", "blocked")),\(workspace("w3", 3, "landing-page", "done")),\(workspace("w4", 4, "dotfiles", "idle"))],
         "tabs":[\(tab("w1", "shello", "working")),\(tab("w2", "api-server", "blocked")),\(tab("w3", "landing-page", "done")),\(tab("w4", "dotfiles", "idle"))],
         "panes":[],
         "agents":[\(agent("w1", "claude", "working", "Fix CI build crash", "~/code/shello")),\(agent("w2", "codex", "blocked", "Add rate limiting to /login", "~/code/api-server")),\(agent("w3", "claude", "done", "Dark mode for the hero section", "~/code/landing-page")),\(agent("w4", "claude", "idle", "Tidy zsh config", "~/dotfiles"))]}
        """
        return try? HerdrResponse.decoder().decode(SessionSnapshot.self, from: Data(json.utf8))
    }

    static var transcript: ClaudeTranscript {
        func user(_ id: String, _ text: String) -> [String: Any] {
            ["type": "user", "uuid": id, "message": ["role": "user", "content": text]]
        }
        func say(_ id: String, _ text: String) -> [String: Any] {
            ["type": "assistant", "uuid": id, "message": ["role": "assistant", "content": [["type": "text", "text": text]]]]
        }
        func tool(_ id: String, _ name: String, _ input: [String: Any], result: String) -> [[String: Any]] {
            [["type": "assistant", "uuid": id, "message": ["role": "assistant", "content": [["type": "tool_use", "id": id, "name": name, "input": input]]]],
             ["type": "user", "uuid": id + "r", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": result, "is_error": false]]]]]
        }
        var lines: [[String: Any]] = [user("u1", "CI is failing on the iOS build again, can you take a look?")]
        lines += tool("t1", "Bash", ["command": "gh run view --log-failed | tail -40", "description": "Read failed CI log"], result: "error: compile command failed due to signal 6")
        lines += tool("t2", "Grep", ["pattern": "Task {", "path": "HerdrMobile/Terminal"], result: "TerminalSession.swift:96")
        lines += tool("t3", "Read", ["file_path": "HerdrMobile/Terminal/TerminalSession.swift"], result: "import Foundation")
        lines.append(say("a1", """
        Found it. The Swift 6.1 optimizer crashes (**ClosureLifetimeFixup**) on a closure nested inside the `Task` in `connect()`. Building the closure outside the task avoids it:

        ```swift
        let verifier = hosts.verifier(for: host)
        Task { try await open(using: verifier) }
        ```
        """))
        lines += tool("t4", "Edit", ["file_path": "HerdrMobile/Terminal/TerminalSession.swift", "old_string": "x"], result: "ok")
        lines += tool("t5", "Bash", ["command": "xcodebuild build -scheme HerdrMobile -quiet", "description": "Build"], result: "** BUILD SUCCEEDED **")
        lines.append(say("a2", """
        The build passes locally now. Summary:

        - Moved the host-key closure out of the `Task` in `TerminalSession.connect`
        - No behavior change; tests still pass (51/51)

        Want me to push and re-run CI?
        """))
        lines.append(user("u2", "yes, push it"))
        lines += tool("t6", "Bash", ["command": "git push && gh run watch", "description": "Push and watch CI"], result: "")
        var transcript = ClaudeTranscript()
        for line in lines {
            if let data = try? JSONSerialization.data(withJSONObject: line) {
                transcript.ingest(String(decoding: data, as: UTF8.self))
            }
        }
        return transcript
    }
}
#endif
