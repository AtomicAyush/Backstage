import AppKit

/// Chromium-family browsers, which can run a second, fully separate copy of themselves.
///
/// Given its own profile folder, a browser starts as an independent process even while the
/// user's own copy is open. The agent gets a browser of its own, the user keeps theirs, and the
/// two never share windows, tabs, or history. The agent's profile persists, so a site the user
/// signs into for the agent stays signed in next time.
public enum Browsers {
    public struct Browser {
        public let name: String
        public let bundleID: String
        public let url: URL
    }

    /// In order of preference.
    static let known: [(name: String, bundleID: String)] = [
        ("Google Chrome", "com.google.Chrome"),
        ("Chromium", "org.chromium.Chromium"),
        ("Brave Browser", "com.brave.Browser"),
        ("Microsoft Edge", "com.microsoft.edgemac"),
        ("Vivaldi", "com.vivaldi.Vivaldi"),
        ("Google Chrome Canary", "com.google.Chrome.canary"),
    ]

    public static func isChromium(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return known.contains { $0.bundleID == bundleID }
    }

    public static func installed() -> [Browser] {
        known.compactMap { entry in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleID)
                .map { Browser(name: entry.name, bundleID: entry.bundleID, url: $0) }
        }
    }

    public static func preferred() -> Browser? {
        if let name = ProcessInfo.processInfo.environment["BACKSTAGE_BROWSER"],
           let match = installed().first(where: { $0.name.localizedCaseInsensitiveContains(name) || $0.bundleID == name }) {
            return match
        }
        return installed().first
    }

    public static func profileFolder(for browser: Browser, slot: Int) -> URL {
        let safeName = browser.name.replacingOccurrences(of: " ", with: "-")
        return Registry.root.appendingPathComponent("BrowserProfiles/\(safeName)-\(slot)", isDirectory: true)
    }

    /// Arguments for an agent-owned instance that opens directly on the agent's screen.
    public static func arguments(profile: URL, frame: CGRect, urls: [String]) -> [String] {
        [
            "--user-data-dir=\(profile.path)",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-default-apps",
            // Expose web content to Accessibility, so read_ui can see inside pages.
            "--force-renderer-accessibility",
            "--window-position=\(Int(frame.minX)),\(Int(frame.minY))",
            "--window-size=\(Int(frame.width)),\(Int(frame.height))",
        ] + urls
    }
}
