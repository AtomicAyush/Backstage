import AppKit
import CoreGraphics

/// Synthetic input aimed at one app, without touching the user's pointer or keyboard focus.
///
/// Every event goes straight to the target process with `CGEvent.postToPid`, which skips the
/// WindowServer's normal routing. That is what keeps the user's cursor still and their frontmost
/// app frontmost. It also means we must fill in what routing normally provides: which window the
/// event is for, and where inside that window it landed.
public enum Input {
    public enum Button: String {
        case left, right, middle

        var cgButton: CGMouseButton {
            switch self {
            case .left: return .left
            case .right: return .right
            case .middle: return .center
            }
        }

        var down: CGEventType {
            switch self {
            case .left: return .leftMouseDown
            case .right: return .rightMouseDown
            case .middle: return .otherMouseDown
            }
        }

        var up: CGEventType {
            switch self {
            case .left: return .leftMouseUp
            case .right: return .rightMouseUp
            case .middle: return .otherMouseUp
            }
        }

        var dragged: CGEventType {
            switch self {
            case .left: return .leftMouseDragged
            case .right: return .rightMouseDragged
            case .middle: return .otherMouseDragged
            }
        }
    }

    /// Where pointer events go: a process, one of its windows, and that window's global frame.
    public struct Target {
        public let pid: pid_t
        public let windowID: CGWindowID
        public let windowFrame: CGRect

        public init(pid: pid_t, windowID: CGWindowID, windowFrame: CGRect) {
            self.pid = pid
            self.windowID = windowID
            self.windowFrame = windowFrame
        }
    }

    /// A private event source: its modifier state is ours alone, so a held "cmd" here can never
    /// leak into what the user is typing.
    private static let source = CGEventSource(stateID: .privateState)

    // Undocumented but stable CGEvent fields. 51 is the window an event belongs to (what
    // -[NSEvent windowNumber] reads); 91 and 92 are the window under the pointer.
    private static let windowNumberField = CGEventField(rawValue: 51)!
    private static let windowUnderPointerField = CGEventField(rawValue: 91)!
    private static let windowUnderPointerThatCanHandleField = CGEventField(rawValue: 92)!
    // Field 76 is 253 on key events AppKit builds itself and 252 on CGEvent-built ones. AppKit
    // only tries a keystroke against the menu bar and window shortcuts (⌘L, ⌘S, …) when it is
    // 253; otherwise the shortcut arrives at the focused view as a plain letter.
    private static let keyRoutingField = CGEventField(rawValue: 76)!

    /// Tells an app it is the active app, without making it frontmost.
    ///
    /// AppKit ignores the first click on an inactive app's window (that click normally just
    /// brings the app forward). This uses the same AppKit-defined "application activated" event
    /// the system sends on a real switch, delivered only to the target. The WindowServer's idea of
    /// the frontmost app, the menu bar, and the user's keyboard focus are all left alone.
    public static func activate(pid: pid_t, windowID: CGWindowID) {
        guard let event = NSEvent.otherEvent(
            with: .appKitDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: Int(windowID),
            context: nil,
            subtype: NSEvent.EventSubtype.applicationActivated.rawValue,
            data1: 0,
            data2: 0
        ) else { return }
        event.cgEvent?.postToPid(pid)
    }

    public static func move(to point: CGPoint, in target: Target) {
        post(.mouseMoved, at: point, button: .left, in: target)
    }

    public static func click(at point: CGPoint, in target: Target, button: Button = .left, count: Int = 1) {
        // Hover first, like a real pointer. Web views decide what is under the pointer from
        // movement, and drop a press that arrives with no movement before it.
        post(.mouseMoved, at: point, button: .left, in: target)
        pause(0.03)
        for clickNumber in 1...max(1, min(count, 3)) {
            post(button.down, at: point, button: button, clickState: clickNumber, in: target)
            pause(0.04)
            post(button.up, at: point, button: button, clickState: clickNumber, in: target)
            pause(0.06)
        }
    }

    public static func drag(from start: CGPoint, to end: CGPoint, in target: Target, button: Button = .left) {
        post(.mouseMoved, at: start, button: button, in: target)
        pause(0.03)
        post(button.down, at: start, button: button, clickState: 1, in: target)
        pause(0.08)
        let distance = hypot(end.x - start.x, end.y - start.y)
        let steps = max(4, min(40, Int(distance / 12)))
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            post(button.dragged, at: point, button: button, clickState: 1, in: target)
            pause(0.012)
        }
        pause(0.05)
        post(button.up, at: end, button: button, clickState: 1, in: target)
    }

    /// Scrolls by whole "notches" of a mouse wheel. Positive `dy` scrolls content down.
    public static func scroll(at point: CGPoint, dx: Int, dy: Int, in target: Target) {
        post(.mouseMoved, at: point, button: .left, in: target)
        pause(0.02)
        // Pixel units scroll the same distance in every app; line units vary wildly.
        let notch: Int32 = 48
        let steps = max(abs(dx), abs(dy), 1)
        for step in 0..<steps {
            let y: Int32 = step < abs(dy) ? (dy > 0 ? -notch : notch) : 0
            let x: Int32 = step < abs(dx) ? (dx > 0 ? -notch : notch) : 0
            guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                      wheel1: y, wheel2: x, wheel3: 0) else { continue }
            event.location = point
            stamp(event, at: point, in: target)
            event.postToPid(target.pid)
            pause(0.016)
        }
    }

    /// Presses a key combination: modifiers down, key down and up, modifiers up.
    ///
    /// `windowID` should be the app's key window, so the keystroke is routed like a real one.
    public static func press(_ combo: KeyCombo, pid: pid_t, windowID: CGWindowID? = nil) {
        // Only real shortcuts take AppKit's shortcut route. Plain keys and shift+key keep the
        // character we send, which is what makes accents, emoji and other layouts type correctly.
        let shortcut = !combo.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
        var held: CGEventFlags = []
        for (flag, code) in Keys.modifierKeys where combo.flags.contains(flag) {
            held.insert(flag)
            postKey(code, down: true, flags: held, pid: pid, windowID: windowID, shortcut: shortcut)
        }
        postKey(combo.keyCode, down: true, flags: combo.flags, character: combo.character, pid: pid, windowID: windowID, shortcut: shortcut)
        postKey(combo.keyCode, down: false, flags: combo.flags, character: combo.character, pid: pid, windowID: windowID, shortcut: shortcut)
        for (flag, code) in Keys.modifierKeys.reversed() where combo.flags.contains(flag) {
            held.remove(flag)
            postKey(code, down: false, flags: held, pid: pid, windowID: windowID, shortcut: shortcut)
        }
    }

    /// Types text into whatever has keyboard focus inside the app.
    public static func type(_ text: String, pid: pid_t, windowID: CGWindowID? = nil, delay: TimeInterval = 0.008) {
        for character in text {
            if character == "\n" || character == "\r\n" {
                press(KeyCombo(keyCode: 36), pid: pid, windowID: windowID)
            } else if character == "\t" {
                press(KeyCombo(keyCode: 48), pid: pid, windowID: windowID)
            } else {
                let key = Keys.code(for: character)
                let flags: CGEventFlags = key?.shift == true ? .maskShift : []
                let string = String(character)
                postKey(key?.code ?? 0, down: true, flags: flags, character: string, pid: pid, windowID: windowID)
                postKey(key?.code ?? 0, down: false, flags: flags, character: string, pid: pid, windowID: windowID)
            }
            pause(delay)
        }
    }

    // MARK: - Plumbing

    private static func post(_ type: CGEventType, at point: CGPoint, button: Button, clickState: Int = 0, in target: Target) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                                  mouseButton: button.cgButton) else { return }
        if clickState > 0 {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        }
        stamp(event, at: point, in: target)
        event.postToPid(target.pid)
    }

    private static func stamp(_ event: CGEvent, at point: CGPoint, in target: Target) {
        let window = Int64(target.windowID)
        event.setIntegerValueField(windowNumberField, value: window)
        event.setIntegerValueField(windowUnderPointerField, value: window)
        event.setIntegerValueField(windowUnderPointerThatCanHandleField, value: window)
        PrivateAPI.setWindowLocation(event, CGPoint(x: point.x - target.windowFrame.minX,
                                                    y: point.y - target.windowFrame.minY))
    }

    private static func postKey(_ code: CGKeyCode, down: Bool, flags: CGEventFlags, character: String? = nil,
                                pid: pid_t, windowID: CGWindowID? = nil, shortcut: Bool = false) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        event.flags = flags
        if shortcut { event.setIntegerValueField(keyRoutingField, value: 253) }
        if let windowID { event.setIntegerValueField(windowNumberField, value: Int64(windowID)) }
        if let character {
            let units = Array(character.utf16.prefix(20))
            units.withUnsafeBufferPointer { buffer in
                event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
        }
        event.postToPid(pid)
        pause(0.004)
    }

    private static func pause(_ seconds: TimeInterval) {
        usleep(useconds_t(seconds * 1_000_000))
    }
}
