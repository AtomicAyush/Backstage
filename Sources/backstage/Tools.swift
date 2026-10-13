import BackstageCore
import Foundation

/// The tools an agent sees, and the glue from JSON arguments to the session.
@MainActor
struct Tools {
    let session: Session

    static let instructions = """
    Backstage gives you a screen of your own on the user's Mac. Apps you open here appear only on \
    that screen, never on the user's display, and your clicks and keystrokes go straight to those \
    apps. The user's cursor, keyboard and frontmost app are never touched, so they keep working \
    while you do. Use these tools instead of general computer-use or screenshot tools whenever you \
    work with Mac apps on this computer.

    Typical loop: open_app or open_url → read_ui (numbered refs) or screenshot → click, type_text, \
    press_key or scroll → screenshot or read_ui to confirm it worked.

    - Prefer refs from read_ui over coordinates. Coordinates are screen points and match screenshot pixels.
    - open_url gives you your own browser, separate from the user's (own windows, tabs and logins).
    - Apps the user already has open are not taken from them unless they agree (take_over).
    - The strip at the top of your screen is the user's menu bar; use use_menu for app menus.
    - For signing in, payments, or anything the user should do personally, call ask_user.
    - Call close_screen when you are finished.
    """

    var definitions: [[String: Any]] {
        [
            tool("open_app", "Open a Mac app on your screen (not the user's). Returns its windows. Chromium browsers open as your own separate copy.", [
                "name": string("App name as shown in Finder (\"TextEdit\", \"Notes\") or a bundle ID."),
                "maximize": boolean("Fill your screen with its main window. Default true."),
                "take_over": boolean("If the user already has this app open, borrow it anyway (moves their windows to your screen). Only with the user's agreement."),
            ], required: ["name"]),
            tool("open_url", "Open web pages in your own browser on your screen, separate from the user's browser. Opens a new tab if your browser is already running.", [
                "url": string("Full URL including https://"),
                "new_window": boolean("Open in a new window instead of a tab."),
            ], required: ["url"]),
            tool("screenshot", "See your screen. Coordinates in the image are screen points you can pass to click, scroll, drag and hover.", [
                "x": number("Optional crop: left edge."),
                "y": number("Optional crop: top edge."),
                "width": number("Optional crop width."),
                "height": number("Optional crop height."),
            ], readOnly: true),
            tool("read_ui", "Read the interface of the apps on your screen as an outline from Accessibility. Elements marked [n] can be passed as ref to click, type_text and scroll. Cheaper and more exact than screenshots for finding controls.", [
                "app": string("Only this app. Default: every app on your screen, front first."),
                "max_elements": integer("Limit on printed elements. Default 350."),
            ], readOnly: true),
            tool("click", "Click an element (by ref from read_ui) or a point on your screen. The user's real cursor does not move.", [
                "ref": integer("Element number from the last read_ui."),
                "x": number("Screen x, if not using ref."),
                "y": number("Screen y, if not using ref."),
                "button": enumeration(["left", "right", "middle"], "Default left."),
                "count": integer("2 for double-click, 3 for triple-click. Default 1."),
            ]),
            tool("type_text", "Type text into an app on your screen. With ref, focuses that field first. Newlines press Return.", [
                "text": string("What to type."),
                "ref": integer("Field to type into, from read_ui. Default: wherever the app's keyboard focus is."),
                "clear": boolean("Select all and delete before typing."),
                "submit": boolean("Press Return afterwards."),
                "app": string("App to type into when not using ref. Default: the app you used last."),
            ], required: ["text"]),
            tool("press_key", "Press keys or shortcuts in an app on your screen, e.g. \"return\", \"cmd+s\", \"cmd+shift+t\", or several separated by spaces: \"cmd+a delete\".", [
                "keys": string("Key or space-separated sequence of combos."),
                "repeat": integer("Press the whole sequence this many times. Default 1."),
                "app": string("Target app. Default: the app you used last."),
            ], required: ["keys"]),
            tool("scroll", "Scroll at an element or point on your screen.", [
                "direction": enumeration(["up", "down", "left", "right"], "Which way to move the content."),
                "amount": integer("Wheel notches, about 50 points each. Default 5."),
                "ref": integer("Scroll the element with this ref."),
                "x": number("Screen x."),
                "y": number("Screen y."),
            ], required: ["direction"]),
            tool("drag", "Press at one point, move to another, release. For sliders, selecting text, moving items.", [
                "from_x": number("Start x."), "from_y": number("Start y."),
                "to_x": number("End x."), "to_y": number("End y."),
            ], required: ["from_x", "from_y", "to_x", "to_y"]),
            tool("hover", "Move the app's idea of the pointer to a point, to reveal hover menus or tooltips. The user's cursor does not move.", [
                "x": number("Screen x."), "y": number("Screen y."),
            ], required: ["x", "y"]),
            tool("use_menu", "Choose a command from an app's menu bar, e.g. [\"File\", \"Export as PDF…\"]. Works without seeing the menu.", [
                "path": ["type": "array", "items": ["type": "string"], "description": "Menu titles from the menu bar down to the command."],
                "app": string("Default: the app you used last."),
            ], required: ["path"]),
            tool("list_windows", "List the apps and windows on your screen, front first, and which one receives keystrokes.", [:], readOnly: true),
            tool("focus_window", "Bring one of your windows to the front so keystrokes go to it.", [
                "app": string("App name."),
                "title": string("Part of the window title. Default: its first window."),
            ], required: ["app"]),
            tool("quit_app", "Quit an app you opened. Apps borrowed from the user are handed back instead.", [
                "app": string("App name."),
                "force": boolean("Quit without letting it ask about unsaved changes."),
            ], required: ["app"]),
            tool("wait", "Wait for something to finish loading. Up to 30 seconds.", [
                "seconds": number("How long. Default 2."),
            ], readOnly: true),
            tool("ask_user", "Ask the user to step in, e.g. to sign in, approve a payment, or solve something only they can. Shows in the Backstage menu and as a notification, then waits for them to say they are done.", [
                "message": string("What you need them to do, in one or two sentences."),
                "wait_seconds": integer("How long to wait for them before returning. Default 120, at most 600."),
            ], required: ["message"]),
            tool("close_screen", "Finish: quit the apps you opened, hand back borrowed ones, and remove your screen.", [:]),
        ]
    }

    func call(_ name: String, arguments args: [String: Any]) async -> [String: Any] {
        do {
            let content: [[String: Any]]
            switch name {
            case "open_app":
                content = text(try await session.openApp(
                    try required(args, "name"),
                    maximize: bool(args, "maximize") ?? true,
                    takeOver: bool(args, "take_over") ?? false))
            case "open_url":
                content = text(try await session.openURLs([try required(args, "url")], newWindow: bool(args, "new_window") ?? false))
            case "screenshot":
                var region: CGRect?
                if let x = double(args, "x"), let y = double(args, "y"), let width = double(args, "width"), let height = double(args, "height") {
                    region = CGRect(x: x, y: y, width: width, height: height)
                }
                let shot = try await session.screenshot(region: region)
                content = [
                    ["type": "image", "data": shot.data.base64EncodedString(), "mimeType": shot.mimeType],
                    ["type": "text", "text": shot.summary],
                ]
            case "read_ui":
                content = text(try session.readUI(appName: args["app"] as? String, limit: int(args, "max_elements") ?? 350))
            case "click":
                content = text(try await session.click(
                    ref: int(args, "ref"), point: point(args, "x", "y"),
                    button: Input.Button(rawValue: (args["button"] as? String ?? "left").lowercased()) ?? .left,
                    count: int(args, "count") ?? 1))
            case "type_text":
                content = text(try await session.typeText(
                    try required(args, "text"), ref: int(args, "ref"),
                    clear: bool(args, "clear") ?? false, submit: bool(args, "submit") ?? false,
                    appName: args["app"] as? String))
            case "press_key":
                content = text(try await session.pressKeys(try required(args, "keys"), repeatCount: int(args, "repeat") ?? 1,
                                                           appName: args["app"] as? String))
            case "scroll":
                content = text(try await session.scroll(ref: int(args, "ref"), point: point(args, "x", "y"),
                                                        direction: try required(args, "direction"), amount: int(args, "amount") ?? 5))
            case "drag":
                guard let from = point(args, "from_x", "from_y"), let to = point(args, "to_x", "to_y") else {
                    throw ToolError("drag needs from_x, from_y, to_x and to_y.")
                }
                content = text(try await session.drag(from: from, to: to))
            case "hover":
                guard let at = point(args, "x", "y") else { throw ToolError("hover needs x and y.") }
                content = text(try await session.hover(at))
            case "use_menu":
                let path: [String]
                if let list = args["path"] as? [String] {
                    path = list
                } else if let single = args["path"] as? String {
                    path = single.components(separatedBy: CharacterSet(charactersIn: ">›")).map { $0.trimmingCharacters(in: .whitespaces) }
                } else {
                    throw ToolError("path is required, e.g. [\"File\", \"Save\"].")
                }
                content = text(try await session.useMenu(path, appName: args["app"] as? String))
            case "list_windows":
                content = text(try session.listWindows())
            case "focus_window":
                content = text(try await session.focusWindow(appName: try required(args, "app"), title: args["title"] as? String))
            case "quit_app":
                content = text(try await session.quitApp(try required(args, "app"), force: bool(args, "force") ?? false))
            case "wait":
                let seconds = min(max(double(args, "seconds") ?? 2, 0), 30)
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                content = text("Waited \(seconds.formatted()) s.")
            case "ask_user":
                content = text(try await session.askUser(try required(args, "message"), waitSeconds: int(args, "wait_seconds") ?? 120))
            case "close_screen":
                content = text(session.hasScreen ? session.close() : "There was no screen to close.")
            default:
                throw ToolError("Unknown tool \"\(name)\".")
            }
            if name != "close_screen", let summary = content.compactMap({ $0["text"] as? String }).first {
                session.noteAction(String(summary.split(separator: "\n").first ?? ""))
            }
            return ["content": content, "isError": false]
        } catch {
            return ["content": text("\(error)"), "isError": true]
        }
    }

    // MARK: - Schema helpers

    private func tool(_ name: String, _ description: String, _ properties: [String: Any],
                      required: [String] = [], readOnly: Bool = false) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return [
            "name": name,
            "description": description,
            "inputSchema": schema,
            "annotations": ["readOnlyHint": readOnly, "openWorldHint": false],
        ]
    }

    private func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
    private func number(_ description: String) -> [String: Any] { ["type": "number", "description": description] }
    private func integer(_ description: String) -> [String: Any] { ["type": "integer", "description": description] }
    private func boolean(_ description: String) -> [String: Any] { ["type": "boolean", "description": description] }
    private func enumeration(_ values: [String], _ description: String) -> [String: Any] {
        ["type": "string", "enum": values, "description": description]
    }

    // MARK: - Argument helpers

    private func text(_ string: String) -> [[String: Any]] { [["type": "text", "text": string]] }

    private func required(_ args: [String: Any], _ key: String) throws -> String {
        guard let value = args[key] as? String, !value.isEmpty else { throw ToolError("\(key) is required.") }
        return value
    }

    private func bool(_ args: [String: Any], _ key: String) -> Bool? {
        if let value = args[key] as? Bool { return value }
        if let value = args[key] as? String { return ["true", "yes", "1"].contains(value.lowercased()) }
        return nil
    }

    private func double(_ args: [String: Any], _ key: String) -> Double? {
        if let value = args[key] as? NSNumber { return value.doubleValue }
        if let value = args[key] as? String { return Double(value) }
        return nil
    }

    private func int(_ args: [String: Any], _ key: String) -> Int? {
        double(args, key).map { Int($0.rounded()) }
    }

    private func point(_ args: [String: Any], _ xKey: String, _ yKey: String) -> CGPoint? {
        guard let x = double(args, xKey), let y = double(args, yKey) else { return nil }
        return CGPoint(x: x, y: y)
    }
}
