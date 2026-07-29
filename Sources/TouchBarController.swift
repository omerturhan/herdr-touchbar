import AppKit

extension NSTouchBarItem.Identifier {
    static let herdrStrip = NSTouchBarItem.Identifier("dev.herdr.touchbar.strip")
    static let herdrList  = NSTouchBarItem.Identifier("dev.herdr.touchbar.list")
}

/// Button content uses explicit constraints because NSButtonCell vertically
/// centers an image and multiline title as one block. The icon stays centered;
/// the tab and project labels start at the top edge.
private final class AgentButton: NSButton {
    private let iconView = NSImageView()
    private let tabLabel = NSTextField(labelWithString: "")
    private let projectLabel = NSTextField(labelWithString: "")

    init(target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        title = ""

        iconView.imageScaling = .scaleProportionallyDown
        tabLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        tabLabel.cell?.lineBreakMode = .byTruncatingTail
        projectLabel.font = .systemFont(ofSize: 8.5, weight: .regular)
        projectLabel.cell?.lineBreakMode = .byTruncatingTail

        for view in [iconView, tabLabel, projectLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        tabLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        projectLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            tabLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            tabLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            tabLabel.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            tabLabel.heightAnchor.constraint(equalToConstant: 14),

            projectLabel.leadingAnchor.constraint(equalTo: tabLabel.leadingAnchor),
            projectLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            projectLabel.topAnchor.constraint(equalTo: tabLabel.bottomAnchor, constant: -1),
            projectLabel.heightAnchor.constraint(equalToConstant: 10),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        let textWidth = max(
            tabLabel.intrinsicContentSize.width,
            projectLabel.intrinsicContentSize.width
        )
        let width = min(max(8 + 18 + 5 + textWidth + 8, 88), 210)
        return NSSize(width: width, height: 30)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    func update(icon: NSImage, tab: String, project: String, color: NSColor) {
        iconView.image = icon
        tabLabel.stringValue = tab
        tabLabel.textColor = color
        projectLabel.stringValue = project
        projectLabel.textColor = color.withAlphaComponent(0.68)
        invalidateIntrinsicContentSize()
    }

    func updateTab(_ tab: String) {
        tabLabel.stringValue = tab
        invalidateIntrinsicContentSize()
    }
}

/// Owns everything the user sees: the always-present Control Strip badge, and the
/// full-width agent list that replaces the Touch Bar when the badge is tapped.
final class TouchBarController: NSObject, NSTouchBarDelegate {

    private let store = AgentStore()

    private let stripItem = NSCustomTouchBarItem(identifier: .herdrStrip)
    private let stripButton = NSButton(title: "", target: nil, action: nil)

    private var panelTouchBar: NSTouchBar?
    private let panelItem = NSCustomTouchBarItem(identifier: .herdrList)
    private var panelVisible = false

    /// Buttons currently on screen, plus the order they were laid out in. Holding
    /// the order lets status changes repaint in place instead of rebuilding —
    /// buttons must not slide out from under a finger that is already reaching.
    private var agentButtons: [String: AgentButton] = [:]
    private var onScreenOrder: [String] = []

    private var spinnerTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var tick = 0

    /// Hide idle agents, for people who only want the ones that need attention.
    private static let onlyActive = ["1", "true", "yes", "on"]
        .contains(ProcessInfo.processInfo.environment["HERDR_TOUCHBAR_ONLY_ACTIVE"]?.lowercased() ?? "")

    private static let panelMaxWidth: CGFloat = 980
    private static let barHeight: CGFloat = 30

    // MARK: - Lifecycle

    func install() {
        stripButton.target = self
        stripButton.action = #selector(openPanel)
        stripButton.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        stripButton.setAccessibilityLabel("Herdr agents")
        stripButton.translatesAutoresizingMaskIntoConstraints = false
        stripButton.widthAnchor.constraint(equalToConstant: 92).isActive = true
        stripItem.view = stripButton

        // We are an accessory app and never become frontmost, so the system close
        // box would never appear — the panel carries its own ✕ instead.
        DFRSystemModalShowsCloseBoxWhenFrontMost(false)
        NSTouchBarItem.addSystemTrayItem(stripItem)
        assertStripPresence()

        // The Control Strip registration does not reliably survive a sleep/wake
        // cycle or a TouchBarServer restart, so re-assert it on wake.
        let center = NSWorkspace.shared.notificationCenter
        for name: NSNotification.Name in [NSWorkspace.didWakeNotification,
                                          NSWorkspace.screensDidWakeNotification,
                                          NSWorkspace.sessionDidBecomeActiveNotification] {
            center.addObserver(self, selector: #selector(assertStripPresence),
                               name: name, object: nil)
        }

        installSignalHandlers()

        store.onChange = { [weak self] snapshot in self?.apply(snapshot) }
        store.start()
        apply(store.snapshot)

        Log.info("control strip item installed")
    }

    func uninstall() {
        spinnerTimer?.invalidate()
        spinnerTimer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DFRElementSetControlStripPresenceForIdentifier(.herdrStrip, false)
        NSTouchBarItem.removeSystemTrayItem(stripItem)
    }

    @objc private func assertStripPresence() {
        DFRElementSetControlStripPresenceForIdentifier(.herdrStrip, true)
    }

    /// SIGUSR1 opens the agent list, SIGUSR2 closes it — so a herdr keybinding
    /// (or any script) can drive the panel without reaching for the Touch Bar.
    private func installSignalHandlers() {
        for (sig, open) in [(SIGUSR1, true), (SIGUSR2, false)] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                open ? self?.openPanel() : self?.closePanel()
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - State

    private func apply(_ snapshot: AgentSnapshot) {
        renderStrip(snapshot)

        if panelVisible {
            let display = agentsForDisplay(snapshot)
            if snapshot.connected, display.map(\.paneId) == onScreenOrder, !display.isEmpty {
                for entry in display { repaint(entry) }
            } else {
                renderPanel(display, connected: snapshot.connected)
            }
        }

        syncSpinner(snapshot)
    }

    /// While the panel is open the layout is frozen: the same agents keep the same
    /// slots even as their status changes. A new or closed agent re-sorts it.
    private func agentsForDisplay(_ snapshot: AgentSnapshot) -> [AgentEntry] {
        var agents = snapshot.agents
        if Self.onlyActive {
            agents = agents.filter { $0.status != .idle && $0.status != .unknown }
        }
        guard panelVisible, Set(onScreenOrder) == Set(agents.map(\.paneId)) else { return agents }
        let byId = Dictionary(agents.map { ($0.paneId, $0) }, uniquingKeysWith: { a, _ in a })
        return onScreenOrder.compactMap { byId[$0] }
    }

    /// The spinner is the only thing burning CPU while idle, so it only runs
    /// when something is actually working.
    private func syncSpinner(_ snapshot: AgentSnapshot) {
        let needed = snapshot.working > 0
        if needed, spinnerTimer == nil {
            let timer = Timer(timeInterval: Spinner.interval, repeats: true) { [weak self] _ in
                self?.advanceSpinner()
            }
            RunLoop.main.add(timer, forMode: .common)
            spinnerTimer = timer
        } else if !needed, let timer = spinnerTimer {
            timer.invalidate()
            spinnerTimer = nil
        }
    }

    private func advanceSpinner() {
        tick &+= 1
        renderStrip(store.snapshot)
        if panelVisible {
            for entry in store.snapshot.agents where entry.status.isBusy {
                agentButtons[entry.paneId]?.updateTab(primaryText(for: entry))
            }
        }
    }

    // MARK: - Control Strip badge

    private func renderStrip(_ snapshot: AgentSnapshot) {
        guard snapshot.connected else {
            stripButton.attributedTitle = attributed("⃠ herdr", color: NSColor(white: 0.5, alpha: 1))
            stripButton.bezelColor = NSColor(white: 0.16, alpha: 1)
            return
        }

        let spin = Spinner.frame(tick)
        let text: String
        let color: NSColor

        // Blocked agents outrank everything: those are the ones holding you up.
        if snapshot.blocked > 0 && snapshot.working > 0 {
            text = "⏸\(snapshot.blocked) \(spin)\(snapshot.working)"
            color = .systemRed
        } else if snapshot.blocked > 0 {
            text = "⏸ \(snapshot.blocked)"
            color = .systemRed
        } else if snapshot.done > 0 && snapshot.working > 0 {
            text = "✓\(snapshot.done) \(spin)\(snapshot.working)"
            color = .systemOrange
        } else if snapshot.working > 0 {
            text = "\(spin) \(snapshot.working)"
            color = .systemOrange
        } else if snapshot.done > 0 {
            text = "✓ \(snapshot.done)"
            color = .systemGreen
        } else {
            text = "⠿ \(snapshot.agents.count)"
            color = NSColor(white: 0.22, alpha: 1)
        }

        stripButton.attributedTitle = attributed(text, color: .white)
        stripButton.bezelColor = color
    }

    // MARK: - Expanded agent list

    @objc private func openPanel() {
        guard !panelVisible else { return }

        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [.herdrList]
        panelTouchBar = bar
        panelVisible = true

        onScreenOrder = []   // re-sort fresh every time the panel is opened
        renderPanel(agentsForDisplay(store.snapshot), connected: store.snapshot.connected)

        NSTouchBar.presentSystemModalTouchBar(bar, placement: 1,
                                              systemTrayItemIdentifier: .herdrStrip)
        assertStripPresence()
    }

    @objc private func closePanel() {
        guard panelVisible, let bar = panelTouchBar else { return }

        panelVisible = false
        agentButtons.removeAll()
        onScreenOrder = []
        // minimize (rather than dismiss) collapses back to the Control Strip badge.
        NSTouchBar.minimizeSystemModalTouchBar(bar)
        panelTouchBar = nil
        assertStripPresence()
    }

    @objc private func agentTapped(_ sender: NSButton) {
        guard let paneId = sender.identifier?.rawValue,
              let entry = store.snapshot.agents.first(where: { $0.paneId == paneId }) else { return }
        AgentStore.focus(entry)
        closePanel()
    }

    func touchBar(_ touchBar: NSTouchBar,
                  makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        identifier == .herdrList ? panelItem : nil
    }

    private func renderPanel(_ agents: [AgentEntry], connected: Bool) {
        agentButtons.removeAll()
        onScreenOrder = agents.map(\.paneId)

        let close = NSButton(title: "✕", target: self, action: #selector(closePanel))
        close.bezelColor = NSColor(white: 0.18, alpha: 1)
        close.font = .systemFont(ofSize: 13, weight: .medium)
        close.setAccessibilityLabel("Close Herdr agent panel")

        var views: [NSView] = [close]
        if !connected {
            views.append(message("herdr server not running"))
        } else if agents.isEmpty {
            views.append(message(Self.onlyActive ? "no active agents" : "no agents"))
        } else {
            views.append(contentsOf: agents.map { button(for: $0) })
        }

        panelItem.view = scrollContainer(views)
    }

    private func message(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14)
        label.textColor = NSColor(white: 0.6, alpha: 1)
        return label
    }

    private func button(for entry: AgentEntry) -> NSButton {
        let btn = AgentButton(target: self, action: #selector(agentTapped(_:)))
        btn.identifier = NSUserInterfaceItemIdentifier(entry.paneId)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.widthAnchor.constraint(greaterThanOrEqualToConstant: 88).isActive = true
        btn.widthAnchor.constraint(lessThanOrEqualToConstant: 210).isActive = true
        btn.heightAnchor.constraint(equalToConstant: Self.barHeight).isActive = true

        agentButtons[entry.paneId] = btn
        paint(btn, with: entry)
        return btn
    }

    private func repaint(_ entry: AgentEntry) {
        guard let btn = agentButtons[entry.paneId] else { return }
        paint(btn, with: entry)
    }

    private func paint(_ btn: AgentButton, with entry: AgentEntry) {
        btn.update(
            icon: AgentIcons.icon(for: entry.agent),
            tab: primaryText(for: entry),
            project: entry.project,
            color: StatusPalette.text(for: entry.status)
        )
        btn.setAccessibilityLabel(
            "\(entry.agent) \(entry.label), \(entry.project), \(entry.status.rawValue)"
        )
        let base = StatusPalette.bezel(for: entry.status)
        // The focused agent gets a brighter face so you can see where you already are.
        btn.bezelColor = entry.focused ? base.blended(withFraction: 0.35, of: .white) : base
    }

    /// Busy agents carry a live spinner ahead of the tab name.
    private func primaryText(for entry: AgentEntry) -> String {
        let prefix: String
        switch entry.status {
        case .working: prefix = Spinner.frame(tick) + " "
        case .blocked: prefix = "⏸ "
        case .done:    prefix = "✓ "
        case .idle, .unknown: prefix = ""
        }
        return prefix + entry.label
    }

    private func attributed(_ text: String, color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: text, attributes: [
            .foregroundColor: color,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium),
            .paragraphStyle: paragraph,
        ])
    }

    /// Horizontal strip of items that scrolls when the agents outgrow the bar.
    private func scrollContainer(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY

        let fitting = stack.fittingSize
        let visible = min(max(fitting.width, 100), Self.panelMaxWidth)
        stack.frame = NSRect(x: 0, y: 0, width: max(fitting.width, visible), height: Self.barHeight)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: visible, height: Self.barHeight))
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.documentView = stack
        return scroll
    }
}
