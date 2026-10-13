import Foundation

/// How agent sessions and the Viewer find each other: a folder per session under
/// ~/Library/Application Support/Backstage/sessions/<pid>/.
///
/// The agent's process writes `session.json` (what it is doing). The Viewer writes
/// `control.json` (what the user wants). Each side only ever writes its own file, so there is
/// nothing to lock.
public enum Registry {
    public static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Backstage", isDirectory: true)
    }

    public static var sessionsFolder: URL { root.appendingPathComponent("sessions", isDirectory: true) }

    public static func folder(for pid: pid_t) -> URL {
        sessionsFolder.appendingPathComponent(String(pid), isDirectory: true)
    }

    public enum Status: String, Codable {
        case idle, working, paused
        case needsYou = "needs_you"
        case takenOver = "taken_over"
    }

    public struct SessionInfo: Codable, Equatable {
        public var pid: Int32
        public var slot: Int
        public var client: String
        public var displayID: UInt32
        public var width: Int
        public var height: Int
        public var startedAt: Date
        public var status: Status
        public var message: String?
        public var lastAction: String?
        public var lastActionAt: Date?
        public var apps: [String]

        public var name: String { "Screen \(slot)" }
    }

    /// What the user asked for from the Viewer.
    public struct Control: Codable, Equatable {
        public var paused = false
        public var takenOver = false
        /// Set when the user answers an agent's `ask_user` request.
        public var answeredAt: Date?
        public var answer: String?

        public init() {}
    }

    public static func write(_ info: SessionInfo) {
        let folder = folder(for: info.pid)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        save(info, to: folder.appendingPathComponent("session.json"))
    }

    public static func readControl(pid: pid_t) -> Control {
        load(Control.self, from: folder(for: pid).appendingPathComponent("control.json")) ?? Control()
    }

    public static func writeControl(_ control: Control, pid: pid_t) {
        let folder = folder(for: pid)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        save(control, to: folder.appendingPathComponent("control.json"))
    }

    public static func remove(pid: pid_t) {
        try? FileManager.default.removeItem(at: folder(for: pid))
    }

    /// Live sessions. Folders left by a process that is gone are cleaned up on the way.
    public static func sessions() -> [SessionInfo] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: sessionsFolder, includingPropertiesForKeys: nil)) ?? []
        var result: [SessionInfo] = []
        for folder in folders {
            guard let pid = Int32(folder.lastPathComponent) else { continue }
            guard kill(pid, 0) == 0 || errno == EPERM else {
                try? FileManager.default.removeItem(at: folder)
                continue
            }
            if let info = load(SessionInfo.self, from: folder.appendingPathComponent("session.json")) {
                result.append(info)
            }
        }
        return result.sorted { $0.slot < $1.slot }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func save<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? encoder.encode(value) else { return }
        // Atomic, so the other side never reads half a file.
        try? data.write(to: url, options: .atomic)
    }

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}
