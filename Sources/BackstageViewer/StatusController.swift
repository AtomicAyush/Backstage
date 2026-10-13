import AppKit
import BackstageCore

/// The menu-bar icon and its menu: one section per agent screen.
final class StatusController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let notifier = Notifier()
    private var sessions: [Registry.SessionInfo] = []
    private var watchers: [Int32: WatchWindowController] = [:]
    private var timer: Timer?
    private var hadSessions = false
    private var emptySince: Date?

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        notifier.onOpen = { [weak self] pid in self?.watch(pid) }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func refresh() {
        sessions = Registry.sessions()
        let needsYou = sessions.contains { $0.status == .needsYou }
        let symbol = needsYou ? "theatermasks.fill" : (sessions.isEmpty ? "theatermasks" : "theatermasks.fill")
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Backstage")
        item.button?.contentTintColor = needsYou ? .systemOrange : nil
        item.button?.toolTip = sessions.isEmpty ? "Backstage: no agents working"
            : "Backstage: \(sessions.count) agent screen\(sessions.count == 1 ? "" : "s")"
        notifier.update(sessions)

        for (pid, watcher) in watchers {
            if let session = sessions.first(where: { $0.pid == pid }) {
                watcher.update(session)
            } else {
                watcher.sessionEnded()
                watchers[pid] = nil
            }
        }

        // Only stay around while agents are working (or briefly after), unless opened by hand.
        if !sessions.isEmpty { hadSessions = true; emptySince = nil }
        else if hadSessions {
            emptySince = emptySince ?? Date()
            if Date().timeIntervalSince(emptySince!) > 20, watchers.isEmpty { NSApp.terminate(nil) }
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        sessions = Registry.sessions()
        if sessions.isEmpty {
            menu.addItem(disabled("No agents are using a screen right now."))
        }
        for session in sessions {
            add(session, to: menu)
            menu.addItem(.separator())
        }
        if !sessions.isEmpty { menu.items.last.map(menu.removeItem) }
        menu.addItem(.separator())
        menu.addItem(action("Quit Backstage", #selector(quit), key: "q"))
    }

    private func add(_ session: Registry.SessionInfo, to menu: NSMenu) {
        let title = NSMutableAttributedString(string: "\(session.name) · \(session.client)",
                                              attributes: [.font: NSFont.menuFont(ofSize: 0).bold])
        title.append(NSAttributedString(string: "  \(Self.describe(session.status))",
                                        attributes: [.foregroundColor: Self.color(session.status), .font: NSFont.menuFont(ofSize: 0)]))
        let header = NSMenuItem()
        header.attributedTitle = title
        header.isEnabled = false
        menu.addItem(header)

        if session.status == .needsYou, let message = session.message {
            menu.addItem(disabled("“\(message)”", wrap: true))
            menu.addItem(action("Answer and Hand Back…", #selector(answer(_:)), pid: session.pid))
        }
        if let last = session.lastAction, !last.isEmpty {
            let ago = session.lastActionAt.map { " · " + Self.relative($0) } ?? ""
            menu.addItem(disabled(Self.clip(last, 70) + ago, small: true))
        }
        if !session.apps.isEmpty {
            menu.addItem(disabled("Apps: " + session.apps.joined(separator: ", "), small: true))
        }
        menu.addItem(action("Watch…", #selector(watchFromMenu(_:)), pid: session.pid))
        let control = Registry.readControl(pid: session.pid)
        menu.addItem(action(control.paused ? "Resume" : "Pause", #selector(togglePause(_:)), pid: session.pid))
        menu.addItem(action(control.takenOver ? "Give Back to Agent" : "Take Over (bring its windows to you)",
                            #selector(toggleTakeOver(_:)), pid: session.pid))
    }

    // MARK: - Actions

    @objc private func watchFromMenu(_ sender: NSMenuItem) { watch(Int32(sender.tag)) }

    func watch(_ pid: Int32) {
        guard let session = Registry.sessions().first(where: { $0.pid == pid }) else { return }
        let watcher = watchers[pid] ?? WatchWindowController(session: session)
        watchers[pid] = watcher
        watcher.onClose = { [weak self] in self?.watchers[pid] = nil }
        watcher.show()
    }

    @objc private func togglePause(_ sender: NSMenuItem) {
        Controls.togglePause(Int32(sender.tag))
    }

    @objc private func toggleTakeOver(_ sender: NSMenuItem) {
        Controls.toggleTakeOver(Int32(sender.tag))
    }

    @objc private func answer(_ sender: NSMenuItem) {
        Controls.answer(Int32(sender.tag))
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Helpers

    private func disabled(_ title: String, small: Bool = false, wrap: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if small {
            item.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor,
            ])
        }
        if wrap, title.count > 60 {
            item.title = Self.clip(title, 120)
        }
        return item
    }

    private func action(_ title: String, _ selector: Selector, pid: Int32? = nil, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        if let pid { item.tag = Int(pid) }
        return item
    }

    static func describe(_ status: Registry.Status) -> String {
        switch status {
        case .idle: return "ready"
        case .working: return "working"
        case .paused: return "paused"
        case .needsYou: return "needs you"
        case .takenOver: return "you have control"
        }
    }

    static func color(_ status: Registry.Status) -> NSColor {
        switch status {
        case .needsYou: return .systemOrange
        case .paused, .takenOver: return .systemBlue
        default: return .secondaryLabelColor
        }
    }

    static func relative(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }

    static func clip(_ text: String, _ length: Int) -> String {
        text.count > length ? String(text.prefix(length)) + "…" : text
    }
}

/// The user's requests, written where the agent's process picks them up.
enum Controls {
    static func togglePause(_ pid: Int32) {
        var control = Registry.readControl(pid: pid)
        control.paused.toggle()
        Registry.writeControl(control, pid: pid)
    }

    static func toggleTakeOver(_ pid: Int32) {
        var control = Registry.readControl(pid: pid)
        control.takenOver.toggle()
        Registry.writeControl(control, pid: pid)
    }

    /// Asks for an optional reply, then tells the waiting agent the user is done.
    static func answer(_ pid: Int32) {
        let session = Registry.sessions().first { $0.pid == pid }
        let alert = NSAlert()
        alert.messageText = "Reply to \(session?.client ?? "the agent")"
        alert.informativeText = session?.message ?? "The agent asked for your help."
        alert.addButton(withTitle: "Hand Back")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Optional message for the agent"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var control = Registry.readControl(pid: pid)
        control.answeredAt = Date()
        let reply = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        control.answer = reply.isEmpty ? nil : reply
        control.takenOver = false
        Registry.writeControl(control, pid: pid)
    }
}

private extension NSFont {
    var bold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
}
