import AppKit
import ServiceManagement

@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private static let openEye = StatusIcon.image(open: true)
    private static let closedEye = StatusIcon.image(open: false)
    private static let duration: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .short
        return formatter
    }()

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    private let insomnia: Insomnia
    private let header = HeaderView()
    private let agentsOption = OptionView(symbol: "sparkles", title: "While Agents Work")
    private let alwaysOption = OptionView(symbol: "infinity", title: "Until Turned Off")
    private let note = NoteView()
    private let login = SwitchView(title: "Open at Login")
    private var agentViews: [AgentView] = []
    private var structure = ""
    private var isOpen = false
    private var shownAwake: Bool?
    private var shownOn: Bool?
    // Both cost a system query, so they are read when the menu opens rather than on every refresh.
    private var loginEnabled = SMAppService.mainApp.status == .enabled
    private lazy var canKeepLidClosed = insomnia.power.canKeepLidClosed

    init(insomnia: Insomnia) {
        self.insomnia = insomnia
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.toolTip = "Insomnia"
        header.toggle.target = self
        header.toggle.action = #selector(toggle)
        login.toggle.target = self
        login.toggle.action = #selector(toggleLogin)
        agentsOption.onSelect = { [weak self] in self?.choose(.agents) }
        alwaysOption.onSelect = { [weak self] in self?.choose(.always) }
        insomnia.onChange = { [weak self] in self?.update() }
        update()
        updateMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        loginEnabled = SMAppService.mainApp.status == .enabled
        canKeepLidClosed = insomnia.power.canKeepLidClosed
        updateMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isOpen = true
        insomnia.isWatching = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isOpen = false
        insomnia.isWatching = false
    }

    /// Touches the menu bar only when its state changes; the menu itself only while it is open.
    private func update() {
        let awake = insomnia.awakeSince != nil
        if awake != shownAwake {
            shownAwake = awake
            statusItem.button?.image = awake ? Self.openEye : Self.closedEye
        }
        if insomnia.isOn != shownOn {
            shownOn = insomnia.isOn
            statusItem.button?.appearsDisabled = !insomnia.isOn
        }
        if isOpen { updateMenu() }
    }

    private func updateMenu() {
        let working = workingAgents
        let structure = "\(insomnia.mode) \(working.count) \(canKeepLidClosed)"
        if structure != self.structure {
            self.structure = structure
            rebuild(agentRows: working.count)
        }

        header.toggle.state = insomnia.isOn ? .on : .off
        header.statusText = status
        agentsOption.isSelected = insomnia.mode == .agents
        alwaysOption.isSelected = insomnia.mode == .always
        login.toggle.state = loginEnabled ? .on : .off
        for (view, agent) in zip(agentViews, working) { view.agent = agent }
        let count = insomnia.agents.count
        note.text = count == 0 ? "No agents running" : count == 1 ? "1 agent is idle" : "\(count) agents are idle"
    }

    private func rebuild(agentRows: Int) {
        menu.removeAllItems()
        menu.addItem(item(view: header))
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Stay Awake"))
        menu.addItem(item(view: agentsOption, action: #selector(pick)))
        menu.addItem(item(view: alwaysOption, action: #selector(pick)))

        if insomnia.mode == .agents {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Working Now"))
            while agentViews.count < agentRows { agentViews.append(AgentView()) }
            agentViews.removeLast(agentViews.count - agentRows)
            for view in agentViews { menu.addItem(item(view: view, enabled: false)) }
            if agentRows == 0 { menu.addItem(item(view: note, enabled: false)) }
        }

        if !canKeepLidClosed {
            menu.addItem(.separator())
            menu.addItem(item("Stay Awake with Lid Closed…", #selector(allowClosedLid)))
        }

        menu.addItem(.separator())
        menu.addItem(item(view: login))
        menu.addItem(item("Quit Insomnia", #selector(quit), key: "q"))
    }

    private var status: String {
        guard insomnia.isOn else { return "Your Mac sleeps as usual" }
        switch insomnia.pause {
        case .battery: return "Paused while the battery is low"
        case .heat: return "Paused while your Mac cools down"
        case nil: break
        }
        guard let since = insomnia.awakeSince else { return "Waiting for agents" }
        if let sleepsAt = insomnia.sleepsAt {
            return "Agents are done, sleep in \(max(1, Int((sleepsAt.timeIntervalSinceNow / 60).rounded(.up)))) min"
        }
        if insomnia.mode == .agents {
            let working = insomnia.agents.filter(\.isWorking)
            return working.count == 1 ? "Awake while \(working[0].name) works" : "Awake while \(working.count) agents work"
        }
        let elapsed = Date.now.timeIntervalSince(since)
        guard elapsed >= 60 else { return "Keeping your Mac awake" }
        return "Awake for \(Self.duration.string(from: elapsed) ?? "")"
    }

    /// Working agents, one row per project and agent.
    private var workingAgents: [(project: String, name: String)] {
        var rows: [(project: String, name: String, count: Int)] = []
        for agent in insomnia.agents where agent.isWorking {
            if let index = rows.firstIndex(where: { $0.project == agent.project && $0.name == agent.name }) {
                rows[index].count += 1
            } else {
                rows.append((agent.project, agent.name, 1))
            }
        }
        return rows.map { ($0.project, $0.count > 1 ? "\($0.name) ×\($0.count)" : $0.name) }
    }

    @objc private func toggle(_ sender: NSSwitch) {
        turn(on: sender.state == .on)
    }

    /// Picking how to stay awake also turns Insomnia on, like choosing a Focus.
    private func choose(_ mode: Insomnia.Mode) {
        insomnia.mode = mode
        turn(on: true)
    }

    /// The first time Insomnia goes on it asks for the closed-lid permission.
    private func turn(on: Bool) {
        insomnia.isOn = on
        let defaults = UserDefaults.standard
        guard on, !canKeepLidClosed, !defaults.bool(forKey: "askedForClosedLid") else { return }
        defaults.set(true, forKey: "askedForClosedLid")
        menu.cancelTracking()
        // The default mode only comes back once the menu is gone.
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated { self.allowClosedLid() }
        }
    }

    /// Return on a highlighted option; clicks go to the view itself.
    @objc private func pick(_ sender: NSMenuItem) {
        (sender.view as? OptionView)?.onSelect()
    }

    @objc private func allowClosedLid() {
        insomnia.power.allowClosedLid()
        canKeepLidClosed = insomnia.power.canKeepLidClosed
        updateMenu()
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        try? loginEnabled ? service.unregister() : service.register()
        loginEnabled = service.status == .enabled
        updateMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func item(view: NSView, enabled: Bool = true, action: Selector? = nil) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = view
        item.isEnabled = enabled
        item.action = action
        item.target = self
        return item
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
}
