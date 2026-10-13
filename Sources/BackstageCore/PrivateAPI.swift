import ApplicationServices
import CoreGraphics
import Darwin

/// The two private functions Backstage relies on, resolved at runtime.
///
/// Both have been exported unchanged for many macOS releases, but they are not in the SDK, so we
/// look them up with dlsym instead of linking them. If Apple removes one, the binary still loads
/// and the feature that needs it reports a clear error.
public enum PrivateAPI {
    private static let handle = dlopen(nil, RTLD_LAZY)

    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias SetWindowLocationFn = @convention(c) (CGEvent, CGPoint) -> Void

    private static let getWindow: GetWindowFn? = dlsym(handle, "_AXUIElementGetWindow")
        .map { unsafeBitCast($0, to: GetWindowFn.self) }

    private static let setWindowLocation: SetWindowLocationFn? = dlsym(handle, "CGEventSetWindowLocation")
        .map { unsafeBitCast($0, to: SetWindowLocationFn.self) }

    /// The WindowServer window number behind an Accessibility window element.
    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let getWindow else { return nil }
        var id: CGWindowID = 0
        return getWindow(element, &id) == .success && id != 0 ? id : nil
    }

    /// Stamps a mouse event with its position inside the target window.
    ///
    /// The WindowServer fills this in for real clicks while routing them. An event posted
    /// straight to a process skips that routing, and without it AppKit sees every click at the
    /// window's corner.
    static func setWindowLocation(_ event: CGEvent, _ point: CGPoint) {
        setWindowLocation?(event, point)
    }

    public static var hasWindowIDSupport: Bool { getWindow != nil }
    public static var hasWindowLocationSupport: Bool { setWindowLocation != nil }
}
