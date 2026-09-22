import XCTest
@testable import OlanziCore

final class HostActionLibraryTests: XCTestCase {
    private let target = ApplicationTarget(bundleIdentifier: "com.example.editor", path: "/Applications/Editor.app", name: "Editor")
    private let keys = [KeyEntry(code: 0x04)]

    func testUnboundLibraryPersistsWithSchemaThreeAndProfileKeepsOuterVersion() throws {
        let item = NamedHostAction(name: "Focus", slot: 0, action: .application(target))
        var map = HostKeymap.defaultKeymap
        XCTAssertEqual(map.version, 1)
        map.actionLibrary = [item]
        XCTAssertEqual(map.version, 3)
        XCTAssertEqual(try HostKeymap.decode(data: JSONEncoder().encode(map)), map)
        let profile = HostProfile(name: "Shared functions", keymap: map)
        XCTAssertEqual(profile.version, 2)
        XCTAssertEqual(try HostProfile.decode(data: JSONEncoder().encode(profile)), profile)
        map.actionLibrary = []
        XCTAssertEqual(map, HostKeymap.defaultKeymap)
    }

    func testLegacyInlineActionsAndVersionOneRemainCompatible() throws {
        var map = HostKeymap.defaultKeymap
        let old = try JSONEncoder().encode(map)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: old) as? [String: Any])
        XCTAssertNil(object["actionLibrary"])
        XCTAssertEqual(try HostKeymap.decode(data: old), map)
        map.controls[0].pressAction = .application(target)
        map.controls[1].doublePressAction = .macro([.keyboard(keys)])
        XCTAssertEqual(map.version, 2)
        XCTAssertEqual(try HostKeymap.decode(data: JSONEncoder().encode(map)), map)
        XCTAssertEqual(map.resolve(map.controls[0].effectivePress), .application(target))
    }

    func testSharedReferencesResolveLatestActionWithoutChangingBindings() throws {
        let item = NamedHostAction(name: "Shared", slot: 0, action: .macro([.keyboard(keys)]))
        var map = HostKeymap.defaultKeymap
        map.actionLibrary = [item]
        map.controls[0].pressAction = .library(item.id)
        map.controls[1].doublePressAction = .library(item.id)
        try map.validate()
        XCTAssertEqual(map.resolve(map.controls[0].effectivePress), item.action)
        XCTAssertEqual(map.resolve(map.controls[1].effectiveDoublePress), item.action)
        let originalControls = map.controls
        map.actionLibrary[0].action = .macro([.application(target), .keyboard(keys)])
        XCTAssertEqual(map.controls, originalControls)
        XCTAssertEqual(map.resolve(map.controls[0].effectivePress), map.actionLibrary[0].action)
        XCTAssertEqual(map.resolve(map.controls[1].effectiveDoublePress), map.actionLibrary[0].action)
        XCTAssertEqual(try HostKeymap.decode(data: JSONEncoder().encode(map)), map)
    }

    func testLibraryValidationRejectsMissingNestedDuplicateAndInvalidItems() throws {
        let item = NamedHostAction(name: "Focus", slot: 0, action: .application(target))
        var map = HostKeymap.defaultKeymap
        map.controls[0].pressAction = .library(item.id)
        XCTAssertNil(map.resolve(map.controls[0].effectivePress))
        XCTAssertThrowsError(try map.validate()) { XCTAssertEqual($0 as? HostActionError, .missingLibraryAction) }
        let invalidLibraries: [[NamedHostAction]] = [
            [item, item],
            [item, NamedHostAction(name: "Duplicate slot", slot: 0, action: .application(target))],
            [NamedHostAction(name: "", slot: 0, action: .application(target))],
            [NamedHostAction(name: "Out of range", slot: 16, action: .application(target))],
            [NamedHostAction(name: "Keyboard", slot: 0, action: .keyboard(keys))],
            [NamedHostAction(name: "Nested", slot: 0, action: .library(item.id))]
        ]
        for library in invalidLibraries {
            map = HostKeymap.defaultKeymap
            map.actionLibrary = library
            XCTAssertThrowsError(try map.validate())
        }
        map = HostKeymap.defaultKeymap
        map.actionLibrary = [item]
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(map)) as? [String: Any])
        encoded["version"] = 2
        XCTAssertThrowsError(try HostKeymap.decode(data: JSONSerialization.data(withJSONObject: encoded)))
        encoded["version"] = 99
        XCTAssertThrowsError(try HostKeymap.decode(data: JSONSerialization.data(withJSONObject: encoded)))
    }

    func testMacroAndApplicationHaveIndependentSixteenSlots() throws {
        let library = (0..<16).flatMap { slot in
            [NamedHostAction(name: "App \(slot)", slot: slot, action: .application(target)),
             NamedHostAction(name: "Macro \(slot)", slot: slot, action: .macro([.keyboard(keys)]))]
        }
        let map = HostKeymap(controls: HostKeymap.defaultKeymap.controls, actionLibrary: library)
        XCTAssertEqual(map.version, 3)
        XCTAssertNoThrow(try map.validate())
        XCTAssertEqual(try HostKeymap.decode(data: JSONEncoder().encode(map)), map)
    }

    func testRouterResolvesSavedLibraryAndRunnerRejectsUnresolvedReferences() throws {
        let item = NamedHostAction(name: "Focus", slot: 0, action: .application(target))
        var map = HostKeymap.defaultKeymap
        map.actionLibrary = [item]
        map.controls[0].pressAction = .library(item.id)
        map.controls[1].longPressAction = .library(item.id)
        map.controls[1].longPressBehavior = .burst
        var router = GestureRouter()
        _ = router.configure(map)
        XCTAssertEqual(router.receive(.init(index: 0, pressed: true), at: 0), [.execute(index: 0, action: item.action)])
        XCTAssertEqual(router.receive(.init(index: 0, pressed: false), at: 0.1), [])
        XCTAssertEqual(router.configure(map), [])
        _ = router.receive(.init(index: 1, pressed: true), at: 1)
        XCTAssertEqual(router.advance(to: 1.5), [.execute(index: 1, action: item.action)])
        XCTAssertEqual(router.advance(to: 2), [])
        XCTAssertThrowsError(try HostActionRunner().enqueue(index: 0, action: .library(item.id))) {
            XCTAssertEqual($0 as? HostActionError, .missingLibraryAction)
        }
    }

    func testLibraryEditCancelsOldMacroAndAllBindingsUseNewContent() throws {
        let item = NamedHostAction(name: "Shared", slot: 0, action: .macro([.delay(1), .keyboard(keys)]))
        var map = HostKeymap.defaultKeymap
        map.actionLibrary = [item]
        map.controls[0].pressAction = .library(item.id)
        map.controls[1].pressAction = .library(item.id)
        var time = 0.0
        var downCodes: [UInt8] = []
        let bridge = VendorKeyBridge(permissions: { (true, true) }, now: { time }, emit: { entries, down, _ in
            if down { downCodes += entries.map(\.code) }
        })
        bridge.synchronize(configuration: map, connected: true, online: true)
        bridge.receive(.init(index: 0, pressed: true))
        XCTAssertTrue(downCodes.isEmpty)
        map.actionLibrary[0].action = .macro([.keyboard([KeyEntry(code: 0x05)])])
        bridge.synchronize(configuration: map, connected: true, online: true)
        bridge.receive(.init(index: 1, pressed: true))
        XCTAssertEqual(downCodes, [0x05])
        time = 2
        bridge.pump()
        bridge.receive(.init(index: 0, pressed: false))
        bridge.receive(.init(index: 0, pressed: true))
        XCTAssertEqual(downCodes, [0x05, 0x05])
    }
}
