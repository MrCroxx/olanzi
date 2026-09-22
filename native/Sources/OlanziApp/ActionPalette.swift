import AppKit
import SwiftUI
import OlanziCore

enum LibraryActionKind {
    case application, macro
    var title: String { self == .macro ? "宏" : "APP" }
    var symbol: String { self == .macro ? "list.bullet.rectangle" : "app" }
    func includes(_ action: HostAction) -> Bool {
        switch action {
        case .application: return self == .application
        case .macro: return self == .macro
        default: return false
        }
    }
}

/// 分类、键帽和编辑器都属于下半区；创建动作和分配动作是两个独立步骤。
struct ActionPalette: View {
    @ObservedObject var model: AppModel
    var minimumHeight: CGFloat = 280
    @State private var category = "常用"
    @State private var search = ""
    @State private var editor: EditTarget?
    private struct EditTarget: Identifiable {
        let id = UUID()
        var item: NamedHostAction?
        var kind: LibraryActionKind
        var initialAction: HostAction?
    }
    private var libraryKind: LibraryActionKind? {
        category == "宏" ? .macro : category == "APP" ? .application : nil
    }
    private var categories: [String] { ["常用", "字符", "功能键", "数字键盘", "组合键", "Layer", "APP", "宏"] }
    private var keyGroups: [String] {
        switch category {
        case "常用": return ["常用", "导航", "修饰键"]
        case "字符": return ["字母", "数字", "符号"]
        default: return [category]
        }
    }
    private var visibleKeys: [KeyOption] {
        // 协议目录保留旧配置的键名，选择器只展示当前驱动可以发送的按键。
        let supported = KeyCatalog.options.filter { $0.code != 0 && model.isSupported($0.code) }
        if search.isEmpty {
            return keyGroups.flatMap { group in supported.filter { $0.category == group } }
        }
        return supported.filter {
            model.l($0.label).localizedCaseInsensitiveContains(search)
                || $0.label.localizedCaseInsensitiveContains(search)
                || String(format: "0x%02X", $0.code).localizedCaseInsensitiveContains(search)
        }
    }

    private func categorySymbol(_ name: String) -> String {
        switch name {
        case "常用": return "star"
        case "组合键": return "command"
        case "Layer": return "square.stack"
        case "APP": return "app"
        case "宏": return "list.bullet.rectangle"
        case "字符": return "a.square"
        case "功能键": return "f.square"
        case "数字键盘": return "square.grid.3x3"
        default: return "keyboard"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.l("选择按键")).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 5)
                ForEach(categories, id: \.self) { name in
                    if name == "组合键" { Divider().padding(.vertical, 4) }
                    Button { category = name; search = "" } label: {
                        HStack(spacing: 8) {
                            Image(systemName: categorySymbol(name))
                                .frame(width: 16, height: 16)
                                .accessibilityHidden(true)
                            Text(model.l(name))
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 13, weight: category == name ? .semibold : .regular))
                        .padding(.horizontal, 10).frame(height: min(28, max(22, (minimumHeight - 58) / CGFloat(categories.count))))
                        .foregroundStyle(category == name ? Palette.accent : Palette.text)
                        .background(category == name ? Palette.raised : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(editor != nil)
                        .accessibilityLabel(model.lf("按键分类：%@", model.l(name)))
                        .accessibilityAddTraits(category == name ? .isSelected : [])
                }
            }.frame(width: 116).padding(10)
            Rectangle().fill(.white.opacity(0.07)).frame(width: 1)
            VStack(alignment: .leading, spacing: 12) {
                if let editor {
                    ActionEditor(model: model, item: editor.item, kind: editor.kind,
                                 initialAction: editor.initialAction, onClose: { self.editor = nil })
                        .id(editor.id)
                } else if let kind = libraryKind {
                    library(kind)
                } else if category == "Layer" {
                    layers
                } else if category == "组合键" {
                    ShortcutAssignmentEditor(model: model)
                } else {
                    keyboard
                }
            }
            .padding(14).frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .topLeading)
        }
        .background(Palette.surface.opacity(0.23), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.07), lineWidth: 1))
        .buttonStyle(OlanziButtonStyle())
    }

    @ViewBuilder
    private var specialKeys: some View {
        Button { model.inheritAction() } label: {
            Image(systemName: "arrowtriangle.down").font(.system(size: 16, weight: .medium))
        }
        .buttonStyle(KeycapButtonStyle(selected: model.isInherited(model.selected, gesture: model.gesture)))
        .disabled(!model.canEdit || model.selectedLayer == 0)
        .help(model.l("继承较低活动层的当前动作。"))
        .accessibilityLabel(model.l("继承当前动作"))
        Button { model.clearAction() } label: {
            Image(systemName: "xmark.square").font(.system(size: 19, weight: .medium))
        }
        .buttonStyle(KeycapButtonStyle(selected: !model.isInherited(model.selected, gesture: model.gesture) && model.isEmptyAction(model.selected, gesture: model.gesture)))
        .disabled(!model.canEdit)
        .help(model.l("当前动作不执行；双击和长按设为空时不参与手势判定。"))
        .accessibilityLabel(model.l("不执行动作"))
    }

    private var layers: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.l("按住切换 Layer")).font(.headline)
            Text(model.l("MO(n)：分配给单击时按下立即切层；分配给长按时达到长按时间后切层，松开恢复。"))
                .font(.callout).foregroundStyle(.secondary)
            Text(model.l("单击切层可同时设置长按动作；分配单击切层时仅清除双击。"))
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90, maximum: 120), spacing: 8)], spacing: 8) {
                specialKeys
                ForEach(model.layerIDs.filter { $0 != 0 }, id: \.self) { id in
                    Button { model.assignAction(.momentaryLayer(id)) } label: {
                        Text("MO(\(id))").font(.system(.body, design: .monospaced))
                    }
                    .buttonStyle(KeycapButtonStyle(selected: !model.isInherited(model.selected, gesture: model.gesture) && model.assignedAction(model.selected, gesture: model.gesture) == .momentaryLayer(id)))
                    .disabled(!model.canEdit || model.selected >= 4 || model.gesture == .doublePress)
                    .accessibilityLabel(model.lf("按住切换到 Layer %d", id))
                }
            }
            Text(model.l("未配置的控件继承底层；多个层同时启用时，编号较大的层优先。"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var keyboard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.l(category)).font(.headline)
                Spacer()
                TextField(model.l("搜索按键"), text: $search)
                    .textFieldStyle(OlanziTextFieldStyle()).frame(width: 180)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 70, maximum: 100), spacing: 6)], spacing: 6) {
                specialKeys
                ForEach(visibleKeys) { key in
                    Button { model.assign(key.code) } label: {
                        Text(model.keyLabel(key.code)).lineLimit(2).multilineTextAlignment(.center)
                    }
                    .buttonStyle(KeycapButtonStyle(selected: !model.isInherited(model.selected, gesture: model.gesture) && model.code(model.selected, gesture: model.gesture) == key.code))
                    .disabled(!model.canEdit)
                    .help(model.l("分配给当前动作"))
                    .accessibilityLabel(model.lf("分配 %@", model.keyLabel(key.code)))
                }
            }
        }
    }

    private func library(_ kind: LibraryActionKind) -> some View {
        let items = model.libraryItems.filter { kind.includes($0.action) }.sorted { $0.slot < $1.slot }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.l(kind == .macro ? "宏" : "APP")).font(.headline)
                    Text(model.l("点击键帽分配给选中的动作；点击铅笔编辑。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button { editor = EditTarget(kind: kind) } label: {
                    Label(model.l(kind == .macro ? "新建宏" : "添加 APP"), systemImage: "plus")
                }.disabled(!model.canEdit || items.count >= 16)
            }
            if items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: kind.symbol).font(.system(size: 27)).foregroundStyle(Palette.accent.opacity(0.7))
                    Text(model.l(kind == .macro ? "先录制一个宏，再像普通按键一样分配。" : "添加常用 APP，之后点击键帽即可分配。"))
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 28)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 172), spacing: 12)], spacing: 12) {
                    ForEach(items) { item in
                        libraryKeycap(item, kind: kind)
                    }
                }
            }
            if let current = model.action(model.selected, gesture: model.gesture), kind.includes(current),
               !items.contains(where: { $0.action == current }) {
                Divider()
                HStack {
                    Text(model.l("当前动作尚未加入动作库。")) .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(model.l("从当前动作创建")) { editor = EditTarget(kind: kind, initialAction: current) }
                        .disabled(!model.canEdit || items.count >= 16)
                }
            }
        }
    }

    private func libraryKeycap(_ item: NamedHostAction, kind: LibraryActionKind) -> some View {
        let selected = !model.isInherited(model.selected, gesture: model.gesture) && model.assignedAction(model.selected, gesture: model.gesture) == .library(item.id)
        let shortName = (kind == .macro ? "M" : "A") + String(item.slot)
        return VStack(spacing: 6) {
            Button { _ = model.assignLibraryAction(item.id) } label: {
                VStack(spacing: 7) {
                    HStack(spacing: 6) {
                        Image(systemName: kind.symbol).font(.system(size: 12))
                        Text(shortName).font(.system(size: 15, weight: .semibold, design: .monospaced))
                    }
                    Text(item.name).font(.system(size: 12)).lineLimit(2)
                }.padding(.vertical, 10)
            }.buttonStyle(KeycapButtonStyle(selected: selected)).disabled(!model.canEdit)
                .accessibilityLabel(model.lf("分配 %@", model.libraryItemLabel(item)))
                .help(model.actionLabel(item.action))
            HStack(spacing: 0) {
                Text(model.lf("%d 个绑定", model.usageCount(item.id))).font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button { editor = EditTarget(item: item, kind: kind) } label: { Image(systemName: "pencil") }
                    .buttonStyle(OlanziButtonStyle(.subtle))
                    .accessibilityLabel(model.lf("编辑 %@", model.libraryItemLabel(item)))
            }
        }
    }
}

private struct ShortcutAssignmentEditor: View {
    @ObservedObject var model: AppModel
    @StateObject private var recorder = ShortcutRecorder()
    @State private var keys: [KeyEntry] = []
    @State private var target: (Int, AssignmentGesture)?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.l("组合键")).font(.headline)
            Text(model.l("按住需要组合的按键，全部松开后完成。"))
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                if recorder.isRecording {
                    HStack(spacing: 7) {
                        Circle().fill(Color.red).frame(width: 7, height: 7)
                        Text(model.l("录制中")).font(.callout)
                    }
                }
                let preview = recorder.isRecording ? (recorder.candidate ?? []) : keys
                if !preview.isEmpty {
                    Text(model.actionLabel(entries: preview))
                        .font(.system(size: 22, weight: .medium)).foregroundStyle(Palette.accent)
                        .lineLimit(3)
                } else if !recorder.isRecording {
                    Text(model.l("尚未录制")).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                .padding(12).background(Palette.background, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button {
                    keys = []
                    target = (model.selected, model.gesture)
                    recorder.start(window: NSApp.keyWindow)
                } label: { Label(model.l("录制组合键"), systemImage: "record.circle") }
                    .disabled(recorder.isRecording || !model.canEdit)
                if recorder.isRecording {
                    Button(model.l("取消录制")) { reset() }
                }
                Spacer()
                Button(model.l("分配组合键")) {
                    if let target, model.assign(keys, index: target.0, gesture: target.1) { reset() }
                }.buttonStyle(OlanziButtonStyle(.primary))
                    .disabled(recorder.isRecording || keys.isEmpty || recorder.error != nil || !model.canEdit)
            }
            if let error = recorder.error { Text(model.displayError(error)).foregroundStyle(.orange).font(.callout) }
            Text(model.l("系统快捷键可能被 macOS 优先处理。")) .font(.caption).foregroundStyle(.secondary)
        }
        .background(ShortcutRecordingFocus(recorder: recorder).frame(width: 0, height: 0))
        .onChange(of: recorder.result) { _, result in
            if let result { keys = result.entries }
        }
        .onChange(of: model.selected) { _, _ in reset() }
        .onChange(of: model.gesture) { _, _ in reset() }
        .onChange(of: model.selectedLayer) { _, _ in reset() }
        .onDisappear { recorder.reset() }
    }
    private func reset() { recorder.reset(); keys = []; target = nil }
}
