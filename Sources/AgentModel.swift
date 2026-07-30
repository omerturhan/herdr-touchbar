import Foundation

enum AgentStatus: String {
    case blocked, working, done, idle, unknown

    init(herdr value: String?) {
        self = AgentStatus(rawValue: value ?? "") ?? .unknown
    }

    var isBusy: Bool { self == .working }
}

struct AgentEntry: Equatable {
    var paneId: String
    var tabId: String
    var workspaceId: String
    var project: String
    var agent: String
    var status: AgentStatus
    var label: String
    var focused: Bool

    static func == (a: AgentEntry, b: AgentEntry) -> Bool {
        a.paneId == b.paneId && a.tabId == b.tabId && a.workspaceId == b.workspaceId
            && a.project == b.project && a.agent == b.agent && a.status == b.status
            && a.label == b.label && a.focused == b.focused
    }
}

struct AgentSnapshot: Equatable {
    var agents: [AgentEntry] = []
    var connected: Bool = false

    var working: Int { agents.filter { $0.status == .working }.count }
    var blocked: Int { agents.filter { $0.status == .blocked }.count }
    var done: Int    { agents.filter { $0.status == .done }.count }
}

/// Owns the live picture of herdr's agents: bootstraps over the socket, keeps
/// itself current from the event stream, and publishes coalesced changes.
final class AgentStore {

    /// Called on the main thread whenever the derived snapshot actually changes.
    var onChange: ((AgentSnapshot) -> Void)?

    private(set) var snapshot = AgentSnapshot()
    private var refreshScheduled = false
    private let queue = DispatchQueue(label: "dev.herdr.touchbar.store")

    /// Events that can plausibly change what we render. `pane.updated` is chatty
    /// (it fires on every terminal revision), which is exactly why refreshes are
    /// coalesced rather than applied per event.
    private static let subscriptions: [[String: Any]] = [
        ["type": "pane.updated"],
        ["type": "pane.created"],
        ["type": "pane.closed"],
        ["type": "pane.exited"],
        ["type": "pane.focused"],
        ["type": "pane.agent_detected"],
        ["type": "pane.moved"],
        ["type": "tab.created"],
        ["type": "tab.closed"],
        ["type": "tab.renamed"],
        ["type": "tab.focused"],
        ["type": "tab.moved"],
        ["type": "workspace.focused"],
        ["type": "workspace.renamed"],
        ["type": "workspace.closed"],
        ["type": "workspace.moved"],
    ]

    /// Status-change subscriptions are pane-scoped in Herdr 0.7.5. Rebuild the
    /// stream when topology changes so the filter set always matches live agents.
    private static let subscriptionTopologyEvents: Set<String> = [
        "pane.created",
        "pane.closed",
        "pane.exited",
        "pane.agent_detected",
        "pane.moved",
        "tab.closed",
        "workspace.closed",
    ]

    func start() {
        Thread.detachNewThread { [weak self] in self?.subscribeLoop() }
    }

    private func subscribeLoop() {
        var backoff: UInt32 = 1
        while true {
            let seed = Self.fetch()
            publish(seed)

            guard seed.connected else {
                sleep(backoff)
                backoff = min(backoff * 2, 15)
                continue
            }

            let statusSubscriptions: [[String: Any]] = seed.agents.map {
                ["type": "pane.agent_status_changed", "pane_id": $0.paneId]
            }

            // Any event may change the picture; re-derive rather than patch.
            let rebuild = HerdrSocket.subscribe(Self.subscriptions + statusSubscriptions) {
                [weak self] event in
                let eventType = event["event"] as? String
                let topologyChanged = eventType.map(Self.subscriptionTopologyEvents.contains) ?? false
                self?.scheduleRefresh(delay: topologyChanged ? 0 : 0.3)
                return !topologyChanged
            }

            if rebuild {
                backoff = 1
                continue
            }

            // subscribe() only returns once the connection is gone.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.snapshot.connected {
                    self.snapshot.connected = false
                    self.onChange?(self.snapshot)
                }
            }
            sleep(backoff)
            backoff = min(backoff * 2, 15)
            scheduleRefresh(delay: 0)
            if HerdrSocket.request("ping") != nil { backoff = 1 }
        }
    }

    /// Coalesces bursts of events into a single refetch.
    private func scheduleRefresh(delay: TimeInterval) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.refreshScheduled else { return }
            self.refreshScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.refreshScheduled = false
                self.queue.async { self.refresh() }
            }
        }
    }

    private func refresh() {
        let next = Self.fetch()
        publish(next)
    }

    private func publish(_ next: AgentSnapshot) {
        DispatchQueue.main.async { [weak self] in
            guard let self, next != self.snapshot else { return }
            self.snapshot = next
            self.onChange?(next)
        }
    }

    private static func fetch() -> AgentSnapshot {
        guard let result = HerdrSocket.request("session.snapshot"),
              let snapshot = result["snapshot"] as? [String: Any],
              let rawAgents = snapshot["agents"] as? [[String: Any]] else {
            return AgentSnapshot(agents: [], connected: false)
        }

        // Tab labels are the user's own names ("Build Worker"); prefer them over the
        // agent-authored terminal title, which is long and changes constantly.
        var tabLabels: [String: String] = [:]
        if let rawTabs = snapshot["tabs"] as? [[String: Any]] {
            for tab in rawTabs {
                if let id = tab["tab_id"] as? String, let label = tab["label"] as? String {
                    tabLabels[id] = label
                }
            }
        }

        var workspaceLabels: [String: String] = [:]
        if let rawWorkspaces = snapshot["workspaces"] as? [[String: Any]] {
            for workspace in rawWorkspaces {
                guard let id = workspace["workspace_id"] as? String,
                      let rawLabel = workspace["label"] as? String else { continue }
                let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                if !label.isEmpty { workspaceLabels[id] = label }
            }
        }

        var entries: [AgentEntry] = []
        for raw in rawAgents {
            guard let paneId = raw["pane_id"] as? String else { continue }
            let tabId = raw["tab_id"] as? String ?? ""
            let workspaceId = raw["workspace_id"] as? String ?? ""
            let fallback = raw["terminal_title_stripped"] as? String
                ?? raw["terminal_title"] as? String
                ?? paneId
            let label = tabLabels[tabId].flatMap { $0.isEmpty ? nil : $0 } ?? fallback
            let reportedAgent = (raw["agent"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let agent = reportedAgent.flatMap { $0.isEmpty ? nil : $0.lowercased() } ?? "agent"

            entries.append(AgentEntry(
                paneId: paneId,
                tabId: tabId,
                workspaceId: workspaceId,
                project: workspaceLabels[workspaceId] ?? "Workspace",
                agent: agent,
                status: AgentStatus(herdr: raw["agent_status"] as? String),
                label: label,
                focused: raw["focused"] as? Bool ?? false
            ))
        }

        // Match herdr's own sidebar: workspaces in their arranged order, and tabs
        // in theirs within each workspace. Both arrays arrive in that order — note
        // that `number` is a stable shortcut identifier, not a position, so a tab
        // dragged elsewhere keeps its number while moving in the array.
        let workspaceOrder = indexMap(snapshot["workspaces"] as? [[String: Any]], key: "workspace_id")
        let tabOrder = indexMap(snapshot["tabs"] as? [[String: Any]], key: "tab_id")
        entries.sort {
            let workspaceA = workspaceOrder[$0.workspaceId] ?? .max
            let workspaceB = workspaceOrder[$1.workspaceId] ?? .max
            if workspaceA != workspaceB { return workspaceA < workspaceB }
            let tabA = tabOrder[$0.tabId] ?? .max
            let tabB = tabOrder[$1.tabId] ?? .max
            if tabA != tabB { return tabA < tabB }
            return $0.paneId < $1.paneId
        }
        return AgentSnapshot(agents: entries, connected: true)
    }

    /// Position of each entry in a snapshot array, keyed by its id.
    private static func indexMap(_ rows: [[String: Any]]?, key: String) -> [String: Int] {
        var map: [String: Int] = [:]
        for (index, row) in (rows ?? []).enumerated() {
            if let id = row[key] as? String { map[id] = index }
        }
        return map
    }

    /// Brings an agent to the foreground: focus it inside herdr, then raise the terminal.
    static func focus(_ entry: AgentEntry) {
        DispatchQueue.global(qos: .userInitiated).async {
            HerdrSocket.request("agent.focus", ["target": entry.paneId])
            DispatchQueue.main.async { TerminalActivator.activate() }
        }
    }
}
