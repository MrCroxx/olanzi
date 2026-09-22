import AppKit
import Combine
import OlanziCore

/// 只在用户主动录制时拦截当前窗口的本地事件；停止后保留已完成步骤供用户确认。
@MainActor
final class MacroRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var steps: [MacroStep] = []
    @Published private(set) var error: String?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var releaseTimer: Timer?
    private weak var window: NSWindow?
    private var session = MacroRecordingSession(recordDelays: false)

    func reset() {
        stop()
        session = MacroRecordingSession(recordDelays: false)
        session.stop()
        steps = []
        error = nil
    }

    func start(window: NSWindow?, recordDelays: Bool) {
        stop()
        session = MacroRecordingSession(recordDelays: recordDelays)
        steps = []
        error = nil
        guard let window, window.isKeyWindow, NSApp.isActive else {
            session.stop()
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
                        self.session.interrupt()
                        self.synchronize()
                    }
                }
            })
        }
        // Command 组合可能漏掉修饰键松开事件；补查聚合状态，不由 function 位猜测物理 Fn。
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshModifierRelease() }
        }
        releaseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        session.stop()
        removeMonitoring()
    }

    private func removeMonitoring() {
        releaseTimer?.invalidate()
        releaseTimer = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        window = nil
        isRecording = false
    }

    private func synchronize() {
        if steps != session.steps { steps = session.steps }
        error = session.error
        if !session.isRecording { removeMonitoring() }
    }

    private func receive(_ event: NSEvent) -> NSEvent? {
        guard isRecording, NSApp.isActive, let window, window.isKeyWindow else {
            session.interrupt()
            synchronize()
            return event
        }
        guard event.window == nil || event.window === window else { return event }
        let flags = UInt64(event.modifierFlags.rawValue)
        switch event.type {
        case .flagsChanged:
            session.receiveFlagsChanged(keyCode: event.keyCode, flags: flags, at: event.timestamp)
        case .keyDown:
            session.receiveKeyDown(keyCode: event.keyCode, flags: flags, isRepeat: event.isARepeat, at: event.timestamp)
        case .keyUp:
            session.receiveKeyUp(keyCode: event.keyCode, flags: flags, at: event.timestamp)
        default: break
        }
        synchronize()
        // 包括 Command-Q、Return、Esc 都进入录制，不交给菜单、文本框或默认按钮。
        return nil
    }

    private func refreshModifierRelease() {
        guard isRecording, NSApp.isActive, window?.isKeyWindow == true, session.hasPendingChord else { return }
        session.receiveFlagsChanged(keyCode: 0, flags: UInt64(NSEvent.modifierFlags.rawValue), at: ProcessInfo.processInfo.systemUptime)
        synchronize()
    }

    deinit {
        releaseTimer?.invalidate()
        if let monitor { NSEvent.removeMonitor(monitor) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
