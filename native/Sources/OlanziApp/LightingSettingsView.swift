import SwiftUI
import OlanziCore

struct LightingSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var selectedLight = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center) {
                Text(model.l("灯效")).font(.title2.bold())
                Spacer()
                if model.lightingBusy { ProgressView().controlSize(.small) }
                Button(model.l("应用灯效")) { model.applyLighting() }
                    .buttonStyle(OlanziButtonStyle(.primary)).disabled(!model.canApplyLighting)
            }
            modeSelector
            HStack(alignment: .top, spacing: 28) {
                preview.frame(width: 330)
                editor.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let failure = model.lightingFailureText {
                Text(failure).font(.callout).foregroundStyle(.orange)
            }
            if let error = model.lightingErrorText {
                HStack {
                    Text(error).font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.lightingDraft == nil {
                        Button(model.l("重试")) { model.readLighting() }
                            .disabled(!model.online || model.lightingBusy)
                    }
                }
            }
        }
        .frame(maxWidth: 1040)
        .frame(maxWidth: .infinity)
    }

    private var modeSelector: some View {
        HStack(spacing: 6) {
            ForEach(Array(["全部关闭", "全部常亮", "工作模式"].enumerated()), id: \.offset) { index, title in
                Button { model.editLighting { $0.mode = UInt8(index) } } label: {
                    Label(model.l(title), systemImage: ["lightbulb.slash", "lightbulb", "slider.horizontal.3"][index])
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .foregroundStyle(model.lighting?.mode == UInt8(index) ? Palette.background : Palette.text)
                        .background(model.lighting?.mode == UInt8(index) ? Palette.accent : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(model.l(title))
                    .accessibilityAddTraits(model.lighting?.mode == UInt8(index) ? .isSelected : [])
            }
        }.padding(5).background(Palette.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 11))
            .disabled(!model.canEditLighting)

    }

    private var preview: some View {
        VStack(spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                deviceBody
                VStack(alignment: .leading, spacing: 0) {
                    Spacer().frame(height: 94)
                    lightLabel(3).frame(height: 32)
                    Spacer().frame(height: 40)
                    ForEach(0..<3) { index in lightLabel(index).frame(height: 81) }
                }.frame(width: 150, height: 416, alignment: .topLeading)
            }.frame(width: 330, height: 455, alignment: .center)
        }
    }

    private func lightLabel(_ index: Int) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(selectedLight == index ? Palette.accent : Color.white.opacity(0.16))
                .frame(width: 22, height: 1)
            Button { selectedLight = index } label: {
                Text(model.l(index == 3 ? "旋钮指示灯" : "键 \(index + 1) 指示灯"))
                    .font(.system(size: 12, weight: selectedLight == index ? .semibold : .regular))
                    .foregroundStyle(selectedLight == index ? Palette.accent : .secondary)
                    .padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }

    private var deviceBody: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 15)
                .fill(LinearGradient(colors: [Color(white: 0.86), Color(white: 0.61), Color(white: 0.76)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(.black.opacity(0.8), lineWidth: 2))
                .shadow(color: .black.opacity(0.4), radius: 18, x: 5, y: 10)
            VStack(spacing: 0) {
                Text("Ulanzi").font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85)).padding(.top, 12)
                HStack(spacing: 5) {
                    ForEach(0..<6) { i in
                        Capsule().fill(Color(white: 0.22)).frame(width: 5, height: i == 0 || i == 5 ? 18 : 24)
                    }
                }.frame(height: 34)
                lightButton(3).frame(width: 96, height: 96)
                VStack(spacing: 12) {
                    ForEach(0..<3) { index in lightButton(index).frame(width: 70, height: 69) }
                }.padding(.top, 14)
            }
        }.frame(width: 108, height: 416)
    }

    private func lightButton(_ index: Int) -> some View {
        let selected = selectedLight == index
        let lit = model.lighting.map { value in
            if value.mode == 1 { return value.brightness > 0 }
            guard value.mode == 2, value.lights.indices.contains(index) else { return false }
            let light = value.lights[index]
            if light.type == 1 { return light.alwaysOnBrightness > 0 }
            if light.type == 2 { return light.breatheBrightness > 0 }
            return light.type != 0
        } ?? false
        return Button { selectedLight = index } label: {
            ZStack {
                if index == 3 {
                    Circle().fill(LinearGradient(colors: [Color(white: 0.89), Color(white: 0.65)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Circle().stroke(lit ? Palette.accent : Color.black.opacity(0.3), lineWidth: 3).padding(4)
                        .shadow(color: lit ? Palette.accent.opacity(0.7) : .clear, radius: 5)
                    Image(systemName: "dial.medium").font(.system(size: 28, weight: .light)).foregroundStyle(Color(white: 0.3))
                } else {
                    RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.84))
                    Circle().fill(LinearGradient(colors: [Color(white: 0.92), Color(white: 0.8)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .padding(7).shadow(color: .black.opacity(0.2), radius: 2, y: 2)
                    Image(systemName: ["mic", "checkmark.circle", "xmark.circle"][index])
                        .font(.system(size: 22, weight: .medium)).foregroundStyle(Color(white: 0.25))
                    Capsule().fill(lit ? Palette.accent : Color(white: 0.45)).frame(width: 25, height: 3).offset(y: 26)
                        .shadow(color: lit ? Palette.accent : .clear, radius: 4)
                }
            }
            .overlay {
                if index == 3 { Circle().stroke(selected ? Palette.accent : .clear, lineWidth: 2).padding(-5) }
                else { RoundedRectangle(cornerRadius: 8).stroke(selected ? Palette.accent : .clear, lineWidth: 2).padding(-5) }
            }
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(model.l(index == 3 ? "旋钮指示灯" : "键 \(index + 1) 指示灯"))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Image(systemName: selectedLight == 3 ? "dial.medium" : ["mic", "checkmark.circle", "xmark.circle"][selectedLight])
                    .font(.system(size: 23)).foregroundStyle(Palette.accent)
                    .frame(width: 46, height: 46).background(Palette.raised, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.l(selectedLight == 3 ? "旋钮指示灯" : "键 \(selectedLight + 1) 指示灯")).font(.title3.weight(.semibold))
                }
            }
            Divider()
            if let lighting = model.lighting, lighting.lights.indices.contains(selectedLight) {
                if lighting.mode == 2 {
                    Text(model.l("灯光效果")).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        effectButton(0, title: "关闭", symbol: "lightbulb.slash", lighting: lighting)
                        effectButton(1, title: "常亮", symbol: "lightbulb", lighting: lighting)
                        if selectedLight == 0 { effectButton(2, title: "呼吸", symbol: "waveform", lighting: lighting) }
                    }.disabled(!model.canEditLighting)
                    if lighting.lights[selectedLight].type > (selectedLight == 0 ? 2 : 1) {
                        Text(model.lf("保留设备值 %d", Int(lighting.lights[selectedLight].type)))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if lighting.mode == 1 {
                    brightnessSlider(title: "全亮亮度", value: lighting.brightness) { value in
                        model.editLighting { $0.brightness = value }
                    }
                }
                if lighting.mode == 2 {
                    let light = lighting.lights[selectedLight]
                    if light.type == 1 || light.type == 2 {
                        let knob = selectedLight == 3 && light.type == 1
                        brightnessSlider(title: "亮度", value: light.type == 1 ? light.alwaysOnBrightness : light.breatheBrightness,
                                         unknown: knob && !model.lightingKnobBrightnessKnown) { value in
                            if knob { model.editKnobBrightness(value) }
                            else {
                                model.editLighting {
                                    if light.type == 1 { $0.lights[selectedLight].alwaysOnBrightness = value }
                                    else { $0.lights[selectedLight].breatheBrightness = value }
                                }
                            }
                        }.help(knob ? model.l("设备不返回当前亮度，显示本次连接内已设置的值。") : "")
                    }
                }
                if lighting.mode > 2 { Text(model.lf("保留设备值 %d", Int(lighting.mode))).font(.callout) }

            } else {
                if !model.online {
                    Text(model.l("连接并唤醒设备后可调节灯效。"))
                        .font(.body).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }.padding(24).frame(minHeight: 360, alignment: .topLeading)
            .background(Palette.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
            .padding(.top, 18)
    }

    private func brightnessSlider(title: String, value: UInt8, unknown: Bool = false, change: @escaping (UInt8) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(model.l(title)).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text(unknown ? "—" : value > 20 ? model.lf("保留设备值 %d", Int(value)) : "\(value) / 20")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
            }
            Slider(value: Binding(get: { unknown ? 0 : Double(min(value, 20)) }, set: { change(UInt8($0.rounded())) }), in: 0...20, step: 1)
                .accessibilityLabel(model.l(title))
                .accessibilityValue(unknown ? "—" : String(value))
        }.disabled(!model.canEditLighting)
    }

    private func effectButton(_ type: UInt8, title: String, symbol: String, lighting: DeviceLighting) -> some View {
        let selected = lighting.lights[selectedLight].type == type
        return Button { model.editLighting { $0.lights[selectedLight].type = type } } label: {
            VStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 22, weight: .light))
                Text(model.l(title)).font(.system(size: 13, weight: .medium))
            }.frame(maxWidth: .infinity).padding(.vertical, 19)
                .foregroundStyle(selected ? Palette.accent : Palette.text)
                .background(selected ? Palette.accent.opacity(0.1) : Palette.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Palette.accent.opacity(0.75) : .clear, lineWidth: 1))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
