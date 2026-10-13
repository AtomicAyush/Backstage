import CoreGraphics
import Foundation

/// Keeps the user's pointer on the user's own displays.
///
/// A virtual display joins the arrangement like any monitor, so without this the pointer would
/// slide off the edge of the user's screen and vanish into the agent's. The fence watches mouse
/// movement (listen-only, so it never delays or alters an event) and puts the pointer back at the
/// nearest edge the moment it crosses onto any Backstage display.
///
/// It runs on its own thread, so a long burst of agent typing on the main thread never leaves
/// the user's pointer unguarded.
public final class CursorFence {
    public static let shared = CursorFence()

    private var tap: CFMachPort?
    private let lock = NSLock()
    private var fenced: [CGRect] = []
    private var allowed: [CGRect] = []

    private init() {}

    public var isRunning: Bool { tap != nil }

    /// Starts the fence. Safe to call more than once.
    public func start() {
        guard tap == nil else { refresh(); return }
        let mask: CGEventMask = [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
            .reduce(0) { $0 | (1 << $1.rawValue) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, info in
                if let info {
                    Unmanaged<CursorFence>.fromOpaque(info).takeUnretainedValue().handle(type, event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: me
        ) else {
            Log.warn("cursor fence unavailable: could not create an event tap")
            return
        }
        self.tap = tap
        refresh()
        let thread = Thread {
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "Backstage cursor fence"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Re-reads the display arrangement. Call after any screen is added or removed.
    public func refresh() {
        let fenced = AgentScreen.onlineBackstageDisplays().map { CGDisplayBounds($0) }
        let allowed = AgentScreen.userDisplays().map { CGDisplayBounds($0) }
        lock.lock()
        self.fenced = fenced
        self.allowed = allowed
        lock.unlock()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        // Our own posted events never move the real pointer; ignore them outright.
        if event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) { return }
        let point = event.location
        lock.lock()
        let fenced = self.fenced, allowed = self.allowed
        lock.unlock()
        guard fenced.contains(where: { $0.contains(point) }) else { return }
        guard let target = Self.nearestPoint(to: point, in: allowed) else { return }
        CGWarpMouseCursorPosition(target)
        // A warp normally freezes the hardware pointer for a quarter second. Re-associating
        // cancels that, so the edge feels like a wall rather than a stall.
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// The closest point to `point` that lies inside one of `rects`.
    static func nearestPoint(to point: CGPoint, in rects: [CGRect]) -> CGPoint? {
        rects.map { rect -> CGPoint in
            CGPoint(
                x: min(max(point.x, rect.minX), rect.maxX - 1),
                y: min(max(point.y, rect.minY), rect.maxY - 1)
            )
        }
        .min { hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y) }
    }
}
