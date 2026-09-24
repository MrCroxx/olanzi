import AppKit
import Combine
import OlanziCore

enum AssignmentGesture: String, CaseIterable, Identifiable {
    case press = "单击"
    case doublePress = "双击"
    case longPress = "长按"
    var id: Self { self }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var device = DeviceSnapshot()
    @Published var selected = 0 {
        didSet { if selected >= 4 { gesture = .press } }
    }
    @Published var gesture: AssignmentGesture = .press
    @Published var selectedLayer = 0 {
        didSet { gesture = .press }
    }
    @Published private(set) var draft: HostKeymap?
    @Published var page = 0 {
        didSet {
            guard page == 2, oldValue != 2 else { return }
            lightingReadPending = lightingDraft == nil
            readLightingIfNeeded()
        }
    }
    private var lightingReadPending = false
    @Published private var lightingFeedbackDismissed = false
    @Published private(set) var lightingDraft: DeviceLighting?
    @Published private(set) var lightingKnobBrightnessEdited = false
    @Published private(set) var lightingReading = false
    @Published private(set) var lightingSubmittedID: UUID?
    private var lightingExpected: DeviceLighting?
    private var lightingReadBecameBusy = false
    var lighting: DeviceLighting? { lightingDraft ?? device.effectiveLighting }
    var lightingKnobBrightnessKnown: Bool { lightingKnobBrightnessEdited || device.lightingKnobBrightnessConfirmation != nil }
    var lightingBusy: Bool { device.busy || lightingReading || lightingSubmittedID != nil }
    var canEditLighting: Bool { online && !lightingBusy && lighting != nil }
    var canApplyLighting: Bool { canEditLighting && lightingDraft != nil }
    func readLighting() {
        guard online, !lightingBusy else { return }
        guard lightingDraft == nil else { return }
        lightingReadPending = false
        lightingFeedbackDismissed = true
        lightingReading = true
        lightingReadBecameBusy = false
        service.readLighting()
    }
    private func readLightingIfNeeded() {
        guard page == 2, lightingReadPending, lightingDraft == nil else { return }
        readLighting()
    }
    var lightingFailureText: String? {
        guard !lightingFeedbackDismissed, !device.lightingFailureFields.isEmpty else { return nil }
        return lf("未生效：%@", device.lightingFailureFields.map { l($0) }.joined(separator: l("，")))
    }
    var lightingErrorText: String? { lightingFeedbackDismissed ? nil : device.lightingError.map(displayError) }
    func editLighting(_ edit: (inout DeviceLighting) -> Void) {
        guard canEditLighting, var value = lighting else { return }
        let expected = lightingExpected ?? device.effectiveLighting
        edit(&value)
        lightingFeedbackDismissed = true
        lightingDraft = value == expected && !lightingKnobBrightnessEdited ? nil : value
        lightingExpected = lightingDraft == nil ? nil : expected
        notice = nil
    }
    func editKnobBrightness(_ brightness: UInt8) {
        guard canEditLighting, brightness <= 20, lighting?.lights.indices.contains(3) == true else { return }
        lightingKnobBrightnessEdited = true
        editLighting { $0.lights[3].alwaysOnBrightness = brightness }
    }
    func applyLighting() {
        guard canApplyLighting, let value = lightingDraft, let expected = lightingExpected else { return }
        let id = UUID()
        lightingFeedbackDismissed = true
        lightingSubmittedID = id
        service.applyLighting(value, expected: expected, requestID: id, setKnobBrightness: lightingKnobBrightnessEdited)
    }

    static let heartbeatIdleMinutesOptions = [0, 1, 5, 10, 15, 30, 60]
    @Published private(set) var heartbeatIdleMinutes: Int
    func setHeartbeatIdleMinutes(_ minutes: Int) {
        guard Self.heartbeatIdleMinutesOptions.contains(minutes), minutes != heartbeatIdleMinutes else { return }
        heartbeatIdleMinutes = minutes
        if !demo { defaults.set(minutes, forKey: "nativeHeartbeatIdleMinutes") }
        service.setHeartbeatIdleTimeout(minutes == 0 ? nil : TimeInterval(minutes * 60))
        didChange?()
    }
    func resumeHeartbeat() { service.resumeHeartbeat() }
    @Published var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            if !demo { defaults.set(language.rawValue, forKey: "nativeAppLanguage") }
            didChange?()
        }
    }
    // 保留消息来源，切换语言时重新渲染，避免草稿或诊断被清空。
    private struct Message {
        let id = UUID()
        let source: String
        var arguments: [String] = []
        func render(_ localizer: AppLocalizer) -> String {
            if arguments.isEmpty { return localizer.diagnostic(source) }
            return localizer.format(source, arguments: arguments.map { localizer.diagnostic($0) })
        }
    }
    @Published private var noticeMessage: Message?
    @Published private var permissionMessage: Message?
    var notice: String? {
        get { noticeMessage?.render(localizer) }
        set { noticeMessage = newValue.map { Message(source: $0) } }
    }
    var noticeID: UUID? { noticeMessage?.id }
    var noticeSymbol: String {
        switch noticeMessage?.source {
        case "键位已保存到本机。", "已保存提交的配置，后续编辑仍保留在草稿中。",
             "配置已保存在这台 Mac。", "演示配置已保存，退出后清除。", "系统权限已就绪。":
            return "checkmark.circle.fill"
        default: return "info.circle"
        }
    }
    var permissionSetupError: String? { permissionMessage?.render(localizer) }
    @Published private(set) var polledPermissions: FnStatus?
    @Published var profiles: [HostProfile] = []
    private var submitted: HostKeymap?
    private(set) var submittedID: UUID?
    private let defaults: UserDefaults
    private let readPermissions: () -> FnStatus
    private let permissionPollInterval: TimeInterval
    private var permissionTimer: Timer?
    let demo: Bool
    var didChange: (() -> Void)?
    private lazy var service = NativeDeviceService(demo: demo, heartbeatIdleTimeout: heartbeatIdleMinutes == 0 ? nil : TimeInterval(heartbeatIdleMinutes * 60)) { [weak self] snapshot in
        DispatchQueue.main.async { self?.receive(snapshot) }
    }

    init(demo: Bool, language: AppLanguage? = nil, defaults: UserDefaults = .standard,
         permissionPollInterval: TimeInterval = 1,
         readPermissions: @escaping () -> FnStatus = { InputPermission.currentStatus() }) {
        self.demo = demo
        self.defaults = defaults
        let idleMinutes = demo ? 0 : defaults.integer(forKey: "nativeHeartbeatIdleMinutes")
        self.heartbeatIdleMinutes = Self.heartbeatIdleMinutesOptions.contains(idleMinutes) ? idleMinutes : 0
        self.language = language ?? defaults.string(forKey: "nativeAppLanguage").flatMap(AppLanguage.init(rawValue:)) ?? .system
        self.permissionPollInterval = permissionPollInterval
        self.readPermissions = readPermissions
        guard !demo else { return }
        // 新格式单独保存，迁移时保留原列表，旧版本仍能读取自己的配置。
        let stored = defaults.data(forKey: "nativeHostProfiles") ?? defaults.data(forKey: "nativeProfiles")
        if let stored {
            do {
                guard let items = try JSONSerialization.jsonObject(with: stored) as? [Any] else {
                    throw NSError(domain: "Olanzi", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "配置列表必须是 JSON 数组。"])
                }
                // 每项独立迁移，单个不受支持的旧键码不能阻止其余配置载入。
                profiles = items.compactMap { item in
                    guard let data = try? JSONSerialization.data(withJSONObject: item, options: [.fragmentsAllowed]) else { return nil }
                    return try? JSONDecoder().decode(HostProfile.self, from: data)
                }
                if profiles.count != items.count {
                    preserveProfileSource(stored)
                    notice = "部分配置包含不支持的键码或格式，未载入；原始列表已备份保留。"
                }
                if defaults.data(forKey: "nativeHostProfiles") == nil { persistProfiles() }
            } catch {
                preserveProfileSource(stored)
                setNotice("无法读取本地配置列表，原始数据已备份保留：%@", error.localizedDescription)
            }
        }
    }
    deinit { permissionTimer?.invalidate() }
    var localizer: AppLocalizer { AppLocalizer(language: language) }
    func l(_ source: String) -> String { localizer.text(source) }
    func lf(_ source: String, _ arguments: CVarArg...) -> String { localizer.format(source, arguments: arguments) }
    func displayError(_ raw: String) -> String { localizer.diagnostic(raw) }
    func gestureTitle(_ gesture: AssignmentGesture) -> String { l(gesture.rawValue) }
    func controlName(_ index: Int) -> String {
        l(KeyCatalog.controlNames.indices.contains(index) ? KeyCatalog.controlNames[index] : "未知控件")
    }
    func categoryTitle(_ category: String) -> String { l(category) }
    func keyLabel(_ code: UInt8?) -> String { l(KeyCatalog.label(code)) }
    private func setNotice(_ source: String, _ arguments: String...) {
        noticeMessage = Message(source: source, arguments: arguments)
    }
    var online: Bool { device.connected && device.online == true }
    // 独立轮询是欢迎页的权限来源，旧设备快照不能把新授权状态覆盖回去。
    var permissionStatus: FnStatus { polledPermissions ?? device.fn }
    var needsPermissionSetup: Bool { !demo && !permissionStatus.missingPermissions.isEmpty }
    var isCheckingPermissions: Bool { !demo && permissionStatus.accessibilityPermission == nil }
    var keymap: HostKeymap? { draft ?? device.hostKeymap ?? (device.hostConfigurationMissing ? .defaultKeymap : nil) }
    var canEdit: Bool { keymap != nil }
    var hasDraft: Bool { draft != nil || device.hostConfigurationMissing }
    var applying: Bool { submitted != nil }
    var dirtyCount: Int { (0..<6).filter { isDirty($0) }.count }
    var timingsChanged: Bool {
        guard let draft, let saved = device.hostKeymap else { return false }
        return draft.doublePressWindow != saved.doublePressWindow || draft.longPressThreshold != saved.longPressThreshold
    }
    var status: String {
        if demo { return l("演示模式") }
        if !device.connected { return l("等待接收器") }
        if device.heartbeatPausedForInactivity { return l("因空闲已停止保活") }
        return l(device.online == true ? "Vibe Key 已连接" : device.online == false ? "设备离线 / 休眠" : "正在确认设备状态")
    }
    var batteryText: String {
        guard online, let battery = device.battery else { return l("电量 —") }
        let value = battery.percentage.map { "\($0)%" }
            ?? String(format: "%.2f V", Double(battery.millivolts) / 1000)
        return battery.isCharging == true ? lf("%@ · 充电中", value) : value
    }
    var batterySymbol: String {
        if online, device.battery?.isCharging == true { return "battery.100percent.bolt" }
        guard online, let percentage = device.battery?.percentage else { return "battery.0percent" }
        switch percentage {
        case 0...10: return "battery.0percent"
        case 11...35: return "battery.25percent"
        case 36...60: return "battery.50percent"
        case 61...85: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
    var batteryLow: Bool { online && (device.battery?.percentage.map { $0 <= 20 } ?? false) }
    var batteryHelp: String {
        guard online else { return l("设备恢复在线后自动读取电量") }
        if let error = device.batteryError { return lf("暂时无法读取电量，将自动重试：%@", displayError(error)) }
        guard let battery = device.battery else { return l("正在读取电量") }
        var detail = lf("电池电压 %.3f V · 每 20 秒自动刷新", Double(battery.millivolts) / 1000)
        if let updated = device.batteryUpdatedAt {
            detail += lf(" · 更新于 %@", updated.formatted(.dateTime.hour().minute().second().locale(localizer.locale)))
        }
        return detail
    }
    func start() { startPermissionMonitoring(); service.start() }
    func stop(completion: @escaping @Sendable () -> Void) {
        stopPermissionMonitoring()
        service.stop(completion: completion)
    }
    func startPermissionMonitoring() {
        guard !demo, permissionTimer == nil else { return }
        pollPermissions()
        let timer = Timer(timeInterval: permissionPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.permissionTimer != nil else { return }
                self.pollPermissions()
            }
        }
        timer.tolerance = min(0.1, permissionPollInterval / 10)
        permissionTimer = timer
        // common 模式避免菜单/窗口交互暂停检测；不依赖设备查询或窗口重新激活。
        RunLoop.main.add(timer, forMode: .common)
    }
    func stopPermissionMonitoring() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }
    private func pollPermissions(forceRuntimeRefresh: Bool = false) {
        guard !demo else { return }
        let latest = readPermissions()
        let changed = polledPermissions != latest
        if changed {
            polledPermissions = latest
            readLightingIfNeeded()
            if !needsPermissionSetup { permissionMessage = nil }
        }
        // 不把每秒检查堆进设备任务队列，只有变化或用户回到应用时才强制复查。
        if changed || forceRuntimeRefresh { service.checkFnPermissions() }
    }
    func connect() { service.connect() }
    func disconnect() { service.disconnect() }
    func suspendForSystemSleep() { service.suspendForSystemSleep() }
    func resumeAfterSystemWake() { service.resumeAfterSystemWake() }
    func refresh() { service.refresh() }
    func refreshPermissions() { pollPermissions(forceRuntimeRefresh: true) }
    func revealApplication() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
    var permissionButtonTitle: String {
        guard let permission = permissionStatus.missingPermissions.first else { return l("检查权限") }
        return lf("打开%@设置", l(permission.title))
    }
    func requestPermissions() {
        guard !demo else { return }
        permissionMessage = nil
        guard let permission = permissionStatus.missingPermissions.first else {
            notice = "系统权限已就绪。"; return
        }
        // 权限请求不等待设备线程，离线时同样可以授权。
        permission.requestAccess()
        refreshPermissions()
        if !NSWorkspace.shared.open(permission.settingsURL) {
            permissionMessage = Message(source: "无法打开系统设置。请手动进入“隐私与安全性 → %@”，允许 Olanzi。", arguments: [permission.title])
        }
    }
    var layerIDs: [Int] { [0, 1, 2, 3] }
    var allControls: [ControlActionMap] { (keymap?.controls ?? []) + (keymap?.layers.flatMap(\.controls) ?? []) }
    func control(_ index: Int) -> ControlActionMap? {
        keymap?.resolvedControl(index: index, activeLayers: selectedLayer == 0 ? [] : [selectedLayer])
    }
    private func controlGesture(_ gesture: AssignmentGesture) -> ControlGesture {
        switch gesture {
        case .press: return .press
        case .doublePress: return .doublePress
        case .longPress: return .longPress
        }
    }
    func isInherited(_ index: Int, gesture: AssignmentGesture = .press) -> Bool {
        guard selectedLayer != 0 else { return false }
        guard let stored = keymap?.control(index: index, layer: selectedLayer) else { return true }
        return stored.inheritedGestures.contains(controlGesture(index >= 4 ? .press : gesture))
    }
    func isEmptyAction(_ index: Int, gesture: AssignmentGesture = .press) -> Bool {
        guard let action = action(index, gesture: gesture) else { return true }
        if case .keyboard(let entries) = action { return entries.allSatisfy { $0.code == 0 } }
        return false
    }
    func inheritAction() {
        guard selectedLayer != 0, var map = keymap,
              let layer = map.layers.firstIndex(where: { $0.id == selectedLayer }),
              let position = map.layers[layer].controls.firstIndex(where: { $0.index == selected }) else { return }
        let target = controlGesture(selected >= 4 ? .press : gesture)
        var value = map.layers[layer].controls[position]
        value.inheritedGestures.insert(target)
        switch target {
        case .press:
            value.press = []; value.pressAction = nil
            value.pressBehavior = .hold; value.pressTapCount = 2
        case .doublePress:
            value.doublePress = nil; value.doublePressAction = nil
            value.doublePressBehavior = .tap; value.doublePressTapCount = 2
        case .longPress:
            value.longPress = nil; value.longPressAction = nil
            value.longPressBehavior = .hold; value.longPressTapCount = 2
        }
        if selected >= 4 || value.inheritedGestures == Set(ControlGesture.allCases) {
            map.layers[layer].controls.remove(at: position)
        } else { map.layers[layer].controls[position] = value }
        if map.layers[layer].controls.isEmpty { map.layers.remove(at: layer) }
        do { try map.validate() }
        catch { notice = error.localizedDescription; return }
        updateDraft(map)
    }
    func clearAction() {
        if selected >= 4 || gesture == .press { assign([KeyEntry(code: 0)]) }
        else { disableGesture() }
    }
    func isLayerSwitch(_ index: Int) -> Bool {
        if case .momentaryLayer = control(index)?.effectivePress { return true }
        return false
    }
    func inheritControl() {
        guard selectedLayer != 0, var map = keymap,
              let position = map.layers.firstIndex(where: { $0.id == selectedLayer }) else { return }
        map.layers[position].controls.removeAll { $0.index == selected }
        if map.layers[position].controls.isEmpty { map.layers.remove(at: position) }
        updateDraft(map)
    }
    /// 编辑非基础层时只展开当前手势的继承值，其他手势继续继承。
    @discardableResult
    private func editControl(_ index: Int, gesture: AssignmentGesture? = nil, _ edit: (inout ControlActionMap) -> Void) -> Bool {
        guard canEdit, layerIDs.contains(selectedLayer), var map = keymap, let resolved = control(index) else { return false }
        let stored = map.control(index: index, layer: selectedLayer)
        var control = stored ?? resolved
        if selectedLayer != 0 && stored == nil {
            control = ControlActionMap(index: index, press: [], inheritedGestures: Set(ControlGesture.allCases))
        }
        let target = index >= 4 ? AssignmentGesture.press : (gesture ?? self.gesture)
        // 编辑继承动作的输出方式时，仅复制当前手势，避免把其它继承项的旧库引用存成覆盖。
        if control.inheritedGestures.remove(controlGesture(target)) != nil {
            switch target {
            case .press:
                control.press = resolved.press; control.pressAction = resolved.pressAction
                control.pressBehavior = resolved.pressBehavior; control.pressTapCount = resolved.pressTapCount
            case .doublePress:
                control.doublePress = resolved.doublePress; control.doublePressAction = resolved.doublePressAction
                control.doublePressBehavior = resolved.doublePressBehavior; control.doublePressTapCount = resolved.doublePressTapCount
            case .longPress:
                control.longPress = resolved.longPress; control.longPressAction = resolved.longPressAction
                control.longPressBehavior = resolved.longPressBehavior; control.longPressTapCount = resolved.longPressTapCount
            }
        }
        edit(&control)
        if selectedLayer == 0 {
            guard let position = map.controls.firstIndex(where: { $0.index == index }) else { return false }
            map.controls[position] = control
        } else {
            // 四个层始终可用；只在实际编辑时保存该层的覆盖。
            if !map.layers.contains(where: { $0.id == selectedLayer }) {
                map.layers.append(HostLayer(id: selectedLayer))
            }
            guard let layer = map.layers.firstIndex(where: { $0.id == selectedLayer }) else { return false }
            if let position = map.layers[layer].controls.firstIndex(where: { $0.index == index }) {
                map.layers[layer].controls[position] = control
            } else { map.layers[layer].controls.append(control) }
        }
        do { try map.validate() }
        catch { notice = error.localizedDescription; return false }
        updateDraft(map)
        return true
    }
    func isDirty(_ index: Int) -> Bool {
        if device.hostConfigurationMissing { return true }
        guard let draft else { return false }
        let current = draft.control(index: index, layer: selectedLayer)
        guard current == device.hostKeymap?.control(index: index, layer: selectedLayer) else { return true }
        guard let current else { return false }
        return zip(ControlGesture.allCases, [current.effectivePress, current.effectiveDoublePress, current.effectiveLongPress]).contains { gesture, action in
            guard !current.inheritedGestures.contains(gesture), case .library(let id) = action else { return false }
            return draft.actionLibrary.first(where: { $0.id == id }) != device.hostKeymap?.actionLibrary.first(where: { $0.id == id })
        }
    }
    func action(_ index: Int, gesture: AssignmentGesture = .press) -> HostAction? {
        keymap?.resolve(assignedAction(index, gesture: gesture))
    }
    func assignedAction(_ index: Int, gesture: AssignmentGesture = .press) -> HostAction? {
        guard let control = control(index) else { return nil }
        switch gesture {
        case .press: return control.effectivePress
        case .doublePress: return control.effectiveDoublePress
        case .longPress: return control.effectiveLongPress
        }
    }
    func entries(_ index: Int, gesture: AssignmentGesture = .press) -> [KeyEntry]? {
        guard case .keyboard(let entries) = action(index, gesture: gesture) else { return nil }
        return entries
    }
    func actionLabel(_ action: HostAction?) -> String {
        guard let action else { return l("关闭") }
        switch action {
        case .momentaryLayer(let id): return "MO(\(id))"
        case .keyboard(let entries): return actionLabel(entries: entries)
        case .application(let target): return lf("切换到 %@", target.name)
        case .macro(let steps): return lf("宏 · %d 步", steps.count)
        case .library(let id):
            guard let item = libraryItems.first(where: { $0.id == id }) else { return l("引用的功能不存在，请重新选择。") }
            return libraryItemLabel(item)
        }
    }
    func code(_ index: Int, gesture: AssignmentGesture = .press) -> UInt8? {
        guard let values = entries(index, gesture: gesture), values.count == 1, values[0].type == 2 else { return nil }
        return values[0].code
    }
    func label(_ index: Int, gesture: AssignmentGesture = .press) -> String {
        guard canEdit else { return l("本机配置未就绪") }
        return actionLabel(assignedAction(index, gesture: gesture))
    }
    static func actionLabel(_ entries: [KeyEntry]?) -> String {
        guard let entries else { return "关闭" }
        let active = entries.filter { $0.code != 0 }
        guard !active.isEmpty else { return "不执行动作" }
        return active.map { KeyCatalog.label($0.code) }.joined(separator: " + ")
    }
    func actionLabel(entries: [KeyEntry]?) -> String {
        guard let entries else { return l("关闭") }
        let active = entries.filter { $0.code != 0 }
        guard !active.isEmpty else { return l("不执行动作") }
        guard active.count > 1 else { return keyLabel(active[0].code) }
        // 左修饰键使用熟悉的快捷键符号；右修饰键保留名称，不能静默丢掉左右语义。
        let modifiers: [(UInt8, String)] = [(0xE0, "⌃"), (0xE1, "⇧"), (0xE2, "⌥"), (0xE3, "⌘")]
        let symbols = modifiers.filter { code, _ in active.contains { $0.type == 2 && $0.code == code } }
            .map(\.1).joined()
        let remaining = active.filter { entry in
            !modifiers.contains { $0.0 == entry.code && entry.type == 2 }
        }.map { keyLabel($0.code) }.joined(separator: " + ")
        return [symbols, remaining].filter { !$0.isEmpty }.joined(separator: " ")
    }
    func extendedLabel(_ index: Int) -> String? {
        guard index < 4, let control = control(index) else { return nil }
        var labels: [String] = []
        if let action = control.effectiveDoublePress { labels.append(lf("双击 %@", actionLabel(action))) }
        if let action = control.effectiveLongPress { labels.append(lf("长按 %@", actionLabel(action))) }
        return labels.isEmpty ? nil : labels.joined(separator: " · ")
    }
    var fnBehaviorHint: String? {
        guard selected < 4,
              entries(selected, gesture: gesture)?.contains(where: { $0.type == 2 && $0.code == 1 }) == true else { return nil }
        switch actionBehavior() {
        case .tap: return l("手势判定后短按一次 Fn，继续按住不会重复触发。")
        case .burst: return lf("手势判定后连按 Fn %d 次；松开后仍完成本组。", actionTapCount())
        case .hold: break
        }
        if gesture == .longPress {
            switch longPressBehavior() {
            case .hold: return l("达到长按阈值后按住 Fn，物理按键松开时释放。")
            case .tap: return l("达到长按阈值后短按一次 Fn；继续按住不会重复触发。")
            case .burst: return lf("达到长按阈值后连按 Fn %d 次；松开后仍完成本组，继续按住不会重复。", longPressTapCount())
            }
        }
        if gesture == .press, let control = control(selected), control.effectiveDoublePress == nil, control.effectiveLongPress == nil {
            return l("Fn 跟随物理按键持续按住，松开时释放。按住呼出输入法无需额外设置长按。")
        }
        return l("此手势的 Fn 是一次短按。需要持续按住时，请关闭此控件的双击和长按，或将 Fn 分配给使用“保持按住”的长按动作。")
    }
    func isSupported(_ code: UInt8) -> Bool {
        (try? MacKeyEmitter.validate(entries: [KeyEntry(code: code)])) != nil
    }
    private func updateDraft(_ map: HostKeymap) {
        // 用户编辑回原值可撤销草稿；后台快照不得代替这一步清空新编辑。
        draft = submitted == nil && map == device.hostKeymap ? nil : map
        if !layerIDs.contains(selectedLayer) { selectedLayer = 0 }
        notice = nil
    }
    func assign(_ code: UInt8, index: Int? = nil) {
        assign([KeyEntry(code: code)], index: index)
    }
    @discardableResult
    func assign(_ entries: [KeyEntry], index: Int? = nil, gesture: AssignmentGesture? = nil) -> Bool {
        guard !entries.isEmpty else { notice = "组合键不能为空。"; return false }
        return assignAction(.keyboard(entries), index: index, gesture: gesture)
    }
    @discardableResult
    func assignAction(_ action: HostAction, index: Int? = nil, gesture: AssignmentGesture? = nil) -> Bool {
        let index = index ?? selected
        guard canEdit else { return false }
        do { try action.validate() }
        catch { notice = error.localizedDescription; return false }
        let targetGesture = index >= 4 ? AssignmentGesture.press : (gesture ?? self.gesture)
        if case .momentaryLayer = action, (index >= 4 || targetGesture == .doublePress) {
            notice = "切层动作只能分配给按键或旋钮按下的单击或长按。"
            return false
        }
        let entries: [KeyEntry]
        let override: HostAction?
        if case .keyboard(let keys) = action { entries = keys; override = nil }
        else { entries = []; override = action }
        return editControl(index, gesture: targetGesture) { control in
            switch targetGesture {
            case .press:
                control.press = entries
                control.pressAction = override
                if case .momentaryLayer = action {
                    control.doublePress = nil; control.doublePressAction = nil
                    control.inheritedGestures.remove(.doublePress)
                }
            case .doublePress:
                control.doublePress = override == nil ? entries : nil
                control.doublePressAction = override
            case .longPress:
                control.longPress = override == nil ? entries : nil
                control.longPressAction = override
            }
        }
    }

    var libraryItems: [NamedHostAction] {
        (keymap?.actionLibrary ?? []).sorted {
            if $0.isMacro != $1.isMacro { return $0.isMacro }
            return $0.slot < $1.slot
        }
    }
    func libraryItemLabel(_ item: NamedHostAction) -> String {
        "\(item.isMacro ? "M" : "A")\(item.slot) · \(item.name)"
    }
    func usageCount(_ id: UUID) -> Int {
        allControls.reduce(0) { count, control in
            count + zip(ControlGesture.allCases, [control.effectivePress, control.effectiveDoublePress, control.effectiveLongPress]).filter { gesture, action in
                guard !control.inheritedGestures.contains(gesture) else { return false }
                if case .library(let reference) = action { return reference == id }
                return false
            }.count
        }
    }
    func canRemoveLibraryAction(_ id: UUID) -> Bool {
        libraryItems.contains(where: { $0.id == id }) && usageCount(id) == 0
    }
    @discardableResult
    func saveLibraryAction(id: UUID?, name: String, action: HostAction) -> UUID? {
        guard canEdit, var map = keymap else { return nil }
        let previous = id.flatMap { id in map.actionLibrary.first { $0.id == id } }
        guard id == nil || previous != nil else { notice = "引用的功能不存在，请重新选择。"; return nil }
        let isMacro: Bool
        switch action {
        case .macro: isMacro = true
        case .application: isMacro = false
        case .keyboard, .library, .momentaryLayer: notice = "功能库只能保存 APP 或宏，不能嵌套引用。"; return nil
        }
        let slot: Int
        if let previous, previous.isMacro == isMacro { slot = previous.slot }
        else {
            let occupied = Set(map.actionLibrary.filter { $0.isMacro == isMacro && $0.id != id }.map(\.slot))
            guard let available = (0..<16).first(where: { !occupied.contains($0) }) else {
                notice = "宏和 APP 功能各支持 16 个编号（0–15）。"; return nil
            }
            slot = available
        }
        let item = NamedHostAction(id: id ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                   slot: slot, action: action)
        if let position = map.actionLibrary.firstIndex(where: { $0.id == item.id }) { map.actionLibrary[position] = item }
        else { map.actionLibrary.append(item) }
        do { try map.validate() }
        catch { notice = error.localizedDescription; return nil }
        updateDraft(map)
        return item.id
    }
    @discardableResult
    func removeLibraryAction(_ id: UUID) -> Bool {
        guard canEdit, var map = keymap, map.actionLibrary.contains(where: { $0.id == id }) else { return false }
        guard usageCount(id) == 0 else {
            notice = "此功能仍有按键绑定，请先解除绑定后再删除。"; return false
        }
        map.actionLibrary.removeAll { $0.id == id }
        do { try map.validate() }
        catch { notice = error.localizedDescription; return false }
        updateDraft(map)
        return true
    }
    @discardableResult
    func assignLibraryAction(_ id: UUID) -> Bool {
        assignAction(.library(id))
    }
    func actionBehavior(index: Int? = nil, gesture: AssignmentGesture? = nil) -> LongPressBehavior {
        let index = index ?? selected
        guard let control = control(index) else { return .tap }
        let gesture = index >= 4 ? AssignmentGesture.press : (gesture ?? self.gesture)
        switch gesture {
        case .press: return index >= 4 && control.pressBehavior == .hold ? .tap : control.pressBehavior
        case .doublePress: return control.doublePressBehavior
        case .longPress: return control.longPressBehavior
        }
    }
    func actionTapCount(index: Int? = nil, gesture: AssignmentGesture? = nil) -> Int {
        let index = index ?? selected
        guard let control = control(index) else { return 2 }
        switch index >= 4 ? AssignmentGesture.press : (gesture ?? self.gesture) {
        case .press: return control.pressTapCount
        case .doublePress: return control.doublePressTapCount
        case .longPress: return control.longPressTapCount
        }
    }
    var availableActionBehaviors: [LongPressBehavior] {
        selected >= 4 || gesture == .doublePress ? [.tap, .burst] : [.hold, .tap, .burst]
    }
    func actionBehaviorLabel(index: Int? = nil, gesture: AssignmentGesture? = nil) -> String {
        switch actionBehavior(index: index, gesture: gesture) {
        case .hold: return l("保持按住")
        case .tap: return l("短按一次")
        case .burst: return lf("连按 %d 次", actionTapCount(index: index, gesture: gesture))
        }
    }
    var actionBehaviorHelp: String {
        switch actionBehavior() {
        case .hold:
            if gesture == .longPress && selected < 4 { return l("达到长按时间后保持按住，松开时释放。") }
            return l("只设置单击时跟随物理按住；另有双击或长按时，在单击判定后短按一次。")
        case .tap: return l("手势判定后短按一次；次数与单击、双击、长按的触发方式独立。")
        case .burst: return lf("手势判定后连按 %d 次；松开后仍完成本组，次数只影响当前动作。", actionTapCount())
        }
    }
    @discardableResult
    func setActionBehavior(_ behavior: LongPressBehavior, index: Int? = nil, gesture: AssignmentGesture? = nil) -> Bool {
        let index = index ?? selected
        let gesture = index >= 4 ? AssignmentGesture.press : (gesture ?? self.gesture)
        guard entries(index, gesture: gesture) != nil,
              behavior != .hold || (index < 4 && gesture != .doublePress) else { return false }
        return editControl(index, gesture: gesture) { control in
            switch gesture {
            case .press: control.pressBehavior = behavior
            case .doublePress: control.doublePressBehavior = behavior
            case .longPress: control.longPressBehavior = behavior
            }
        }
    }
    @discardableResult
    func setActionTapCount(_ count: Int, index: Int? = nil, gesture: AssignmentGesture? = nil) -> Bool {
        let index = index ?? selected
        let gesture = index >= 4 ? AssignmentGesture.press : (gesture ?? self.gesture)
        guard entries(index, gesture: gesture) != nil else { return false }
        return editControl(index, gesture: gesture) { control in
            switch gesture {
            case .press: control.pressTapCount = count
            case .doublePress: control.doublePressTapCount = count
            case .longPress: control.longPressTapCount = count
            }
        }
    }
    func longPressBehavior(index: Int? = nil) -> LongPressBehavior {
        control(index ?? selected)?.longPressBehavior ?? .hold
    }
    func longPressTapCount(index: Int? = nil) -> Int {
        control(index ?? selected)?.longPressTapCount ?? 2
    }
    func longPressBehaviorLabel(index: Int? = nil) -> String {
        switch longPressBehavior(index: index) {
        case .hold: return l("保持按住")
        case .tap: return l("短按一次")
        case .burst: return lf("连按 %d 次", longPressTapCount(index: index))
        }
    }
    var longPressBehaviorHelp: String {
        switch longPressBehavior() {
        case .hold: return l("达到长按时间后保持按住，松开时释放。")
        case .tap: return l("达到长按时间后短按一次，继续按住不会重复。")
        case .burst: return lf("达到长按时间后连按 %d 次；松开后仍完成本组，继续按住不会重复。", longPressTapCount())
        }
    }
    @discardableResult
    func setLongPressTapCount(_ count: Int, index: Int? = nil) -> Bool {
        let index = index ?? selected
        guard (0..<4).contains(index) else { return false }
        return editControl(index, gesture: .longPress) { $0.longPressTapCount = count }
    }
    @discardableResult
    func setLongPressBehavior(_ behavior: LongPressBehavior, index: Int? = nil) -> Bool {
        let index = index ?? selected
        guard (0..<4).contains(index) else { return false }
        return editControl(index, gesture: .longPress) { $0.longPressBehavior = behavior }
    }
    func disableGesture() {
        guard selected < 4, gesture != .press else { return }
        editControl(selected) { control in
            if gesture == .doublePress {
                control.doublePress = nil; control.doublePressAction = nil
            } else {
                control.longPress = nil; control.longPressAction = nil
            }
        }
    }
    func discard() { draft = nil; selectedLayer = 0; notice = nil }
    func apply() {
        guard canEdit, hasDraft, !device.busy, !applying, let configuration = keymap else { return }
        do { try configuration.validate() } catch { notice = error.localizedDescription; return }
        submitted = configuration
        let requestID = UUID()
        submittedID = requestID
        service.applyHostKeymap(configuration, requestID: requestID)
    }
    func receive(_ snapshot: DeviceSnapshot) {
        let wasOnline = online
        device = snapshot
        if page == 2 && !wasOnline && online && lightingDraft == nil { lightingReadPending = true }
        if lightingReading {
            if snapshot.busy { lightingReadBecameBusy = true }
            if lightingReadBecameBusy && !snapshot.busy {
                lightingReading = false
                lightingFeedbackDismissed = false
            }
        }
        if let id = lightingSubmittedID, let result = snapshot.lightingResult, result.requestID == id {
            if result.error == nil && snapshot.effectiveLighting == lightingDraft {
                lightingDraft = nil
                lightingExpected = nil
                lightingKnobBrightnessEdited = false
            } else {
                if let actual = snapshot.effectiveLighting { lightingExpected = actual }
            }
            lightingFeedbackDismissed = false
            lightingSubmittedID = nil
        }
        if !online {
            lightingKnobBrightnessEdited = false
            lightingDraft = nil
            lightingExpected = nil
            lightingReading = false
            lightingReadBecameBusy = false
        }
        readLightingIfNeeded()
        if !needsPermissionSetup { permissionMessage = nil }
        if let saving = submitted, let result = snapshot.hostSaveResult,
           result.requestID == submittedID {
            submitted = nil
            submittedID = nil
            if result.error == nil && snapshot.hostKeymap == saving {
                // 保存期间还可继续编辑；仅清除已经提交成功的那一份草稿。
                if draft == saving { draft = nil }
                notice = draft == nil ? "键位已保存到本机。" : "已保存提交的配置，后续编辑仍保留在草稿中。"
            } else { setNotice("保存未完成，草稿已保留。%@", result.error ?? "请重试。") }
        }
        if !layerIDs.contains(selectedLayer) { selectedLayer = 0 }
        didChange?()
    }
    func saveProfile(name: String) {
        guard canEdit, let keymap else { notice = "本机配置尚未就绪。"; return }
        let profile = HostProfile(name: name.trimmingCharacters(in: .whitespacesAndNewlines), keymap: keymap)
        do { try profile.validate(); profiles.append(profile); persistProfiles(); notice = demo ? "演示配置已保存，退出后清除。" : "配置已保存在这台 Mac。" }
        catch { notice = error.localizedDescription }
    }
    func loadProfile(_ profile: HostProfile) {
        do {
            try profile.validate()
            updateDraft(profile.keymap)
            notice = "配置已载入草稿，保存到本机后生效；不会修改设备键位。"
        } catch { notice = error.localizedDescription }
    }
    func loadDefaults() {
        loadProfile(HostProfile(name: "默认键位", keymap: .defaultKeymap))
    }
    func importDeviceBindings() {
        guard online, !device.busy, device.keys.count == 6 else {
            notice = "请连接设备并读取完整键位后再导入。"; return
        }
        // 设备键位只是可选来源，导入失败不得覆盖当前本机配置或草稿。
        for binding in device.keys {
            do { try MacKeyEmitter.validate(entries: binding.entries) }
            catch {
                let name = KeyCatalog.controlNames.indices.contains(binding.index)
                    ? KeyCatalog.controlNames[binding.index] : "未知控件"
                setNotice("无法导入%@的设备动作：%@ 当前本机配置和草稿保持不变。", name, error.localizedDescription)
                return
            }
        }
        do {
            let map = try HostKeymap.fromDeviceBindings(device.keys)
            loadProfile(HostProfile(name: "设备键位", keymap: map))
        } catch { setNotice("设备键位导入失败：%@", error.localizedDescription) }
    }
    func profileSummary(_ profile: HostProfile) -> String {
        profile.keymap.controls.sorted { $0.index < $1.index }.map { control in
            let textAction = control.effectivePress
            let primaryLabel: String
            if case .library(let id) = textAction, let item = profile.keymap.actionLibrary.first(where: { $0.id == id }) {
                primaryLabel = libraryItemLabel(item)
            } else { primaryLabel = actionLabel(textAction) }
            var text = primaryLabel
            if control.effectiveDoublePress != nil { text += " / " + gestureTitle(.doublePress) }
            if control.effectiveLongPress != nil { text += " / " + gestureTitle(.longPress) }
            return text
        }.joined(separator: " · ")
    }
    func removeProfile(_ id: UUID) { profiles.removeAll { $0.id == id }; persistProfiles() }
    private func preserveProfileSource(_ data: Data) {
        // 单独保留完整原始字节；后续保存、删除配置也不会覆盖失败项的恢复副本。
        let key = "nativeHostProfilesRecoveryBackups"
        var backups = defaults.array(forKey: key) as? [Data] ?? []
        if !backups.contains(data) { backups.append(data); defaults.set(backups, forKey: key) }
    }
    private func persistProfiles() {
        if !demo, let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: "nativeHostProfiles") }
    }
    func exportProfile() {
        guard canEdit, let keymap else { notice = "请先初始化本机配置。"; return }
        let profile = HostProfile(name: "Vibe Key", keymap: keymap)
        do { try profile.validate() } catch { notice = error.localizedDescription; return }
        let timestamp = DateFormatter()
        timestamp.locale = Locale(identifier: "en_US_POSIX")
        timestamp.calendar = Calendar(identifier: .gregorian)
        timestamp.timeZone = .current
        timestamp.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "vibe-key-\(timestamp.string(from: Date())).json"
        panel.allowedContentTypes = [.json]
        panel.title = l("导出配置"); panel.prompt = l("导出"); panel.nameFieldLabel = l("文件名：")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(profile).write(to: url, options: .atomic)
        } catch { notice = error.localizedDescription }
    }
    func importProfile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.title = l("导入配置"); panel.prompt = l("导入")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 32768 else {
                notice = "配置文件不能超过 32 KB。"; return
            }
            let information = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard information.isRegularFile == true else { notice = "请选择普通 JSON 配置文件。"; return }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: HostKeymap.maximumJSONBytes + 1) ?? Data()
            guard data.count <= HostKeymap.maximumJSONBytes else { notice = "配置文件不能超过 32 KB。"; return }
            let profile = try HostProfile.decode(data: data)
            try profile.validate(); loadProfile(profile)
        } catch { setNotice("导入失败：%@", error.localizedDescription) }
    }
}
