import AppKit
import CVirtualDisplay

/// An invisible display that belongs to one agent.
///
/// macOS treats it like a real monitor: apps draw on it, Accessibility and ScreenCaptureKit see
/// it, and it has its own Space, so nothing on it ever covers the user's work. Nobody can see it
/// except through a screenshot or the Viewer.
///
/// The display exists for exactly as long as this object (and at most as long as this process),
/// so an agent that crashes cannot leave a stray screen attached.
public final class AgentScreen {
    /// Distinct vendor number on every Backstage display, so any process can find them.
    public static let vendorID: UInt32 = 0xBAC5

    public let displayID: CGDirectDisplayID
    public let slot: Int
    public let size: CGSize
    private var backing: BSVirtualScreen?

    public enum Failure: Error, CustomStringConvertible {
        case unsupported
        case creationFailed
        case neverCameOnline
        case tooMany

        public var description: String {
            switch self {
            case .unsupported:
                return "This version of macOS does not offer virtual displays to apps."
            case .creationFailed:
                return "macOS refused to create a virtual display."
            case .neverCameOnline:
                return "The virtual display was created but never came online."
            case .tooMany:
                return "Every Backstage screen slot is in use. Close another agent's screen first."
            }
        }
    }

    public static var isSupported: Bool { BSVirtualScreen.isSupported }

    public init(width: Int, height: Int, hiDPI: Bool = false) throws {
        guard BSVirtualScreen.isSupported else { throw Failure.unsupported }
        let used = Set(Self.onlineBackstageDisplays().map { CGDisplaySerialNumber($0) })
        guard let slot = (1...8).first(where: { !used.contains(UInt32($0)) }) else { throw Failure.tooMany }

        guard let backing = BSVirtualScreen(
            name: "Backstage \(slot)",
            width: UInt32(width),
            height: UInt32(height),
            hiDPI: hiDPI,
            serial: UInt32(slot)
        ) else { throw Failure.creationFailed }

        // A new display takes a moment to receive its place in the arrangement.
        let deadline = Date().addingTimeInterval(4)
        while CGDisplayBounds(backing.displayID).isEmpty && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard !CGDisplayBounds(backing.displayID).isEmpty else {
            backing.invalidate()
            throw Failure.neverCameOnline
        }

        self.backing = backing
        self.displayID = backing.displayID
        self.slot = slot
        self.size = CGSize(width: width, height: height)
    }

    deinit { backing?.invalidate() }

    public var isAlive: Bool { backing != nil && !CGDisplayBounds(displayID).isEmpty }

    /// The display's rectangle in global coordinates (top-left origin).
    public var bounds: CGRect { CGDisplayBounds(displayID) }

    /// Height of the menu bar macOS draws across the top of this display.
    public var menuBarHeight: CGFloat {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { return 30 }
        return max(0, screen.frame.maxY - screen.visibleFrame.maxY)
    }

    /// The area windows may occupy, in global coordinates.
    public var usableBounds: CGRect {
        var rect = bounds
        let inset = menuBarHeight
        rect.origin.y += inset
        rect.size.height -= inset
        return rect
    }

    /// Converts a point the agent gave (relative to its screen, as in its screenshots) to global.
    public func toGlobal(_ point: CGPoint) -> CGPoint {
        CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y)
    }

    public func toLocal(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)
    }

    public func toLocal(_ rect: CGRect) -> CGRect {
        CGRect(origin: toLocal(rect.origin), size: rect.size)
    }

    public func destroy() {
        backing?.invalidate()
        backing = nil
    }

    /// Every Backstage display currently attached, from any process.
    public static func onlineBackstageDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { CGDisplayVendorNumber($0) == vendorID && !CGDisplayBounds($0).isEmpty }
    }

    /// The user's real displays: everything active that is not a Backstage screen.
    public static func userDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [CGMainDisplayID()] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [CGMainDisplayID()] }
        let user = ids.prefix(Int(count)).filter { CGDisplayVendorNumber($0) != vendorID }
        return user.isEmpty ? [CGMainDisplayID()] : Array(user)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
