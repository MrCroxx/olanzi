import CoreGraphics
import Foundation
import OSLog

/// 厂商物理控件先识别手势，再执行本机配置；运行时从不读取界面草稿。
final class VendorKeyBridge {
    private(set) var status = FnStatus()
    private var configuration: HostKeymap?
    private var router = GestureRouter()
    private let actions: HostActionRunner
    private var held: [Int: [KeyEntry]] = [:]
    private var pendingReleases = Set<Int>()
    private var connected = false
    private var online: Bool?
    private var nextCheck: TimeInterval = 0
    private var fault: String?
    private let permissions: () -> (input: Bool?, accessibility: Bool)
    private let request: () -> Void
    private let prepare: () throws -> Void
    private let emit: ([KeyEntry], Bool, CGEventFlags) throws -> Void
    private let now: () -> TimeInterval
    private let log = Logger(subsystem: "com.mrcroxx.olanzi", category: "device-input")

    convenience init() {
        let access = NativeFnBackend()
        let emitter = MacKeyEmitter()
        self.init(permissions: { access.permissions() }, request: { access.requestPermissions() },
                  prepare: { try emitter.prepareFnMonitoring() },
                  emit: { try emitter.emit(entries: $0, pressed: $1, heldModifiers: $2) })
    }

    init(permissions: @escaping () -> (input: Bool?, accessibility: Bool),
         request: @escaping () -> Void = {},
         prepare: @escaping () throws -> Void = {},
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         launcher: ApplicationLauncher = .native,
         emit: @escaping ([KeyEntry], Bool, CGEventFlags) throws -> Void) {
        self.actions = HostActionRunner(launcher: launcher)
        self.permissions = permissions
        self.request = request
        self.prepare = prepare
        self.now = now
        self.emit = emit
    }

    func synchronize(configuration: HostKeymap?, connected: Bool, online: Bool?) {
        if self.configuration != configuration {
            actions.cancel()
            _ = router.configure(configuration)
            releaseAll()
            self.configuration = configuration
        }
        self.connected = connected
        self.online = online
        status.enabled = configuration != nil
        pump()
    }

    /// 仅保留给旧工具和协议回归；新服务只传已持久化的本机配置。
    func synchronize(bindings: [KeyBinding], connected: Bool, online: Bool?) {
        let configuration = bindings.isEmpty ? nil : HostKeymap(controls: bindings.map {
            ControlActionMap(index: $0.index, press: $0.entries)
        })
        synchronize(configuration: configuration, connected: connected, online: online)
    }

    func refreshPermissions() { nextCheck = 0; pump() }
    func requestPermissions() { request(); refreshPermissions() }

    func pump() {
        if now() >= nextCheck {
            nextCheck = now() + 2
            let access = permissions()
            status.inputPermission = access.input
            status.accessibilityPermission = access.accessibility
        }
        retryReleases()
        let ready = status.enabled && connected && online == true
        let granted = status.missingPermissions.isEmpty
        status.active = ready && granted && pendingReleases.isEmpty
        var preparationError: String?
        if status.active {
            do { try prepare() }
            catch {
                status.active = false
                preparationError = error.localizedDescription
            }
        }
        if !status.active {
            actions.cancel()
            _ = router.cancel(quarantine: connected)
            releaseAll()
        } else {
            process(router.advance(to: now()))
            pumpActions()
        }
        // 权限提示独立于设备和配置状态，初始化失败时也必须让用户看到授权入口。
        if !granted {
            status.error = "权限不足：按键转换需要" + status.missingPermissions.map(\.title).joined(separator: "与") + "权限，心跳已暂停。"
        } else {
            status.error = preparationError ?? fault
        }
        updatePressed()
    }

    func receive(_ event: VendorKeyEvent) {
        pump()
        guard status.active else { router.observeWhileSuspended(event); return }
        log.debug("AU05 厂商按键：控件=\(event.index)，按下=\(event.pressed)")
        process(router.receive(event, at: now()))
        pumpActions()
        status.error = fault
        updatePressed()
    }

    private func process(_ transitions: [GestureTransition]) {
        var failed = false
        var completed = false
        for transition in transitions {
            do {
                switch transition {
                case .execute(let index, let action):
                    try actions.enqueue(index: index, action: action)
                    completed = true
                case .begin(let index, let entries):
                    try press(index: index, entries: entries)
                    completed = true
                case .end(let index):
                    if held[index] != nil {
                        try release(index: index)
                        completed = true
                    }
                }
            } catch {
                failed = true
                fault = error.localizedDescription
                // 任意边沿失败即取消该控件的后续连按，补 up 仍走现有释放重试机制。
                // 不能因此释放另一个控件仍持有的共享键。
                switch transition {
                case .begin(let index, _), .end(let index), .execute(let index, _): router.cancel(index: index)
                }
            }
        }
        if completed && !failed && pendingReleases.isEmpty { fault = nil }
    }

    private func pumpActions() {
        guard pendingReleases.isEmpty else {
            actions.cancel()
            // 其它控件释放失败也会取消宏；同时释放宏所有权，不能遗留已按下的键。
            do { try release(index: HostActionRunner.keyboardOwner) }
            catch { fault = error.localizedDescription }
            return
        }
        do {
            try actions.pump(at: now(), press: { try self.press(index: HostActionRunner.keyboardOwner, entries: $0) },
                             release: { try self.release(index: HostActionRunner.keyboardOwner) })
        } catch { fault = error.localizedDescription }
    }

    private func press(index: Int, entries: [KeyEntry]) throws {
        guard held[index] == nil else { return }
        try MacKeyEmitter.validate(entries: entries)
        var unique: [KeyEntry] = []
        for entry in entries where !unique.contains(where: { Self.sameKey($0, entry) }) { unique.append(entry) }
        let others = held.values.flatMap { $0 }
        let fresh = unique.filter { entry in !others.contains { Self.sameKey($0, entry) } }
        // 即使发布器在部分提交后失败，也保留所有权并补 up，不能遗失已经按下的键。
        held[index] = unique
        do {
            try emit(fresh, true, MacKeyEmitter.modifierFlags(for: others))
            status.events += 1
        } catch {
            try? release(index: index)
            throw error
        }
    }

    private func release(index: Int) throws {
        guard let entries = held[index] else { return }
        let others = held.filter { $0.key != index }.values.flatMap { $0 }
        do {
            try emit(entries.filter { entry in !others.contains { Self.sameKey($0, entry) } }, false,
                     MacKeyEmitter.modifierFlags(for: others))
        } catch {
            pendingReleases.insert(index)
            throw error
        }
        pendingReleases.remove(index)
        held.removeValue(forKey: index)
        status.events += 1
    }

    private func retryReleases() {
        let retrying = !pendingReleases.isEmpty
        for index in pendingReleases.sorted() {
            do { try release(index: index) }
            catch { fault = error.localizedDescription }
        }
        if retrying && pendingReleases.isEmpty { fault = nil }
    }

    private func releaseAll() {
        for index in held.keys.sorted().reversed() {
            do { try release(index: index) }
            catch { fault = error.localizedDescription }
        }
    }

    private func updatePressed() {
        status.pressed = held.values.flatMap { $0 }.contains { $0.type == 2 && $0.code == 1 }
    }

    private static func sameKey(_ lhs: KeyEntry, _ rhs: KeyEntry) -> Bool {
        if lhs == rhs { return true }
        guard lhs.type == 2, rhs.type == 2,
              let key = MacKeyEmitter.virtualKey(for: lhs.code) else { return false }
        return key == MacKeyEmitter.virtualKey(for: rhs.code)
    }

    func close() {
        status.active = false
        actions.cancel()
        _ = router.cancel(quarantine: false)
        for _ in 0..<3 where !held.isEmpty { releaseAll() }
        updatePressed()
        status.error = fault
        if !held.isEmpty { log.error("退出时仍有动作未释放：\(self.fault ?? "未知错误", privacy: .public)") }
    }
}
