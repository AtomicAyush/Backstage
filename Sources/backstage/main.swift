import AppKit
import BackstageCore

enum Version {
    static let current = "0.1.0"
}

let usage = """
backstage \(Version.current) — give AI agents their own screen on your Mac

Usage:
  backstage mcp                 Run the MCP server (what Claude Code, Claude, and Codex launch)
  backstage setup [client…]     Connect Backstage to claude-code, claude-desktop, codex (default: all found)
  backstage doctor              Check permissions and system support
  backstage try                 Run a short live demo on an agent screen and verify isolation
  backstage watch [screen]      Open a live view of an agent screen (default: the first)
  backstage cleanup             Remove agent screens left behind by sessions that ended badly
  backstage version             Print the version

Environment:
  BACKSTAGE_SIZE=1440x900       Agent screen size in points
  BACKSTAGE_BROWSER=Chrome      Which Chromium browser open_url uses
  BACKSTAGE_FENCE=0             Let your pointer wander onto agent screens
  BACKSTAGE_DEBUG=1             Log diagnostics to stderr
"""

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "mcp":
    MainActor.assumeIsolated { MCPServer.run() }
case "doctor":
    exit(Doctor.run() ? 0 : 1)
case "setup":
    exit(Setup.run(Array(arguments.dropFirst())) ? 0 : 1)
case "try":
    MainActor.assumeIsolated { SelfTest.run() }
case "watch":
    let sessions = Registry.sessions()
    let wanted = arguments.dropFirst().first.flatMap(Int.init)
    guard let session = sessions.first(where: { wanted == nil || $0.slot == wanted || Int($0.pid) == wanted }) else {
        print(sessions.isEmpty ? "No agent is using a screen right now." : "No such screen. Open: \(sessions.map(\.name).joined(separator: ", ")).")
        exit(1)
    }
    if NSRunningApplication.runningApplications(withBundleIdentifier: "com.ayush.Backstage.Viewer").isEmpty {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.ayush.Backstage.Viewer") else {
            print("The Backstage app is not installed. Run ./install.sh.")
            exit(1)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--watch", String(session.pid)]
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in done.signal() }
        done.wait()
    } else {
        DistributedNotificationCenter.default().postNotificationName(
            ViewerRequests.watch, object: String(session.pid), userInfo: nil, deliverImmediately: true)
    }
    print("Watching \(session.name) (\(session.client)).")
case "cleanup":
    let orphans = AgentScreen.orphanedDisplays()
    if orphans.isEmpty {
        print("No leftover agent screens.")
    } else {
        print("Found \(orphans.count) leftover agent screen\(orphans.count == 1 ? "" : "s").")
        AgentScreen.retireOrphans().forEach { print("  " + $0) }
    }
case "version", "--version", "-v":
    print(Version.current)
case nil, "help", "--help", "-h":
    print(usage)
default:
    FileHandle.standardError.write(Data("Unknown command \"\(arguments[0])\".\n\n\(usage)\n".utf8))
    exit(2)
}
