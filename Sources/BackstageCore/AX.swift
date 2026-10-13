import AppKit
import ApplicationServices

/// Small conveniences over the C Accessibility API. Every read is optional because any element
/// can disappear between two calls.
extension AXUIElement {
    static func application(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        // The default is six seconds. A hung app should cost the agent one second, not six.
        AXUIElementSetMessagingTimeout(app, 1.5)
        return app
    }

    func value<T>(_ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    func string(_ attribute: String) -> String? {
        guard let value: CFTypeRef = value(attribute) else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    var role: String { string(kAXRoleAttribute) ?? "" }
    var subrole: String { string(kAXSubroleAttribute) ?? "" }
    var roleDescription: String { string(kAXRoleDescriptionAttribute) ?? "" }
    var title: String { string(kAXTitleAttribute) ?? "" }
    var axDescription: String { string(kAXDescriptionAttribute) ?? "" }
    var help: String { string(kAXHelpAttribute) ?? "" }
    var placeholder: String { string(kAXPlaceholderValueAttribute) ?? "" }
    var identifier: String { string(kAXIdentifierAttribute) ?? "" }
    var valueString: String? { string(kAXValueAttribute) }

    var children: [AXUIElement] { value(kAXChildrenAttribute) ?? [] }
    var windows: [AXUIElement] { value(kAXWindowsAttribute) ?? [] }
    var parent: AXUIElement? { value(kAXParentAttribute) }

    var isEnabled: Bool { (value(kAXEnabledAttribute) as Bool?) ?? true }
    var isFocused: Bool { (value(kAXFocusedAttribute) as Bool?) ?? false }
    var isSelected: Bool { (value(kAXSelectedAttribute) as Bool?) ?? false }
    var isMinimized: Bool { (value(kAXMinimizedAttribute) as Bool?) ?? false }

    var position: CGPoint? {
        guard let value: AXValue = value(kAXPositionAttribute) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    var size: CGSize? {
        guard let value: AXValue = value(kAXSizeAttribute) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    /// Frame in global screen coordinates (top-left origin, the same space CGEvent uses).
    var frame: CGRect? {
        guard let position, let size else { return nil }
        return CGRect(origin: position, size: size)
    }

    var actions: [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(self, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(self, &pid) == .success ? pid : nil
    }

    var windowID: CGWindowID? { PrivateAPI.windowID(of: self) }

    func isSettable(_ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(self, attribute as CFString, &settable) == .success && settable.boolValue
    }

    @discardableResult
    func set(_ attribute: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(self, attribute as CFString, value)
    }

    @discardableResult
    func setPosition(_ point: CGPoint) -> AXError {
        var point = point
        return set(kAXPositionAttribute, AXValueCreate(.cgPoint, &point)!)
    }

    @discardableResult
    func setSize(_ size: CGSize) -> AXError {
        var size = size
        return set(kAXSizeAttribute, AXValueCreate(.cgSize, &size)!)
    }

    @discardableResult
    func perform(_ action: String) -> AXError {
        AXUIElementPerformAction(self, action as CFString)
    }

    /// The most human label available, in the order people would read it.
    var label: String {
        for candidate in [title, axDescription, placeholder, help] where !candidate.isEmpty {
            return candidate
        }
        // Many controls are labelled by a separate static text element.
        if let titleElement: AXUIElement = value(kAXTitleUIElementAttribute) {
            let text = titleElement.valueString ?? titleElement.title
            if !text.isEmpty { return text }
        }
        return ""
    }
}
