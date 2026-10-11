import SwiftUI
import UIKit
import UserNotifications

@main
struct HerdrMobileApp: App {
    @StateObject private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            HostListView()
                .environmentObject(app)
                .environmentObject(app.hosts)
                .environmentObject(app.keys)
                .hostKeyPrompt(app)
                .onAppear { Notifier.requestAuthorization() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                BackgroundKeepAlive.end()
                app.sceneBecameActive()
            case .background:
                BackgroundKeepAlive.begin()
            default:
                break
            }
        }
    }
}

/// Asks iOS for the short grace period apps get after backgrounding, so the
/// SSH connection and agent polling survive a quick app switch.
@MainActor
enum BackgroundKeepAlive {
    private static var task: UIBackgroundTaskIdentifier = .invalid

    static func begin() {
        guard task == .invalid else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: "ssh-keepalive") {
            end()
        }
    }

    static func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}

private struct HostKeyPromptModifier: ViewModifier {
    @ObservedObject var app: AppModel

    func body(content: Content) -> some View {
        content.alert(
            title,
            isPresented: Binding(get: { app.hostKeyPrompt != nil }, set: { if !$0 { app.answerHostKey(false) } }),
            presenting: app.hostKeyPrompt
        ) { _ in
            Button(isChanged ? "Trust New Key" : "Trust", role: isChanged ? .destructive : nil) { app.answerHostKey(true) }
            Button("Cancel", role: .cancel) { app.answerHostKey(false) }
        } message: { challenge in
            switch challenge.reason {
            case .firstConnection:
                Text("First connection to \(challenge.host).\n\n\(challenge.keyType)\n\(challenge.fingerprint)\n\nCompare with `ssh-keygen -lf` on the server.")
            case .changed(let previous):
                Text("WARNING: the host key for \(challenge.host) changed. Someone could be intercepting the connection.\n\nOld: \(previous)\nNew: \(challenge.fingerprint)")
            }
        }
    }

    private var isChanged: Bool {
        if case .changed = app.hostKeyPrompt?.reason { return true }
        return false
    }

    private var title: String {
        isChanged ? "Host Key Changed" : "Trust This Host?"
    }
}

extension View {
    func hostKeyPrompt(_ app: AppModel) -> some View {
        modifier(HostKeyPromptModifier(app: app))
    }
}
