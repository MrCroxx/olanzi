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
    @State private var page = 0
    @State private var category = "常用"
    @State private var search = ""
    @State private var profileName = ""
    var body: some View {
        VStack(spacing: 0) {
            header
            if let notice = model.notice {
                HStack {
                    Image(systemName: "info.circle").foregroundStyle(Palette.accent)
                    Text(notice).font(.callout)
                    Spacer()
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("关闭提示")
                }.padding(.horizontal, 28).padding(.vertical, 12).background(Palette.surface)
            }
            Divider().overlay(Color.white.opacity(0.06))
            ScrollView {
                VStack(spacing: 24) {
                    if page == 0 { keymap }
                    else if page == 1 { deviceSettings }
                    else { profiles }
                }.padding(28).frame(maxWidth: .infinity)
            }
            footer
        }
        .background(Palette.background).foregroundStyle(Palette.text)
        .tint(Palette.accent).preferredColorScheme(.dark)
        .frame(minWidth: 860, minHeight: 690)

    }
    private var header: some View {
        HStack(spacing: 24) {
            HStack(spacing: 9) {
                Image(systemName: "slider.horizontal.3").font(.title2).foregroundStyle(Palette.accent)
                Text("OLANZI").font(.system(size: 17, weight: .bold, design: .rounded)).tracking(3)
            }
            Spacer()
            ForEach(Array([(0, "keyboard", "键位"), (1, "slider.horizontal.3", "设备"), (2, "square.stack", "配置")].enumerated()), id: \.offset) { _, item in
                Button { page = item.0 } label: {
                    VStack(spacing: 5) { Image(systemName: item.1).font(.system(size: 20)); Text(item.2).font(.caption) }
                        .foregroundStyle(page == item.0 ? Palette.accent : Color.gray)
                        .frame(width: 54, height: 46)
                }.buttonStyle(.plain).accessibilityLabel(item.2)
            }
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(model.online ? Color.green.opacity(0.8) : Color.gray).frame(width: 6, height: 6)
                Text(model.status).font(.caption)
            }.frame(minWidth: 150, alignment: .trailing)
        }.padding(.horizontal, 28).padding(.vertical, 13)
    }
    private var keymap: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 24) {
                hardware.frame(maxWidth: .infinity)
                controlList.padding(.top, 42)
            }
                .overlay(alignment: .topTrailing) {
                    Button { model.refresh() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 15))
                    }
                    .buttonStyle(.plain).padding(10)
                    .help("读取硬件状态，不覆盖本机配置或草稿").accessibilityLabel("重新读取硬件状态")
                    .disabled(!model.device.connected || model.device.busy)
                }
            Divider()
            gestureEditor
            HStack {
                HStack(spacing: 4) {
                    ForEach(KeyCatalog.categories, id: \.self) { name in
                        Button(name) { category = name; search = "" }
                            .buttonStyle(.plain).font(.system(size: 11, weight: category == name ? .semibold : .regular))
                            .padding(.horizontal, 9).padding(.vertical, 8)
                            .background(category == name ? Palette.raised : .clear, in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(category == name ? Palette.accent : Palette.text)
                    }
                }
                Spacer(minLength: 10)
                TextField("搜索键码", text: $search).textFieldStyle(.roundedBorder).frame(width: 135)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 73, maximum: 110), spacing: 8)], spacing: 8) {
                ForEach(KeyCatalog.options.filter { search.isEmpty ? $0.category == category : $0.label.localizedCaseInsensitiveContains(search) || String(format: "0x%02X", $0.code).localizedCaseInsensitiveContains(search) }) { key in
                    Button { model.assign(key.code) } label: {
                        Text(key.label).font(.system(size: 12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.65)
                            .frame(maxWidth: .infinity).frame(height: 43)
                            .foregroundStyle(model.code(model.selected, gesture: model.gesture) == key.code ? Palette.background : Palette.text)
                            .background(model.code(model.selected, gesture: model.gesture) == key.code ? Palette.accent : Palette.surface, in: RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain).disabled(!model.canEdit || !model.isSupported(key.code))
                        .opacity(model.isSupported(key.code) ? 1 : 0.35)
                        .help(model.isSupported(key.code) ? "分配给当前动作" : "当前 macOS 不支持此键码")
                        .accessibilityLabel("分配 \(key.label)")
                }
            }
        }
    }
    private var controlList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("控件").font(.caption).foregroundStyle(.secondary).padding(.bottom, 7)
            ForEach(0..<6) { index in
                Button { model.selected = index } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(KeyCatalog.controlNames[index]).font(.system(size: 11))
                            Text(model.label(index)).font(.system(size: 11, weight: .medium))
                            if let extended = model.extendedLabel(index) {
                                Text(extended).font(.system(size: 9)).foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        if model.isDirty(index) {
                            Circle().fill(Palette.accent).frame(width: 5, height: 5)
                        }
                    }.padding(10).frame(width: 160)
                        .background(model.selected == index ? Palette.raised : .clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(model.selected == index ? Palette.accent : Palette.text)
                }.buttonStyle(.plain)
                    .accessibilityLabel("控件列表 · \(KeyCatalog.controlNames[index])")
                    .accessibilityValue(assignmentAccessibility(index))
            }
        }
    }
    private var hardware: some View {
        HStack(alignment: .top, spacing: 18) {
            rotationSelector(index: 5, symbol: "arrow.counterclockwise")
                .padding(.top, 93)
            deviceBody
            VStack(spacing: 15) {
                rotationSelector(index: 4, symbol: "arrow.clockwise")
                VStack(spacing: 4) {
                    ForEach(0..<3) { index in
                        Button { model.selected = index } label: {
                            HStack(spacing: 10) {
                                Rectangle().fill(model.selected == index ? Palette.accent : Palette.raised)
                                    .frame(width: 20, height: 1)
                                assignmentLabel(index)
                                    .padding(.horizontal, 10).padding(.vertical, 8)
                                    .background(model.selected == index ? Palette.surface : .clear,
                                                in: RoundedRectangle(cornerRadius: 5))
                                Spacer(minLength: 0)
                            }.frame(width: 140, height: 69).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityLabel(KeyCatalog.controlNames[index])
                            .accessibilityValue(assignmentAccessibility(index))
                    }
                }
            }.padding(.top, 93)
        }
    }
    private var gestureEditor: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 16) {
                Text(KeyCatalog.controlNames[model.selected]).font(.callout.weight(.semibold))
                if model.selected < 4 {
                    Picker("动作", selection: $model.gesture) {
                        ForEach(AssignmentGesture.allCases) { gesture in Text(gesture.rawValue).tag(gesture) }
                    }.pickerStyle(.segmented).frame(width: 235).disabled(!model.canEdit)
                } else {
                    Text("转动").font(.callout).foregroundStyle(Palette.accent)
                }
                Text(model.label(model.selected, gesture: model.gesture)).font(.callout)
                    .foregroundStyle(Palette.accent).lineLimit(1)
                Spacer()
                if model.gesture != .press && model.selected < 4 {
                    Button("关闭\(model.gesture.rawValue)") { model.disableGesture() }
                        .disabled(!model.canEdit || model.entries(model.selected, gesture: model.gesture) == nil)
                }
            }
            if !model.canEdit {
                Text("首次连接设备后初始化本机配置，之后可离线编辑。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.selected < 4 {
                Text(model.gesture == .press
                     ? "仅配置双击或长按时，单击会等待手势判定；未配置时按下立即响应。"
                     : "选择键码启用\(model.gesture.rawValue)；“关闭”不识别该手势，“未分配”识别手势但不执行动作。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func assignmentLabel(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(model.label(index)).font(.system(size: 13, weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.7)
                if model.isDirty(index) {
                    Circle().fill(Palette.accent).frame(width: 4, height: 4)
                }
            }
            if let extended = model.extendedLabel(index) {
                Text(extended).font(.system(size: 9)).lineLimit(2)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(model.selected == index ? Palette.accent : Palette.text)
        .help(assignmentAccessibility(index))
    }
    private func assignmentAccessibility(_ index: Int) -> String {
        "\(model.label(index))，\(model.selected == index ? "已选中" : "未选中")\(model.isDirty(index) ? "，待保存" : "")\(model.extendedLabel(index).map { "，\($0)" } ?? "")"
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
                        VStack(spacing: 4) {
                            Text(model.label(3)).font(.system(size: 12, weight: .semibold))
                                .lineLimit(1).minimumScaleFactor(0.65)
                            if let extended = model.extendedLabel(3) {
                                Text(extended).font(.system(size: 8)).lineLimit(2).minimumScaleFactor(0.65)
                            }
                        }.foregroundStyle(Color(white: 0.2)).frame(width: 64)
                        if model.isDirty(3) {
                            Circle().fill(Color(white: 0.2)).frame(width: 4, height: 4)
                                .offset(y: model.extendedLabel(3) == nil ? 16 : 32)
                        }
                    }.frame(width: 96, height: 96)
                }.buttonStyle(.plain).accessibilityLabel("旋钮按下")
                    .accessibilityValue(assignmentAccessibility(3))
                    .help("旋钮按下 · \(model.label(3))")
                VStack(spacing: 4) {
                    ForEach(0..<3) { index in
                        Button { model.selected = index } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.84))
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(model.selected == index ? Palette.accent : Color.black.opacity(0.25), lineWidth: model.selected == index ? 3 : 1))
                                Circle().fill(LinearGradient(colors: [Color(white: 0.91), Color(white: 0.8)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .padding(7).shadow(color: .black.opacity(0.2), radius: 2, y: 2)
                                Image(systemName: ["mic", "checkmark.circle", "xmark.circle"][index]).font(.system(size: 22, weight: .medium)).foregroundStyle(Color(white: 0.25))
                            }.frame(width: 70, height: 69)
                        }.buttonStyle(.plain).accessibilityLabel(KeyCatalog.controlNames[index])
                            .accessibilityValue(assignmentAccessibility(index))
                    }
                }.padding(.top, 10)
            }
        }.frame(width: 108, height: 400)
    }
    private func rotationSelector(index: Int, symbol: String) -> some View {
        Button { model.selected = index } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 20, weight: .medium))
                    .foregroundStyle(model.selected == index ? Palette.background : Palette.text)
                    .frame(width: 36, height: 36)
                    .background(model.selected == index ? Palette.accent : Palette.surface, in: Circle())
                assignmentLabel(index).frame(height: 18)
            }.frame(width: 140, height: 60).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(KeyCatalog.controlNames[index])
            .accessibilityValue(assignmentAccessibility(index))
            .help(KeyCatalog.controlNames[index])
    }
    private var deviceSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("设备与后台").font(.title2.bold())
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 15) {
                    Label("Vibe Key · AU05", systemImage: "keyboard").font(.headline)
                    Text(model.status)
                    Text("3 个按键 · 1 个旋钮 · 6 个动作").font(.caption).foregroundStyle(.secondary)
                    Button(model.device.connected ? "断开设备" : "连接设备") {
                        if model.device.connected { model.disconnect() } else { model.connect() }
                    }.disabled(model.device.busy)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 15) {
                    Label("后台保活", systemImage: "waveform.path.ecg").font(.headline)
                    Text(model.device.heartbeatEnabled ? "运行中 · 每秒一次" : "未运行").foregroundStyle(Palette.accent)
                    if let date = model.device.lastHeartbeat { Text("最近发送 \(date.formatted(date: .omitted, time: .standard))").font(.caption) }
                    Text("采用 Studio 心跳，独立查询本体状态。关闭窗口继续运行，从菜单栏退出时停止。")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(22).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 10) {
                Text("连接帮助").font(.headline)
                Text("插入 USB 接收器后会自动连接。设备休眠时短按电源键唤醒；不要长按。")
                Text("权限需要授予 Olanzi 应用。授权后可退出再打开；如果其他工具占用设备，请先退出 Studio 或抓包程序。")
                if !model.demo {
                    HStack {
                        Button(model.permissionButtonTitle) { model.requestPermissions() }
                            .disabled(model.device.busy)
                        Button("显示 App 位置") { model.revealApplication() }
                    }
                    Text("设置列表没有 Olanzi 时，点击 + 并添加当前应用。")
                }
                Text("手动断开会暂停自动连接，点击“连接设备”恢复。当前版本不会添加开机启动项。")
            }.font(.callout).foregroundStyle(.secondary)
        }
    }
    private var profiles: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("键位配置").font(.title2.bold())
            HStack {
                TextField("配置名称", text: $profileName).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                Button("保存当前配置") { model.saveProfile(name: profileName); profileName = "" }
                    .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.canEdit)
                Spacer()
                Button("导入…") { model.importProfile() }.disabled(!model.canEdit)
                Button("导出…") { model.exportProfile() }.disabled(!model.canEdit)
            }
            ForEach(model.profiles) { profile in
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(profile.name).font(.headline)
                        Text(model.profileSummary(profile)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("载入") { model.loadProfile(profile) }.disabled(!model.canEdit)
                    Button { model.removeProfile(profile.id) } label: { Image(systemName: "trash") }.help("删除配置")
                }.padding(18).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
            }
            if model.profiles.isEmpty { Text("还没有保存的配置。").foregroundStyle(.secondary).padding(.vertical, 35) }
            Button("载入出厂键位") { model.loadDefaults() }.disabled(!model.canEdit)
        }
    }
    private var footer: some View {
        VStack(spacing: 0) {
            if let error = model.device.error {
                HStack { Image(systemName: "exclamationmark.circle"); Text(error).font(.caption); Spacer() }
                    .foregroundStyle(.orange).padding(.horizontal, 28).padding(.vertical, 10)
            }
            if let error = model.device.fn.error {
                HStack {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).font(.caption)
                    Spacer()
                    if model.device.fn.enabled && !model.demo &&
                        (model.device.fn.inputPermission != true || model.device.fn.accessibilityPermission != true) {
                        Button(model.permissionButtonTitle) { model.requestPermissions() }
                            .font(.caption).disabled(model.device.busy)
                    }
                }.foregroundStyle(.orange).padding(.horizontal, 28).padding(.vertical, 10)
            }
            Divider()
            HStack(spacing: 15) {
                Circle().fill(model.hasDraft ? Palette.accent : Color.gray).frame(width: 6, height: 6)
                Text(model.applying ? "正在保存本机配置…" : model.hasDraft ? "本机配置待保存" : model.canEdit ? "本机配置已保存" : "等待设备初始化")
                    .font(.callout)
                Spacer()
                Button("撤销更改") { model.discard() }.disabled(!model.hasDraft || model.applying)
                Button("保存到本机") { model.apply() }.buttonStyle(.borderedProminent)
                    .foregroundStyle(Palette.background).disabled(!model.hasDraft || !model.canEdit || model.device.busy || model.applying)
            }.padding(.horizontal, 28).padding(.vertical, 17)
        }
    }
}
