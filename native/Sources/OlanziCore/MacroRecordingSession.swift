import Foundation

/// 连续录制状态只接收调用者提供的事件；不监听键盘，不发送事件，也不访问系统时钟。
public struct MacroRecordingSession {
    public private(set) var steps: [MacroStep] = []
    public private(set) var isRecording = true
    public private(set) var error: String?
    public var hasPendingChord: Bool { !chord.candidate.isEmpty }

    private let recordDelays: Bool
    private var chord = ShortcutRecordingSession()
    private var previousRelease: TimeInterval?
    private var pendingDelay: TimeInterval?

    public init(recordDelays: Bool) { self.recordDelays = recordDelays }

    public mutating func receiveKeyDown(keyCode: UInt16, flags: UInt64,
                                        isRepeat: Bool = false, at time: TimeInterval) {
        guard !isRepeat else { return }
        receive(at: time) { try $0.receiveKeyDown(keyCode: keyCode, flags: flags) }
    }

    public mutating func receiveKeyUp(keyCode: UInt16, flags: UInt64, at time: TimeInterval) {
        receive(at: time) { try $0.receiveKeyUp(keyCode: keyCode, flags: flags) }
    }

    public mutating func receiveFlagsChanged(keyCode: UInt16, flags: UInt64, at time: TimeInterval) {
        receive(at: time) { try $0.receiveFlagsChanged(keyCode: keyCode, flags: flags) }
    }

    /// 手动停止或离开界面时，只舍弃当前尚未完全松开的组合。
    public mutating func stop() {
        isRecording = false
        chord = ShortcutRecordingSession()
        pendingDelay = nil
    }

    public mutating func interrupt() {
        guard isRecording else { return }
        fail("录制因窗口失去焦点而停止，已完成的步骤已保留。")
    }

    private mutating func fail(_ message: String) {
        error = message
        stop()
    }

    private mutating func receive(at time: TimeInterval,
                                   _ update: (inout ShortcutRecordingSession) throws -> Void) {
        guard isRecording else { return }
        guard time.isFinite else { fail("录制时间无效，已停止并保留完成的步骤。"); return }
        var next = chord
        do { try update(&next) }
        catch { fail(error.localizedDescription); return }
        if chord.candidate.isEmpty && !next.candidate.isEmpty {
            // 等待从上一组完全松开到下一组首次按下；首组不记录启动等待。
            if recordDelays, let previousRelease {
                let interval = max(0, time - previousRelease)
                guard interval <= 10 else {
                    fail("两次按键的间隔超过 10 秒，录制已停止；已完成的步骤已保留。")
                    return
                }
                // 使用毫秒精度，保证录制结果能导出为 QMK wait_ms；短于 50 ms 的间隔省略。
                pendingDelay = interval >= 0.05 ? (interval * 1000).rounded() / 1000 : nil
            }
            let required = pendingDelay == nil ? 1 : 2
            guard steps.count + required <= 32 else {
                fail("宏最多包含 32 个步骤，剩余空间不足以记录下一组按键和间隔。")
                return
            }
        }
        chord = next
        guard chord.isComplete else { return }
        // keyboard 和它前面的 delay 一起提交，未完成的组合永远不留下孤立 delay。
        if let pendingDelay { steps.append(.delay(pendingDelay)) }
        steps.append(.keyboard(chord.candidate))
        previousRelease = time
        self.pendingDelay = nil
        chord = ShortcutRecordingSession()
        if steps.count == 32 { fail("已达到 32 个步骤，录制已停止。") }
    }
}
