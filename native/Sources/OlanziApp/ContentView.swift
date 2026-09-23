import AppKit
import SwiftUI
import OlanziCore

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var profileName = ""
    @State private var showsGestureHelp = false
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
        .buttonStyle(OlanziButtonStyle())
    }
    private var languagePicker: some View {
        Menu {
            Button(model.l("跟随系统")) { model.language = .system }
            Button("简体中文") { model.language = .simplifiedChinese }
            Button("English") { model.language = .english }
        } label: {
            HStack {
                Text(model.language == .system ? model.l("跟随系统") : model.language == .english ? "English" : "简体中文")
                Spacer()
                Image(systemName: "chevron.down").font(.caption)
            }.font(.system(size: 13, weight: .medium))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .padding(.horizontal, 12).frame(height: 34)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel(model.l("界面语言"))
    }
    private var appSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(model.l("设置")).font(.title2.bold())
                Spacer()
                Label(model.l("界面语言"), systemImage: "globe").font(.body)
                languagePicker.labelsHidden().frame(width: 200)
            }
            deviceSettings
            profiles
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
                .buttonStyle(OlanziButtonStyle(.primary)).controlSize(.large)
                .foregroundStyle(Palette.background)
                .disabled(model.isCheckingPermissions)
                if let error = model.permissionSetupError {
                    Text(error).font(.callout).foregroundStyle(Palette.accent)
                        .multilineTextAlignment(.center)
                }
                Text(model.l("在系统设置中开启 Olanzi，授权后自动进入。"))
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
            Divider().overlay(Color.white.opacity(0.06))
            GeometryReader { viewport in
                ScrollView {
                    VStack(spacing: 24) {
                        if model.page == 0 {
                            keymap(availableHeight: viewport.size.height - 28,
                                   availableWidth: viewport.size.width - 48)
                        } else { appSettings }
                    }
                    .padding(.horizontal, 24).padding(.vertical, model.page == 0 ? 14 : 20)
                    .frame(maxWidth: .infinity)
                }
            }
            footer
        }
        .overlay(alignment: .top) {
            if let notice = model.notice {
                HStack(spacing: 9) {
                    Image(systemName: model.noticeSymbol)
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.accent)
                    Text(notice).font(.system(size: 13, weight: .medium))
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    Button { withAnimation(.easeOut(duration: 0.18)) { model.notice = nil } } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary).frame(width: 20, height: 20)
                            .contentShape(Circle())
                    }.buttonStyle(.plain).accessibilityLabel(model.l("关闭提示"))
                }
                .padding(.leading, 17).padding(.trailing, 12).padding(.vertical, 12)
                // Capsule 的半径始终为高度的一半，左右是真正的半圆。
                .background(Palette.raised, in: Capsule(style: .circular))
                .overlay(Capsule(style: .circular).stroke(.white.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.24), radius: 12, x: 0, y: 5)
                .frame(maxWidth: 560).padding(.horizontal, 24).padding(.top, 76)
                .transition(.opacity.combined(with: .offset(y: -6)))
                .accessibilityElement(children: .contain)
            }
        }
        .task(id: model.noticeID) {
            guard let id = model.noticeID, let message = model.notice else { return }
            // 相同文案再次出现也从头计时；旧任务不能关闭后来出现的新提示。
            do { try await Task.sleep(for: .seconds(message.count > 45 ? 7 : 3.5)) }
            catch { return }
            guard model.noticeID == id else { return }
            withAnimation(.easeOut(duration: 0.18)) { model.notice = nil }
        }
    }
    private var header: some View {
        HStack(spacing: 24) {
            HStack(spacing: 9) {
                Image(systemName: "slider.horizontal.3").font(.title2).foregroundStyle(Palette.accent)
                Text("OLANZI").font(.system(size: 17, weight: .bold, design: .rounded)).tracking(3)
            }
            Spacer()
            ForEach(Array([(0, "keyboard", "键位"), (1, "gearshape", "设置")].enumerated()), id: \.offset) { _, item in
                Button { model.page = item.0 } label: {
                    Label(model.l(item.2), systemImage: item.1).font(.system(size: 14, weight: .medium))
                        .foregroundStyle(model.page == item.0 ? Palette.accent : Color.gray)
                        .frame(width: 82, height: 42)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(model.l(item.2))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 7) {
                    Circle().fill(model.device.heartbeatPausedForInactivity ? Color.orange : model.online ? Color.green.opacity(0.8) : Color.gray).frame(width: 6, height: 6)
                    Text(model.device.heartbeatPausedForInactivity ? model.l("保活已暂停") : model.online ? model.l("已连接") : model.status).font(.system(size: 13)).help(model.status)
                }
                Label(model.batteryText, systemImage: model.batterySymbol)
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundStyle(model.batteryLow ? Color.orange : Color.secondary)
                    .help(model.batteryHelp)
                    .accessibilityLabel(model.lf("电池电量：%@", model.batteryText))
            }.frame(minWidth: 150, alignment: .trailing)
        }.padding(.horizontal, 28).padding(.vertical, 13)
    }
    private func keymap(availableHeight: CGFloat, availableWidth: CGFloat) -> some View {
        // 按窗口剩余空间放大设备区，并让按键区填满余下高度。
        let scale = min(1.18, max(1, (availableHeight - 562) / 600 + 1), availableWidth / 702)
        let hardwareHeight = 218 * scale
        return VStack(alignment: .leading, spacing: 10) {
            layerEditor
            hardware.scaleEffect(scale).frame(height: hardwareHeight)
            Divider()
            gestureEditor
            ActionPalette(model: model, minimumHeight: max(280, availableHeight - hardwareHeight - 115))
        }
    }
    private var layerEditor: some View {
        HStack(spacing: 12) {
            Text("Layer").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(model.layerIDs, id: \.self) { id in
                    Button { model.selectedLayer = id } label: {
                        Text(String(id))
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .frame(width: 36, height: 30)
                            .foregroundStyle(model.selectedLayer == id ? Palette.accent : Palette.text)
                            .background(model.selectedLayer == id ? Palette.raised : .clear,
                                        in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .disabled(!model.canEdit)
                        .accessibilityLabel("Layer \(id)")
                        .accessibilityAddTraits(model.selectedLayer == id ? .isSelected : [])
                }
            }.padding(4).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
                .help(model.l("编辑层仅用于预览；保存后按住 MO 键切层。"))
            Spacer()
        }.buttonStyle(OlanziButtonStyle())
    }
    private var hardware: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .trailing, spacing: 10) {
                rotationControl(5, title: "左旋", symbol: "arrow.counterclockwise")
                    .frame(height: 40)
                VStack(alignment: .leading, spacing: 10) {
                    Label(model.l("旋钮按下"), systemImage: "hand.tap")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(model.selected == 3 ? Palette.accent : Palette.text)
                    gestureAssignment(3)
                        .anchorPreference(key: KnobAnchorKey.self, value: .bounds) { [13: $0] }
                }
                .frame(width: 272)
            }.frame(width: 300, alignment: .leading)
            deviceBody.scaleEffect(0.5).frame(width: 58, height: 210)
                .transformAnchorPreference(key: KnobAnchorKey.self, value: .bounds) { anchors, anchor in anchors[30] = anchor }
            VStack(alignment: .leading, spacing: 0) {
                rotationControl(4, title: "右旋", symbol: "arrow.clockwise")
                    .padding(.leading, 28).frame(height: 40)
                Spacer().frame(height: 2)
                VStack(spacing: 4) {
                    ForEach(0..<3) { index in
                        HStack(spacing: 0) {
                            Color.clear.frame(width: 28)
                            gestureAssignment(index)
                                .anchorPreference(key: KnobAnchorKey.self, value: .bounds) { [20 + index: $0] }
                        }.frame(height: 56)
                    }
                }
            }.frame(width: 300, alignment: .leading)
        }.frame(maxWidth: .infinity)
        .overlayPreferenceValue(KnobAnchorKey.self) { anchors in
            GeometryReader { geometry in
                if let knobAnchor = anchors[3], let deviceAnchor = anchors[30] {
                    let knob = geometry[knobAnchor]
                    let device = geometry[deviceAnchor]
                    ForEach([5, 4, 13, 20, 21, 22], id: \.self) { id in
                        if let sourceAnchor = anchors[id] {
                            let source = geometry[sourceAnchor]
                            let right = id == 4 || id >= 20
                            let control = id >= 20 ? id - 20 : id == 13 ? 3 : id
                            // 先取通往旋钮中心的直线，再按统一留白基准截取可见线段。
                            let sourceX = right ? source.minX : source.maxX
                            let startX = sourceX + (right ? -10 : 10)
                            let endX = right ? device.maxX + 22 : device.minX - 22
                            let slope = id >= 20 ? 0 : (knob.midY - source.midY) / (knob.midX - sourceX)
                            let start = CGPoint(x: startX, y: source.midY + (startX - sourceX) * slope)
                            let end = CGPoint(x: endX, y: source.midY + (endX - sourceX) * slope)
                            Path { path in
                                path.move(to: start)
                                path.addLine(to: end)
                            }
                            .stroke(model.selected == control ? Palette.accent : Palette.text.opacity(0.35),
                                    style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                        }
                    }
                }
            }.allowsHitTesting(false).accessibilityHidden(true)
        }
    }
    private func gestureAssignment(_ index: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(AssignmentGesture.allCases) { gesture in
                let selected = model.selected == index && model.gesture == gesture
                let unset = model.action(index, gesture: gesture) == nil
                let title = unset ? model.l("未设置") : assignmentTitle(index, gesture: gesture)
                Button {
                    model.selected = index
                    model.gesture = gesture
                } label: {
                    VStack(spacing: 2) {
                        Text(model.gestureTitle(gesture)).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(selected ? Palette.accent : Color.secondary)
                        Group {
                            if model.isInherited(index, gesture: gesture) {
                                Image(systemName: "arrowtriangle.down")
                                    .font(.system(size: 12, weight: .medium))
                            } else if model.isEmptyAction(index, gesture: gesture) {
                                Image(systemName: "xmark.square").font(.system(size: 14, weight: .medium))
                            } else { Text(title) }
                        }
                            .font(.system(size: 13, weight: selected ? .semibold : .regular))
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
                .buttonStyle(.plain).disabled(!model.canEdit || (gesture == .doublePress && model.isLayerSwitch(index)))
                .help(gestureAssignmentHelp(index, gesture: gesture, title: model.label(index, gesture: gesture)))
                .accessibilityLabel(model.controlName(index) + " · " + model.gestureTitle(gesture))
                .accessibilityValue((model.isInherited(index, gesture: gesture) ? model.l("继承底层") : model.label(index, gesture: gesture)) + (selected ? model.l("，已选中") : ""))
            }
        }
        .padding(4).frame(height: 54)
        .background(Palette.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .stroke(model.selected == index ? Palette.accent.opacity(0.5) : .clear, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if model.isDirty(index) {
                Circle().fill(Palette.accent).frame(width: 5, height: 5).padding(4)
            }
        }
    }
    private func assignmentTitle(_ index: Int, gesture: AssignmentGesture = .press) -> String {
        if case .library(let id) = model.assignedAction(index, gesture: gesture),
           let item = model.libraryItems.first(where: { $0.id == id }), item.isMacro {
            return "M\(item.slot)"
        }
        return model.label(index, gesture: gesture)
    }
    private func gestureAssignmentHelp(_ index: Int, gesture: AssignmentGesture, title: String) -> String {
        if model.isInherited(index, gesture: gesture) { return model.l("继承较低活动层的动作。") }
        var help = model.lf("%@ · %@：%@", model.controlName(index), model.gestureTitle(gesture), title)
        if model.entries(index, gesture: gesture) != nil {
            help += " · " + model.actionBehaviorLabel(index: index, gesture: gesture)
        }
        return help
    }
    private func rotationControl(_ index: Int, title: String, symbol: String) -> some View {
        Button { model.selected = index } label: {
            HStack(spacing: 8) {
                if index == 4 { rotationIcon(symbol, selected: model.selected == index) }
                VStack(alignment: index == 5 ? .trailing : .leading, spacing: 3) {
                    Text(model.l(title)).font(.system(size: 13, weight: .medium))
                    if model.isInherited(index) {
                        Image(systemName: "arrowtriangle.down").font(.system(size: 11, weight: .medium))
                    } else if model.isEmptyAction(index) {
                        Image(systemName: "xmark.square").font(.system(size: 14, weight: .medium))
                    } else { Text(assignmentTitle(index)).font(.system(size: 12)).lineLimit(1) }
                }
                if index == 5 { rotationIcon(symbol, selected: model.selected == index) }
            }
            .foregroundStyle(model.selected == index ? Palette.accent : Palette.text)
            .padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!model.canEdit)
            .help(model.isInherited(index) ? model.l("继承较低活动层的动作。") : model.controlName(index) + " · " + model.label(index))
            .accessibilityLabel(model.l("旋钮" + title)).accessibilityValue(assignmentAccessibility(index))
            .anchorPreference(key: KnobAnchorKey.self, value: .bounds) { [index: $0] }
    }
    private func rotationIcon(_ symbol: String, selected: Bool) -> some View {
        Image(systemName: symbol).font(.system(size: 17, weight: .medium))
            .foregroundStyle(selected ? Palette.background : Palette.accent)
            .frame(width: 32, height: 32)
            .background(selected ? Palette.accent : Palette.surface, in: Circle())
    }
    private var gestureEditor: some View {
        HStack(spacing: 12) {
            Text(model.controlName(model.selected)).font(.system(size: 16, weight: .semibold))
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(.secondary)
            Text(model.selected < 4 ? model.gestureTitle(model.gesture) : model.l("转动"))
                .font(.system(size: 16)).foregroundStyle(Palette.accent)
            Spacer()
            if model.entries(model.selected, gesture: model.gesture) != nil {
                actionOptions
            }
            Button { showsGestureHelp.toggle() } label: {
                Image(systemName: "questionmark.circle").font(.system(size: 18))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityLabel(model.l("手势说明"))
            .popover(isPresented: $showsGestureHelp, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(model.l("按键如何响应")).font(.headline)
                    if model.isLayerSwitch(model.selected) {
                        Text(model.l("单击切层在按下时立即生效；长按动作达到设定时间后执行，松开时退出切层。"))
                    } else {
                        Text(model.l("只设置单击且选择保持按住时，按下立即生效，松开释放。"))
                        Text(model.l("单击、双击和长按决定何时触发；每个动作的按键输出可独立设置为保持按住、短按一次或连按指定次数。"))
                    }
                    if case .momentaryLayer = model.action(model.selected, gesture: .longPress) {
                        Text(model.l("长按切层达到设定时间后启用，松开恢复；不会补发单击动作。"))
                    }
                    Text(model.l("带叉圆角正方形表示不执行动作；双击和长按设为空时不参与手势判定。倒三角表示继承较低活动层的当前动作。"))
                    Text(model.l("未配置的控件继承底层；多个层同时启用时，编号较大的层优先。"))
                    if let hint = model.fnBehaviorHint { Text(hint).foregroundStyle(Palette.accent) }
                }.font(.body).padding(24).frame(width: 360)
            }
        }
    }
    private var actionOptions: some View {
        HStack(spacing: 10) {
            actionModeSelector
            if model.actionBehavior() == .burst {
                HStack(spacing: 4) {
                    Button { model.setActionTapCount(model.actionTapCount() - 1) } label: {
                        Image(systemName: "minus")
                            .frame(width: 32, height: 32)
                            // plain 样式的透明留白默认不响应；整个按钮格都应可点击。
                            .contentShape(Rectangle())
                    }
                    .disabled(model.actionTapCount() <= 2)
                    .accessibilityLabel(model.l("减少次数"))
                    Text(model.lf("%d 次", model.actionTapCount()))
                        .font(.system(size: 14, weight: .medium)).monospacedDigit()
                        .fixedSize().frame(minWidth: 42)
                        .accessibilityLabel(model.l("连按次数"))
                        .accessibilityValue(model.lf("%d 次", model.actionTapCount()))
                    Button { model.setActionTapCount(model.actionTapCount() + 1) } label: {
                        Image(systemName: "plus")
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .disabled(model.actionTapCount() >= 20)
                    .accessibilityLabel(model.l("增加次数"))
                }
                .buttonStyle(.plain).padding(.horizontal, 5)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 6))
                .help(model.l("连按次数：2–20 次。"))
            }
        }.disabled(!model.canEdit)
    }
    private func actionModeTitle(_ behavior: LongPressBehavior) -> String {
        switch behavior {
        case .hold: return model.l("保持按住")
        case .tap: return model.l("短按一次")
        case .burst: return model.l("连按")
        }
    }
    private var actionModeSelector: some View {
        HStack(spacing: 2) {
            ForEach(model.availableActionBehaviors, id: \.self) { behavior in
                Button { model.setActionBehavior(behavior) } label: {
                    Text(actionModeTitle(behavior))
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .foregroundStyle(model.actionBehavior() == behavior ? Palette.background : Palette.text)
                        .background(model.actionBehavior() == behavior ? Palette.accent : .clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.actionBehavior() == behavior ? .isSelected : [])
            }
        }
        .padding(3).frame(width: model.availableActionBehaviors.count == 3 ? 264 : 176, height: 32)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.l("按键输出"))
        .help(model.actionBehaviorHelp)
    }
    private func assignmentAccessibility(_ index: Int) -> String {
        if index >= 4 { return model.isInherited(index) ? model.l("继承底层") : model.label(index) }
        return AssignmentGesture.allCases.map { gesture in
            model.lf("%@：%@", model.gestureTitle(gesture), model.isInherited(index, gesture: gesture) ? model.l("继承底层") : model.isEmptyAction(index, gesture: gesture) ? model.l("不执行动作") : model.label(index, gesture: gesture))
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
                    .anchorPreference(key: KnobAnchorKey.self, value: .bounds) { [3: $0] }
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
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Vibe Key").font(.headline)
                Spacer()
                Button(model.l("刷新状态")) { model.refresh() }
                    .disabled(!model.device.connected || model.device.busy)
                Button(model.l(model.device.connected ? "断开连接" : "连接设备")) {
                    if model.device.connected { model.disconnect() } else { model.connect() }
                }.disabled(model.device.busy)
            }
            HStack(spacing: 20) {
                Label(model.status, systemImage: "keyboard")
                Label(model.batteryText, systemImage: model.batterySymbol)
                    .help(model.batteryHelp)
                Spacer()
                Label(model.l(model.device.heartbeatPausedForInactivity ? "因空闲已停止保活" : model.device.heartbeatEnabled ? "后台运行中" : "后台已暂停"),
                      systemImage: "waveform.path.ecg")
                    .help(model.l("关闭窗口后继续运行，退出应用时停止。"))
            }.font(.body).foregroundStyle(.secondary)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(model.l("保活"), systemImage: "waveform.path.ecg").font(.headline)
                    Spacer()
                    Picker(model.l("空闲后停止保活"), selection: Binding(
                        get: { model.heartbeatIdleMinutes },
                        set: { model.setHeartbeatIdleMinutes($0) })) {
                        ForEach(AppModel.heartbeatIdleMinutesOptions, id: \.self) { minutes in
                            Text(minutes == 0 ? model.l("永不") : model.lf("%d 分钟", minutes)).tag(minutes)
                        }
                    }.frame(width: 290)
                    .accessibilityLabel(model.l("空闲后停止保活"))
                    .help(model.l("按 Vibe Key 的按键和旋钮操作计算空闲时间，按住期间不会超时。"))
                }
                Text(model.l("停止保活会暂停 Layer、手势和宏，设备可能恢复自身键位。"))
                    .font(.callout).foregroundStyle(.secondary)
                if model.device.heartbeatPausedForInactivity {
                    HStack {
                        Label(model.l("因空闲已停止保活"), systemImage: "pause.circle").foregroundStyle(Palette.accent)
                        Spacer()
                        Button(model.l("恢复保活")) { model.resumeHeartbeat() }
                            .disabled(model.device.busy)
                            .help(model.l("有按住的按键时，松开后恢复。"))
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Label(model.l("连接帮助"), systemImage: "questionmark.circle")
                    .font(.headline).accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.l("插入 USB 接收器后会自动连接。设备休眠时，短按电源键唤醒。"))
                    Text(model.l("如果其他工具占用设备，请先退出 Ulanzi Studio 或抓包程序。"))
                    if !model.demo {
                        HStack(spacing: 12) {
                            Button(model.permissionButtonTitle) { model.requestPermissions() }
                                .disabled(model.device.busy)
                            Button(model.l("显示 App 位置")) { model.revealApplication() }
                        }
                    }
                }.font(.body).frame(maxWidth: .infinity, alignment: .leading)
            }.font(.body)
        }.padding(18).background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
    }
    private var profiles: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.l("键位配置")).font(.headline)
            HStack {
                TextField(model.l("配置名称"), text: $profileName).textFieldStyle(OlanziTextFieldStyle()).frame(maxWidth: 320)
                Button(model.l("保存当前配置")) { model.saveProfile(name: profileName); profileName = "" }
                    .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.canEdit)
                Spacer()
                Button { model.importProfile() } label: { Label(model.l("导入…"), systemImage: "square.and.arrow.down") }
                Button { model.exportProfile() } label: { Label(model.l("导出…"), systemImage: "square.and.arrow.up") }.disabled(!model.canEdit)
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
                }.padding(12).background(Palette.raised, in: RoundedRectangle(cornerRadius: 8))
            }
            if model.profiles.isEmpty { Text(model.l("还没有保存的配置。")).foregroundStyle(.secondary).padding(.vertical, 6) }
            HStack {
                Button(model.l("载入默认键位")) { model.loadDefaults() }
                Button(model.l("从设备键位导入")) { model.importDeviceBindings() }
                    .disabled(!model.online || model.device.busy || model.device.keys.count != 6)
            }
        }.padding(18).background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
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
                if model.page == 1 {
                    Button { NSApp.terminate(nil) } label: {
                        Image(systemName: "power").foregroundStyle(.red)
                    }
                    .buttonStyle(OlanziButtonStyle())
                    .help(model.l("退出 Olanzi"))
                    .accessibilityLabel(model.l("退出 Olanzi"))
                }
                if model.applying {
                    ProgressView().controlSize(.small)
                    Text(model.l("正在保存…")).font(.body)
                } else if model.hasDraft {
                    Text(model.l("有未保存的更改")).font(.body).foregroundStyle(Palette.accent)
                }
                Spacer()
                Button(model.l("撤销更改")) { model.discard() }.disabled(model.draft == nil || model.applying)
                Button(model.l("保存到本机")) { model.apply() }.buttonStyle(OlanziButtonStyle(.primary))
                    .foregroundStyle(Palette.background).disabled(!model.hasDraft || !model.canEdit || model.device.busy || model.applying)
            }.controlSize(.large).padding(.horizontal, 28).padding(.vertical, 14)
        }
    }
}

/// 用实际控件边界连接旋钮，避免布局缩放后引导线与目标错位。
private struct KnobAnchorKey: PreferenceKey {
    static var defaultValue: [Int: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [Int: Anchor<CGRect>], nextValue: () -> [Int: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
