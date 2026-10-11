import Foundation

/// A state change worth telling the user about.
public struct AgentAlert: Hashable, Sendable {
    public enum Kind: String, Sendable {
        /// The agent is showing an approval prompt or question.
        case needsInput
        /// The agent stopped working and is waiting for the next prompt.
        case finished
    }

    public var kind: Kind
    public var agent: AgentInfo

    public var title: String {
        switch kind {
        case .needsInput: return "\(agent.displayName) needs you"
        case .finished: return "\(agent.displayName) finished"
        }
    }
}

public enum AgentTransitions {
    /// Compares two snapshots of the same server and returns alerts for agents
    /// that just became blocked or just finished a turn. Agents that appear for
    /// the first time are not reported, so connecting doesn't spam alerts.
    public static func alerts(from old: SessionSnapshot?, to new: SessionSnapshot) -> [AgentAlert] {
        guard let old else { return [] }
        let previous = Dictionary(old.agents.map { ($0.terminalId, $0) }, uniquingKeysWith: { a, _ in a })
        var alerts: [AgentAlert] = []
        for agent in new.agents {
            guard let before = previous[agent.terminalId], before.agentStatus != agent.agentStatus else { continue }
            switch (before.agentStatus, agent.agentStatus) {
            case (_, .blocked):
                alerts.append(AgentAlert(kind: .needsInput, agent: agent))
            case (.working, .done), (.working, .idle):
                alerts.append(AgentAlert(kind: .finished, agent: agent))
            default:
                break
            }
        }
        return alerts
    }
}
