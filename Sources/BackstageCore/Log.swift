import Foundation

/// Diagnostics go to stderr. stdout belongs to the MCP protocol, and a stray print there would
/// corrupt the stream the agent is reading.
public enum Log {
    public static var verbose = ProcessInfo.processInfo.environment["BACKSTAGE_DEBUG"] == "1"

    public static func info(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        write("backstage: \(message())")
    }

    public static func warn(_ message: @autoclosure () -> String) {
        write("backstage: warning: \(message())")
    }

    private static func write(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
