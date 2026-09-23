import Foundation

/// 窗口只提交任务；设备与 Fn 桥始终在独立线程及其 CFRunLoop 中运行。
public final class NativeDeviceService: @unchecked Sendable {
    private enum Job {
        case connect, disconnect, refresh, apply([KeyChange], [KeyBinding])
        case permissions, checkPermissions
        case heartbeatIdleTimeout(TimeInterval?), resumeHeartbeat
        case applyHostKeymap(HostKeymap, UUID)
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
    private let batteryClock: () -> TimeInterval
    private let idleClock: () -> TimeInterval
    private var heartbeatIdleTimer = HeartbeatIdleTimer()
    private var heartbeatResumeRequested = false
    private enum ConfigurationState { case notLoaded, missing, ready, invalidFile }
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
    private var lastConfirmedOnline: Bool?
    private var nextBatteryCheck: TimeInterval = 0

    public convenience init(demo: Bool = false, heartbeatIdleTimeout: TimeInterval? = nil,
                            onChange: @escaping @Sendable (DeviceSnapshot) -> Void) {
        self.init(demo: demo, transportFactory: {
            if demo { return DemoHIDTransport() }
            return MacHIDTransport()
        }, heartbeatIdleTimeout: heartbeatIdleTimeout, onChange: onChange)
    }

    init(demo: Bool, transportFactory: @escaping () -> DeviceTransport,
         loadHostKeymap: @escaping () throws -> HostKeymap? = { try HostKeymapStore().load() },
         saveHostKeymap: @escaping (HostKeymap) throws -> Void = { try HostKeymapStore().save($0) },
         bridgeFactory: @escaping () -> VendorKeyBridge = { VendorKeyBridge() },
         batteryClock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         heartbeatIdleTimeout: TimeInterval? = nil,
         idleClock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         onChange: @escaping @Sendable (DeviceSnapshot) -> Void) {
        self.demo = demo
        self.transportFactory = transportFactory
        self.loadHostKeymap = loadHostKeymap
        self.saveHostKeymap = saveHostKeymap
        self.bridgeFactory = bridgeFactory
        self.batteryClock = batteryClock
        self.idleClock = idleClock
        heartbeatIdleTimer.configure(timeout: heartbeatIdleTimeout, at: idleClock())
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

    public func setHeartbeatIdleTimeout(_ timeout: TimeInterval?) { enqueue(.heartbeatIdleTimeout(timeout)) }
    public func resumeHeartbeat() { enqueue(.resumeHeartbeat) }
    public func connect() { enqueue(.connect) }
    public func disconnect() { enqueue(.disconnect) }
    public func refresh() { enqueue(.refresh) }
    public func apply(changes: [KeyChange], expected: [KeyBinding]) { enqueue(.apply(changes, expected)) }
    /// 普通编辑只保存并激活本机动作，不写设备可编程按键表。
    public func applyHostKeymap(_ configuration: HostKeymap, requestID: UUID = UUID()) {
        enqueue(.applyHostKeymap(configuration, requestID))
    }
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
            case .heartbeatIdleTimeout(let timeout):
                heartbeatIdleTimer.configure(timeout: timeout, at: idleClock())
                requestHeartbeatResume()
            case .resumeHeartbeat:
                requestHeartbeatResume()
            case .disconnect:
                wantsConnection = false
                disconnectDevice()
            case .refresh:
                try refreshKeys()
            case .apply(let changes, let expected):
                try applyKeys(changes, expected: expected)
            case .applyHostKeymap(let configuration, let requestID):
                do {
                    try applyHostConfiguration(configuration)
                    state.hostSaveResult = HostSaveResult(requestID: requestID)
                } catch {
                    state.hostSaveResult = HostSaveResult(requestID: requestID, error: error.localizedDescription)
                    throw error
                }
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
        // 停止保活必须同时停止后台查询，给固件留下真正无请求的空闲窗口。
        // 仍泵送接收回调，以处理 USB 拔出和物理松开；显式刷新不受此限制。
        checkHeartbeatIdleTimeout()
        if state.connected && !state.heartbeatPausedForInactivity && now >= nextCheck {
            nextCheck = now + 2
            do { try checkOnline() }
            catch {
                // 查询超时保留只读厂商通道；暂停心跳，避免在无法转发时继续接管输入。
                state.online = nil
                state.error = error.localizedDescription
            }
        }
        refreshBatteryIfDue()
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
            resetHeartbeatIdleTimer()
            nextBatteryCheck = 0
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
        let wasConfirmedOnline = lastConfirmedOnline
        // 查询中的回调继续使用上一次已确认状态，不能每两秒取消一次按住动作。
        do { state.online = try transport?.queryOnline() }
        catch { state.online = nil; throw error }
        lastConfirmedOnline = state.online
        if state.online == true && wasConfirmedOnline == false { resetHeartbeatIdleTimer() }
        if state.online == false {
            // 离线清掉可能丢失 up 的物理按住状态，但保持空闲暂停原因。
            heartbeatIdleTimer.reset(at: idleClock())
            clearBattery()
            state.error = "接收器已连接，但 Vibe Key 本体离线，请短按电源键唤醒。"
        } else if state.online == true && (wasOnline != true || state.keys.isEmpty) {
            if wasOnline != true { nextBatteryCheck = 0 }
            try refreshKeys()
        }
    }

    private func refreshBatteryIfDue() {
        checkHeartbeatIdleTimeout()
        guard state.connected, state.online == true, !isInputSuspended,
              !state.heartbeatPausedForInactivity, let transport else { return }
        let now = batteryClock()
        guard now >= nextBatteryCheck else { return }
        // 电量是低频遥测，失败也等下个周期；查询沿用 transport 的输入和心跳泵送。
        nextBatteryCheck = now + 20
        do {
            let battery = try transport.readBattery()
            guard !isInputSuspended else { return }
            state.battery = battery
            state.batteryUpdatedAt = Date()
            state.batteryError = nil
        } catch {
            clearBattery()
            state.batteryError = error.localizedDescription
        }
    }

    private func clearBattery() {
        state.battery = nil
        state.batteryUpdatedAt = nil
        state.batteryError = nil
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
        transport?.heartbeatEnabled = false
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
        lastConfirmedOnline = nil
        state.keys = []
        clearBattery()
        nextBatteryCheck = 0
        state.lastRead = nil
        state.lastHeartbeat = nil
        state.heartbeatEnabled = false
        resetHeartbeatIdleTimer()
        state.error = nil
    }

    private func synchronizeFn() {
        // 运行时只使用成功持久化的本机动作；设备回读始终与本机配置独立。
        checkHeartbeatIdleTimeout()
        let enabled = state.connected && !isInputSuspended && !state.heartbeatPausedForInactivity && state.hostKeymap != nil
        guard let bridge = bridge else {
            state.fn = FnStatus(enabled: enabled)
            updateHeartbeat()
            return
        }
        bridge.synchronize(configuration: state.hostKeymap, connected: state.connected && !isInputSuspended,
                           online: state.heartbeatPausedForInactivity ? nil : state.online)
        bridge.pump()
        state.fn = bridge.status
        updateHeartbeat()
    }

    private func requestHeartbeatResume() {
        heartbeatResumeRequested = true
        finishHeartbeatResumeIfReleased()
    }

    private func finishHeartbeatResumeIfReleased() {
        guard heartbeatResumeRequested, !heartbeatIdleTimer.hasHeldControls else { return }
        heartbeatIdleTimer.restart(at: idleClock())
        heartbeatResumeRequested = false
        state.heartbeatPausedForInactivity = false
    }

    private func resetHeartbeatIdleTimer() {
        heartbeatResumeRequested = false
        heartbeatIdleTimer.reset(at: idleClock())
        state.heartbeatPausedForInactivity = false
    }

    private func checkHeartbeatIdleTimeout() {
        guard state.connected, state.online == true, !isInputSuspended,
              !state.heartbeatPausedForInactivity, heartbeatIdleTimer.expired(at: idleClock()) else { return }
        state.heartbeatPausedForInactivity = true
        // 先停心跳和主机动作；保留物理按住隔离，恢复时不能重放暂停期间的 down。
        transport?.heartbeatEnabled = false
        bridge?.synchronize(configuration: state.hostKeymap, connected: true, online: nil)
        state.fn = bridge?.status ?? FnStatus()
    }

    private func updateHeartbeat() {
        checkHeartbeatIdleTimeout()
        let ready = demo ? state.hostKeymap != nil && state.online == true : bridge?.status.active == true
        let enabled = state.connected && !isInputSuspended && !state.heartbeatPausedForInactivity && ready
        transport?.heartbeatEnabled = enabled
        state.heartbeatEnabled = enabled
        state.lastHeartbeat = enabled ? transport?.lastHeartbeat : nil
    }

    private var isInputSuspended: Bool {
        condition.lock()
        defer { condition.unlock() }
        return inputSuspended
    }

    private func suspendInputIfNeeded() {
        if isInputSuspended {
            bridge?.synchronize(configuration: state.hostKeymap, connected: false, online: nil)
            updateHeartbeat()
        }
    }

    private func receiveInput(_ event: VendorKeyEvent) {
        guard !isInputSuspended else {
            bridge?.synchronize(configuration: state.hostKeymap, connected: false, online: nil)
            updateHeartbeat()
            return
        }
        // 暂停后的首个厂商事件可能已由标准 HID 直出，不用它自动恢复或重放。
        // 查询暂时失败时仍消费松开，避免恢复在线后残留 held 导致永不空闲。
        if state.connected && (state.online == true || !event.pressed) {
            heartbeatIdleTimer.receive(event, at: idleClock())
        }
        bridge?.receive(event)
        if heartbeatResumeRequested && !heartbeatIdleTimer.hasHeldControls {
            finishHeartbeatResumeIfReleased()
            synchronizeFn()
        }
        updateHeartbeat()
    }

    private func pumpInput() {
        checkHeartbeatIdleTimeout()
        if isInputSuspended {
            bridge?.synchronize(configuration: state.hostKeymap, connected: false, online: nil)
        } else {
            bridge?.pump()
        }
        // 查询等待中的每次 pump 也复查，撤权或睡眠后不能再发送下一次心跳。
        updateHeartbeat()
    }

    private func loadConfigurationOnce() {
        guard configurationState == .notLoaded else { return }
        if demo {
            state.hostKeymap = .defaultKeymap
            configurationState = .ready
            return
        }
        do {
            if let saved = try loadHostKeymap() {
                try saved.validate()
                state.hostKeymap = saved
                configurationState = .ready
            } else {
                configurationState = .missing
                state.hostConfigurationMissing = true
            }
        } catch {
            configurationState = .invalidFile
            hostConfigurationError = "本机动作配置读取失败，已保留原文件且停止动作执行：" + error.localizedDescription
        }
    }

    private func applyHostConfiguration(_ configuration: HostKeymap) throws {
        do {
            guard configurationState != .notLoaded, configurationState != .invalidFile else {
                throw DeviceProtocolError.message("请先修复已报告的本机配置文件错误并重新启动；原文件不会覆盖。")
            }
            try configuration.validate()
            // 保存成功才更新快照并切换运行时；失败时继续使用完整的旧配置。
            if !demo { try saveHostKeymap(configuration) }
            state.hostKeymap = configuration
            state.hostConfigurationMissing = false
            configurationState = .ready
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
