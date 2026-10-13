import AppKit
import ApplicationServices

/// A readable outline of an app's interface, built from the Accessibility tree.
///
/// Each element worth acting on gets a short number (a "ref") that the agent can pass back to
/// click or type into it. Clicking by ref is coordinate-free, so it cannot miss when a layout
/// shifts by a few pixels. Refs stay valid until the next snapshot.
public final class UISnapshot {
    public private(set) var text = ""
    public private(set) var elements: [Int: AXUIElement] = [:]
    public private(set) var truncated = false
    private var count = 0
    private let limit: Int
    private let origin: CGPoint

    /// Roles that are just layout. They are not printed, but their children are.
    private static let structural: Set<String> = [
        "AXGroup", "AXScrollArea", "AXSplitGroup", "AXLayoutArea", "AXLayoutItem", "AXUnknown",
        "AXList", "AXOutline", "AXTable", "AXColumn", "AXCell", "AXBrowser", "AXGrowArea",
        "AXMatte", "AXRuler", "AXRulerMarker", "AXSplitter", "AXWebArea", "AXSection", "AXGenericElement",
        "AXScrollBar", "AXLandmarkMain", "AXLandmarkNavigation", "AXLandmarkBanner", "AXLandmarkContentInfo",
    ]

    /// Roles worth a ref, because the agent can do something with them.
    private static let actionable: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXComboBox",
        "AXTextField", "AXTextArea", "AXSearchField", "AXSecureTextField", "AXSlider", "AXIncrementor",
        "AXLink", "AXTab", "AXTabButton", "AXDisclosureTriangle", "AXColorWell", "AXDateField",
        "AXMenuItem", "AXMenuBarItem", "AXDockItem", "AXSwitch", "AXToggle", "AXStepper", "AXSegment",
        "AXRow", "AXValueIndicator",
    ]

    /// Roles whose visible text is their label. When they have no label of their own, the text
    /// inside them becomes the label, and that inner text is not printed a second time.
    private static let summarized: Set<String> = [
        "AXButton", "AXLink", "AXRow", "AXHeading", "AXTab", "AXTabButton", "AXMenuItem", "AXRadioButton",
        "AXCheckBox", "AXMenuButton", "AXPopUpButton", "AXCell",
    ]

    /// Roles with nothing useful inside them.
    private static let leaves: Set<String> = [
        "AXTextField", "AXTextArea", "AXSearchField", "AXSecureTextField", "AXPopUpButton", "AXComboBox",
        "AXSlider", "AXCheckBox", "AXRadioButton", "AXIncrementor", "AXColorWell", "AXDateField", "AXSwitch",
    ]

    /// Containers printed even without a label, because they explain where things are.
    private static let landmarks: Set<String> = ["AXToolbar", "AXTabGroup", "AXSheet", "AXDialog", "AXPopover"]

    private static let friendlyRoles: [String: String] = [
        "AXButton": "button", "AXCheckBox": "checkbox", "AXRadioButton": "radio", "AXPopUpButton": "popup",
        "AXMenuButton": "menu button", "AXComboBox": "combo box", "AXTextField": "text field",
        "AXTextArea": "text area", "AXSearchField": "search field", "AXSecureTextField": "password field",
        "AXStaticText": "text", "AXLink": "link", "AXImage": "image", "AXSlider": "slider",
        "AXTab": "tab", "AXTabGroup": "tabs", "AXToolbar": "toolbar", "AXMenuItem": "menu item",
        "AXMenuBarItem": "menu", "AXHeading": "heading", "AXDisclosureTriangle": "disclosure",
        "AXRow": "row", "AXCell": "cell", "AXSheet": "sheet", "AXDialog": "dialog",
        "AXIncrementor": "stepper", "AXColorWell": "color well", "AXDateField": "date field",
        "AXValueIndicator": "slider thumb", "AXSwitch": "switch", "AXList": "list",
    ]

    /// - Parameters:
    ///   - origin: global position of the agent screen's top-left, so frames print in the same
    ///     coordinates as the agent's screenshots.
    ///   - limit: maximum number of printed elements, to keep the outline readable.
    public init(origin: CGPoint, limit: Int = 350) {
        self.origin = origin
        self.limit = limit
    }

    public func addWindow(_ window: AXUIElement, appName: String) {
        let title = window.title
        var header = "Window \"\(title.isEmpty ? "untitled" : title)\" — \(appName)"
        if let frame = window.frame { header += " \(format(frame))" }
        if window.subrole == "AXDialog" || window.subrole == "AXSystemDialog" { header += " (dialog)" }
        text += header + "\n"
        walk(window.children, depth: 1, clip: window.frame)
        text += "\n"
    }

    public func addLine(_ line: String) {
        text += line + "\n"
    }

    public var refCount: Int { elements.count }

    private func walk(_ children: [AXUIElement], depth: Int, clip: CGRect?, insideLabel: Bool = false) {
        for child in children {
            if count >= limit { truncated = true; return }
            walk(child, depth: depth, clip: clip, insideLabel: insideLabel)
        }
    }

    private func walk(_ element: AXUIElement, depth: Int, clip: CGRect?, insideLabel: Bool) {
        guard depth < 40 else { return }
        let role = element.role
        let frame = element.frame

        // Skip anything scrolled out of view. It cannot be clicked, and long lists would
        // otherwise drown the parts the agent can see.
        if let frame, let clip, !frame.isEmpty, !clip.intersects(frame) { return }

        if role == "AXStaticText" {
            guard !insideLabel, let value = Self.displayValue(of: element, role: role), !value.isEmpty else { return }
            emit(element, role: role, label: "", value: value, frame: frame, depth: depth, ref: false)
            return
        }

        let isActionable = Self.actionable.contains(role) || element.actions.contains(kAXPressAction as String)
        var label = element.label
        var labelFromText = false
        if label.isEmpty, Self.summarized.contains(role) {
            label = Self.innerText(of: element)
            labelFromText = !label.isEmpty
        }
        let value = Self.displayValue(of: element, role: role)

        let printable: Bool
        if Self.structural.contains(role) {
            printable = false
        } else if role == "AXImage" {
            printable = !label.isEmpty
        } else {
            printable = isActionable || !label.isEmpty || !(value ?? "").isEmpty || Self.landmarks.contains(role)
        }
        if printable {
            emit(element, role: role, label: label, value: value, frame: frame, depth: depth, ref: isActionable)
        }
        if Self.leaves.contains(role) { return }

        var childClip = clip
        if role == "AXScrollArea", let frame { childClip = clip.map { $0.intersection(frame) } ?? frame }
        walk(element.children, depth: printable ? depth + 1 : depth, clip: childClip,
             insideLabel: insideLabel || (printable && Self.summarized.contains(role) && (labelFromText || !label.isEmpty)))
    }

    private func emit(_ element: AXUIElement, role: String, label: String, value: String?, frame: CGRect?, depth: Int, ref: Bool) {
        var line = String(repeating: "  ", count: depth)
        if ref {
            let number = elements.count + 1
            elements[number] = element
            line += "[\(number)] "
        }
        line += Self.friendlyRoles[role] ?? role.replacingOccurrences(of: "AX", with: "").lowercased()
        if role == "AXStaticText" {
            line += " \"\(Self.clip(value ?? "", 160))\""
        } else {
            if !label.isEmpty { line += " \"\(Self.clip(label, 80))\"" }
            if let value, !value.isEmpty, value != label { line += " value=\"\(Self.clip(value, 120))\"" }
        }
        if !element.isEnabled { line += " disabled" }
        if element.isFocused { line += " focused" }
        if element.isSelected { line += " selected" }
        if let frame, !frame.isEmpty { line += " " + format(frame) }
        text += line + "\n"
        count += 1
    }

    /// The text a person would read inside an element, for controls with no label of their own.
    private static func innerText(of element: AXUIElement, depth: Int = 0) -> String {
        guard depth < 5 else { return "" }
        var parts: [String] = []
        for child in element.children.prefix(12) {
            if child.role == "AXStaticText" {
                if let value = child.valueString?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    parts.append(value)
                }
            } else {
                let label = child.label
                let inner = label.isEmpty ? innerText(of: child, depth: depth + 1) : label
                if !inner.isEmpty { parts.append(inner) }
            }
            if parts.joined(separator: " ").count > 100 { break }
        }
        return parts.joined(separator: " ")
    }

    private static func displayValue(of element: AXUIElement, role: String) -> String? {
        if role == "AXSecureTextField" { return nil }
        if role == "AXCheckBox" || role == "AXRadioButton" || role == "AXSwitch" {
            guard let raw = element.valueString else { return nil }
            return raw == "1" ? "on" : raw == "0" ? "off" : raw
        }
        guard let value = element.valueString else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func format(_ frame: CGRect) -> String {
        "(\(Int(frame.minX - origin.x)),\(Int(frame.minY - origin.y)) \(Int(frame.width))x\(Int(frame.height)))"
    }

    static func clip(_ string: String, _ length: Int) -> String {
        let flat = string.replacingOccurrences(of: "\n", with: " ⏎ ")
        return flat.count > length ? String(flat.prefix(length)) + "…" : flat
    }
}
