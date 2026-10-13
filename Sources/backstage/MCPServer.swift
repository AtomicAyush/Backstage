import BackstageCore
import Foundation

/// A Model Context Protocol server over stdio: one JSON-RPC message per line in, one per line out.
///
/// Each agent that connects starts its own `backstage mcp` process, and each process owns at
/// most one agent screen. When the agent goes away, stdin closes, and the screen goes with it.
@MainActor
final class MCPServer {
    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    private let session = Session()
    private lazy var tools = Tools(session: session)
    private var queue: [[String: Any]] = []
    private var busy = false

    static func run() -> Never {
        let server = MCPServer()
        Thread.detachNewThread {
            while let line = readLine(strippingNewline: true) {
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                DispatchQueue.main.async { MainActor.assumeIsolated { server.receive(line) } }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { server.shutdown() } }
        }
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { server.shutdown() } }
            source.resume()
            server.signalSources.append(source)
        }
        RunLoop.main.run()
        exit(0)
    }

    private var signalSources: [DispatchSourceSignal] = []

    private func shutdown() -> Never {
        if session.hasScreen { session.close() }
        exit(0)
    }

    private func receive(_ line: String) {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
            return
        }
        let method = message["method"] as? String ?? ""
        let id = message["id"]

        // Requests are answered one at a time, in order. Two agent actions racing on the same
        // screen would be impossible to reason about.
        switch method {
        case "initialize":
            respond(id, initialize(message["params"] as? [String: Any] ?? [:]))
        case "ping":
            respond(id, [:])
        case "tools/list":
            respond(id, ["tools": tools.definitions])
        case "tools/call":
            queue.append(message)
            drain()
        case "resources/list":
            respond(id, ["resources": []])
        case "prompts/list":
            respond(id, ["prompts": []])
        default:
            if let id, !(id is NSNull) {
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
            }
            // Notifications (initialized, cancelled, …) need no reply.
        }
    }

    private func drain() {
        guard !busy, !queue.isEmpty else { return }
        busy = true
        let message = queue.removeFirst()
        Task { @MainActor in
            let params = message["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let result = await tools.call(name, arguments: arguments)
            respond(message["id"], result)
            busy = false
            drain()
        }
    }

    private func initialize(_ params: [String: Any]) -> [String: Any] {
        if let client = params["clientInfo"] as? [String: Any], let name = client["name"] as? String {
            session.clientName = Self.friendlyClientName(name)
        }
        let requested = params["protocolVersion"] as? String ?? ""
        return [
            "protocolVersion": Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0],
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "backstage", "title": "Backstage", "version": Version.current],
            "instructions": Tools.instructions,
        ]
    }

    static func friendlyClientName(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("claude-code") || lower.contains("claude code") { return "Claude Code" }
        if lower.contains("claude") { return "Claude" }
        if lower.contains("codex") { return "Codex" }
        if lower.contains("chatgpt") || lower.contains("openai") { return "ChatGPT" }
        if lower.contains("cursor") { return "Cursor" }
        return raw
    }

    private func respond(_ id: Any?, _ result: [String: Any]) {
        guard let id, !(id is NSNull) else { return }
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}
