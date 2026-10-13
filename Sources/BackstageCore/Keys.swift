import CoreGraphics

/// A key press with modifiers, parsed from text like "cmd+shift+t", "return" or "ctrl+a".
public struct KeyCombo: Equatable, CustomStringConvertible {
    public var keyCode: CGKeyCode
    public var character: String?
    public var flags: CGEventFlags

    public var description: String {
        var parts: [String] = []
        if flags.contains(.maskControl) { parts.append("ctrl") }
        if flags.contains(.maskAlternate) { parts.append("option") }
        if flags.contains(.maskShift) { parts.append("shift") }
        if flags.contains(.maskCommand) { parts.append("cmd") }
        if flags.contains(.maskSecondaryFn) { parts.append("fn") }
        parts.append(character ?? Keys.name(for: keyCode) ?? "key\(keyCode)")
        return parts.joined(separator: "+")
    }

    public enum ParseError: Error, CustomStringConvertible {
        case empty
        case unknownKey(String)
        case onlyModifiers(String)

        public var description: String {
            switch self {
            case .empty: return "No key given."
            case .unknownKey(let key): return "Unknown key \"\(key)\"."
            case .onlyModifiers(let text): return "\"\(text)\" has modifiers but no key."
            }
        }
    }

    public init(keyCode: CGKeyCode, character: String? = nil, flags: CGEventFlags = []) {
        self.keyCode = keyCode
        self.character = character
        self.flags = flags
    }

    public static func parse(_ text: String) throws -> KeyCombo {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw ParseError.empty }
        // "+" on its own, or as the last part of "cmd++", is the plus key.
        var parts = trimmed.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if trimmed.hasSuffix("+") {
            parts = Array(parts.dropLast(2)) + ["+"]
        }
        var flags: CGEventFlags = []
        var key: String?
        for raw in parts {
            let part = raw.trimmingCharacters(in: .whitespaces)
            if let modifier = Keys.modifiers[part.lowercased()] {
                flags.insert(modifier)
            } else if key == nil, !part.isEmpty {
                key = part
            } else if !part.isEmpty {
                throw ParseError.unknownKey(part)
            }
        }
        guard let key else { throw ParseError.onlyModifiers(text) }

        if let code = Keys.named[key.lowercased()] {
            return KeyCombo(keyCode: code, flags: flags)
        }
        if key.count == 1, let typed = Keys.code(for: Character(key)) {
            var combo = KeyCombo(keyCode: typed.code, character: key.lowercased(), flags: flags)
            // "cmd+T" means cmd+shift+t, the way people write shortcuts.
            if typed.shift { combo.flags.insert(.maskShift) }
            return combo
        }
        throw ParseError.unknownKey(key)
    }
}

public enum Keys {
    static let modifiers: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "⌘": .maskCommand, "meta": .maskCommand, "super": .maskCommand,
        "shift": .maskShift, "⇧": .maskShift,
        "alt": .maskAlternate, "option": .maskAlternate, "opt": .maskAlternate, "⌥": .maskAlternate,
        "ctrl": .maskControl, "control": .maskControl, "⌃": .maskControl,
        "fn": .maskSecondaryFn,
    ]

    /// Virtual key codes of the modifier keys themselves, pressed before and released after.
    static let modifierKeys: [(CGEventFlags, CGKeyCode)] = [
        (.maskControl, 59), (.maskAlternate, 58), (.maskShift, 56), (.maskCommand, 55), (.maskSecondaryFn, 63),
    ]

    static let named: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "spacebar": 49,
        "delete": 51, "backspace": 51, "forwarddelete": 117, "del": 117,
        "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "arrowleft": 123, "arrowright": 124, "arrowdown": 125, "arrowup": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "help": 114,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113,
        "keypadenter": 76, "plus": 24, "minus": 27,
    ]

    /// US ANSI positions. Virtual key codes name physical keys, so this is the layout apps assume
    /// when they read key codes; the character itself travels separately in each event.
    private static let unshifted: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50, " ": 49, "\n": 36, "\r": 36, "\t": 48,
    ]

    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    /// The key that types `character`, and whether it needs shift. Nil for anything off the
    /// keyboard (accents, emoji), which is still typed by sending the character itself.
    public static func code(for character: Character) -> (code: CGKeyCode, shift: Bool)? {
        if let code = unshifted[character] { return (code, false) }
        if let base = shifted[character], let code = unshifted[base] { return (code, true) }
        if character.isUppercase, let lower = character.lowercased().first, let code = unshifted[lower] {
            return (code, true)
        }
        return nil
    }

    static func name(for code: CGKeyCode) -> String? {
        let preferred = ["return", "tab", "space", "delete", "forwarddelete", "escape", "left", "right", "down", "up",
                         "home", "end", "pageup", "pagedown", "help"]
        if let name = preferred.first(where: { named[$0] == code }) { return name }
        return named.first(where: { $0.value == code })?.key
    }
}
