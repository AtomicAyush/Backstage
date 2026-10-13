import BackstageCore
import Foundation

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
case "version", "--version", "-v":
    print(Version.current)
case nil, "help", "--help", "-h":
    print(usage)
default:
    FileHandle.standardError.write(Data("Unknown command \"\(arguments[0])\".\n\n\(usage)\n".utf8))
    exit(2)
}
