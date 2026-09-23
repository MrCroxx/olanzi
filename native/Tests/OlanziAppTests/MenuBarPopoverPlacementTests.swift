import XCTest
@testable import OlanziApp

final class MenuBarPopoverPlacementTests: XCTestCase {
    func testNotchedDisplayKeepsEntirePopoverBelowMenuBar() {
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let result = MenuBarPopoverPlacement.constrainedFrame(
            NSRect(x: 1200, y: 450, width: 406, height: 554),
            anchor: NSRect(x: 1380, y: 950, width: 24, height: 32),
            screenFrame: screen, visibleFrame: NSRect(x: 0, y: 65, width: 1512, height: 884), safeTop: 32)
        XCTAssertEqual(result.maxY, 945)
        XCTAssertEqual(result.maxX, 1512)
        XCTAssertEqual(result.size, NSSize(width: 406, height: 554))
    }

    func testHiddenMenuBarStillRespectsNotch() {
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let result = MenuBarPopoverPlacement.constrainedFrame(
            NSRect(x: 400, y: 500, width: 406, height: 554),
            anchor: NSRect(x: 500, y: 960, width: 24, height: 22),
            screenFrame: screen, visibleFrame: screen, safeTop: 32)
        XCTAssertEqual(result.maxY, 946)
    }

    func testExternalDisplayUsesItsOwnOriginAndMenuBar() {
        let screen = NSRect(x: -1920, y: 982, width: 1920, height: 1080)
        let result = MenuBarPopoverPlacement.constrainedFrame(
            NSRect(x: -1980, y: 1550, width: 406, height: 554),
            anchor: NSRect(x: -1900, y: 2038, width: 24, height: 24),
            screenFrame: screen, visibleFrame: screen, safeTop: 0)
        XCTAssertEqual(result.maxY, 2034)
        XCTAssertEqual(result.minX, -1920)
    }

    func testAlreadySafeFrameDoesNotMoveAgain() {
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let frame = NSRect(x: 600, y: 300, width: 406, height: 554)
        let result = MenuBarPopoverPlacement.constrainedFrame(
            frame, anchor: NSRect(x: 700, y: 950, width: 24, height: 32),
            screenFrame: screen, visibleFrame: screen, safeTop: 32)
        XCTAssertEqual(result, frame)
    }
}
