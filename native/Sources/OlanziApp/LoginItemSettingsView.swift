import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class LoginItemSettings: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var error: String?
    private let readStatus: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () throws -> Void

    init(readStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
         register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
         unregister: @escaping () throws -> Void = { try SMAppService.mainApp.unregister() }) {
        self.readStatus = readStatus
        self.register = register
        self.unregister = unregister
        refresh()
    }

    // 等待批准仍属于已注册，用户可以直接关闭以撤销注册。
    var isRegistered: Bool { status == .enabled || status == .requiresApproval }
    func refresh() { status = readStatus() }
    func setEnabled(_ enabled: Bool) {
        error = nil
        do {
            if enabled { try register() } else { try unregister() }
        } catch {
            self.error = error.localizedDescription
        }
        // 无论成功或失败，都以系统实际状态为准。
        refresh()
    }
}

struct LoginItemSettingsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var settings = LoginItemSettings()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.l("登录时启动")).font(.headline)
                Spacer()
                Toggle(model.l("登录时启动"), isOn: Binding(
                    get: { settings.isRegistered }, set: { settings.setEnabled($0) }))
                    .labelsHidden().toggleStyle(.switch)
                    .disabled(model.demo)
            }
            Text(model.l("登录 Mac 后在菜单栏运行，不打开主窗口。"))
                .font(.callout).foregroundStyle(.secondary)
            if settings.status == .requiresApproval {
                HStack {
                    Text(model.l("需要在系统设置中允许登录项。"))
                    Spacer()
                    Button(model.l("打开登录项设置…")) { SMAppService.openSystemSettingsLoginItems() }
                }.font(.callout)
            }
            if let error = settings.error {
                Text(model.lf("无法更新登录项：%@", error))
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(18).background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .onAppear { settings.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refresh()
        }
    }
}
