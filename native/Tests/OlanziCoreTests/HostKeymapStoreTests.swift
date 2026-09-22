import Darwin
import XCTest
@testable import OlanziCore

final class HostKeymapStoreTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("nested/host-keymap.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func keymap() throws -> HostKeymap {
        try HostKeymap.fromDeviceBindings(DeviceProtocol.defaultCodes.enumerated().map {
            KeyBinding(index: $0.offset, entries: [KeyEntry(code: $0.element)])
        })
    }

    func testMissingLoadDoesNotCreateFilesAndSaveRoundtripsPrivately() throws {
        let store = HostKeymapStore(url: url)
        XCTAssertNil(try store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        let map = try keymap()
        try store.save(map)
        XCTAssertEqual(try HostKeymapStore(url: url).load(), map)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), [url.lastPathComponent])
    }

    func testCorruptAndOversizedFilesAreNeverSilentlyReplaced() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        for bytes in [Data("{broken".utf8), Data(repeating: 32, count: 32769)] {
            try bytes.write(to: url)
            let store = HostKeymapStore(url: url)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(keymap()))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testRejectedSavePreservesOldContentAndValidSaveReplacesIt() throws {
        let store = HostKeymapStore(url: url)
        var map = try keymap()
        try store.save(map)
        let before = try Data(contentsOf: url)
        map.controls[4].doublePress = []
        XCTAssertThrowsError(try store.save(map))
        XCTAssertEqual(try Data(contentsOf: url), before)
        map.controls[4].doublePress = nil
        map.controls[0].press = [KeyEntry(code: 0x28)]
        try store.save(map)
        XCTAssertEqual(try store.load(), map)
        XCTAssertNotEqual(try Data(contentsOf: url), before)
    }

    func testUnwritableDirectoryLeavesExistingFileIntact() throws {
        guard geteuid() != 0 else { throw XCTSkip("root 可绕过目录写权限。") }
        let store = HostKeymapStore(url: url)
        var map = try keymap()
        try store.save(map)
        let before = try Data(contentsOf: url)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
        map.controls[0].press = []
        XCTAssertThrowsError(try store.save(map))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testSymlinkDoesNotRedirectLoadOrSave() throws {
        let target = directory.appendingPathComponent("target.json")
        let bytes = try JSONEncoder().encode(keymap())
        try bytes.write(to: target)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        let store = HostKeymapStore(url: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(keymap()))
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }
}
