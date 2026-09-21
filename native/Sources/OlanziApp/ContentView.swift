import AppKit
import SwiftUI
import OlanziCore

private enum Palette {
    static let background = Color(red: 0.115, green: 0.106, blue: 0.106)
    static let surface = Color(red: 0.212, green: 0.204, blue: 0.204)
    static let raised = Color(red: 0.255, green: 0.255, blue: 0.255)
    static let accent = Color(red: 0.91, green: 0.769, blue: 0.722)
    static let text = Color(white: 0.85)
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var category = "常用"
    @State private var search = ""
    @State private var profileName = ""
    @State private var showsGestureHelp = false
    @StateObject private var recorder = ShortcutRecorder()
    private struct CombinationTarget: Equatable {
        let index: Int
        let gesture: AssignmentGesture
    }
    @State private var combinationTarget: CombinationTarget?
    @State private var combination: [KeyEntry] = []
    var body: some View {
        Group {
            if !model.demo && model.needsPermissionSetup {
                permissionWelcome
            } else {
                workspace
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background).foregroundStyle(Palette.text)
        .tint(Palette.accent).preferredColorScheme(.dark)
        .environment(\.locale, model.localizer.locale)
        .frame(minWidth: 860, minHeight: 690)
        .onChange(of: model.selected) { _, _ in closeCombinationEditor() }
        .onChange(of: model.gesture) { _, _ in closeCombinationEditor() }
        .onChange(of: model.page) { _, _ in closeCombinationEditor() }
        .onChange(of: model.needsPermissionSetup) { _, _ in closeCombinationEditor() }
        .onChange(of: recorder.isRecording) { _, recording in
            if !recording, let candidate = recorder.candidate { combination = candidate }
        }
        .onDisappear { recorder.stop() }
    }
    private var languagePicker: some View {
        Picker(model.l("语言"), selection: $model.language) {
            Text(model.l("跟随系统")).tag(AppLanguage.system)
            Text("简体中文").tag(AppLanguage.simplifiedChinese)
            Text("English").tag(AppLanguage.english)
        }
        .pickerStyle(.menu)
        .accessibilityLabel(model.l("界面语言"))
    }
    private var appSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(model.l("设置")).font(.title2.bold())
            HStack {
                Label(model.l("界面语言"), systemImage: "globe").font(.headline)
                Spacer()
                languagePicker.labelsHidden().frame(width: 260)
            }
            .padding(24)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
        }
    }
    private var permissionWelcome: some View {
        VStack(spacing: 30) {
            HStack {
                Spacer()
                languagePicker.labelsHidden().frame(width: 180)
            }
            VStack(spacing: 20) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 72, height: 72)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityHidden(true)
                VStack(spacing: 10) {
                    Text(model.l("欢迎使用 Olanzi")).font(.system(size: 30, weight: .semibold))
                    Text(model.l("开启两项系统权限，开始设置你的 Vibe Key。"))
                        .font(.body).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 0) {
                permissionRow(title: model.l("输入监控"), symbol: "keyboard",
                              detail: model.l("接收 Vibe Key 的按键与旋钮操作"),
                              granted: model.permissionStatus.inputPermission == true)
                Divider().padding(.horizontal, 22)
                permissionRow(title: model.l("辅助功能"), symbol: "cursorarrow.rays",
                              detail: model.l("让自定义按键在 macOS 中生效"),
                              granted: model.permissionStatus.accessibilityPermission == true)
            }
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            VStack(spacing: 16) {
                Button { model.requestPermissions() } label: {
                    HStack(spacing: 10) {
                        if model.isCheckingPermissions { ProgressView().controlSize(.small) }
                        Text(model.isCheckingPermissions ? model.l("正在检查权限…") : model.permissionButtonTitle)
                            .font(.body.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .foregroundStyle(Palette.background)
                .disabled(model.isCheckingPermissions)
                if let error = model.permissionSetupError {
                    Text(error).font(.callout).foregroundStyle(Palette.accent)
                        .multilineTextAlignment(.center)
                }
                Text(model.l("在系统设置中开启 Olanzi。\n每秒自动检测，权限就绪后会自动进入。"))
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineSpacing(4)
                HStack(spacing: 6) {
                    Text(model.l("列表中没有 Olanzi？")).foregroundStyle(.secondary)
                    Button(model.l("显示 App 位置")) { model.revealApplication() }
                        .buttonStyle(.plain).foregroundStyle(Palette.accent)
                }.font(.callout)
            }
        }
        .frame(width: 540)
        .padding(.vertical, 48)
    }
    private func permissionRow(title: String, symbol: String, detail: String, granted: Bool) -> some View {
        HStack(spacing: 15) {
            Image(systemName: symbol).font(.system(size: 21))
                .foregroundStyle(Palette.accent).frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            HStack(spacing: 6) {
                Image(systemName: !model.isCheckingPermissions && granted ? "checkmark.circle.fill" : "circle")
                Text(model.l(model.isCheckingPermissions ? "检查中" : granted ? "已就绪" : "待开启"))
            }
            .font(.callout)
            .foregroundStyle(!model.isCheckingPermissions && granted ? Palette.accent : Color.secondary)
        }
        .padding(22)
        .accessibilityElement(children: .combine)
    }
    private var workspace: some View {
        VStack(spacing: 0) {
            header
            if let notice = model.notice {
                HStack {
                    Image(systemName: "info.circle").foregroundStyle(Palette.accent)
                    Text(notice).font(.callout)
                    Spacer()
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel(model.l("关闭提示"))
                }.padding(.horizontal, 28).padding(.vertical, 12).background(Palette.surface)
            }
            Divider().overlay(Color.white.opacity(0.06))
            ScrollView {
                VStack(spacing: 24) {
                    if model.page == 0 { keymap }
                    else if model.page == 1 { deviceSettings }
                    else if model.page == 2 { profiles }
                    else { appSettings }
                }.padding(28).frame(maxWidth: .infinity)
            }
            footer
        }
    }
    private var header: some View {
        HStack(spacing: 24) {
            HStack(spacing: 9) {
                Image(systemName: "slider.horizontal.3").font(.title2).foregroundStyle(Palette.accent)
                Text("OLANZI").font(.system(size: 17, weight: .bold, design: .rounded)).tracking(3)
            }
            Spacer()
            ForEach(Array([(0, "keyboard", "键位"), (1, "slider.horizontal.3", "设备"), (2, "square.stack", "配置"), (3, "gearshape", "设置")].enumerated()), id: \.offset) { _, item in
                Button { model.page = item.0 } label: {
                    Label(model.l(item.2), systemImage: item.1).font(.system(size: 14, weight: .medium))
                        .foregroundStyle(model.page == item.0 ? Palette.accent : Color.gray)
                        .frame(width: 82, height: 42)
                }.buttonStyle(.plain).accessibilityLabel(model.l(item.2))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 7) {
                    Circle().fill(model.online ? Color.green.opacity(0.8) : Color.gray).frame(width: 6, height: 6)
                    Text(model.online ? model.l("已连接") : model.status).font(.system(size: 13)).help(model.status)
                }
                Label(model.batteryText, systemImage: model.batterySymbol)
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundStyle(model.batteryLow ? Color.orange : Color.secondary)
                    .help(model.batteryHelp)
                    .accessibilityLabel(model.lf("电池电量：%@", model.batteryText))
            }.frame(minWidth: 150, alignment: .trailing)
        }.padding(.horizontal, 28).padding(.vertical, 13)
    }
    private var keymap: some View {
        VStack(alignment: .leading, spacing: 16) {
            hardware
            Divider()
            gestureEditor
            keyPicker.disabled(recorder.isRecording)
        }
    }
    private var keyPicker: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                HStack(spacing: 4) {
                    ForEach(KeyCatalog.categories, id: \.self) { name in
                        Button(model.categoryTitle(name)) { category = name; search = "" }
                            .buttonStyle(.plain).font(.system(size: 13, weight: category == name ? .semibold : .regular))
                            .padding(.horizontal, 8).padding(.vertical, 9)
                            .background(category == name ? Palette.raised : .clear, in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(category == name ? Palette.accent : Palette.text)
                    }
                }
                Spacer(minLength: 10)
                TextField(model.l("搜索按键"), text: $search).textFieldStyle(.roundedBorder).frame(width: 135)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 73, maximum: 110), spacing: 8)], spacing: 8) {
                ForEach(KeyCatalog.options.filter { search.isEmpty ? $0.category == category : (model.l($0.label).localizedCaseInsensitiveContains(search) || $0.label.localizedCaseInsensitiveContains(search)) || String(format: "0x%02X", $0.code).localizedCaseInsensitiveContains(search) }) { key in
                    Button { closeCombinationEditor(); model.assign(key.code) } label: {
                        Text(model.l(key.label)).font(.system(size: 14, weight: .medium))
                            .lineLimit(2).multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity).frame(height: 43)
                            .foregroundStyle(model.code(model.selected, gesture: model.gesture) == key.code ? Palette.background : Palette.text)
                            .background(model.code(model.selected, gesture: model.gesture) == key.code ? Palette.accent : Palette.surface, in: RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain).disabled(!model.canEdit || !model.isSupported(key.code))
                        .opacity(model.isSupported(key.code) ? 1 : 0.35)
                        .help(model.l(model.isSupported(key.code) ? "分配给当前动作" : "当前 macOS 不支持此键码"))
                        .accessibilityLabel(model.lf("分配 %@", model.l(key.label)))
                }
            }
        }
    }
    private var hardware: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .trailing, spacing: 16) {
                rotationControl(5, title: "左旋", symbol: "arrow.counterclockwise")
                    .frame(height: 96)
                VStack(alignment: .leading, spacing: 10) {
                    Label(model.l("旋钮按下"), systemImage: "hand.tap")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(model.selected == 3 ? Palette.accent : Palette.text)
                    gestureAssignment(3)
                }
                .frame(width: 272)
            }.frame(width: 300).padding(.top, 70)
            deviceBody
            VStack(alignment: .leading, spacing: 0) {
                rotationControl(4, title: "右旋", symbol: "arrow.clockwise")
                    .frame(height: 96)
                Spacer().frame(height: 2)
                VStack(spacing: 4) {
                    ForEach(0..<3) { index in
                        HStack(spacing: 10) {
                            Rectangle().fill(model.selected == index ? Palette.accent : Palette.raised)
                                .frame(width: 18, height: 1)
                            gestureAssignment(index)
                        }.frame(height: 77)
                    }
                }
            }.frame(width: 300).padding(.top, 70)
        }.frame(maxWidth: .infinity)
    }
    private func gestureAssignment(_ index: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(AssignmentGesture.allCases) { gesture in
                let selected = model.selected == index && model.gesture == gesture
                let unset = model.entries(index, gesture: gesture) == nil
                let title = unset ? model.l("未设置") : model.label(index, gesture: gesture)
                Button {
                    model.selected = index
                    model.gesture = gesture
                } label: {
                    VStack(spacing: 4) {
                        Text(model.gestureTitle(gesture)).font(.system(size: 13, weight: .medium))
                            .foregroundStyle(selected ? Palette.accent : Color.secondary)
                        Text(title)
                            .font(.system(size: 14, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Palette.accent : unset ? Color.secondary : Palette.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 4).padding(.horizontal, 3)
                    .background(selected ? Palette.raised : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(!model.canEdit)
                .help(gestureAssignmentHelp(index, gesture: gesture, title: title))
                .accessibilityLabel(model.controlName(index) + " · " + model.gestureTitle(gesture))
                .accessibilityValue(title + (selected ? model.l("，已选中") : ""))
            }
        }
        .padding(5).frame(height: 69)
        .background(Palette.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .stroke(model.selected == index ? Palette.accent.opacity(0.5) : .clear, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if model.isDirty(index) {
                Circle().fill(Palette.accent).frame(width: 5, height: 5).padding(4)
            }
        }
    }
    private func gestureAssignmentHelp(_ index: Int, gesture: AssignmentGesture, title: String) -> String {
        var help = model.lf("%@ · %@：%@", model.controlName(index), model.gestureTitle(gesture), title)
        if gesture == .longPress, model.entries(index, gesture: gesture) != nil {
            help += " · " + model.l(model.longPressBehavior(index: index) == .hold ? "保持按住" : "短按一次")
        }
        return help
    }
    private func rotationControl(_ index: Int, title: String, symbol: String) -> some View {
        Button { model.selected = index } label: {
            HStack(spacing: 12) {
                if index == 4 { rotationIcon(symbol, selected: model.selected == index) }
                VStack(alignment: index == 5 ? .trailing : .leading, spacing: 6) {
                    Text(model.l(title)).font(.system(size: 15, weight: .semibold))
                    Text(model.label(index)).font(.system(size: 14)).lineLimit(1)
                }
                if index == 5 { rotationIcon(symbol, selected: model.selected == index) }
            }
            .foregroundStyle(model.selected == index ? Palette.accent : Palette.text)
            .padding(.vertical, 10).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!model.canEdit)
            .help(model.controlName(index))
            .accessibilityLabel(model.l("旋钮" + title)).accessibilityValue(assignmentAccessibility(index))
    }
    private func rotationIcon(_ symbol: String, selected: Bool) -> some View {
        Image(systemName: symbol).font(.system(size: 24, weight: .medium))
            .foregroundStyle(selected ? Palette.background : Palette.accent)
            .frame(width: 48, height: 48)
            .background(selected ? Palette.accent : Palette.surface, in: Circle())
    }
    private var gestureEditor: some View {
        HStack(spacing: 12) {
            Text(model.controlName(model.selected)).font(.system(size: 16, weight: .semibold))
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(.secondary)
            Text(model.selected < 4 ? model.gestureTitle(model.gesture) : model.l("转动"))
                .font(.system(size: 16)).foregroundStyle(Palette.accent)
            Spacer()
            if model.gesture == .longPress && model.selected < 4 && combinationTarget == nil {
                Picker(model.l("触发方式"), selection: Binding(
                    get: { model.longPressBehavior() },
                    set: { _ = model.setLongPressBehavior($0) }
                )) {
                    Text(model.l("保持按住")).tag(LongPressBehavior.hold)
                    Text(model.l("短按一次")).tag(LongPressBehavior.tap)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 208)
                .disabled(!model.canEdit)
                .help(model.l(model.longPressBehavior() == .hold
                    ? "达到长按时间后保持按住，松开时释放。"
                    : "达到长按时间后短按一次，继续按住不会重复。"))
            }
            if combinationTarget != nil { combinationEditor }
            else {
                Button(model.l("录制组合键")) {
                    combinationTarget = CombinationTarget(index: model.selected, gesture: model.gesture)
                    combination = []
                    recorder.start(window: NSApp.keyWindow)
                }.disabled(!model.canEdit)
                    .help(model.l("系统快捷键可能被 macOS 优先处理。"))
            }
            if combinationTarget == nil && model.gesture != .press && model.selected < 4 {
                Button(model.l("清除动作")) { model.disableGesture() }
                    .disabled(!model.canEdit || model.entries(model.selected, gesture: model.gesture) == nil)
            }
            Button { showsGestureHelp.toggle() } label: {
                Image(systemName: "questionmark.circle").font(.system(size: 18))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityLabel(model.l("手势说明"))
            .popover(isPresented: $showsGestureHelp, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(model.l("按键如何响应")).font(.headline)
                    Text(model.l("只设置单击时，按下立即生效，松开释放。"))
                    Text(model.l("设置双击或长按后，单击会等待手势判定。长按达到设定时间后，可保持按住或短按一次。"))
                    Text(model.l("未设置的手势不参与判定。“未分配”则保留手势，但不执行动作。"))
                    if let hint = model.fnBehaviorHint { Text(hint).foregroundStyle(Palette.accent) }
                }.font(.body).padding(24).frame(width: 360)
            }
        }
    }
    private var recordingPreview: String {
        if let error = recorder.error { return model.displayError(error) }
        let preview = recorder.isRecording ? recorder.candidate : combination
        return preview?.isEmpty == false ? model.actionLabel(entries: preview) : model.l("按下组合键…")
    }
    private var combinationEditor: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Circle().fill(recorder.isRecording ? Palette.accent : Color.secondary).frame(width: 6, height: 6)
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(recordingPreview).font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Palette.accent).fixedSize()
                }
                .frame(width: 224, height: 22)
                .help(recordingPreview + "\n" + model.l("按住需要组合的按键，全部松开后完成。"))
                Button {
                    combination = []
                    recorder.start(window: NSApp.keyWindow)
                } label: { Image(systemName: "arrow.clockwise").font(.system(size: 14)) }
                .buttonStyle(.plain).disabled(recorder.isRecording)
                .help(model.l("重新录制")).accessibilityLabel(model.l("重新录制"))
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.accent.opacity(recorder.isRecording ? 0.7 : 0.2), lineWidth: 1))
            Button { closeCombinationEditor() } label: { Image(systemName: "xmark").font(.system(size: 14)) }
                .buttonStyle(.plain).help(model.l("取消")).accessibilityLabel(model.l("取消"))
            Button(model.l("使用组合键")) {
                guard let target = combinationTarget else { return }
                if model.assign(combination, index: target.index, gesture: target.gesture) {
                    closeCombinationEditor()
                }
            }
            .buttonStyle(.borderedProminent).foregroundStyle(Palette.background)
            .disabled(recorder.isRecording || combination.isEmpty || recorder.error != nil)
        }
        .onDisappear { recorder.stop() }
    }
    private func closeCombinationEditor() {
        recorder.reset()
        combinationTarget = nil
        combination = []
    }
    private func assignmentAccessibility(_ index: Int) -> String {
        if index >= 4 { return model.label(index) }
        return AssignmentGesture.allCases.map { gesture in
            model.lf("%@：%@", model.gestureTitle(gesture), model.entries(index, gesture: gesture) == nil ? model.l("未设置") : model.label(index, gesture: gesture))
        }.joined(separator: model.l("，"))
    }
    private var deviceBody: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 13).fill(LinearGradient(colors: [Color(white: 0.83), Color(white: 0.6), Color(white: 0.74)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(.black.opacity(0.8), lineWidth: 2))
                .shadow(color: .black.opacity(0.5), radius: 14, x: 5, y: 10)
            VStack(spacing: 0) {
                Text("Ulanzi").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.8)).padding(.top, 12)
                HStack(spacing: 5) {
                    ForEach(0..<6) { index in
                        Capsule().fill(Color(white: 0.22)).frame(width: 5, height: index == 0 || index == 5 ? 18 : 24)
                            .overlay(Capsule().stroke(.white.opacity(0.35), lineWidth: 1))
                    }
                }.frame(height: 34)
                Button { model.selected = 3 } label: {
                    ZStack {
                        Circle().fill(LinearGradient(colors: [Color(white: 0.88), Color(white: 0.65)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .overlay(Circle().stroke(model.selected == 3 ? Palette.accent : Color.black.opacity(0.6), lineWidth: model.selected == 3 ? 3 : 1))
                            .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 3)
                        ForEach([30.0, 150.0, 270.0], id: \.self) { angle in
                            Rectangle().fill(Color(white: 0.3)).frame(width: 1.5, height: 7).offset(y: -39).rotationEffect(.degrees(angle))
                        }
                        Image(systemName: "dial.medium")
                            .font(.system(size: 28, weight: .light)).foregroundStyle(Color(white: 0.3))
                    }.frame(width: 96, height: 96)
                }.buttonStyle(.plain).accessibilityLabel(model.l("旋钮按下"))
                    .accessibilityValue(assignmentAccessibility(3))
                    .help(model.controlName(3) + " · " + model.label(3))
                VStack(spacing: 12) {
                    ForEach(0..<3) { index in
                        Button { model.selected = index } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.84))
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(model.selected == index ? Palette.accent : Color.black.opacity(0.25), lineWidth: model.selected == index ? 3 : 1))
                                Circle().fill(LinearGradient(colors: [Color(white: 0.91), Color(white: 0.8)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .padding(7).shadow(color: .black.opacity(0.2), radius: 2, y: 2)
                                Image(systemName: ["mic", "checkmark.circle", "xmark.circle"][index]).font(.system(size: 22, weight: .medium)).foregroundStyle(Color(white: 0.25))
                            }.frame(width: 70, height: 69)
                        }.buttonStyle(.plain).accessibilityLabel(model.controlName(index))
                            .accessibilityValue(assignmentAccessibility(index))
                    }
                }.padding(.top, 14)
            }
        }.frame(width: 108, height: 416)
    }
    private var deviceSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("Vibe Key").font(.title2.bold())
                Spacer()
                Button(model.l("刷新状态")) { model.refresh() }
                    .disabled(!model.device.connected || model.device.busy)
                Button(model.l(model.device.connected ? "断开连接" : "连接设备")) {
                    if model.device.connected { model.disconnect() } else { model.connect() }
                }.disabled(model.device.busy)
            }
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Label(model.status, systemImage: "keyboard").font(.headline)
                    Label(model.batteryText, systemImage: model.batterySymbol).font(.body)
                        .help(model.batteryHelp)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 12) {
                    Label(model.l(model.device.heartbeatEnabled ? "后台运行中" : "后台已暂停"),
                          systemImage: "waveform.path.ecg").font(.headline)
                    Text(model.l("关闭窗口后继续运行，退出应用时停止。"))
                        .font(.body).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(24).background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
            DisclosureGroup(model.l("连接帮助")) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(model.l("插入 USB 接收器后会自动连接。设备休眠时，短按电源键唤醒。"))
                    Text(model.l("如果其他工具占用设备，请先退出 Ulanzi Studio 或抓包程序。"))
                    if !model.demo {
                        HStack(spacing: 12) {
                            Button(model.permissionButtonTitle) { model.requestPermissions() }
                                .disabled(model.device.busy)
                            Button(model.l("显示 App 位置")) { model.revealApplication() }
                        }
                    }
                }.font(.body).padding(.top, 16)
            }.font(.body)
        }
    }
    private var profiles: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(model.l("键位配置")).font(.title2.bold())
            HStack {
                TextField(model.l("配置名称"), text: $profileName).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                Button(model.l("保存当前配置")) { model.saveProfile(name: profileName); profileName = "" }
                    .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.canEdit)
                Spacer()
                Button(model.l("导入…")) { model.importProfile() }
                Button(model.l("导出…")) { model.exportProfile() }.disabled(!model.canEdit)
            }
            ForEach(model.profiles) { profile in
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(profile.name).font(.headline)
                        Text(model.profileSummary(profile)).font(.body).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.l("载入")) { model.loadProfile(profile) }
                    Button { model.removeProfile(profile.id) } label: { Image(systemName: "trash") }.help(model.l("删除配置"))
                }.padding(18).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
            }
            if model.profiles.isEmpty { Text(model.l("还没有保存的配置。")).foregroundStyle(.secondary).padding(.vertical, 35) }
            HStack {
                Button(model.l("载入默认键位")) { model.loadDefaults() }
                Button(model.l("从设备键位导入")) { model.importDeviceBindings() }
                    .disabled(!model.online || model.device.busy || model.device.keys.count != 6)
            }
        }
    }
    private var footer: some View {
        VStack(spacing: 0) {
            if let error = model.device.error {
                HStack { Image(systemName: "exclamationmark.circle"); Text(model.displayError(error)).font(.body); Spacer() }
                    .foregroundStyle(.orange).padding(.horizontal, 28).padding(.vertical, 10)
            }
            if let error = model.device.fn.error {
                HStack { Image(systemName: "exclamationmark.circle"); Text(model.displayError(error)).font(.body); Spacer() }
                    .foregroundStyle(.orange).padding(.horizontal, 28).padding(.vertical, 10)
            }
            Divider()
            HStack(spacing: 15) {
                if model.applying {
                    ProgressView().controlSize(.small)
                    Text(model.l("正在保存…")).font(.body)
                } else if model.hasDraft {
                    Text(model.l("有未保存的更改")).font(.body).foregroundStyle(Palette.accent)
                }
                Spacer()
                Button(model.l("撤销更改")) { model.discard() }.disabled(model.draft == nil || model.applying)
                Button(model.l("保存到本机")) { model.apply() }.buttonStyle(.borderedProminent)
                    .foregroundStyle(Palette.background).disabled(!model.hasDraft || !model.canEdit || model.device.busy || model.applying)
            }.controlSize(.large).padding(.horizontal, 28).padding(.vertical, 14)
        }
    }
}
