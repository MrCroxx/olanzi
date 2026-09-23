import SwiftUI
import Charts
import OlanziCore

/// 菜单栏概览沿用工作区配色；统计只描述设备活动，不猜测正在运行的应用。
struct DriverStatusView: View {
    @ObservedObject var model: AppModel
    let settings: () -> Void
    let quit: () -> Void

    private struct Day: Identifiable {
        let date: Date
        let keys: Int
        let turns: Int
        let seconds: Double
        var id: Date { date }
    }
    private func week(at now: Date) -> [Day] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return (-6...0).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            let values = model.device.usageDays.filter { calendar.isDate($0.date, inSameDayAs: date) }
            return Day(date: date, keys: values.reduce(0) { $0 + $1.keyPresses },
                       turns: values.reduce(0) { $0 + $1.knobTurns }, seconds: values.reduce(0) { $0 + $1.activeSeconds })
        }
    }
    private func duration(_ seconds: Double) -> String {
        if seconds < 60 { return model.lf("%d 秒", Int(seconds)) }
        return model.lf("%d 分钟", Int(seconds / 60))
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let days = week(at: context.date)
            let today = days.last!
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(nsImage: VibeKeyIcon.image).resizable().scaledToFit()
                        .frame(width: 24, height: 24).foregroundStyle(Palette.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Olanzi").font(.headline)
                        Text(model.l("后台设备服务")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.demo { Text(model.l("演示模式")).font(.caption).foregroundStyle(Palette.accent) }
                    else { Label(model.batteryText, systemImage: model.batterySymbol).font(.caption).help(model.batteryHelp) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label(model.status, systemImage: model.online ? "checkmark.circle.fill" : "circle.dotted")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(model.online ? Palette.accent : Palette.text)
                    HStack {
                        Text(model.l(model.device.heartbeatPausedForInactivity ? "因空闲已停止保活" : model.device.heartbeatEnabled ? "心跳运行中" : "心跳已暂停"))
                        Spacer()
                        if model.device.heartbeatPausedForInactivity {
                            Button(model.l("恢复保活")) { model.resumeHeartbeat() }
                        } else {
                            Button(model.l(model.device.connected ? "断开设备" : "连接设备")) {
                                if model.device.connected { model.disconnect() } else { model.connect() }
                            }.disabled(model.device.busy)
                        }
                    }.font(.caption)
                    if model.needsPermissionSetup {
                        Button(action: settings) { Label(model.l("需要授予输入权限"), systemImage: "exclamationmark.shield") }
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let error = model.device.error {
                        Text(model.displayError(error)).font(.caption).foregroundStyle(.orange)
                            .lineLimit(3).help(model.displayError(error))
                    }
                }
                .padding(12).background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
                Text(model.l("今日活动")).font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    metric("按键", value: today.keys.formatted(), symbol: "keyboard")
                    metric("旋钮转动", value: today.turns.formatted(), symbol: "dial.low")
                    metric("活跃时间", value: duration(today.seconds), symbol: "clock")
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(model.l("最近 7 天")).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(duration(days.reduce(0) { $0 + $1.seconds })).font(.caption).foregroundStyle(.secondary)
                    }
                    Chart(days) { day in
                        BarMark(x: .value(model.l("日期"), day.date, unit: .day),
                                y: .value(model.l("分钟"), day.seconds / 60))
                            .foregroundStyle(Calendar.current.isDateInToday(day.date) ? Palette.accent : Palette.accent.opacity(0.4))
                            .cornerRadius(3)
                            .accessibilityLabel(day.date.formatted(.dateTime.month().day().locale(model.localizer.locale)))
                            .accessibilityValue(duration(day.seconds))
                    }
                    .chartYScale(domain: 0...max(1, (days.map(\.seconds).max() ?? 0) / 60 * 1.2))
                    .chartXAxis {
                        AxisMarks(values: days.map(\.date)) { value in
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(date.formatted(.dateTime.weekday(.abbreviated).locale(model.localizer.locale)))
                                }
                            }
                        }
                    }
                    .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                    .frame(height: 104)
                    if days.allSatisfy({ $0.keys + $0.turns == 0 }) {
                        Text(model.l("按一下设备，开始积累你的使用足迹。")).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(model.l("每次操作后的 30 秒计为活跃时间，重叠不重复；纵轴为分钟。"))
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if model.device.usageError != nil {
                    Label(model.l("统计暂未保存，请检查本地存储。"), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).help(model.device.usageError ?? "")
                }
                Text(model.l("仅在本机保存活动汇总，不记录输入内容。"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Button(action: quit) {
                        Image(systemName: "power").foregroundStyle(.red)
                    }
                    .buttonStyle(OlanziButtonStyle())
                    .help(model.l("退出 Olanzi"))
                    .accessibilityLabel(model.l("退出 Olanzi"))
                    Spacer()
                    Button(action: settings) {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(OlanziButtonStyle())
                    .help(model.l("设置"))
                    .accessibilityLabel(model.l("设置"))
                }
            }
            .padding(20).frame(width: 380)
            .foregroundStyle(Palette.text).background(Palette.background)
        }
        .environment(\.locale, model.localizer.locale)
        .preferredColorScheme(.dark)
    }
    private func metric(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.l(title), systemImage: symbol).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
    }
}
