import AppKit
import BackstageCore

// Backstage's menu-bar app. Agents launch it when they create a screen; it shows what each
// agent is doing and lets the user watch, pause, take over, or answer them. It quits itself a
// little while after the last agent screen goes away, so the icon is only there while needed.
//
// `backstage watch` opens a live view: it launches the app with `--watch <pid>`, or, when the
// app is already running, asks it over a distributed notification.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: StatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let status = StatusController()
        self.status = status
        DistributedNotificationCenter.default().addObserver(
            forName: ViewerRequests.watch, object: nil, queue: .main
        ) { note in
            if let pid = (note.object as? String).flatMap(Int32.init) { status.watch(pid) }
        }
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--watch"), index + 1 < arguments.count, let pid = Int32(arguments[index + 1]) {
            status.watch(pid)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
