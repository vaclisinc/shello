import ActivityKit
import Foundation

/// The Live Activity shown on the Lock Screen and in the Dynamic Island while
/// Shello holds SSH connections. Shared by the app and the widget extension.
struct ShelloActivityAttributes: ActivityAttributes {
    struct Host: Codable, Hashable {
        var name: String
        var connected: Bool
        var working: Int
        var waiting: Int
    }

    struct ContentState: Codable, Hashable {
        var hosts: [Host]

        var connections: Int { hosts.filter(\.connected).count }
        var working: Int { hosts.reduce(0) { $0 + $1.working } }
        var waiting: Int { hosts.reduce(0) { $0 + $1.waiting } }

        var title: String {
            switch connections {
            case 0: return "Reconnecting…"
            case 1: return "One connection"
            default: return "\(connections) connections"
            }
        }
    }
}
