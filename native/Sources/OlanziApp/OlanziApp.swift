import AppKit
import SwiftUI

@main
struct OlanziApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var stopping = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model = AppModel(demo: CommandLine.arguments.contains("--demo"))
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Olanzi")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = "Olanzi · 后台设备服务"
        statusItem.button?.setAccessibilityLabel("Olanzi 后台设备服务")
        model.didChange = { [weak self] in self?.updateMenu() }
        updateMenu()
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        let quit = NSMenuItem(title: "退出 Olanzi", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self
        appMenu.addItem(quit); appItem.submenu = appMenu; mainMenu.addItem(appItem)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""); let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", Selector(("undo:")), "z"), ("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        editItem.submenu = editMenu; mainMenu.addItem(editItem); NSApp.mainMenu = mainMenu
        let windowItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu; mainMenu.addItem(windowItem); NSApp.windowsMenu = windowMenu
        model.start()
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.addObserver(self, selector: #selector(systemWillSleep(_:)),
                                           name: NSWorkspace.willSleepNotification, object: nil)
        workspaceNotifications.addObserver(self, selector: #selector(systemDidWake(_:)),
                                           name: NSWorkspace.didWakeNotification, object: nil)
        if !CommandLine.arguments.contains("--background") { showWindow() }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        model?.refreshPermissions()
    }
    private func updateMenu() {
        guard let model else { return }
        let menu = NSMenu()
        let title = NSMenuItem(title: model.status, action: nil, keyEquivalent: ""); title.isEnabled = false; menu.addItem(title)
        let heartbeat = NSMenuItem(title: model.device.heartbeatEnabled ? "后台运行中 · 心跳运行中" : "后台运行中 · 等待设备", action: nil, keyEquivalent: ""); heartbeat.isEnabled = false; menu.addItem(heartbeat)
        menu.addItem(.separator())
        let open = NSMenuItem(title: "打开 Olanzi…", action: #selector(showWindow), keyEquivalent: "o"); open.target = self; menu.addItem(open)
        let connect = NSMenuItem(title: model.device.connected ? "断开设备" : "连接设备", action: #selector(toggleConnection), keyEquivalent: ""); connect.target = self; connect.isEnabled = !model.device.busy; menu.addItem(connect)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Olanzi", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        statusItem.menu = menu
    }
    @objc private func showWindow() {
        if window == nil {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 830),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            created.title = model.demo ? "Olanzi · 演示" : "Olanzi"
            created.titlebarAppearsTransparent = true
            created.backgroundColor = NSColor(calibratedWhite: 0.115, alpha: 1)
            created.contentView = NSHostingView(rootView: ContentView(model: model))
            created.minSize = NSSize(width: 900, height: 740)
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.center()
            window = created
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !stopping else { return true }
        // 红色关闭按钮与 Cmd-W 只隐藏窗口，保留草稿、菜单栏和独立设备线程。
        // 不切换 activationPolicy，让 Dock 图标继续表示 App 仍在运行。
        sender.orderOut(nil)
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    @objc private func toggleConnection() { if model.device.connected { model.disconnect() } else { model.connect() } }
    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func systemWillSleep(_ notification: Notification) { model.suspendForSystemSleep() }
    @objc private func systemDidWake(_ notification: Notification) { model.resumeAfterSystemWake() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !stopping else { return .terminateLater }
        stopping = true
        model.stop { DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) } }
        return .terminateLater
    }
}
