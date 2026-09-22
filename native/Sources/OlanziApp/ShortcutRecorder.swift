import AppKit
import Combine
import SwiftUI
import CoreGraphics
import OlanziCore

/// 仅在用户主动录制时拦截所属窗口的本地事件；不安装全局键盘监听。
@MainActor
final class ShortcutRecorder: ObservableObject {
    struct RecordingResult: Equatable {
        let id = UUID()
        let entries: [KeyEntry]
    }
    @Published private(set) var result: RecordingResult?
    @Published private(set) var isRecording = false
    @Published private(set) var candidate: [KeyEntry]?
    @Published private(set) var error: String?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var releaseTimer: Timer?
    private weak var window: NSWindow?
    private var session = ShortcutRecordingSession()
    weak var captureView: NSView?
    private weak var previousResponder: NSResponder?
    private var lastInputAt: TimeInterval = 0

    func reset() {
        stop()
        candidate = nil
        result = nil
        session = ShortcutRecordingSession()
        error = nil
    }

    func start(window: NSWindow?) {
        stop()
        candidate = nil
        result = nil
        session = ShortcutRecordingSession()
        error = nil
        guard let window = captureView?.window ?? window else {
            error = "录制已暂停，请重新录制。"
            return
        }
        self.window = window
        previousResponder = window.firstResponder
        // 显式录制操作负责取得焦点，不能因窗口只是可见而静默拒绝输入。
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let captureView { window.makeFirstResponder(captureView) }
        isRecording = true
        lastInputAt = ProcessInfo.processInfo.systemUptime
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.receive(event)
        }
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSApplication.didResignActiveNotification || note.object as? NSWindow === self.window {
                        self.pause()
                    }
                }
            })
        }
        // Command 组合可能丢失普通键或修饰键的 up；只对已捕获的按住状态补查释放。
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
        if let window, window.firstResponder === captureView, let previousResponder {
            window.makeFirstResponder(previousResponder)
        }
        previousResponder = nil
        window = nil
        isRecording = false
    }

    private func pause() {
        stop()
        candidate = nil
        result = nil
        session = ShortcutRecordingSession()
        error = "录制已暂停，请重新录制。"
    }

    private func receive(_ event: NSEvent) -> NSEvent? {
        // local monitor 只接收本应用事件；窗口归属才是录制边界。
        // 激活标志可晚于实际输入更新，不能据此丢弃已送到录制窗口的事件。
        guard isRecording, let window, window.isVisible else {
            pause()
            return event
        }
        guard event.window == nil || event.window === window else { return event }
        lastInputAt = ProcessInfo.processInfo.systemUptime
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
            if session.isComplete { finish() }
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
        guard isRecording else { return }
        guard window?.isVisible == true else { pause(); return }
        guard !session.candidate.isEmpty,
              ProcessInfo.processInfo.systemUptime - lastInputAt >= 0.1 else { return }
        do {
            let pressed = Set(session.heldKeyCodes.filter {
                CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0))
            })
            try session.reconcileReleasedKeys(pressedKeyCodes: pressed,
                                             flags: UInt64(NSEvent.modifierFlags.rawValue))
            if candidate != session.candidate { candidate = session.candidate }
            if session.isComplete { finish() }
        } catch {
            self.error = error.localizedDescription
            candidate = nil
            stop()
        }
    }

    private func finish() {
        let entries = session.candidate
        stop()
        // 完成结果有独立标识，快速按下/松开也不依赖 SwiftUI 观察到中间的录制状态。
        result = RecordingResult(entries: entries)
    }

    deinit {
        releaseTimer?.invalidate()
        if let monitor { NSEvent.removeMonitor(monitor) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}

/// 将录制焦点绑定到控件所在窗口，避免 NSApp.keyWindow 指向其它窗口或为空。
struct ShortcutRecordingFocus: NSViewRepresentable {
    let recorder: ShortcutRecorder
    final class FocusView: NSView {
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {}
        override func keyUp(with event: NSEvent) {}
    }
    func makeNSView(context: Context) -> FocusView {
        let view = FocusView()
        recorder.captureView = view
        return view
    }
    func updateNSView(_ nsView: FocusView, context: Context) { recorder.captureView = nsView }
}
