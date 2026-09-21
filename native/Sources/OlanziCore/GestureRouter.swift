import Foundation

/// 纯状态机的输出；键盘事件发布、权限与共享修饰键由 VendorKeyBridge 负责。
enum GestureTransition: Equatable {
    case begin(index: Int, entries: [KeyEntry])
    case end(index: Int)
}

/// 单调时间由调用者注入，不读取系统时钟、不访问设备、不发送事件。
struct GestureRouter {
    private enum Phase {
        case pressing(start: TimeInterval, second: Bool)
        case waiting(deadline: TimeInterval)
        case holding
    }
    private var configuration: HostKeymap?
    private var phases: [Int: Phase] = [:]
    private var physicalDown = Set<Int>()
    private var quarantined = Set<Int>()
    private var lastTime: TimeInterval = 0

    mutating func configure(_ configuration: HostKeymap?) -> [GestureTransition] {
        guard self.configuration != configuration else { return [] }
        let releases = cancel()
        self.configuration = configuration
        return releases
    }

    /// 配置切换、撤权期间仍按住的物理键必须先松开，才接受新动作。
    mutating func cancel(quarantine: Bool = true) -> [GestureTransition] {
        let releases = phases.keys.sorted().compactMap { index -> GestureTransition? in
            guard case .holding = phases[index] else { return nil }
            return .end(index: index)
        }
        phases.removeAll()
        if quarantine { quarantined.formUnion(physicalDown) }
        else { physicalDown.removeAll(); quarantined.removeAll() }
        return releases
    }

    mutating func observeWhileSuspended(_ event: VendorKeyEvent) {
        guard (0..<4).contains(event.index) else { return }
        if event.pressed { physicalDown.insert(event.index); quarantined.insert(event.index) }
        else { physicalDown.remove(event.index); quarantined.remove(event.index) }
    }

    mutating func advance(to now: TimeInterval) -> [GestureTransition] {
        let time = monotonic(now)
        guard let configuration else { return [] }
        var transitions: [GestureTransition] = []
        for index in phases.keys.sorted() {
            guard let control = configuration.controls.first(where: { $0.index == index }) else { continue }
            switch phases[index] {
            case .waiting(let deadline) where time >= deadline:
                phases.removeValue(forKey: index)
                transitions += pulse(index: index, entries: control.press)
            case .pressing(let start, _) where time >= start + configuration.longPressThreshold:
                if let action = control.longPress {
                    phases[index] = .holding
                    transitions.append(.begin(index: index, entries: action))
                }
            default: break
            }
        }
        return transitions
    }

    mutating func receive(_ event: VendorKeyEvent, at now: TimeInterval) -> [GestureTransition] {
        // 先处理到期动作：恰好在双击截止时的 down 属于下一轮，不能依赖回调顺序。
        var transitions = advance(to: now)
        let time = lastTime
        guard let configuration,
              let control = configuration.controls.first(where: { $0.index == event.index }) else { return transitions }
        if event.index >= 4 {
            if event.pressed { transitions += pulse(index: event.index, entries: control.press) }
            return transitions
        }
        if event.pressed {
            guard physicalDown.insert(event.index).inserted else { return transitions }
            guard !quarantined.contains(event.index) else { return transitions }
            if control.doublePress == nil && control.longPress == nil {
                phases[event.index] = .holding
                transitions.append(.begin(index: event.index, entries: control.press))
            } else {
                let second: Bool
                if case .waiting = phases[event.index] { second = true } else { second = false }
                phases[event.index] = .pressing(start: time, second: second)
            }
        } else {
            let wasDown = physicalDown.remove(event.index) != nil
            if quarantined.remove(event.index) != nil { return transitions }
            guard wasDown else { return transitions }
            switch phases[event.index] {
            case .holding:
                phases.removeValue(forKey: event.index)
                transitions.append(.end(index: event.index))
            case .pressing(_, let second):
                if second, let action = control.doublePress {
                    // 第二次长按已由 advance 转入 holding，因此不会再补双击或单击。
                    phases.removeValue(forKey: event.index)
                    transitions += pulse(index: event.index, entries: action)
                } else if control.doublePress != nil {
                    phases[event.index] = .waiting(deadline: time + configuration.doublePressWindow)
                } else {
                    phases.removeValue(forKey: event.index)
                    transitions += pulse(index: event.index, entries: control.press)
                }
            default: break
            }
        }
        return transitions
    }

    private func pulse(index: Int, entries: [KeyEntry]) -> [GestureTransition] {
        [.begin(index: index, entries: entries), .end(index: index)]
    }

    private mutating func monotonic(_ now: TimeInterval) -> TimeInterval {
        // 系统单调时钟不会回退；测试或替身输入回退时也不能重新打开已到期窗口。
        if now.isFinite { lastTime = max(lastTime, now) }
        return lastTime
    }
}
