import AppKit
import BackstageCore

/// `backstage try`: a short, real run on an agent screen that drives two apps the way an agent
/// would (through the same calls the MCP tools make) and checks that the user was never disturbed.
@MainActor
enum SelfTest {
    static func run() -> Never {
        Task { @MainActor in
            let passed = await perform()
            exit(passed ? 0 : 1)
        }
        RunLoop.main.run()
        exit(0)
    }

    private static func perform() async -> Bool {
        let session = Session()
        session.clientName = "backstage try"
        var failures = 0
        func check(_ ok: Bool, _ title: String, _ detail: String = "") {
            print("\(ok ? "✓" : "✗") \(title)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        let frontBefore = NSWorkspace.shared.frontmostApplication
        let mouseBefore = NSEvent.mouseLocation
        print("Your frontmost app is \(frontBefore?.localizedName ?? "unknown"). Keep working; nothing should change.\n")

        do {
            try session.ensureScreen()
            check(true, "Created an agent screen", "\(session.screen.map { "\(Int($0.size.width))×\(Int($0.size.height)) at \($0.bounds.origin)" } ?? "")")
        } catch {
            check(false, "Create an agent screen", "\(error)")
            return false
        }

        // 1. Typing into a native document.
        do {
            _ = try await session.openApp("TextEdit")
            _ = try await session.useMenu(["File", "New"], appName: "TextEdit")
            try await Task.sleep(nanoseconds: 600_000_000)
            let note = "Hello from Backstage. Typed while you kept working."
            _ = try await session.typeText(note, ref: nil, clear: false, submit: false, appName: "TextEdit")
            try await Task.sleep(nanoseconds: 300_000_000)
            var outline = try session.readUI(appName: "TextEdit")
            check(outline.contains(note), "Typed into TextEdit without focusing it")
            _ = try await session.pressKeys("cmd+a", appName: "TextEdit")
            _ = try await session.typeText("Replaced (with ⌘A) — ünïcödé ✓", ref: nil, clear: false, submit: false, appName: "TextEdit")
            try await Task.sleep(nanoseconds: 300_000_000)
            outline = try session.readUI(appName: "TextEdit")
            check(outline.contains("Replaced (with ⌘A) — ünïcödé ✓") && !outline.contains(note), "Used a ⌘ shortcut and typed symbols and accents")
            _ = try await session.quitApp("TextEdit", force: true)
        } catch {
            check(false, "TextEdit", "\(error)")
        }

        // 2. Clicking: once through Accessibility (by ref), once by coordinates.
        do {
            _ = try await session.openApp("Calculator", maximize: false)
            try await Task.sleep(nanoseconds: 500_000_000)
            var outline = try session.readUI(appName: "Calculator")
            for label in ["All Clear", "7", "Add", "2", "Equals"] {
                guard let ref = ref(for: label, in: outline) else { throw ToolError("No \"\(label)\" button in Calculator's outline.") }
                _ = try await session.click(ref: ref, point: nil)
            }
            outline = try session.readUI(appName: "Calculator")
            check(outline.contains("\"9\""), "Pressed Calculator buttons by ref (7 + 2 = 9)")

            for label in ["All Clear", "8", "Multiply", "3", "Equals"] {
                guard let point = center(for: label, in: outline) else { throw ToolError("No position for \"\(label)\".") }
                _ = try await session.click(ref: nil, point: point)
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            outline = try session.readUI(appName: "Calculator")
            check(outline.contains("\"24\""), "Clicked Calculator buttons by coordinates (8 × 3 = 24)")

            let shot = try await session.screenshot()
            let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("backstage-try.\(shot.mimeType == "image/png" ? "png" : "jpg")")
            try shot.data.write(to: file)
            check(true, "Took a screenshot of the agent screen", file.path)
            _ = try await session.quitApp("Calculator", force: true)
        } catch {
            check(false, "Calculator", "\(error)")
        }

        let frontAfter = NSWorkspace.shared.frontmostApplication
        let mouseAfter = NSEvent.mouseLocation
        check(frontAfter?.processIdentifier == frontBefore?.processIdentifier, "Your frontmost app never changed",
              frontAfter?.localizedName ?? "")
        check(true, "Agent apps tried to take focus \(session.focusRestores) time\(session.focusRestores == 1 ? "" : "s")", session.focusRestores == 0 ? "" : "each was handed straight back")
        let moved = hypot(mouseAfter.x - mouseBefore.x, mouseAfter.y - mouseBefore.y)
        print("  (Your pointer moved \(Int(moved)) points during the test — that was you, not the agent.)")

        print(session.close())
        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check\(failures == 1 ? "" : "s") failed.")
        while session.isRetiring {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return failures == 0
    }

    /// Finds `[n] button "label"` in a read_ui outline.
    private static func ref(for label: String, in outline: String) -> Int? {
        for line in outline.split(separator: "\n") where line.contains("button \"\(label)\"") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { continue }
            return Int(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
        }
        return nil
    }

    /// The centre of `button "label" … (x,y wxh)` in a read_ui outline.
    private static func center(for label: String, in outline: String) -> CGPoint? {
        for line in outline.split(separator: "\n") where line.contains("button \"\(label)\"") {
            guard let open = line.lastIndex(of: "("), let close = line.lastIndex(of: ")") else { continue }
            let parts = line[line.index(after: open)..<close].split(whereSeparator: { $0 == "," || $0 == " " || $0 == "x" })
            guard parts.count == 4, let x = Double(parts[0]), let y = Double(parts[1]),
                  let width = Double(parts[2]), let height = Double(parts[3]) else { continue }
            return CGPoint(x: x + width / 2, y: y + height / 2)
        }
        return nil
    }
}
