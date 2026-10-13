import AppKit
import BackstageCore

/// A read-only check of everything Backstage depends on. Changes nothing.
enum Doctor {
    static func run() -> Bool {
        var healthy = true
        func check(_ ok: Bool, _ title: String, _ fix: String? = nil, required: Bool = true) {
            print("\(ok ? "✓" : (required ? "✗" : "–")) \(title)")
            if !ok, let fix { print("    \(fix)") }
            if !ok && required { healthy = false }
        }

        let os = ProcessInfo.processInfo.operatingSystemVersion
        print("Backstage \(Version.current) on macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)\n")

        let host = responsibleApp()
        check(AXIsProcessTrusted(), "Accessibility permission",
              "Turn on \(host) in System Settings › Privacy & Security › Accessibility.")
        check(CGPreflightScreenCaptureAccess(), "Screen Recording permission",
              "Turn on \(host) in System Settings › Privacy & Security › Screen & System Audio Recording.")
        check(AgentScreen.isSupported, "Virtual displays available",
              "This macOS does not expose CGVirtualDisplay; Backstage cannot create agent screens.")
        check(PrivateAPI.hasWindowLocationSupport, "Background clicks supported",
              "CGEventSetWindowLocation is missing; clicks by coordinate will not land.")
        check(PrivateAPI.hasWindowIDSupport, "Window lookup supported",
              "_AXUIElementGetWindow is missing; window tracking will be limited.")

        let browsers = Browsers.installed()
        check(!browsers.isEmpty, "A browser for open_url: \(browsers.first?.name ?? "none")",
              "Install Google Chrome, Brave, Edge, Chromium or Vivaldi to give agents a browser of their own.",
              required: false)

        let viewer = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.ayush.Backstage.Viewer")
        check(viewer != nil, "Backstage Viewer installed\(viewer.map { " (\($0.path))" } ?? "")",
              "Run ./install.sh to install the menu-bar Viewer.", required: false)

        let screens = AgentScreen.onlineBackstageDisplays()
        let sessions = Registry.sessions()
        check(AgentScreen.hasAwakeUserDisplay, "A display of your own is awake",
              "Backstage only creates agent screens while one of your displays is on (open the lid or wake the screen).")
        let orphans = AgentScreen.orphanedDisplays()
        check(orphans.isEmpty, "No leftover agent screens",
              "\(orphans.count) agent screen\(orphans.count == 1 ? " has" : "s have") no owner. Run `backstage cleanup`.")
        print("\nAgent screens online: \(screens.count)")
        for session in sessions {
            print("  \(session.name) — \(session.client), \(session.status.rawValue), apps: \(session.apps.joined(separator: ", "))")
        }
        print(healthy ? "\nReady." : "\nFix the items marked ✗, then run `backstage doctor` again.")
        return healthy
    }

    /// The app macOS charges permissions to: the terminal or agent app that started us.
    static func responsibleApp() -> String {
        var pid = getppid()
        for _ in 0..<12 {
            if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName, app.bundleIdentifier != nil {
                return name
            }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, info.kp_eproc.e_ppid > 1 else { break }
            pid = info.kp_eproc.e_ppid
        }
        return "the app that runs your agent (your terminal, Claude, or Codex)"
    }
}
