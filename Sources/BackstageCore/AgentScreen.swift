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
        case noUserDisplay

        public var description: String {
            switch self {
            case .noUserDisplay:
                return "The Mac has no screen of its own awake right now (is the lid closed?). Backstage waits for a real display, because an agent screen must never become the only one."
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
        guard Self.hasAwakeUserDisplay else { throw Failure.noUserDisplay }
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

    deinit {
        // Last resort only; Session retires screens through destroy(), which waits when needed.
        backing?.invalidate()
    }

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

    /// Detaches the display. Returns false, leaving it attached, while no real display is awake.
    ///
    /// macOS will not remove the last display it has: with the lid closed, an agent screen is
    /// promoted to main display, and detaching it then silently fails and leaves it behind with
    /// no owner. Waiting until a real display is back avoids that.
    @discardableResult
    public func destroy() -> Bool {
        guard backing != nil else { return true }
        guard Self.hasAwakeUserDisplay else { return false }
        backing?.invalidate()
        backing = nil
        return true
    }

    /// Whether at least one of the user's own displays is attached and awake.
    public static var hasAwakeUserDisplay: Bool {
        userDisplays().contains { CGDisplayIsAsleep($0) == 0 }
    }

    /// Backstage displays that no running session owns: left behind when a process could not
    /// remove its screen (see `destroy`).
    public static func orphanedDisplays() -> [CGDirectDisplayID] {
        let owned = Set(Registry.sessions().map(\.displayID))
        return onlineBackstageDisplays().filter { !owned.contains($0) }
    }

    /// Tries to remove orphaned screens by attaching a display with the same identity and then
    /// detaching it, which gives macOS a live owner to retire. Returns one line per display.
    public static func retireOrphans() -> [String] {
        var report: [String] = []
        for id in orphanedDisplays() {
            guard hasAwakeUserDisplay else {
                report.append("Display \(id): left in place, because no real display is awake to take its place.")
                break
            }
            let serial = CGDisplaySerialNumber(id)
            let claim = BSVirtualScreen(name: "Backstage \(serial)", width: UInt32(CGDisplayPixelsWide(id)),
                                        height: UInt32(CGDisplayPixelsHigh(id)), hiDPI: false, serial: serial)
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            claim?.invalidate()
            let deadline = Date().addingTimeInterval(4)
            while onlineBackstageDisplays().contains(id) && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
            report.append(onlineBackstageDisplays().contains(id)
                ? "Display \(id): still attached. Logging out or restarting removes it."
                : "Display \(id): removed.")
        }
        return report
    }

    /// Every Backstage display currently attached, from any process.
    public static func onlineBackstageDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { CGDisplayVendorNumber($0) == vendorID && !CGDisplayBounds($0).isEmpty }
    }

    /// The user's real displays: everything active that is not a Backstage screen. Empty when
    /// the lid is closed with no monitor attached.
    public static func userDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { CGDisplayVendorNumber($0) != vendorID }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
