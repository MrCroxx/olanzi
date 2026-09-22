import Foundation

/// 纯状态机的输出；键盘事件发布、权限与共享修饰键由 VendorKeyBridge 负责。
enum GestureTransition: Equatable {
    case begin(index: Int, entries: [KeyEntry])
    case end(index: Int)
    case execute(index: Int, action: HostAction)
}

/// 单调时间由调用者注入，不读取系统时钟、不访问设备、不发送事件。
struct GestureRouter {
    private enum Phase {
        case pressing(start: TimeInterval, second: Bool)
        case waiting(deadline: TimeInterval)
        case holding
        case burst(down: Bool, remaining: Int, deadline: TimeInterval)
        case completed
    }
    private var configuration: HostKeymap?
    private var resolvedControls: [ControlActionMap] = []
    private var phases: [Int: Phase] = [:]
    private var physicalDown = Set<Int>()
    private var quarantined = Set<Int>()
    private var lastTime: TimeInterval = 0

    mutating func configure(_ configuration: HostKeymap?) -> [GestureTransition] {
        guard self.configuration != configuration else { return [] }
        let releases = cancel()
        self.configuration = configuration
        // 只展开成功保存的配置副本；原配置保留引用，便于识别库内容更新并取消旧宏。
        resolvedControls = configuration?.controls.map { control in
            var resolved = control
            resolved.pressAction = configuration?.resolve(control.effectivePress) ?? control.effectivePress
            resolved.doublePressAction = configuration?.resolve(control.effectiveDoublePress) ?? control.effectiveDoublePress
            resolved.longPressAction = configuration?.resolve(control.effectiveLongPress) ?? control.effectiveLongPress
            return resolved
        } ?? []
        return releases
    }

    /// 配置切换、撤权期间仍按住的物理键必须先松开，才接受新动作。
    mutating func cancel(quarantine: Bool = true) -> [GestureTransition] {
        let releases = phases.keys.sorted().compactMap { index -> GestureTransition? in
            switch phases[index] {
            case .holding, .burst(down: true, remaining: _, deadline: _): return .end(index: index)
            default: return nil
            }
        }
        phases.removeAll()
        if quarantine { quarantined.formUnion(physicalDown) }
        else { physicalDown.removeAll(); quarantined.removeAll() }
        return releases
    }

    /// 发布失败只取消该控件的后续调度，其它控件的真实按住所有权继续保留。
    mutating func cancel(index: Int) {
        phases.removeValue(forKey: index)
        if physicalDown.contains(index) { quarantined.insert(index) }
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
            guard let control = resolvedControls.first(where: { $0.index == index }) else { continue }
            switch phases[index] {
            case .waiting(let deadline) where time >= deadline:
                phases.removeValue(forKey: index)
                transitions += pulse(index: index, action: control.effectivePress)
            case .pressing(let start, _) where time >= start + configuration.longPressThreshold:
                if let action = control.effectiveLongPress {
                    guard case .keyboard(let entries) = action else {
                        phases[index] = .completed
                        transitions.append(.execute(index: index, action: action))
                        continue
                    }
                    switch control.longPressBehavior {
                    case .tap:
                        // 已完成的长按仍等待物理松开，重复报文和后续时钟不能重触发。
                        phases[index] = .completed
                        transitions += pulse(index: index, action: action)
                    case .hold:
                        phases[index] = .holding
                        transitions.append(.begin(index: index, entries: entries))
                    case .burst:
                        phases[index] = .burst(down: true, remaining: control.longPressTapCount - 1,
                                               deadline: time + 0.04)
                        transitions.append(.begin(index: index, entries: entries))
                    }
                }
            case .burst(let down, let remaining, let deadline) where time >= deadline:
                // 每次推进仅产生一个边沿，下一期限相对实际执行时间计算；不追赶补发积压脉冲。
                if down {
                    transitions.append(.end(index: index))
                    if remaining == 0 {
                        if physicalDown.contains(index) { phases[index] = .completed }
                        else { phases.removeValue(forKey: index) }
                    } else {
                        phases[index] = .burst(down: false, remaining: remaining, deadline: time + 0.08)
                    }
                } else if case .keyboard(let action) = control.effectiveLongPress {
                    phases[index] = .burst(down: true, remaining: remaining - 1, deadline: time + 0.04)
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
              let control = resolvedControls.first(where: { $0.index == event.index }) else { return transitions }
        if event.index >= 4 {
            if event.pressed { transitions += pulse(index: event.index, action: control.effectivePress) }
            return transitions
        }
        if event.pressed {
            guard physicalDown.insert(event.index).inserted else { return transitions }
            guard !quarantined.contains(event.index) else { return transitions }
            // 连按期间的新物理按下只更新按住状态，不另开一组或覆盖队列。
            if case .burst = phases[event.index] { return transitions }
            if control.effectiveDoublePress == nil && control.effectiveLongPress == nil {
                if case .keyboard(let entries) = control.effectivePress {
                    phases[event.index] = .holding
                    transitions.append(.begin(index: event.index, entries: entries))
                } else {
                    phases[event.index] = .completed
                    transitions.append(.execute(index: event.index, action: control.effectivePress))
                }
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
            case .completed:
                phases.removeValue(forKey: event.index)
            case .pressing(_, let second):
                if second, let action = control.effectiveDoublePress {
                    // 第二次长按已由 advance 转入 holding 或 completed，不会再补双击或单击。
                    phases.removeValue(forKey: event.index)
                    transitions += pulse(index: event.index, action: action)
                } else if control.effectiveDoublePress != nil {
                    phases[event.index] = .waiting(deadline: time + configuration.doublePressWindow)
                } else {
                    phases.removeValue(forKey: event.index)
                    transitions += pulse(index: event.index, action: control.effectivePress)
                }
            default: break
            }
        }
        return transitions
    }

    private func pulse(index: Int, action: HostAction) -> [GestureTransition] {
        if case .keyboard(let entries) = action {
            return [.begin(index: index, entries: entries), .end(index: index)]
        }
        return [.execute(index: index, action: action)]
    }

    private mutating func monotonic(_ now: TimeInterval) -> TimeInterval {
        // 系统单调时钟不会回退；测试或替身输入回退时也不能重新打开已到期窗口。
        if now.isFinite { lastTime = max(lastTime, now) }
        return lastTime
    }
}
