import Foundation

/// 窗口只提交任务；设备与 Fn 桥始终在独立线程及其 CFRunLoop 中运行。
public final class NativeDeviceService: @unchecked Sendable {
    private enum Job {
        case connect, disconnect, refresh, apply([KeyChange], [KeyBinding])
        case permissions, checkPermissions
        case applyHostKeymap(HostKeymap)
        case suspendForSleep, resumeAfterWake(UInt64)
        case stop(@Sendable () -> Void)
    }
    private let condition = NSCondition()
    private var jobs: [Job] = []
    private var started = false
    private var stopping = false
    private var finished = false
    private var stopCallbacks: [@Sendable () -> Void] = []
    // 以下两个字段由 condition 保护，通知到来时立即阻止忙碌查询里的输入回调。
    private var inputSuspended = false
    private var sleepGeneration: UInt64 = 0
    private let demo: Bool
    private let onChange: @Sendable (DeviceSnapshot) -> Void
    private let transportFactory: () -> DeviceTransport
    private let bridgeFactory: () -> VendorKeyBridge
    private let loadHostKeymap: () throws -> HostKeymap?
    private let saveHostKeymap: (HostKeymap) throws -> Void
    private enum ConfigurationState { case notLoaded, awaitingDevice, ready, blocked }
    private var configurationState = ConfigurationState.notLoaded
    private var hostConfigurationError: String?
    // 以下成员仅由工作线程读写。
    private var state = DeviceSnapshot()
    private var lastPublished: DeviceSnapshot?
    private var transport: DeviceTransport?
    private var bridge: VendorKeyBridge?
    private var backgroundActivity: NSObjectProtocol?
    private var wantsConnection = true
    private var nextConnect: TimeInterval = 0
    private var nextCheck: TimeInterval = 0

    public convenience init(demo: Bool = false,
                            onChange: @escaping @Sendable (DeviceSnapshot) -> Void) {
        self.init(demo: demo, transportFactory: {
            if demo { return DemoHIDTransport() }
            return MacHIDTransport()
        }, onChange: onChange)
    }

    init(demo: Bool, transportFactory: @escaping () -> DeviceTransport,
         loadHostKeymap: @escaping () throws -> HostKeymap? = { try HostKeymapStore().load() },
         saveHostKeymap: @escaping (HostKeymap) throws -> Void = { try HostKeymapStore().save($0) },
         bridgeFactory: @escaping () -> VendorKeyBridge = { VendorKeyBridge() },
         onChange: @escaping @Sendable (DeviceSnapshot) -> Void) {
        self.demo = demo
        self.transportFactory = transportFactory
        self.loadHostKeymap = loadHostKeymap
        self.saveHostKeymap = saveHostKeymap
        self.bridgeFactory = bridgeFactory
        self.onChange = onChange
    }

    public func start() {
        condition.lock()
        guard !started, !finished else { condition.unlock(); return }
        started = true
        condition.unlock()
        let thread = Thread { [self] in run() }
        thread.name = "olanzi.native-hid"
        thread.start()
    }

    public func stop(completion: @escaping @Sendable () -> Void) {
        condition.lock()
        if finished || !started {
            finished = true
            condition.unlock()
            completion()
            return
        }
        if stopping {
            stopCallbacks.append(completion)
        } else {
            stopping = true
            jobs.append(.stop(completion))
        }
        condition.signal()
        condition.unlock()
    }

    public func suspendForSystemSleep() {
        condition.lock()
        defer { condition.unlock() }
        guard !stopping, !finished else { return }
        inputSuspended = true
        sleepGeneration &+= 1
        jobs.append(.suspendForSleep)
        condition.signal()
    }

    public func resumeAfterSystemWake() {
        condition.lock()
        defer { condition.unlock() }
        guard !stopping, !finished else { return }
        // 此处不能解禁；先让 worker 消化之前的 sleep 并取消旧手势。
        jobs.append(.resumeAfterWake(sleepGeneration))
        condition.signal()
    }

    public func connect() { enqueue(.connect) }
    public func disconnect() { enqueue(.disconnect) }
    public func refresh() { enqueue(.refresh) }
    public func apply(changes: [KeyChange], expected: [KeyBinding]) { enqueue(.apply(changes, expected)) }
    /// 普通编辑只保存并激活本机动作，不写设备可编程按键表。
    public func applyHostKeymap(_ configuration: HostKeymap) { enqueue(.applyHostKeymap(configuration)) }
    public func requestFnPermissions() { enqueue(.permissions) }
    public func checkFnPermissions() { enqueue(.checkPermissions) }

    private func enqueue(_ job: Job) {
        condition.lock()
        if !stopping && !finished { jobs.append(job); condition.signal() }
        condition.unlock()
    }

    private func run() {
        transport = transportFactory()
        if !demo { bridge = bridgeFactory() }
        transport?.onKeyEvent = { [weak self] event in self?.receiveInput(event) }
        transport?.onPump = { [weak self] in self?.pumpInput() }
        state.demo = demo
        loadConfigurationOnce()
        publish()
        while true {
            condition.lock()
            let batch = jobs
            jobs.removeAll()
            condition.unlock()
            for job in batch {
                if case .stop(let completion) = job {
                    disconnectDevice()
                    publish()
                    condition.lock()
                    finished = true
                    let callbacks = stopCallbacks
                    stopCallbacks.removeAll()
                    condition.unlock()
                    completion()
                    callbacks.forEach { $0() }
                    return
                }
                perform(job)
            }
            tick()
            condition.lock()
            if jobs.isEmpty { _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05)) }
            condition.unlock()
        }
    }

    private func perform(_ job: Job) {
        state.busy = true
        publish()
        defer { state.busy = false; synchronizeFn(); publish() }
        do {
            switch job {
            case .connect:
                wantsConnection = true
                if !isInputSuspended { try connectDevice() }
            case .disconnect:
                wantsConnection = false
                disconnectDevice()
            case .refresh:
                try refreshKeys()
            case .apply(let changes, let expected):
                try applyKeys(changes, expected: expected)
            case .applyHostKeymap(let configuration):
                try applyHostConfiguration(configuration)
            case .suspendForSleep:
                disconnectDevice()
            case .resumeAfterWake(let generation):
                // 即使 wake 先于 sleep 任务被处理，也不能复活睡前的 pending/held。
                disconnectDevice()
                condition.lock()
                if generation == sleepGeneration { inputSuspended = false }
                condition.unlock()
                nextConnect = 0
            case .permissions:
                if !demo {
                    suspendInputIfNeeded()
                    bridge?.requestPermissions()
                }
            case .checkPermissions:
                if !demo {
                    suspendInputIfNeeded()
                    bridge?.refreshPermissions()
                }
            case .stop: break
            }
        } catch {
            state.error = error.localizedDescription
        }
    }

    private func tick() {
        guard !isInputSuspended else { synchronizeFn(); publish(); return }
        let now = ProcessInfo.processInfo.systemUptime
        if wantsConnection && !state.connected && now >= nextConnect {
            nextConnect = now + 2
            do { try connectDevice() }
            catch { state.error = error.localizedDescription }
        }
        do { try transport?.pump(for: demo ? 0 : 0.01) }
        catch {
            let message = error.localizedDescription
            disconnectDevice()
            state.error = message
            nextConnect = now + 2
        }
        if state.connected && now >= nextCheck {
            nextCheck = now + 2
            do { try checkOnline() }
            catch {
                // 查询超时不代表接收器被拔掉，保留厂商通道继续发送心跳。
                state.online = nil
                state.error = error.localizedDescription
            }
        }
        state.lastHeartbeat = transport?.lastHeartbeat
        synchronizeFn()
        if let events = transport?.takeKeyEvents() {
            for event in events { receiveInput(event) }
            state.fn = bridge?.status ?? state.fn
        }
        publish()
    }

    private func connectDevice() throws {
        guard let transport = transport else { return }
        if !state.connected {
            try transport.open()
            state.connected = true
            state.heartbeatEnabled = true
            if !demo && backgroundActivity == nil {
                // 防止隐藏窗口后的 App Nap 延后心跳与输入处理，但允许 Mac 正常睡眠。
                backgroundActivity = ProcessInfo.processInfo.beginActivity(
                    options: .userInitiatedAllowingIdleSystemSleep,
                    reason: "维护 Vibe Key 的连接、心跳与输入转换")
            }
        }
        try transport.pump(for: 0)
        state.error = nil
        try checkOnline()
        nextCheck = ProcessInfo.processInfo.systemUptime + 2
    }

    private func checkOnline() throws {
        let wasOnline = state.online
        state.online = nil
        state.online = try transport?.queryOnline()
        if state.online == false {
            state.error = "接收器已连接，但 Vibe Key 本体离线，请短按电源键唤醒。"
        } else if state.online == true && (wasOnline != true || state.keys.isEmpty) {
            try refreshKeys()
        }
    }

    private func refreshKeys() throws {
        guard state.connected, let transport = transport else {
            throw DeviceProtocolError.message("请先连接设备。")
        }
        do {
            let keys = try (0..<6).map { try transport.readKey(index: $0) }
            state.keys = keys
            state.online = true
            state.lastRead = Date()
            state.error = nil
            seedConfigurationIfNeeded()
        } catch {
            state.online = nil
            throw error
        }
    }

    private func applyKeys(_ changes: [KeyChange], expected: [KeyBinding]) throws {
        guard (1...6).contains(changes.count), changes.count == expected.count,
              Set(changes.map(\.index)).count == changes.count,
              Set(expected.map(\.index)) == Set(changes.map(\.index)),
              Set(expected.map(\.index)).count == expected.count,
              expected.allSatisfy({ $0.entries.count <= 24 }) else {
            throw DeviceProtocolError.message("修改列表或原始配置无效，请刷新后重试。")
        }
        for change in changes {
            _ = try DeviceProtocol.writeRequest(index: change.index, entries: [[2, change.code]])
        }
        guard state.connected, state.online == true, let transport = transport else {
            throw DeviceProtocolError.message("请先连接并打开设备。")
        }
        try refreshKeys()
        for original in expected {
            guard state.keys[original.index].entries == original.entries else {
                throw DeviceProtocolError.message("设备配置已被其他程序修改，请刷新后重新确认草稿。")
            }
        }
        do {
            for change in changes {
                let desired = [KeyEntry(code: change.code)]
                if state.keys[change.index].entries == desired { continue }
                try transport.writeKey(index: change.index, code: change.code)
                let readback = try transport.readKey(index: change.index)
                state.keys[change.index] = readback
                guard readback.entries == desired else {
                    throw DeviceProtocolError.message("设备回读与目标键码不一致。")
                }
            }
            try refreshKeys()
        } catch {
            let originalError = error.localizedDescription
            // 设备写入没有事务保证；尽量展示已生效的部分，绝不自动写回旧值。
            try? refreshKeys()
            throw DeviceProtocolError.message("写入未全部完成，部分改动可能已生效。" + originalError)
        }
    }

    private func disconnectDevice() {
        bridge?.synchronize(configuration: state.hostKeymap, connected: false, online: nil)
        bridge?.close()
        state.fn = bridge?.status ?? FnStatus()
        transport?.close()
        if let activity = backgroundActivity {
            ProcessInfo.processInfo.endActivity(activity)
            backgroundActivity = nil
        }
        state.connected = false
        state.online = nil
        state.keys = []
        state.lastRead = nil
        state.lastHeartbeat = nil
        state.heartbeatEnabled = false
        state.error = nil
    }

    private func synchronizeFn() {
        // 运行时只使用成功持久化的本机动作；设备回读仅用于首次初始化。
        let enabled = state.connected && !isInputSuspended && state.hostKeymap != nil
        guard let bridge = bridge else {
            state.fn = FnStatus(enabled: enabled)
            return
        }
        bridge.synchronize(configuration: state.hostKeymap, connected: state.connected && !isInputSuspended,
                           online: state.online)
        bridge.pump()
        state.fn = bridge.status
    }

    private var isInputSuspended: Bool {
        condition.lock()
        defer { condition.unlock() }
        return inputSuspended
    }

    private func suspendInputIfNeeded() {
        if isInputSuspended {
            bridge?.synchronize(configuration: state.hostKeymap, connected: false, online: nil)
        }
    }

    private func receiveInput(_ event: VendorKeyEvent) {
        guard !isInputSuspended else {
            bridge?.synchronize(configuration: state.hostKeymap, connected: false, online: nil)
            return
        }
        bridge?.receive(event)
    }

    private func pumpInput() {
        if isInputSuspended {
            bridge?.synchronize(configuration: state.hostKeymap, connected: false, online: nil)
        } else {
            bridge?.pump()
        }
    }

    private func loadConfigurationOnce() {
        guard configurationState == .notLoaded else { return }
        if demo { configurationState = .awaitingDevice; return }
        do {
            if let saved = try loadHostKeymap() {
                try saved.validate()
                state.hostKeymap = saved
                configurationState = .ready
            } else {
                configurationState = .awaitingDevice
            }
        } catch {
            configurationState = .blocked
            hostConfigurationError = "本机动作配置读取失败，已保留原文件且停止动作执行：" + error.localizedDescription
        }
    }

    private func seedConfigurationIfNeeded() {
        guard configurationState == .awaitingDevice else { return }
        // 首次写入失败后停在明确错误状态，不在心跳/重连时反复覆盖或悄悄换默认值。
        configurationState = .blocked
        do {
            let initial = try HostKeymap.fromDeviceBindings(state.keys)
            if !demo { try saveHostKeymap(initial) }
            state.hostKeymap = initial
            configurationState = .ready
            hostConfigurationError = nil
        } catch {
            hostConfigurationError = "无法从设备初始化本机动作配置，配置尚未激活：" + error.localizedDescription
        }
    }

    private func applyHostConfiguration(_ configuration: HostKeymap) throws {
        do {
            guard configurationState == .ready, state.hostKeymap != nil else {
                throw DeviceProtocolError.message("本机动作配置尚未初始化；请先连接设备，或修复已报告的配置文件错误。")
            }
            try configuration.validate()
            // 保存成功才更新快照并切换运行时；失败时继续使用完整的旧配置。
            if !demo { try saveHostKeymap(configuration) }
            state.hostKeymap = configuration
            hostConfigurationError = nil
            state.error = nil
            synchronizeFn()
        } catch {
            hostConfigurationError = "本机动作配置未更改：" + error.localizedDescription
            throw error
        }
    }

    private func publish() {
        var snapshot = state
        // 设备查询成功不能抹掉损坏文件或保存失败；用户必须始终看得到这个错误。
        if let hostConfigurationError { snapshot.error = hostConfigurationError }
        guard snapshot != lastPublished else { return }
        lastPublished = snapshot
        onChange(snapshot)
    }
}
