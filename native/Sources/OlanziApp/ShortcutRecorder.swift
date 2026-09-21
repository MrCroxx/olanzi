import AppKit
import Combine
import OlanziCore

/// 仅在用户主动录制且当前窗口获得焦点时拦截本地事件；不安装全局键盘监听。
@MainActor
final class ShortcutRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var candidate: [KeyEntry]?
    @Published private(set) var error: String?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var releaseTimer: Timer?
    private weak var window: NSWindow?
    private var session = ShortcutRecordingSession()

    func reset() {
        stop()
        candidate = nil
        session = ShortcutRecordingSession()
        error = nil
    }

    func start(window: NSWindow?) {
        stop()
        candidate = nil
        session = ShortcutRecordingSession()
        error = nil
        guard let window, window.isKeyWindow, NSApp.isActive else {
            error = "录制已暂停，请重新录制。"
            return
        }
        self.window = window
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.receive(event)
        }
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSApplication.didResignActiveNotification || note.object as? NSWindow === self.window {
                        self.pause()
                    }
                }
            })
        }
        // 部分 Command 组合不会把最后的修饰键松开通知送回窗口。
        // 仅在主动录制期间补查四种修饰键状态，不读取键盘文本，也不据此推断 Fn。
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshModifierRelease() }
        }
        releaseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        releaseTimer?.invalidate()
        releaseTimer = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        window = nil
        isRecording = false
    }

    private func pause() {
        stop()
        candidate = nil
        session = ShortcutRecordingSession()
        error = "录制已暂停，请重新录制。"
    }

    private func receive(_ event: NSEvent) -> NSEvent? {
        guard isRecording, NSApp.isActive, let window, window.isKeyWindow else {
            pause()
            return event
        }
        guard event.window == nil || event.window === window else { return event }
        do {
            let flags = UInt64(event.modifierFlags.rawValue)
            switch event.type {
            case .flagsChanged:
                try session.receiveFlagsChanged(keyCode: event.keyCode, flags: flags)
            case .keyDown:
                try session.receiveKeyDown(keyCode: event.keyCode, flags: flags, isRepeat: event.isARepeat)
            case .keyUp:
                try session.receiveKeyUp(keyCode: event.keyCode, flags: flags)
            default: break
            }
            candidate = session.candidate
            if session.isComplete { stop() }
        } catch {
            // 失败的录制不能悄悄保存之前那一部分；终止并要求重新录制。
            self.error = error.localizedDescription
            candidate = nil
            stop()
        }
        // 包括 Command-Q、Return、Esc，录制时都作为候选键，不交给菜单或按钮。
        return nil
    }

    private func refreshModifierRelease() {
        guard isRecording, NSApp.isActive, window?.isKeyWindow == true else { return }
        guard !session.candidate.isEmpty else { return }
        do {
            try session.receiveFlagsChanged(keyCode: 0, flags: UInt64(NSEvent.modifierFlags.rawValue))
            if candidate != session.candidate { candidate = session.candidate }
            if session.isComplete { stop() }
        } catch {
            self.error = error.localizedDescription
            candidate = nil
            stop()
        }
    }

    deinit {
        releaseTimer?.invalidate()
        if let monitor { NSEvent.removeMonitor(monitor) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
