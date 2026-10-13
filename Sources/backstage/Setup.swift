import AppKit
import BackstageCore

/// Connects Backstage to the agents on this Mac by adding it to each one's MCP configuration.
enum Setup {
    static let clients = ["claude-code", "claude-desktop", "codex"]

    static func run(_ requested: [String]) -> Bool {
        let binary = executablePath()
        print("Backstage binary: \(binary)\n")
        let explicit = !requested.isEmpty
        let targets = explicit ? requested : clients
        var ok = true
        for client in targets {
            switch client {
            case "claude-code": ok = claudeCode(binary, explicit: explicit) && ok
            case "claude-desktop": ok = claudeDesktop(binary, explicit: explicit) && ok
            case "codex": ok = codex(binary, explicit: explicit) && ok
            default:
                print("✗ Unknown client \"\(client)\". Choose from: \(clients.joined(separator: ", ")).")
                ok = false
            }
        }
        print("")
        requestPermissions()
        print("\nRestart your agent, then ask it to \"open TextEdit in Backstage and write a short note\".")
        return ok
    }

    // MARK: - Clients

    private static func claudeCode(_ binary: String, explicit: Bool) -> Bool {
        guard let claude = findCommand("claude") else {
            if explicit { print("✗ Claude Code: the `claude` command was not found.") }
            else { print("– Claude Code: not installed, skipped.") }
            return !explicit
        }
        _ = shell(claude, ["mcp", "remove", "--scope", "user", "backstage"])
        let (status, output) = shell(claude, ["mcp", "add", "--scope", "user", "backstage", "--", binary, "mcp"])
        if status == 0 {
            print("✓ Claude Code: added the backstage MCP server for all your projects.")
            return true
        }
        print("✗ Claude Code: `claude mcp add` failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        return false
    }

    private static func claudeDesktop(_ binary: String, explicit: Bool) -> Bool {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            if explicit { print("✗ Claude desktop app: not installed.") }
            else { print("– Claude desktop app: not installed, skipped.") }
            return !explicit
        }
        let file = folder.appendingPathComponent("claude_desktop_config.json")
        var config: [String: Any] = [:]
        if let data = try? Data(contentsOf: file) {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("✗ Claude desktop app: \(file.path) is not valid JSON, so it was left untouched.")
                return false
            }
            config = parsed
            try? data.write(to: file.appendingPathExtension("backstage-backup"))
        }
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers["backstage"] = ["command": binary, "args": ["mcp"]]
        config["mcpServers"] = servers
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              (try? data.write(to: file, options: .atomic)) != nil else {
            print("✗ Claude desktop app: could not write \(file.path).")
            return false
        }
        print("✓ Claude desktop app: added backstage to claude_desktop_config.json (restart Claude to load it).")
        return true
    }

    private static func codex(_ binary: String, explicit: Bool) -> Bool {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) || findCommand("codex") != nil else {
            if explicit { print("✗ Codex: not installed.") }
            else { print("– Codex: not installed, skipped.") }
            return !explicit
        }
        let file = folder.appendingPathComponent("config.toml")
        var text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let section = "[mcp_servers.backstage]"
        let entry = "\(section)\ncommand = \(tomlString(binary))\nargs = [\"mcp\"]\n"
        if let range = text.range(of: section) {
            // Replace our own section, up to the next table header, and nothing else.
            let rest = text[range.upperBound...]
            let end = rest.range(of: "\n[")?.lowerBound ?? text.endIndex
            text.replaceSubrange(range.lowerBound..<end, with: entry.trimmingCharacters(in: .newlines))
        } else {
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            text += (text.isEmpty ? "" : "\n") + entry
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            print("✗ Codex: could not write \(file.path): \(error.localizedDescription)")
            return false
        }
        print("✓ Codex: added [mcp_servers.backstage] to ~/.codex/config.toml.")
        return true
    }

    // MARK: - Permissions

    private static func requestPermissions() {
        let host = Doctor.responsibleApp()
        print("Permissions are granted to \(host), the app that starts Backstage.")
        if AXIsProcessTrusted() {
            print("✓ Accessibility is on.")
        } else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            print("→ Turn on \(host) under Privacy & Security › Accessibility (a prompt should have opened).")
        }
        if CGPreflightScreenCaptureAccess() {
            print("✓ Screen Recording is on.")
        } else {
            _ = CGRequestScreenCaptureAccess()
            print("→ Turn on \(host) under Privacy & Security › Screen & System Audio Recording.")
        }
        print("  If you run agents from more than one app (say Terminal and Claude), each needs both.")
    }

    // MARK: - Helpers

    static func executablePath() -> String {
        let installed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/backstage").path
        if FileManager.default.isExecutableFile(atPath: installed) { return installed }
        return Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
    }

    private static func findCommand(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/\(name)", "\(home)/.claude/local/\(name)", "/opt/homebrew/bin/\(name)",
                          "/usr/local/bin/\(name)", "\(home)/.npm-global/bin/\(name)", "\(home)/.bun/bin/\(name)"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return found }
        // Fall back to the user's login shell, which knows their PATH.
        let (status, output) = shell("/bin/zsh", ["-lc", "command -v \(name)"])
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return status == 0 && path.hasPrefix("/") ? path : nil
    }

    @discardableResult
    private static func shell(_ command: String, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func tomlString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
