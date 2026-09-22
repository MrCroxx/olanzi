import SwiftUI

/// 全部工作区共用的颜色、按钮与输入框，避免系统默认控件混入键帽界面。
enum Palette {
    static let background = Color(red: 0.115, green: 0.106, blue: 0.106)
    static let surface = Color(red: 0.212, green: 0.204, blue: 0.204)
    static let raised = Color(red: 0.255, green: 0.255, blue: 0.255)
    static let accent = Color(red: 0.91, green: 0.769, blue: 0.722)
    static let text = Color(white: 0.85)
}

struct OlanziButtonStyle: ButtonStyle {
    enum Kind { case secondary, primary, subtle }
    var kind: Kind = .secondary
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    init(_ kind: Kind = .secondary) { self.kind = kind }
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12).frame(minHeight: 34)
            .foregroundStyle(kind == .primary ? Palette.background : Palette.text)
            .background(kind == .primary ? Palette.accent : hovering || configuration.isPressed ? Palette.raised : kind == .subtle ? .clear : Palette.surface,
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(kind == .subtle ? 0 : 0.06), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.35)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

struct KeycapButtonStyle: ButtonStyle {
    var selected = false
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .frame(maxWidth: .infinity, minHeight: 46)
            .padding(.horizontal, 6)
            .foregroundStyle(selected ? Palette.background : Palette.text)
            .background(selected ? Palette.accent : hovering ? Palette.raised : Palette.surface,
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.07), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.3)
            .onHover { hovering = $0 }
    }
}

struct OlanziTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).padding(.horizontal, 10).padding(.vertical, 8)
            .background(Palette.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.12), lineWidth: 1))
    }
}

struct OlanziToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: { configuration.label }
            .buttonStyle(OlanziButtonStyle(configuration.isOn ? .primary : .secondary))
            .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}
