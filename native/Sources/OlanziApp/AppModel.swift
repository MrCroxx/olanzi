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
    @Published private(set) var draft: HostKeymap?
    @Published var notice: String?
    @Published var profiles: [HostProfile] = []
    private var submitted: HostKeymap?
    private var applyWasBusy = false
    let demo: Bool
    var didChange: (() -> Void)?
    private lazy var service = NativeDeviceService(demo: demo) { [weak self] snapshot in
        DispatchQueue.main.async { self?.receive(snapshot) }
    }

    init(demo: Bool) {
        self.demo = demo
        guard !demo else { return }
        // 新格式单独保存，迁移时保留原列表，旧版本仍能读取自己的配置。
        let defaults = UserDefaults.standard
        let stored = defaults.data(forKey: "nativeHostProfiles") ?? defaults.data(forKey: "nativeProfiles")
        if let stored {
            do {
                let decoded = try JSONDecoder().decode([HostProfile].self, from: stored)
                profiles = decoded.filter { (try? $0.validate()) != nil }
                if profiles.count != decoded.count { notice = "部分配置包含不支持的键码，未载入；原始列表已保留。" }
                if defaults.data(forKey: "nativeHostProfiles") == nil { persistProfiles() }
            } catch { notice = "无法读取本地配置列表，原始数据已保留：\(error.localizedDescription)" }
        }
    }
    var online: Bool { device.connected && device.online == true }
    var keymap: HostKeymap? { draft ?? device.hostKeymap }
    var canEdit: Bool { device.hostKeymap != nil }
    var hasDraft: Bool { draft != nil }
    var applying: Bool { submitted != nil }
    var dirtyCount: Int { (0..<6).filter { isDirty($0) }.count }
    var timingsChanged: Bool {
        guard let draft, let saved = device.hostKeymap else { return false }
        return draft.doublePressWindow != saved.doublePressWindow || draft.longPressThreshold != saved.longPressThreshold
    }
    var status: String {
        if demo { return "演示模式" }
        if !device.connected { return "等待接收器" }
        return device.online == true ? "Vibe Key 已连接" : device.online == false ? "设备离线 / 休眠" : "正在确认设备状态"
    }
    func start() { service.start() }
    func stop(completion: @escaping @Sendable () -> Void) { service.stop(completion: completion) }
    func connect() { service.connect() }
    func disconnect() { service.disconnect() }
    func suspendForSystemSleep() { service.suspendForSystemSleep() }
    func resumeAfterSystemWake() { service.resumeAfterSystemWake() }
    func refresh() { service.refresh() }
    func refreshPermissions() { if !demo { service.checkFnPermissions() } }
    func revealApplication() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
    var permissionButtonTitle: String {
        guard let permission = device.fn.missingPermissions.first else { return "检查权限" }
        return "打开\(permission.title)设置"
    }
    func requestPermissions() {
        guard !demo else { return }
        guard let permission = device.fn.missingPermissions.first else {
            notice = "系统权限已就绪。"; return
        }
        // 权限请求不等待设备线程，离线时同样可以授权。
        permission.requestAccess()
        refreshPermissions()
        if NSWorkspace.shared.open(permission.settingsURL) {
            notice = "已打开\(permission.title)设置，请开启 Olanzi。列表中没有时，点 + 添加应用；可在设备页显示 App 位置。返回后自动复查，必要时退出并重新打开 Olanzi。"
        } else { notice = "无法打开系统设置。请手动进入“隐私与安全性 → \(permission.title)”，允许 Olanzi。" }
    }
    func control(_ index: Int) -> ControlActionMap? { keymap?.controls.first { $0.index == index } }
    func isDirty(_ index: Int) -> Bool {
        guard let draft else { return false }
        return draft.controls.first { $0.index == index } != device.hostKeymap?.controls.first { $0.index == index }
    }
    func entries(_ index: Int, gesture: AssignmentGesture = .press) -> [KeyEntry]? {
        guard let control = control(index) else { return nil }
        switch gesture {
        case .press: return control.press
        case .doublePress: return control.doublePress
        case .longPress: return control.longPress
        }
    }
    func code(_ index: Int, gesture: AssignmentGesture = .press) -> UInt8? {
        guard let values = entries(index, gesture: gesture), values.count == 1, values[0].type == 2 else { return nil }
        return values[0].code
    }
    func label(_ index: Int, gesture: AssignmentGesture = .press) -> String {
        guard canEdit else { return "等待初始化" }
        return Self.actionLabel(entries(index, gesture: gesture))
    }
    static func actionLabel(_ entries: [KeyEntry]?) -> String {
        guard let entries else { return "关闭" }
        let active = entries.filter { $0.code != 0 }
        guard !active.isEmpty else { return "不执行动作" }
        return active.map { KeyCatalog.label($0.code) }.joined(separator: " + ")
    }
    func extendedLabel(_ index: Int) -> String? {
        guard index < 4, let control = control(index) else { return nil }
        var labels: [String] = []
        if let action = control.doublePress { labels.append("双击 \(Self.actionLabel(action))") }
        if let action = control.longPress { labels.append("长按 \(Self.actionLabel(action))") }
        return labels.isEmpty ? nil : labels.joined(separator: " · ")
    }
    func isSupported(_ code: UInt8) -> Bool {
        (try? MacKeyEmitter.validate(entries: [KeyEntry(code: code)])) != nil
    }
    private func updateDraft(_ map: HostKeymap) {
        // 用户编辑回原值可撤销草稿；后台快照不得代替这一步清空新编辑。
        draft = submitted == nil && map == device.hostKeymap ? nil : map
        notice = nil
    }
    func assign(_ code: UInt8, index: Int? = nil) {
        let index = index ?? selected
        guard canEdit, var map = keymap, let position = map.controls.firstIndex(where: { $0.index == index }) else { return }
        do { try MacKeyEmitter.validate(entries: [KeyEntry(code: code)]) }
        catch { notice = error.localizedDescription; return }
        let action = [KeyEntry(code: code)]
        switch index >= 4 ? AssignmentGesture.press : gesture {
        case .press: map.controls[position].press = action
        case .doublePress: map.controls[position].doublePress = action
        case .longPress: map.controls[position].longPress = action
        }
        updateDraft(map)
    }
    func disableGesture() {
        guard selected < 4, gesture != .press, canEdit, var map = keymap,
              let position = map.controls.firstIndex(where: { $0.index == selected }) else { return }
        if gesture == .doublePress { map.controls[position].doublePress = nil }
        else { map.controls[position].longPress = nil }
        updateDraft(map)
    }
    func discard() { draft = nil; notice = nil }
    func apply() {
        guard canEdit, !device.busy, !applying, let draft else { return }
        do { try draft.validate() } catch { notice = error.localizedDescription; return }
        submitted = draft
        applyWasBusy = false
        service.applyHostKeymap(draft)
    }
    func receive(_ snapshot: DeviceSnapshot) {
        device = snapshot
        if submitted != nil && snapshot.busy { applyWasBusy = true }
        if let saving = submitted, applyWasBusy && !snapshot.busy {
            submitted = nil
            if snapshot.hostKeymap == saving {
                // 保存期间还可继续编辑；仅清除已经提交成功的那一份草稿。
                if draft == saving { draft = nil }
                notice = draft == nil ? "键位已保存到本机。" : "已保存提交的配置，后续编辑仍保留在草稿中。"
            } else { notice = "保存未完成，草稿已保留。\(snapshot.error.map { "\($0)" } ?? "请重试。")" }
        }
        didChange?()
    }
    func saveProfile(name: String) {
        guard canEdit, let keymap else { notice = "请先连接设备，初始化本机配置。"; return }
        let profile = HostProfile(name: name.trimmingCharacters(in: .whitespacesAndNewlines), keymap: keymap)
        do { try profile.validate(); profiles.append(profile); persistProfiles(); notice = demo ? "演示配置已保存，退出后清除。" : "配置已保存在这台 Mac。" }
        catch { notice = error.localizedDescription }
    }
    func loadProfile(_ profile: HostProfile) {
        do {
            try profile.validate()
            guard canEdit else { notice = "请先连接设备，初始化本机配置。"; return }
            updateDraft(profile.keymap)
            notice = "配置已载入草稿，保存到本机后生效。"
        } catch { notice = error.localizedDescription }
    }
    func loadDefaults() {
        let controls = KeyCatalog.defaults.enumerated().map {
            ControlActionMap(index: $0.offset, press: [KeyEntry(code: $0.element)], doublePress: nil, longPress: nil)
        }
        loadProfile(HostProfile(name: "出厂键位", keymap: HostKeymap(controls: controls)))
    }
    func profileSummary(_ profile: HostProfile) -> String {
        profile.keymap.controls.sorted { $0.index < $1.index }.map { control in
            var text = Self.actionLabel(control.press)
            if control.doublePress != nil { text += " / 双击" }
            if control.longPress != nil { text += " / 长按" }
            return text
        }.joined(separator: " · ")
    }
    func removeProfile(_ id: UUID) { profiles.removeAll { $0.id == id }; persistProfiles() }
    private func persistProfiles() {
        if !demo, let data = try? JSONEncoder().encode(profiles) { UserDefaults.standard.set(data, forKey: "nativeHostProfiles") }
    }
    func exportProfile() {
        guard canEdit, let keymap else { notice = "请先初始化本机配置。"; return }
        let profile = HostProfile(name: "Vibe Key", keymap: keymap)
        do { try profile.validate() } catch { notice = error.localizedDescription; return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "vibe-key.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(profile).write(to: url, options: .atomic)
        } catch { notice = error.localizedDescription }
    }
    func importProfile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
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
        } catch { notice = "导入失败：\(error.localizedDescription)" }
    }
}
