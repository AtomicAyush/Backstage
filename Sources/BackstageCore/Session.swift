import AppKit
import ApplicationServices

/// An error the agent should read: plain words about what went wrong and what to do instead.
public struct ToolError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// One agent's workspace: its invisible screen, the apps on it, and everything it can do there.
///
/// The screen is created lazily on the first action that needs it, so an agent that never uses
/// Backstage never adds a display. It goes away with `close()` or when the process exits.
@MainActor
public final class Session {
    public struct Options {
        public var width = 1440
        public var height = 900
        public var hiDPI = false
        public var fence = true

        public init() {}

        public static func fromEnvironment() -> Options {
            var options = Options()
            let env = ProcessInfo.processInfo.environment
            if let size = env["BACKSTAGE_SIZE"]?.split(separator: "x"), size.count == 2,
               let width = Int(size[0]), let height = Int(size[1]), width >= 800, height >= 600 {
                options.width = width
                options.height = height
            }
            options.hiDPI = env["BACKSTAGE_HIDPI"] == "1"
            options.fence = env["BACKSTAGE_FENCE"] != "0"
            return options
        }
    }

    /// An app living on the agent's screen.
    final class AgentApp {
        let app: NSRunningApplication
        let ax: AXUIElement
        /// Launched by the agent (quit at the end) or borrowed from the user (handed back).
        let launchedByAgent: Bool
        let isBrowser: Bool
        var placedWindows: Set<CGWindowID> = []
        /// Windows the user opened while using this app themselves. Never moved.
        var userWindows: Set<CGWindowID> = []
        var userEngaged = false
        var observer: AXObserver?

        func detach() {
            if let observer {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            }
            observer = nil
        }

        init(app: NSRunningApplication, launchedByAgent: Bool, isBrowser: Bool) {
            self.app = app
            self.ax = AXUIElement.application(app.processIdentifier)
            self.launchedByAgent = launchedByAgent
            self.isBrowser = isBrowser
        }

        var pid: pid_t { app.processIdentifier }
        var name: String { app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)" }
    }

    public let options: Options
    public var clientName = "Agent"
    public private(set) var screen: AgentScreen?

    var apps: [pid_t: AgentApp] = [:]
    private var activePid: pid_t?
    private var snapshot: UISnapshot?
    private var keeper: Timer?
    private var info: Registry.SessionInfo?
    private var control = Registry.Control()
    private var userFrontmost: NSRunningApplication?
    private var lastAgentActionAt = Date.distantPast
    private var notices: [String] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    public init(options: Options = .fromEnvironment()) {
        self.options = options
    }

    // MARK: - Screen lifecycle

    @discardableResult
    public func ensureScreen() throws -> AgentScreen {
        if let screen, screen.isAlive { return screen }
        guard AXIsProcessTrusted() else {
            throw ToolError("Backstage needs Accessibility permission. Open System Settings › Privacy & Security › Accessibility and turn it on for the app that runs your agent (your terminal, Claude, or Codex), then restart the agent.")
        }
        let screen: AgentScreen
        do {
            screen = try AgentScreen(width: options.width, height: options.height, hiDPI: options.hiDPI)
        } catch {
            throw ToolError("Could not create the agent screen: \(error)")
        }
        self.screen = screen
        if options.fence { CursorFence.shared.start() }
        CursorFence.shared.refresh()
        userFrontmost = NSWorkspace.shared.frontmostApplication
        startWatchingFocus()
        keeper?.invalidate()
        keeper = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        info = Registry.SessionInfo(
            pid: getpid(), slot: screen.slot, client: clientName, displayID: screen.displayID,
            width: Int(screen.size.width), height: Int(screen.size.height), startedAt: Date(),
            status: .idle, message: nil, lastAction: "Screen created", lastActionAt: Date(), apps: []
        )
        Registry.writeControl(Registry.Control(), pid: getpid())
        publish()
        Self.launchViewerIfInstalled()
        return screen
    }

    /// Quits the apps the agent opened, hands borrowed apps back, and removes the screen.
    @discardableResult
    public func close() -> String {
        keeper?.invalidate()
        keeper = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers = []

        var report: [String] = []
        let owned = apps.values.filter { $0.launchedByAgent && !$0.app.isTerminated }
        for app in owned { app.app.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while owned.contains(where: { !$0.app.isTerminated }) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        for app in apps.values where !app.app.isTerminated {
            // Still running: either the user's own app, or one asking to save changes. Either
            // way it now belongs on the user's screen, never silently force-quit.
            moveWindowsToUser(app)
            report.append(app.launchedByAgent
                ? "\(app.name) did not quit (it may be asking to save), so its windows were moved to the user's screen."
                : "\(app.name) was handed back to the user's screen.")
        }
        for app in apps.values { app.detach() }
        apps = [:]
        snapshot = nil
        activePid = nil
        screen?.destroy()
        screen = nil
        CursorFence.shared.refresh()
        Registry.remove(pid: getpid())
        info = nil
        return report.isEmpty ? "Closed the agent screen." : "Closed the agent screen. " + report.joined(separator: " ")
    }

    // MARK: - Opening things

    public func openApp(_ name: String, maximize: Bool = true, takeOver: Bool = false) async throws -> String {
        try ensureCanAct()
        let screen = try ensureScreen()
        guard let url = Self.findApplication(name) else {
            throw ToolError("Could not find an app called \"\(name)\". Use the name shown in Finder (e.g. \"TextEdit\") or a bundle ID (e.g. \"com.apple.TextEdit\").")
        }
        let bundleID = Bundle(url: url)?.bundleIdentifier
        if Browsers.isChromium(bundleID: bundleID) {
            return try await openURLs([], browserBundleID: bundleID)
        }

        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL == url || ($0.bundleIdentifier != nil && $0.bundleIdentifier == bundleID) }) {
            if let existing = apps[running.processIdentifier] {
                activePid = existing.pid
                placeWindows(of: existing, on: screen, maximize: maximize)
                return "\(existing.name) is already open on your screen.\n" + describeWindows(of: existing)
            }
            guard takeOver else {
                throw ToolError("\(running.localizedName ?? name) is already open on the user's screen, and Backstage does not take apps away from the user. Ask the user to quit it, or call open_app again with take_over: true if they agree to lend it to you. For web pages, use open_url, which gives you a separate browser.")
            }
            let app = adopt(running, launchedByAgent: false)
            placeWindows(of: app, on: screen, maximize: maximize)
            noteAction("Borrowed \(app.name) from the user")
            return "Borrowed \(app.name) from the user and moved its windows to your screen. It will be handed back when you call close_screen.\n" + describeWindows(of: app)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        markAgentAction()
        let running = try await Self.launch(url, configuration: configuration)
        let app = adopt(running, launchedByAgent: true)
        await waitForWindow(of: app)
        placeWindows(of: app, on: screen, maximize: maximize)
        guardFocus()
        noteAction("Opened \(app.name)")
        return "Opened \(app.name) on your screen (\(Int(screen.size.width))×\(Int(screen.size.height))).\n" + describeWindows(of: app)
    }

    /// Opens pages in the agent's own browser, starting it if needed.
    public func openURLs(_ urls: [String], browserBundleID: String? = nil, newWindow: Bool = false) async throws -> String {
        try ensureCanAct()
        let screen = try ensureScreen()
        for url in urls where URL(string: url)?.scheme == nil {
            throw ToolError("\"\(url)\" is not a full URL. Include the scheme, e.g. https://example.com")
        }
        let browser: Browsers.Browser
        if let browserBundleID, let match = Browsers.installed().first(where: { $0.bundleID == browserBundleID }) {
            browser = match
        } else if let existing = apps.values.first(where: { $0.isBrowser && !$0.app.isTerminated }),
                  let match = Browsers.installed().first(where: { $0.bundleID == existing.app.bundleIdentifier }) {
            browser = match
        } else if let preferred = Browsers.preferred() {
            browser = preferred
        } else {
            throw ToolError("Backstage needs a Chromium browser (Google Chrome, Brave, Edge, Chromium or Vivaldi) to give you a browser of your own, and none is installed.")
        }

        let profile = Browsers.profileFolder(for: browser, slot: screen.slot)
        try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        var arguments = Browsers.arguments(profile: profile, frame: screen.usableBounds, urls: urls)
        if newWindow { arguments.insert("--new-window", at: arguments.count - urls.count) }

        let existing = apps.values.first { $0.isBrowser && !$0.app.isTerminated && $0.app.bundleIdentifier == browser.bundleID }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        configuration.arguments = arguments
        markAgentAction()

        if let existing {
            // A second launch with the same profile hands its URLs to the running copy and exits.
            guard !urls.isEmpty else { return "\(existing.name) is already open on your screen.\n" + describeWindows(of: existing) }
            _ = try? await Self.launch(browser.url, configuration: configuration)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            activePid = existing.pid
            placeWindows(of: existing, on: screen, maximize: true)
            guardFocus()
            noteAction("Opened \(urls.joined(separator: ", "))")
            return "Opened \(urls.joined(separator: ", ")) in a new tab of your \(existing.name).\n" + describeWindows(of: existing)
        }

        let running = try await Self.launch(browser.url, configuration: configuration)
        let app = adopt(running, launchedByAgent: true, isBrowser: true)
        await waitForWindow(of: app, timeout: 10)
        placeWindows(of: app, on: screen, maximize: true)
        guardFocus()
        noteAction(urls.isEmpty ? "Opened \(browser.name)" : "Opened \(urls.joined(separator: ", "))")
        try? await Task.sleep(nanoseconds: 800_000_000)
        return "Opened your own \(browser.name) (separate from the user's) on your screen" +
            (urls.isEmpty ? "." : " at \(urls.joined(separator: ", ")).") + "\n" + describeWindows(of: app)
    }

    // MARK: - Seeing

    public func screenshot(region: CGRect? = nil) async throws -> (summary: String, data: Data, mimeType: String) {
        let screen = try ensureScreen()
        var image = try await Capture.image(of: screen.displayID, pointSize: screen.size)
        image = Self.coverMenuBar(image, height: screen.menuBarHeight)
        var origin = CGPoint.zero
        if let region {
            let bounds = CGRect(origin: .zero, size: screen.size)
            let crop = region.integral.intersection(bounds)
            guard !crop.isEmpty, let cropped = image.cropping(to: crop) else {
                throw ToolError("That region is outside your \(Int(screen.size.width))×\(Int(screen.size.height)) screen.")
            }
            image = cropped
            origin = crop.origin
        }
        let encoded = try Capture.encode(image)
        var summary = "Your screen is \(Int(screen.size.width))×\(Int(screen.size.height)); coordinates in this image are screen points"
        if origin != .zero { summary += " offset by (\(Int(origin.x)),\(Int(origin.y))), so add that to positions you read here" }
        summary += ".\n" + windowSummary()
        return (summary + drainNotices(), encoded.data, encoded.mimeType)
    }

    public func readUI(appName: String? = nil, limit: Int = 350) throws -> String {
        let screen = try ensureScreen()
        let targets: [AgentApp]
        if let appName {
            targets = [try app(named: appName)]
        } else {
            targets = orderedApps()
        }
        guard !targets.isEmpty else {
            return "Your screen has no apps yet. Use open_app or open_url first."
        }
        let snapshot = UISnapshot(origin: screen.bounds.origin, limit: limit)
        for app in targets {
            let windows = app.ax.windows.filter { window in
                guard !window.isMinimized, let frame = window.frame else { return false }
                return screen.bounds.intersects(frame)
            }
            if windows.isEmpty {
                snapshot.addLine("\(app.name): no windows on your screen.\n")
            }
            for window in windows { snapshot.addWindow(window, appName: app.name) }
        }
        if let focusedApp = activePid.flatMap({ apps[$0] }),
           let focused: AXUIElement = focusedApp.ax.value(kAXFocusedUIElementAttribute) {
            let label = focused.label
            snapshot.addLine("Keyboard focus: \(focused.roleDescription.isEmpty ? focused.role : focused.roleDescription)\(label.isEmpty ? "" : " \"\(label)\"") in \(focusedApp.name).")
        }
        if snapshot.truncated {
            snapshot.addLine("(Outline cut at \(limit) elements. Pass app, or a larger max_elements, to see more.)")
        }
        self.snapshot = snapshot
        return "Elements with [n] can be used as ref in click, type_text and scroll. Positions are (x,y width×height) on your screen.\n\n"
            + snapshot.text + drainNotices()
    }

    public func listWindows() throws -> String {
        try ensureScreen()
        return windowSummary(detailed: true) + drainNotices()
    }

    // MARK: - Acting

    public func click(ref: Int?, point: CGPoint?, button: Input.Button = .left, count: Int = 1) async throws -> String {
        try ensureCanAct()
        let screen = try ensureScreen()
        markAgentAction()
        if let ref {
            let element = try element(for: ref)
            guard let pid = element.pid, let app = apps[pid] else { throw ToolError("Element [\(ref)] is gone. Call read_ui again.") }
            let description = describe(element)
            // Native controls are pressed through Accessibility: no coordinates, nothing to
            // miss. Web content is clicked like a person would, because pages listen for mouse
            // events rather than accessibility actions.
            if button == .left, count == 1, !app.isBrowser,
               element.actions.contains(kAXPressAction as String),
               element.perform(kAXPressAction) == .success {
                activePid = pid
                try await settle()
                return "Pressed \(description) in \(app.name)." + drainNotices()
            }
            guard let frame = element.frame, !frame.isEmpty else {
                throw ToolError("\(description) has no position on screen, so it cannot be clicked.")
            }
            let center = CGPoint(x: frame.midX, y: frame.midY)
            guard screen.bounds.contains(center) else {
                throw ToolError("\(description) is outside your screen. Scroll it into view first.")
            }
            let target = try target(atGlobal: center, preferring: pid)
            Input.activate(pid: target.target.pid, windowID: target.target.windowID)
            Input.click(at: center, in: target.target, button: button, count: count)
            activePid = target.app.pid
            try await settle()
            return "Clicked \(description) in \(target.app.name)." + drainNotices()
        }
        guard let point else { throw ToolError("Give either ref or both x and y.") }
        let global = try globalPoint(point)
        let target = try target(atGlobal: global)
        Input.activate(pid: target.target.pid, windowID: target.target.windowID)
        Input.click(at: global, in: target.target, button: button, count: count)
        activePid = target.app.pid
        try await settle()
        let what = count == 2 ? "Double-clicked" : count == 3 ? "Triple-clicked" : button == .right ? "Right-clicked" : "Clicked"
        return "\(what) at (\(Int(point.x)),\(Int(point.y))) in \(target.app.name)." + drainNotices()
    }

    public func typeText(_ text: String, ref: Int?, clear: Bool, submit: Bool, appName: String?) async throws -> String {
        try ensureCanAct()
        try ensureScreen()
        markAgentAction()
        var field: AXUIElement?
        let app: AgentApp
        if let ref {
            let element = try element(for: ref)
            guard let pid = element.pid, let owner = apps[pid] else { throw ToolError("Element [\(ref)] is gone. Call read_ui again.") }
            app = owner
            field = element
            try await focus(element, in: owner)
        } else {
            app = try appForKeyboard(appName)
        }
        let windowID = keyWindowID(of: app)
        if clear {
            Input.press(try KeyCombo.parse("cmd+a"), pid: app.pid, windowID: windowID)
            Input.press(KeyCombo(keyCode: 51), pid: app.pid, windowID: windowID)
        }
        Input.type(text, pid: app.pid, windowID: windowID)
        if submit { Input.press(KeyCombo(keyCode: 36), pid: app.pid, windowID: windowID) }
        activePid = app.pid
        try await settle()

        var result = "Typed \(text.count) character\(text.count == 1 ? "" : "s") into \(app.name)"
        if let field, !submit, let value = field.valueString, field.role != "AXSecureTextField" {
            result += ". The field now reads: \"\(UISnapshot.clip(value, 200))\""
        }
        return result + "." + drainNotices()
    }

    public func pressKeys(_ keys: String, repeatCount: Int = 1, appName: String?) async throws -> String {
        try ensureCanAct()
        try ensureScreen()
        let combos = try keys.split(separator: " ").map { try KeyCombo.parse(String($0)) }
        guard !combos.isEmpty else { throw ToolError("No keys given.") }
        let app = try appForKeyboard(appName)
        markAgentAction()
        let windowID = keyWindowID(of: app)
        for _ in 0..<max(1, min(repeatCount, 50)) {
            for combo in combos {
                Input.press(combo, pid: app.pid, windowID: windowID)
                usleep(25_000)
            }
        }
        activePid = app.pid
        try await settle()
        let times = repeatCount > 1 ? " ×\(repeatCount)" : ""
        return "Pressed \(combos.map(\.description).joined(separator: " "))\(times) in \(app.name)." + drainNotices()
    }

    public func scroll(ref: Int?, point: CGPoint?, direction: String, amount: Int) async throws -> String {
        try ensureCanAct()
        let screen = try ensureScreen()
        markAgentAction()
        let global: CGPoint
        if let ref {
            let element = try element(for: ref)
            guard let frame = element.frame else { throw ToolError("Element [\(ref)] has no position.") }
            global = CGPoint(x: frame.midX, y: frame.midY)
        } else if let point {
            global = try globalPoint(point)
        } else if let app = activePid.flatMap({ apps[$0] }), let frame = frontWindow(of: app)?.frame {
            global = CGPoint(x: frame.midX, y: frame.midY)
        } else {
            global = CGPoint(x: screen.bounds.midX, y: screen.bounds.midY)
        }
        let steps = max(1, min(amount, 50))
        var dx = 0, dy = 0
        switch direction.lowercased() {
        case "down": dy = steps
        case "up": dy = -steps
        case "right": dx = steps
        case "left": dx = -steps
        default: throw ToolError("direction must be up, down, left or right.")
        }
        let target = try target(atGlobal: global)
        Input.scroll(at: global, dx: dx, dy: dy, in: target.target)
        activePid = target.app.pid
        try await settle()
        let local = screen.toLocal(global)
        return "Scrolled \(direction) \(steps) at (\(Int(local.x)),\(Int(local.y))) in \(target.app.name)." + drainNotices()
    }

    public func drag(from: CGPoint, to: CGPoint) async throws -> String {
        try ensureCanAct()
        try ensureScreen()
        markAgentAction()
        let start = try globalPoint(from)
        let end = try globalPoint(to)
        let target = try target(atGlobal: start)
        Input.activate(pid: target.target.pid, windowID: target.target.windowID)
        Input.drag(from: start, to: end, in: target.target)
        activePid = target.app.pid
        try await settle()
        return "Dragged from (\(Int(from.x)),\(Int(from.y))) to (\(Int(to.x)),\(Int(to.y))) in \(target.app.name)." + drainNotices()
    }

    public func hover(_ point: CGPoint) async throws -> String {
        try ensureCanAct()
        try ensureScreen()
        let global = try globalPoint(point)
        let target = try target(atGlobal: global)
        Input.move(to: global, in: target.target)
        try await settle()
        return "Moved the pointer to (\(Int(point.x)),\(Int(point.y))) in \(target.app.name). (Only the app sees this pointer; the user's cursor did not move.)" + drainNotices()
    }

    /// Picks a menu command through Accessibility, e.g. ["File", "Export as PDF…"].
    public func useMenu(_ path: [String], appName: String?) async throws -> String {
        try ensureCanAct()
        try ensureScreen()
        guard !path.isEmpty else { throw ToolError("Give the menu path, e.g. [\"File\", \"Save\"].") }
        let app = try appForKeyboard(appName)
        markAgentAction()
        guard let menuBar: AXUIElement = app.ax.value(kAXMenuBarAttribute) else {
            throw ToolError("\(app.name) has no menu bar available to Accessibility.")
        }
        if let window = frontWindow(of: app), let id = window.windowID {
            Input.activate(pid: app.pid, windowID: id)
        }
        var level = menuBar.children
        var item: AXUIElement?
        for (index, name) in path.enumerated() {
            guard let match = level.first(where: { Self.menuTitle($0.title, matches: name) }) else {
                let options = level.map(\.title).filter { !$0.isEmpty }
                throw ToolError("No \"\(name)\" in \(index == 0 ? "\(app.name)'s menu bar" : path[index - 1]). Available: \(options.joined(separator: ", ")).")
            }
            item = match
            if index < path.count - 1 {
                level = match.children.first?.children ?? []
            }
        }
        guard let item else { throw ToolError("Empty menu path.") }
        guard item.isEnabled else { throw ToolError("\(path.joined(separator: " › ")) is disabled right now.") }
        let error = item.perform(kAXPressAction)
        guard error == .success else { throw ToolError("\(app.name) did not accept the menu command (error \(error.rawValue)).") }
        activePid = app.pid
        try await settle()
        return "Chose \(path.joined(separator: " › ")) in \(app.name)." + drainNotices()
    }

    public func focusWindow(appName: String, title: String?) async throws -> String {
        try ensureCanAct()
        try ensureScreen()
        let app = try app(named: appName)
        let windows = app.ax.windows
        guard let window = title.map({ wanted in windows.first { $0.title.localizedCaseInsensitiveContains(wanted) } }) ?? windows.first else {
            throw ToolError("\(app.name) has no window\(title.map { " titled \"\($0)\"" } ?? ""). Its windows: \(windows.map { "\"\($0.title)\"" }.joined(separator: ", ")).")
        }
        window.perform(kAXRaiseAction)
        window.set(kAXMainAttribute, kCFBooleanTrue)
        if let id = window.windowID { Input.activate(pid: app.pid, windowID: id) }
        activePid = app.pid
        try await settle()
        return "\(app.name)'s window \"\(window.title)\" is now in front, and keys go to it." + drainNotices()
    }

    public func quitApp(_ appName: String, force: Bool) async throws -> String {
        try ensureScreen()
        let app = try app(named: appName)
        guard app.launchedByAgent else {
            moveWindowsToUser(app)
            app.detach()
            apps[app.pid] = nil
            return "\(app.name) belongs to the user, so it was not quit; its windows are back on the user's screen."
        }
        if force { app.app.forceTerminate() } else { app.app.terminate() }
        let deadline = Date().addingTimeInterval(4)
        while !app.app.isTerminated && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard app.app.isTerminated else {
            return "\(app.name) has not quit yet. It may be showing a dialog (for example, about unsaved changes). Take a screenshot, answer it, or call quit_app with force: true to discard changes."
        }
        app.detach()
        apps[app.pid] = nil
        if activePid == app.pid { activePid = orderedApps().first?.pid }
        publish()
        return "Quit \(app.name)."
    }

    /// Hands control to the user for something only they should do, such as signing in.
    public func askUser(_ message: String, waitSeconds: Int) async throws -> String {
        try ensureScreen()
        let askedAt = Date()
        setStatus(.needsYou, message: message)
        if !Self.viewerIsRunning {
            Self.notify(title: "Your agent needs you", body: message)
        }
        let deadline = askedAt.addingTimeInterval(TimeInterval(max(5, min(waitSeconds, 600))))
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 500_000_000)
            tick()
            if let answered = control.answeredAt, answered > askedAt {
                setStatus(.working, message: nil)
                let answer = control.answer.map { " They said: \"\($0)\"" } ?? ""
                return "The user is done.\(answer) Take a screenshot to see where things stand."
            }
        }
        return "The user has not responded yet. They can see your request in the Backstage menu. Call ask_user again to keep waiting, or carry on with something else."
    }

    // MARK: - Status

    public var hasScreen: Bool { screen?.isAlive == true }

    public func noteAction(_ action: String) {
        guard info != nil else { return }
        info?.lastAction = action
        info?.lastActionAt = Date()
        if info?.status == .idle { info?.status = .working }
        publish()
    }

    private func setStatus(_ status: Registry.Status, message: String?) {
        info?.status = status
        info?.message = message
        publish()
    }

    private func publish() {
        guard var info else { return }
        info.client = clientName
        info.apps = orderedApps().map(\.name)
        self.info = info
        Registry.write(info)
    }

    // MARK: - The keeper

    /// Runs four times a second: keeps agent windows on the agent screen, follows the user's
    /// requests from the Viewer, and notices apps that quit.
    private func tick() {
        guard let screen else { return }
        if !screen.isAlive {
            Log.warn("the agent screen disappeared")
            return
        }
        applyControl()
        for (pid, app) in apps where app.app.isTerminated {
            app.detach()
            apps[pid] = nil
            if activePid == pid { activePid = nil }
            publish()
        }
        guard !control.takenOver else { return }
        for app in apps.values { placeWindows(of: app, on: screen, maximize: true) }
    }

    private func applyControl() {
        let latest = Registry.readControl(pid: getpid())
        guard latest != control else { return }
        let wasTakenOver = control.takenOver
        control = latest
        if latest.takenOver && !wasTakenOver {
            for app in apps.values { moveWindowsToUser(app) }
            setStatus(.takenOver, message: nil)
        } else if !latest.takenOver && wasTakenOver {
            for app in apps.values {
                // Back on the agent screen at the size the user left them.
                app.placedWindows.removeAll()
                if let screen { placeWindows(of: app, on: screen, maximize: false) }
            }
            setStatus(latest.paused ? .paused : .working, message: nil)
        } else if info?.status != .needsYou {
            setStatus(latest.paused ? .paused : (latest.takenOver ? .takenOver : .working), message: nil)
        }
    }

    private func ensureCanAct() throws {
        applyControl()
        if control.takenOver {
            throw ToolError("The user has taken over your apps from the Backstage menu. Wait for them to hand control back (ask_user lets you wait), then take a screenshot.")
        }
        if control.paused {
            throw ToolError("The user paused this session from the Backstage menu. Stop and wait for them to resume it.")
        }
    }

    // MARK: - Windows

    private func adopt(_ running: NSRunningApplication, launchedByAgent: Bool, isBrowser: Bool = false) -> AgentApp {
        if let existing = apps[running.processIdentifier] { return existing }
        let app = AgentApp(app: running, launchedByAgent: launchedByAgent,
                           isBrowser: isBrowser || Browsers.isChromium(bundleID: running.bundleIdentifier))
        if !launchedByAgent {
            // Windows the user already has open stay theirs when this app is handed back.
            app.placedWindows = []
        }
        // Chromium and Electron only build their accessibility tree when asked.
        app.ax.set("AXManualAccessibility", kCFBooleanTrue)
        observeWindows(of: app)
        apps[running.processIdentifier] = app
        activePid = running.processIdentifier
        publish()
        return app
    }

    /// Moves new windows the moment they appear, rather than at the next keeper tick.
    private func observeWindows(of app: AgentApp) {
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let session = Unmanaged<Session>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated {
                guard let pid = element.pid, let app = session.apps[pid], let screen = session.screen,
                      !session.control.takenOver else { return }
                session.placeWindows(of: app, on: screen, maximize: true)
            }
        }
        guard AXObserverCreate(app.pid, callback, &observer) == .success, let observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, app.ax, kAXWindowCreatedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        app.observer = observer
    }

    private func placeWindows(of app: AgentApp, on screen: AgentScreen, maximize: Bool) {
        guard !app.userEngaged else { return }
        let usable = screen.usableBounds
        for window in app.ax.windows {
            guard let id = window.windowID, !app.userWindows.contains(id), !window.isMinimized,
                  let frame = window.frame else { continue }
            let isNew = !app.placedWindows.contains(id)
            let onScreen = screen.bounds.contains(CGPoint(x: frame.midX, y: frame.midY))
            guard isNew || !onScreen else { continue }

            let standard = window.subrole == "AXStandardWindow"
            if isNew && maximize && standard {
                window.setPosition(usable.origin)
                window.setSize(usable.size)
            } else {
                // Keep the size the app chose, shrunk to fit, centred on the agent screen.
                let size = CGSize(width: min(frame.width, usable.width), height: min(frame.height, usable.height))
                if size != frame.size { window.setSize(size) }
                window.setPosition(CGPoint(x: usable.midX - size.width / 2, y: usable.minY + max(0, (usable.height - size.height) / 3)))
            }
            app.placedWindows.insert(id)
        }
    }

    private func moveWindowsToUser(_ app: AgentApp) {
        let main = CGDisplayBounds(CGMainDisplayID())
        let visible = NSScreen.screens.first(where: { $0.displayID == CGMainDisplayID() }).map {
            CGRect(x: $0.visibleFrame.minX, y: main.height - $0.visibleFrame.maxY,
                   width: $0.visibleFrame.width, height: $0.visibleFrame.height)
        } ?? main.insetBy(dx: 0, dy: 30)
        for (index, window) in app.ax.windows.enumerated() {
            guard let frame = window.frame else { continue }
            let size = CGSize(width: min(frame.width, visible.width - 40), height: min(frame.height, visible.height - 40))
            if size != frame.size { window.setSize(size) }
            let offset = CGFloat(index * 24)
            window.setPosition(CGPoint(x: visible.midX - size.width / 2 + offset, y: visible.minY + 20 + offset))
        }
    }

    private func waitForWindow(of app: AgentApp, timeout: TimeInterval = 6) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !app.ax.windows.isEmpty { return }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    }

    /// The window keystrokes should go to, after telling the app it is active so that window is key.
    private func keyWindowID(of app: AgentApp) -> CGWindowID? {
        guard let id = frontWindow(of: app)?.windowID else { return nil }
        Input.activate(pid: app.pid, windowID: id)
        return id
    }

    private func frontWindow(of app: AgentApp) -> AXUIElement? {
        if let focused: AXUIElement = app.ax.value(kAXFocusedWindowAttribute) { return focused }
        if let main: AXUIElement = app.ax.value(kAXMainWindowAttribute) { return main }
        return app.ax.windows.first
    }

    // MARK: - Focus protection

    private func startWatchingFocus() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.applicationActivated(app) }
        })
    }

    private func applicationActivated(_ activated: NSRunningApplication?) {
        guard let activated else { return }
        guard let app = apps[activated.processIdentifier] else {
            userFrontmost = activated
            for app in apps.values where app.userEngaged { app.userEngaged = false }
            return
        }
        // Right after the agent did something, an agent app coming forward is the app pulling
        // focus by itself: hand it straight back. Otherwise the user switched to it on purpose
        // (Dock, ⌘-Tab), so leave them be and keep their new windows on their screen.
        if Date().timeIntervalSince(lastAgentActionAt) < 3 {
            restoreUserFocus(from: app)
        } else {
            app.userEngaged = true
            for window in app.ax.windows { if let id = window.windowID, !app.placedWindows.contains(id) { app.userWindows.insert(id) } }
        }
    }

    private func guardFocus() {
        guard let front = NSWorkspace.shared.frontmostApplication, let app = apps[front.processIdentifier] else { return }
        restoreUserFocus(from: app)
    }

    private func restoreUserFocus(from app: AgentApp) {
        guard let user = userFrontmost, !user.isTerminated, apps[user.processIdentifier] == nil else { return }
        user.activate()
        notices.append("\(app.name) tried to take keyboard focus from the user; Backstage gave it back to \(user.localizedName ?? "their app"). Your input still reaches \(app.name).")
    }

    private func markAgentAction() {
        lastAgentActionAt = Date()
    }

    private func drainNotices() -> String {
        guard !notices.isEmpty else { return "" }
        defer { notices = [] }
        return "\nNote: " + notices.joined(separator: "\nNote: ")
    }

    // MARK: - Lookups

    private func app(named name: String) throws -> AgentApp {
        let wanted = name.lowercased()
        if let match = apps.values.first(where: { $0.name.lowercased() == wanted || $0.app.bundleIdentifier?.lowercased() == wanted })
            ?? apps.values.first(where: { $0.name.lowercased().contains(wanted) }) {
            return match
        }
        let names = orderedApps().map(\.name)
        throw ToolError("\"\(name)\" is not open on your screen. \(names.isEmpty ? "Nothing is open yet." : "Open: \(names.joined(separator: ", ")).") Use open_app first.")
    }

    private func appForKeyboard(_ name: String?) throws -> AgentApp {
        if let name { return try app(named: name) }
        if let active = activePid.flatMap({ apps[$0] }), !active.app.isTerminated { return active }
        if let first = orderedApps().first { return first }
        throw ToolError("No app is open on your screen. Use open_app or open_url first.")
    }

    /// Apps front to back, as they are stacked on the agent screen.
    private func orderedApps() -> [AgentApp] {
        var order: [pid_t] = []
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
            for entry in list {
                if let pid = entry[kCGWindowOwnerPID as String] as? pid_t, apps[pid] != nil, !order.contains(pid) {
                    order.append(pid)
                }
            }
        }
        if let active = activePid, let index = order.firstIndex(of: active) { order.remove(at: index); order.insert(active, at: 0) }
        let rest = apps.keys.filter { !order.contains($0) }.sorted()
        return (order + rest).compactMap { apps[$0] }.filter { !$0.app.isTerminated }
    }

    private func element(for ref: Int) throws -> AXUIElement {
        guard let snapshot else { throw ToolError("No refs yet. Call read_ui first.") }
        guard let element = snapshot.elements[ref] else {
            throw ToolError("There is no [\(ref)] in the last read_ui (it had \(snapshot.refCount)). Call read_ui again.")
        }
        guard element.pid != nil, !element.role.isEmpty else {
            throw ToolError("Element [\(ref)] no longer exists; the interface changed. Call read_ui again.")
        }
        return element
    }

    private func focus(_ element: AXUIElement, in app: AgentApp) async throws {
        if !app.isBrowser, element.isSettable(kAXFocusedAttribute), element.set(kAXFocusedAttribute, kCFBooleanTrue) == .success {
            if let window = frontWindow(of: app), let id = window.windowID { Input.activate(pid: app.pid, windowID: id) }
            return
        }
        guard let frame = element.frame, !frame.isEmpty else { return }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let target = try target(atGlobal: center, preferring: app.pid)
        Input.activate(pid: target.target.pid, windowID: target.target.windowID)
        Input.click(at: center, in: target.target)
        try await Task.sleep(nanoseconds: 120_000_000)
    }

    private func globalPoint(_ local: CGPoint) throws -> CGPoint {
        guard let screen else { throw ToolError("No screen.") }
        guard local.x >= 0, local.y >= 0, local.x < screen.size.width, local.y < screen.size.height else {
            throw ToolError("(\(Int(local.x)),\(Int(local.y))) is off your screen, which is \(Int(screen.size.width))×\(Int(screen.size.height)).")
        }
        if local.y < screen.menuBarHeight {
            throw ToolError("That is the menu bar strip, which belongs to the user. Use use_menu to reach an app's menus.")
        }
        return screen.toGlobal(local)
    }

    /// The topmost agent window under a point. Menus and popovers count, so clicks land in
    /// whatever the agent just opened.
    private func target(atGlobal point: CGPoint, preferring pid: pid_t? = nil) throws -> (target: Input.Target, app: AgentApp) {
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        for entry in list {
            guard let owner = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let app = apps[owner],
                  let number = entry[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.contains(point) else { continue }
            if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha < 0.05 { continue }
            if let pid, pid != owner, (entry[kCGWindowLayer as String] as? Int ?? 0) == 0 { continue }
            return (Input.Target(pid: owner, windowID: number, windowFrame: bounds), app)
        }
        let local = screen?.toLocal(point) ?? point
        throw ToolError("None of your apps has a window at (\(Int(local.x)),\(Int(local.y))). Take a screenshot to see where things are.")
    }

    private func describe(_ element: AXUIElement) -> String {
        let role = element.roleDescription.isEmpty ? element.role : element.roleDescription
        let label = element.label
        return label.isEmpty ? role : "\(role) \"\(UISnapshot.clip(label, 60))\""
    }

    private func describeWindows(of app: AgentApp) -> String {
        guard let screen else { return "" }
        let windows = app.ax.windows
        guard !windows.isEmpty else { return "\(app.name) has no windows yet. Take a screenshot in a moment." }
        return windows.map { window in
            let frame = window.frame.map { screen.toLocal($0) }
            let place = frame.map { " at (\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height)))" } ?? ""
            return "• \(app.name) window \"\(window.title.isEmpty ? "untitled" : window.title)\"\(place)"
        }.joined(separator: "\n")
    }

    private func windowSummary(detailed: Bool = false) -> String {
        let ordered = orderedApps()
        guard !ordered.isEmpty else { return "No apps are open on your screen yet." }
        var lines = ["Open on your screen (front first):"]
        for app in ordered {
            let windows = app.ax.windows.filter { !$0.isMinimized }
            let keys = app.pid == activePid ? " ← keyboard goes here" : ""
            if detailed {
                lines.append("\(app.name)\(app.launchedByAgent ? "" : " (borrowed from the user)")\(keys)")
                lines.append(contentsOf: describeWindows(of: app).split(separator: "\n").map { "  " + $0 })
            } else {
                let titles = windows.prefix(3).map { "\"\($0.title.isEmpty ? "untitled" : $0.title)\"" }.joined(separator: ", ")
                lines.append("• \(app.name): \(titles.isEmpty ? "no windows" : titles)\(keys)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func settle() async throws {
        // Give the app a moment to react before the agent looks again.
        try await Task.sleep(nanoseconds: 180_000_000)
        guardFocus()
    }

    // MARK: - Helpers

    static func menuTitle(_ title: String, matches wanted: String) -> Bool {
        func normalize(_ text: String) -> String {
            text.lowercased()
                .replacingOccurrences(of: "…", with: "")
                .replacingOccurrences(of: "...", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
        return !title.isEmpty && normalize(title) == normalize(wanted)
    }

    static func findApplication(_ name: String) -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix(".app"), FileManager.default.fileExists(atPath: trimmed) {
            return URL(fileURLWithPath: trimmed)
        }
        if trimmed.contains("."), !trimmed.contains(" "),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed) {
            return url
        }
        let bare = trimmed.replacingOccurrences(of: ".app", with: "")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                       "/Applications/Utilities", "\(home)/Applications", "/System/Library/CoreServices"]
        for folder in folders {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            if let match = items.first(where: { $0.lowercased() == bare.lowercased() + ".app" }) {
                return URL(fileURLWithPath: folder).appendingPathComponent(match)
            }
        }
        // Spotlight finds apps anywhere, including ones whose display name differs from the file.
        let query = Process()
        query.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        query.arguments = ["kMDItemContentType == 'com.apple.application-bundle' && kMDItemDisplayName == '\(bare.replacingOccurrences(of: "'", with: ""))'c"]
        let pipe = Pipe()
        query.standardOutput = pipe
        query.standardError = FileHandle.nullDevice
        guard (try? query.run()) != nil else { return nil }
        query.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output.split(separator: "\n").first.map { URL(fileURLWithPath: String($0)) }
    }

    static func launch(_ url: URL, configuration: NSWorkspace.OpenConfiguration) async throws -> NSRunningApplication {
        try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                if let app { continuation.resume(returning: app) }
                else { continuation.resume(throwing: ToolError("macOS could not open \(url.lastPathComponent): \(error?.localizedDescription ?? "unknown error")")) }
            }
        }
    }

    /// The top strip of the agent screen shows the user's menu bar, which the agent cannot use
    /// and has no business reading. Screenshots show a plain bar in its place.
    static func coverMenuBar(_ image: CGImage, height: CGFloat) -> CGImage {
        guard height > 0, let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return image }
        let bar = height
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setFillColor(CGColor(gray: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: CGFloat(image.height) - bar, width: CGFloat(image.width), height: bar))
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let label = NSAttributedString(string: "Backstage — use the use_menu tool for app menus", attributes: [
            .font: NSFont.systemFont(ofSize: max(10, bar * 0.48), weight: .medium),
            .foregroundColor: NSColor(white: 0.75, alpha: 1),
        ])
        let textSize = label.size()
        label.draw(at: CGPoint(x: 12, y: CGFloat(image.height) - bar + (bar - textSize.height) / 2))
        NSGraphicsContext.current = previous
        return context.makeImage() ?? image
    }

    // MARK: - Viewer and notifications

    static let viewerBundleID = "com.ayush.Backstage.Viewer"

    static var viewerIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: viewerBundleID).isEmpty
    }

    static func launchViewerIfInstalled() {
        guard !viewerIsRunning, ProcessInfo.processInfo.environment["BACKSTAGE_NO_VIEWER"] != "1",
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: viewerBundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }

    static func notify(title: String, body: String) {
        let script = "display notification \(appleScriptString(body)) with title \(appleScriptString(title))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    private static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
