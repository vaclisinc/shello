import Foundation

/// Lifecycle state herdr assigns to a pane's agent.
/// Mirrors `AgentStatus` in herdr's `src/api/schema/common.rs`.
public enum AgentStatus: String, Codable, Sendable, CaseIterable, Comparable {
    case blocked
    case done
    case working
    case idle
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentStatus(rawValue: raw) ?? .unknown
    }

    /// Sort order for an "inbox": things that need you first.
    public var priority: Int {
        switch self {
        case .blocked: return 0
        case .done: return 1
        case .working: return 2
        case .idle: return 3
        case .unknown: return 4
        }
    }

    public static func < (lhs: AgentStatus, rhs: AgentStatus) -> Bool {
        lhs.priority < rhs.priority
    }

    /// `idle` and `done` both mean the agent is waiting for input.
    public var isReadyForInput: Bool { self == .idle || self == .done }
}

public struct WorkspaceInfo: Codable, Hashable, Sendable, Identifiable {
    public var workspaceId: String
    public var number: Int
    public var label: String
    public var focused: Bool
    public var paneCount: Int
    public var tabCount: Int
    public var activeTabId: String
    public var agentStatus: AgentStatus

    public var id: String { workspaceId }
}

public struct TabInfo: Codable, Hashable, Sendable, Identifiable {
    public var tabId: String
    public var workspaceId: String
    public var number: Int
    public var label: String
    public var focused: Bool
    public var paneCount: Int
    public var agentStatus: AgentStatus

    public var id: String { tabId }
}

public struct PaneInfo: Codable, Hashable, Sendable, Identifiable {
    public var paneId: String
    public var terminalId: String
    public var workspaceId: String
    public var tabId: String
    public var focused: Bool
    public var cwd: String?
    public var foregroundCwd: String?
    public var label: String?
    public var agent: String?
    public var title: String?
    public var displayAgent: String?
    public var agentStatus: AgentStatus

    public var id: String { paneId }
}

public struct AgentInfo: Codable, Hashable, Sendable, Identifiable {
    public var terminalId: String
    public var name: String?
    public var agent: String?
    public var title: String?
    public var terminalTitleStripped: String?
    public var displayAgent: String?
    public var agentStatus: AgentStatus
    public var workspaceId: String
    public var tabId: String
    public var paneId: String
    public var focused: Bool
    public var stateChangeSeq: UInt64?
    public var completionSeq: UInt64?
    public var cwd: String?
    public var foregroundCwd: String?

    public var id: String { paneId }

    /// What to pass to `herdr agent <cmd> <target>`: a live name, or the hosting pane id.
    public var target: String { name ?? paneId }

    public var kindLabel: String { displayAgent ?? agent ?? "agent" }

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return "\(kindLabel) · \(paneId)"
    }

    public var subtitle: String? {
        let t = terminalTitleStripped ?? title
        if let t, !t.isEmpty { return t }
        return foregroundCwd ?? cwd
    }
}

public struct SessionSnapshot: Codable, Hashable, Sendable {
    public var version: String
    public var `protocol`: Int
    public var focusedWorkspaceId: String?
    public var focusedTabId: String?
    public var focusedPaneId: String?
    public var workspaces: [WorkspaceInfo]
    public var tabs: [TabInfo]
    public var panes: [PaneInfo]
    public var agents: [AgentInfo]

    public init(
        version: String = "",
        protocol protocolVersion: Int = 0,
        focusedWorkspaceId: String? = nil,
        focusedTabId: String? = nil,
        focusedPaneId: String? = nil,
        workspaces: [WorkspaceInfo] = [],
        tabs: [TabInfo] = [],
        panes: [PaneInfo] = [],
        agents: [AgentInfo] = []
    ) {
        self.version = version
        self.protocol = protocolVersion
        self.focusedWorkspaceId = focusedWorkspaceId
        self.focusedTabId = focusedTabId
        self.focusedPaneId = focusedPaneId
        self.workspaces = workspaces
        self.tabs = tabs
        self.panes = panes
        self.agents = agents
    }

    public func workspace(_ id: String) -> WorkspaceInfo? {
        workspaces.first { $0.workspaceId == id }
    }

    /// Agents sorted inbox-style: blocked, then done, working, idle.
    public var agentsByUrgency: [AgentInfo] {
        agents.sorted {
            if $0.agentStatus != $1.agentStatus { return $0.agentStatus < $1.agentStatus }
            return $0.paneId.localizedStandardCompare($1.paneId) == .orderedAscending
        }
    }

    public var blockedCount: Int { agents.filter { $0.agentStatus == .blocked }.count }
}
