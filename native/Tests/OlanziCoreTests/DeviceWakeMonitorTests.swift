import XCTest
@testable import OlanziCore

final class DeviceWakeMonitorTests: XCTestCase {
    func testKeyboardPressAndReleaseIncludingReportIDAndInvalidFactoryKey() {
        var parser = DeviceWakeReportParser()
        XCTAssertNil(parser.receive(reportID: 3, bytes: Array(repeating: 0, count: 8)))
        XCTAssertEqual(parser.receive(reportID: 3, bytes: [3, 0, 0, 1, 0, 0, 0, 0, 0]), true)
        XCTAssertEqual(parser.receive(reportID: 3, bytes: [3, 0, 0, 0, 0, 0, 0, 0, 0]), false)
        XCTAssertNil(parser.receive(reportID: 3, bytes: Array(repeating: 0, count: 8)))
        XCTAssertEqual(parser.receive(reportID: 3, bytes: [2, 0, 0, 0, 0, 0, 0, 0]), true)
        XCTAssertEqual(parser.receive(reportID: 3, bytes: Array(repeating: 0, count: 8)), false)
    }

    func testCombinesHeldReportsAndInterfacesBeforeReleasing() {
        var parser = DeviceWakeReportParser()
        XCTAssertEqual(parser.receive(reportID: 3, bytes: [0, 0, 40, 0, 0, 0, 0, 0], source: 1), true)
        XCTAssertEqual(parser.receive(reportID: 1, bytes: [1, 0xE9, 0], source: 2), true)
        XCTAssertEqual(parser.receive(reportID: 2, bytes: [2, 1, 0, 0, 0, 0], source: 2), true)
        XCTAssertEqual(parser.receive(reportID: 3, bytes: Array(repeating: 0, count: 8), source: 1), true)
        XCTAssertEqual(parser.receive(reportID: 1, bytes: [0, 0], source: 2), true)
        XCTAssertEqual(parser.receive(reportID: 2, bytes: [0, 0, 0, 0, 0], source: 2), false)
    }

    func testMouseMotionAndWheelAreActivityWithoutHeldButtons() {
        var parser = DeviceWakeReportParser()
        for payload: [UInt8] in [[0, 1, 0, 0, 0], [0, 0, 255, 0, 0], [0, 0, 0, 1, 0], [0, 0, 0, 0, 255]] {
            XCTAssertEqual(parser.receive(reportID: 2, bytes: payload), false)
        }
        XCTAssertNil(parser.receive(reportID: 2, bytes: [0, 0, 0, 0, 0]))
    }

    func testUnknownAndMalformedReportsCannotCreateOrReleaseHeldState() {
        var parser = DeviceWakeReportParser()
        XCTAssertEqual(parser.receive(reportID: 1, bytes: [0xE9, 0]), true)
        XCTAssertNil(parser.receive(reportID: 0x55, bytes: Array(repeating: 1, count: 64)))
        XCTAssertNil(parser.receive(reportID: 1, bytes: [0]))
        XCTAssertNil(parser.receive(reportID: 1, bytes: [2, 0, 0]))
        XCTAssertNil(parser.receive(reportID: 3, bytes: [0, 1, 0, 0, 0, 0, 0, 0]))
        XCTAssertNil(parser.receive(reportID: 2, bytes: [8, 0, 0, 0, 0]))
        XCTAssertEqual(parser.receive(reportID: 2, bytes: [0, 0, 0, 1, 0]), true)
        XCTAssertEqual(parser.receive(reportID: 1, bytes: [0, 0]), false)
        XCTAssertNil(parser.receive(reportID: 1, bytes: [0, 0]))
    }

    func testSameReportFromDifferentInterfacesDoesNotReleaseAnotherInterface() {
        var parser = DeviceWakeReportParser()
        let down: [UInt8] = [0, 0, 40, 0, 0, 0, 0, 0]
        let up = Array(repeating: UInt8(0), count: 8)
        XCTAssertEqual(parser.receive(reportID: 3, bytes: down, source: 1), true)
        XCTAssertEqual(parser.receive(reportID: 3, bytes: down, source: 2), true)
        XCTAssertEqual(parser.receive(reportID: 3, bytes: up, source: 1), true)
        XCTAssertEqual(parser.receive(reportID: 3, bytes: up, source: 2), false)
    }
}
