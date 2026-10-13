import CoreGraphics
import XCTest
@testable import BackstageCore

final class KeyComboTests: XCTestCase {
    func testNamedKeys() throws {
        XCTAssertEqual(try KeyCombo.parse("return").keyCode, 36)
        XCTAssertEqual(try KeyCombo.parse("Escape").keyCode, 53)
        XCTAssertEqual(try KeyCombo.parse("pagedown").keyCode, 121)
    }

    func testModifiers() throws {
        let combo = try KeyCombo.parse("cmd+shift+t")
        XCTAssertEqual(combo.keyCode, 17)
        XCTAssertEqual(combo.flags, [.maskCommand, .maskShift])
        XCTAssertEqual(combo.description, "shift+cmd+t")
    }

    func testUppercaseImpliesShift() throws {
        let combo = try KeyCombo.parse("cmd+T")
        XCTAssertTrue(combo.flags.contains(.maskShift))
        XCTAssertEqual(combo.keyCode, 17)
    }

    func testPlusKey() throws {
        XCTAssertEqual(try KeyCombo.parse("cmd++").flags, [.maskCommand, .maskShift])
        XCTAssertEqual(try KeyCombo.parse("cmd++").keyCode, 24)
        XCTAssertEqual(try KeyCombo.parse("+").keyCode, 24)
    }

    func testErrors() {
        XCTAssertThrowsError(try KeyCombo.parse(""))
        XCTAssertThrowsError(try KeyCombo.parse("cmd+shift"))
        XCTAssertThrowsError(try KeyCombo.parse("cmd+banana"))
    }

    func testTypingTable() {
        XCTAssertEqual(Keys.code(for: "a")?.code, 0)
        XCTAssertEqual(Keys.code(for: "A")?.shift, true)
        XCTAssertEqual(Keys.code(for: "?")?.code, 44)
        XCTAssertNil(Keys.code(for: "é"))
    }
}

final class GeometryTests: XCTestCase {
    func testFenceSendsPointerToNearestEdge() {
        let user = [CGRect(x: 0, y: 0, width: 1512, height: 982)]
        let back = CursorFence.nearestPoint(to: CGPoint(x: -10, y: 300), in: user)
        XCTAssertEqual(back, CGPoint(x: 0, y: 300))
        let corner = CursorFence.nearestPoint(to: CGPoint(x: 1600, y: 1100), in: user)
        XCTAssertEqual(corner, CGPoint(x: 1511, y: 981))
    }

    @MainActor
    func testMenuTitlesIgnoreEllipsis() {
        XCTAssertTrue(Session.menuTitle("Export as PDF…", matches: "export as pdf..."))
        XCTAssertTrue(Session.menuTitle("Save", matches: "save"))
        XCTAssertFalse(Session.menuTitle("", matches: ""))
    }
}
