import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OlanziCore

/// 动作库的内嵌编辑器；确认只更新库草稿，分配与本机生效另行完成。
struct ActionEditor: View {
    @ObservedObject var model: AppModel
    let item: NamedHostAction?
    let kind: LibraryActionKind
    let onClose: () -> Void
    @State private var name: String
    @State private var application: ApplicationTarget?
    @State private var steps: [StepDraft]
    @State private var error: String?
    @State private var codeSource = ""
    @State private var validationMessage: String?
    @State private var codeMode = false
    @State private var showsCodeHelp = false
    @State private var recordingID: UUID?
    @StateObject private var recorder = ShortcutRecorder()
    @StateObject private var macroRecorder = MacroRecorder()
    @State private var recordingSessionShown = false
    @State private var recordDelays = true
    private var busyRecording: Bool { recorder.isRecording || macroRecorder.isRecording }

    private struct StepDraft: Identifiable {
        let id = UUID()
        var action: MacroStep
        var delayText: String
        init(action: MacroStep) {
            self.action = action
            if case .delay(let seconds) = action { delayText = String(seconds) }
            else { delayText = "" }
        }
    }

    init(model: AppModel, item: NamedHostAction?, kind: LibraryActionKind,
         initialAction: HostAction? = nil, onClose: @escaping () -> Void) {
        self.model = model
        self.item = item
        self.kind = kind
        self.onClose = onClose
        _name = State(initialValue: item?.name ?? "")
        let action = item?.action ?? initialAction
        if case .application(let target) = action {
            _application = State(initialValue: target)
            _steps = State(initialValue: [])
        } else if case .macro(let values) = action {
            _steps = State(initialValue: values.map { StepDraft(action: $0) })
        } else { _steps = State(initialValue: []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button { onClose() } label: { Image(systemName: "arrow.left") }
                    .buttonStyle(OlanziButtonStyle(.subtle)).disabled(busyRecording)
                    .accessibilityLabel(model.l("返回动作库"))
                Text(model.l(kind == .macro ? (item == nil ? "新建宏" : "编辑宏") : (item == nil ? "添加 APP" : "编辑 APP")))
                    .font(.headline)
                Spacer()
                if let item {
                    Button {
                        if model.removeLibraryAction(item.id) { onClose() }
                    } label: { Image(systemName: "trash") }
                        .disabled(!model.canRemoveLibraryAction(item.id) || busyRecording)
                        .accessibilityLabel(model.l("删除库动作"))
                        .help(model.l("已分配的动作需先解除所有绑定，再删除。"))
                }
            }
            TextField(model.l("动作名称"), text: $name)
                .textFieldStyle(OlanziTextFieldStyle()).disabled(busyRecording)
            if kind == .application {
                Text(model.l("启动或切换到所选 APP，等待它成为前台应用。"))
                    .font(.callout).foregroundStyle(.secondary)
                applicationRow(application) { application = $0; if name.isEmpty { name = $0.name } }
                Spacer(minLength: 100)
            } else {
                HStack(spacing: 6) {
                    Button(model.l("可视化")) { switchEditor(toCode: false) }
                        .buttonStyle(OlanziButtonStyle(codeMode ? .subtle : .secondary))
                    Button("Code") { switchEditor(toCode: true) }
                        .buttonStyle(OlanziButtonStyle(codeMode ? .secondary : .subtle))
                    Spacer()
                    Button { showsCodeHelp.toggle() } label: { Image(systemName: "questionmark.circle") }
                        .buttonStyle(OlanziButtonStyle(.subtle)).accessibilityLabel(model.l("语法说明"))
                        .popover(isPresented: $showsCodeHelp) { codeHelp }
                }.disabled(busyRecording || recordingSessionShown)
                if recordingSessionShown { recordingPanel }
                else if codeMode { codeEditor }
                else { macroEditor }
            }
            if let error { Text(model.displayError(error)).foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true) }
            Divider()
            HStack {
                Text(model.l("保存到动作库后，点击键帽分配；保存到本机后生效。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(model.l("取消")) { recorder.reset(); macroRecorder.reset(); onClose() }
                    .disabled(busyRecording)
                Button(model.l("保存动作")) { save() }
                    .buttonStyle(OlanziButtonStyle(.primary))
                    .disabled(busyRecording || recordingSessionShown || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              (kind == .application ? application == nil : codeMode ? codeSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : steps.isEmpty))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(OlanziButtonStyle())
        .onChange(of: recorder.isRecording) { _, recording in
            if !recording {
                if let id = recordingID, let position = steps.firstIndex(where: { $0.id == id }),
                   let keys = recorder.candidate, !keys.isEmpty, recorder.error == nil {
                    steps[position].action = .keyboard(keys)
                }
                if let message = recorder.error { error = message }
                recordingID = nil
            }
        }
        .onChange(of: codeSource) { _, _ in validationMessage = nil }
        .onDisappear { recorder.reset(); macroRecorder.reset() }
    }

    private var recordingPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(macroRecorder.isRecording ? Color.red : Palette.accent).frame(width: 8, height: 8)
                Text(model.l(macroRecorder.isRecording ? "正在录制宏…" : "录制已停止")).font(.headline)
                Spacer()
                Text(model.lf("%d / 32 步", macroRecorder.steps.count)).monospacedDigit().foregroundStyle(.secondary)
            }
            Text(model.l("依次按下按键或组合键，完成后点击停止。"))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(macroRecorder.steps.enumerated()), id: \.offset) { index, step in
                        HStack {
                            Text(String(index + 1)).foregroundStyle(.secondary).frame(width: 24)
                            if case .keyboard(let keys) = step { Text(model.actionLabel(entries: keys)) }
                            else if case .delay(let seconds) = step { Text(model.lf("等待 %.2f 秒", seconds)) }
                            Spacer()
                        }.font(.system(size: 14, design: .monospaced))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 180).padding(12).background(Palette.background, in: RoundedRectangle(cornerRadius: 8))
            if let error = macroRecorder.error { Text(model.displayError(error)).font(.caption).foregroundStyle(.orange) }
            HStack {
                if macroRecorder.isRecording {
                    Button(model.l("停止录制")) { macroRecorder.stop() }.buttonStyle(OlanziButtonStyle(.primary))
                } else {
                    Button(model.l("丢弃录制")) { macroRecorder.reset(); recordingSessionShown = false }
                    Spacer()
                    Button(model.l("追加录制步骤")) {
                        guard steps.count + macroRecorder.steps.count <= 32 else { error = "宏必须包含 1–32 个步骤。"; return }
                        steps += macroRecorder.steps.map { StepDraft(action: $0) }
                        macroRecorder.reset(); recordingSessionShown = false; error = nil
                    }.buttonStyle(OlanziButtonStyle(.primary)).disabled(macroRecorder.steps.isEmpty)
                }
            }
        }
    }

    private var codeEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.l("QMK 宏语法子集；应用切换使用 OLANZI_APP 扩展。"))
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $codeSource)
                .font(.system(size: 13, design: .monospaced))
                .autocorrectionDisabled()
                .accessibilityLabel(model.l("宏代码"))
                .padding(8).frame(height: 210).background(Palette.background, in: RoundedRectangle(cornerRadius: 8))
            if let validationMessage { Text(validationMessage).font(.caption).foregroundStyle(.green) }
            HStack {
                Button(model.l("校验代码")) {
                    do {
                        let parsed = try QMKMacroCodec.decode(codeSource)
                        try HostAction.macro(parsed).validate()
                        error = nil
                        validationMessage = model.lf("代码有效：%d 步。", parsed.count)
                    } catch { self.error = error.localizedDescription }
                }
                Button(model.l("填入 Codex 聚焦宏")) { fillCodex() }
                Spacer()
            }
        }
    }

    private var codeHelp: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.l("QMK 宏代码")).font(.headline)
            Text("OLANZI_APP(\"com.openai.codex\");\nwait_ms(800);\ntap_code16(LCTL(LALT(LGUI(KC_I))));")
                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Text(model.l("使用 QMK 键码和毫秒等待。只解析受支持的宏语句，不执行任意 C 代码。"))
            Text(model.l("切回可视化或使用此功能时会校验代码；错误不会覆盖已有步骤。"))
            Link(model.l("QMK 官方宏文档"), destination: URL(string: "https://docs.qmk.fm/feature_macros")!)
        }.padding(20).frame(width: 420)
    }

    private func switchEditor(toCode: Bool) {
        guard toCode != codeMode else { return }
        do {
            if toCode { codeSource = try QMKMacroCodec.encode(try validatedSteps()) }
            else {
                let parsed = try QMKMacroCodec.decode(codeSource)
                try HostAction.macro(parsed).validate()
                steps = parsed.map { StepDraft(action: $0) }
            }
            codeMode = toCode
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private var macroEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    error = nil
                    macroRecorder.start(window: NSApp.keyWindow, recordDelays: recordDelays)
                    recordingSessionShown = true
                } label: { Label(model.l("录制宏"), systemImage: "record.circle") }
                    .disabled(recorder.isRecording)
                Toggle(model.l("记录间隔"), isOn: $recordDelays).toggleStyle(.checkbox).font(.caption)
                    .disabled(recorder.isRecording)
                Spacer()
                Menu {
                    Button(model.l("填入 Codex 聚焦宏")) { fillCodex() }
                } label: { Label(model.l("模板"), systemImage: "sparkles") }
                    .menuStyle(.borderlessButton).padding(.horizontal, 10).frame(height: 34)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 6)).fixedSize().disabled(recorder.isRecording)
            }
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { offset, step in
                        stepRow(offset, step: step)
                    }
                    if steps.isEmpty {
                        Text(model.l("添加 APP、组合键或等待步骤，组成你的宏。"))
                            .foregroundStyle(.secondary).padding(36)
                    }
                }
            }.frame(height: 230)
            HStack(spacing: 8) {
                Button(model.l("添加 APP")) {
                    if let target = chooseApplication() { steps.append(StepDraft(action: .application(target))) }
                }
                Button(model.l("添加组合键")) { steps.append(StepDraft(action: .keyboard([KeyEntry(code: 0x28)]))) }
                Button(model.l("添加等待")) { steps.append(StepDraft(action: .delay(0.8))) }
                Spacer()
                Text(model.lf("%d / 32 步", steps.count)).foregroundStyle(.secondary)
            }.disabled(steps.count >= 32 || recorder.isRecording)
        }
    }

    private func stepRow(_ offset: Int, step: StepDraft) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(offset + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 22)
                switch step.action {
                case .application(let target):
                    applicationRow(target) { steps[offset].action = .application($0) }
                case .delay:
                    Label(model.l("等待"), systemImage: "clock")
                    TextField(model.l("秒"), text: Binding(get: { steps[offset].delayText }, set: { steps[offset].delayText = $0 }))
                        .textFieldStyle(OlanziTextFieldStyle()).frame(width: 80)
                    Text(model.l("秒（0.05–10）")).foregroundStyle(.secondary)
                    Spacer()
                case .keyboard(let keys):
                    Label(model.actionLabel(entries: keys), systemImage: "keyboard").lineLimit(2)
                    Spacer()
                    Button(model.l(recordingID == step.id ? "按下组合键…" : "录制组合键")) {
                        error = nil
                        recordingID = step.id
                        recorder.start(window: NSApp.keyWindow)
                        if !recorder.isRecording { error = recorder.error; recordingID = nil }
                    }.disabled(recorder.isRecording)
                }
                Button { steps.swapAt(offset, offset - 1) } label: { Image(systemName: "arrow.up") }
                    .disabled(offset == 0 || recorder.isRecording).help(model.l("上移"))
                    .accessibilityLabel(model.l("上移"))
                Button { steps.swapAt(offset, offset + 1) } label: { Image(systemName: "arrow.down") }
                    .disabled(offset == steps.count - 1 || recorder.isRecording).help(model.l("下移"))
                    .accessibilityLabel(model.l("下移"))
                Button { steps.remove(at: offset) } label: { Image(systemName: "trash") }
                    .disabled(recorder.isRecording).help(model.l("删除步骤"))
                    .accessibilityLabel(model.l("删除步骤"))
            }
            if case .keyboard(let keys) = step.action {
                HStack {
                    ForEach([(UInt8(0xE0), "⌃"), (0xE1, "⇧"), (0xE2, "⌥"), (0xE3, "⌘")], id: \.0) { code, title in
                        Toggle(title, isOn: Binding(get: { keys.contains { $0.code == code } }, set: { enabled in
                            var updated = keys.filter { $0.code != code }
                            if enabled { updated.insert(KeyEntry(code: code), at: 0) }
                            steps[offset].action = .keyboard(updated)
                        })).toggleStyle(OlanziToggleStyle())
                    }
                    Menu(model.l("选择按键")) {
                        ForEach(KeyCatalog.categories, id: \.self) { category in
                            Menu(model.categoryTitle(category)) {
                                ForEach(KeyCatalog.options.filter { $0.category == category && model.isSupported($0.code) }) { key in
                                    Button(model.keyLabel(key.code)) {
                                        let modifiers = keys.filter { (0xE0...0xE7).contains($0.code) }
                                        steps[offset].action = .keyboard(modifiers + [KeyEntry(code: key.code)])
                                    }
                                }
                            }
                        }
                    }.menuStyle(.borderlessButton).padding(.horizontal, 10).frame(width: 150, height: 34)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 6))
                    Text(model.l("也可录制完整组合键。")) .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.disabled(recorder.isRecording)
            }
        }
        .padding(12).background(Palette.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    private func applicationRow(_ target: ApplicationTarget?, set: @escaping (ApplicationTarget) -> Void) -> some View {
        HStack {
            Image(systemName: "app")
            VStack(alignment: .leading) {
                Text(target?.name ?? model.l("尚未选择 APP"))
                if let target { Text(target.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            Spacer()
            Button(model.l("选择 APP…")) { if let target = chooseApplication() { set(target) } }
                .disabled(recorder.isRecording)
        }
    }

    private func chooseApplication() -> ApplicationTarget? {
        let panel = NSOpenPanel()
        panel.title = model.l("选择 APP")
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else {
            error = "请选择有效的 macOS APP。"; return nil
        }
        return ApplicationTarget(bundleIdentifier: identifier, path: url.path,
                                 name: url.deletingPathExtension().lastPathComponent)
    }

    private func fillCodex() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else {
            error = "未找到 Codex，请使用添加 APP 选择应用。"; return
        }
        steps = [StepDraft(action: .application(ApplicationTarget(bundleIdentifier: "com.openai.codex", path: url.path, name: "Codex"))),
                 StepDraft(action: .delay(0.8)),
                 StepDraft(action: .keyboard([0xE0, 0xE2, 0xE3, 0x0C].map { KeyEntry(code: $0) }))]
        error = nil
        if name.isEmpty { name = model.l("聚焦 Codex") }
        if codeMode {
            do { codeSource = try QMKMacroCodec.encode(try validatedSteps()) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func validatedSteps() throws -> [MacroStep] {
        try steps.map { step in
            if case .delay = step.action {
                guard let value = Double(step.delayText.replacingOccurrences(of: ",", with: ".")),
                      value.isFinite, (0.05...10).contains(value) else { throw HostActionError.invalidDelay }
                return .delay(value)
            }
            return step.action
        }
    }

    private func save() {
        let action: HostAction
        if kind == .application {
            guard let application else { return }
            action = .application(application)
        } else if codeMode {
            do { action = .macro(try QMKMacroCodec.decode(codeSource)) }
            catch { self.error = error.localizedDescription; return }
        } else {
            do { action = .macro(try validatedSteps()) }
            catch { self.error = error.localizedDescription; return }
        }
        if model.saveLibraryAction(id: item?.id, name: name, action: action) != nil { onClose() }
        else { error = model.notice }
    }
}
