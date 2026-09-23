import AppKit
import SwiftUI
import OlanziCore

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
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private let popover = NSPopover()
    private var stopping = false
    private var menuLanguage: AppLanguage?
    private var menuLocale: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model = AppModel(demo: CommandLine.arguments.contains("--demo"))
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = VibeKeyIcon.image
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.delegate = self
        // 展示前后都校正位置，避免动画经过菜单栏或刘海区域。
        popover.animates = false
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(popoverWindowGeometryChanged(_:)),
                                                   name: name, object: nil)
        }
        popover.contentViewController = NSHostingController(rootView: DriverStatusView(
            model: model, settings: { [weak self] in self?.showHome() },
            quit: { [weak self] in self?.quitApp() }))
        model.didChange = { [weak self] in self?.updateMenu() }
        updateMenu()
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
        updateMenu()
    }
    private func updateMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        let overview = NSMenuItem(title: model.l("设备概览"), action: #selector(togglePopover), keyEquivalent: "d")
        overview.keyEquivalentModifierMask = [.command, .shift]
        overview.target = self; appMenu.addItem(overview)
        let settings = NSMenuItem(title: model.l("设置…"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self; appMenu.addItem(settings); appMenu.addItem(.separator())
        let quit = NSMenuItem(title: model.l("退出 Olanzi"), action: #selector(quitApp), keyEquivalent: "q"); quit.target = self
        appMenu.addItem(quit); appItem.submenu = appMenu; mainMenu.addItem(appItem)
        let editItem = NSMenuItem(title: model.l("编辑"), action: nil, keyEquivalent: ""); let editMenu = NSMenu(title: model.l("编辑"))
        for (title, action, key) in [("撤销", Selector(("undo:")), "z"), ("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(withTitle: model.l(title), action: action, keyEquivalent: key)
        }
        editItem.submenu = editMenu; mainMenu.addItem(editItem); NSApp.mainMenu = mainMenu
        let windowItem = NSMenuItem(title: model.l("窗口"), action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: model.l("窗口"))
        windowMenu.addItem(withTitle: model.l("关闭窗口"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: model.l("最小化"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu; mainMenu.addItem(windowItem); NSApp.windowsMenu = windowMenu
    }
    private func updateMenu() {
        guard let model else { return }
        if menuLanguage != model.language || menuLocale != model.localizer.locale.identifier {
            menuLanguage = model.language
            menuLocale = model.localizer.locale.identifier
            updateMainMenu()
        }
        window?.title = model.demo ? model.l("Olanzi · 演示") : "Olanzi"
        statusItem.button?.toolTip = model.l("Olanzi · 后台设备服务")
        statusItem.button?.setAccessibilityLabel(model.l("Olanzi 后台设备服务"))
    }
    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            model.refreshPermissions()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            constrainPopoverToScreen()
            popover.contentViewController?.view.window?.makeKey()
        }
    }
    func popoverDidShow(_ notification: Notification) {
        constrainPopoverToScreen()
    }
    @objc private func popoverWindowGeometryChanged(_ notification: Notification) {
        guard let changed = notification.object as? NSWindow,
              changed === popover.contentViewController?.view.window else { return }
        constrainPopoverToScreen()
    }
    private func constrainPopoverToScreen() {
        guard popover.isShown, let popupWindow = popover.contentViewController?.view.window,
              let button = statusItem.button, let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) })
                ?? buttonWindow.screen else { return }
        let corrected = MenuBarPopoverPlacement.constrainedFrame(
            popupWindow.frame, anchor: anchor, screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame, safeTop: screen.safeAreaInsets.top)
        // setFrame 会同步发送移动通知；位置相同就不再设置，避免递归。
        if popupWindow.frame != corrected { popupWindow.setFrame(corrected, display: true) }
    }
    private func showHome() {
        model.page = 0
        showWindow()
    }
    @objc private func showSettings() {
        model.page = 1
        showWindow()
    }
    @objc private func showWindow() {
        popover.performClose(nil)
        if window == nil {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 830),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            created.title = model.demo ? model.l("Olanzi · 演示") : "Olanzi"
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
        // 隐藏 Dock 图标，重新打开窗口时由 showWindow 恢复。
        sender.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
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
