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
        case holding(Int)
        case layer(Int)
        case burst
        case completed
    }
    private struct KeyboardJob {
        let id: Int
        let entries: [KeyEntry]
        let count: Int
        let hold: Bool
        let longBurst: Bool
    }
    private struct Playback {
        let job: KeyboardJob
        var down: Bool
        var remaining: Int
        var deadline: TimeInterval
    }
    /// 每控件最多一个执行中动作和十六个待执行动作；满队列丢弃新触发。
    static let maximumQueuedActions = 16
    private var configuration: HostKeymap?
    // 每轮手势固定动作快照，层变化不改写按住、双击等待或连按队列。
    private var snapshots: [Int: ControlActionMap] = [:]
    private var layerOwners: [Int: Int] = [:]
    private var phases: [Int: Phase] = [:]
    private var playback: [Int: Playback] = [:]
    private var queues: [Int: [KeyboardJob]] = [:]
    private var nextJobID = 0
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
        let releases = playback.keys.sorted().compactMap { index in
            playback[index]?.down == true ? GestureTransition.end(index: index) : nil
        }
        phases.removeAll()
        snapshots.removeAll()
        layerOwners.removeAll()
        playback.removeAll()
        queues.removeAll()
        if quarantine { quarantined.formUnion(physicalDown) }
        else { physicalDown.removeAll(); quarantined.removeAll() }
        return releases
    }

    /// 发布失败只取消该控件的后续调度，其它控件的真实按住所有权继续保留。
    mutating func cancel(index: Int) {
        finish(index)
        layerOwners.removeValue(forKey: index)
        playback.removeValue(forKey: index)
        queues.removeValue(forKey: index)
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
            guard let control = snapshots[index] else { continue }
            switch phases[index] {
            case .waiting(let deadline) where time >= deadline:
                finish(index)
                transitions += trigger(index: index, action: control.effectivePress,
                                       behavior: control.pressBehavior, count: control.pressTapCount)
            case .pressing(let start, _) where time >= start + configuration.longPressThreshold:
                guard let action = control.effectiveLongPress else { continue }
                if case .momentaryLayer(let target) = action {
                    layerOwners[index] = target
                    phases[index] = .layer(target)
                } else if case .keyboard(let entries) = action {
                    if control.longPressBehavior == .hold {
                        let result = enqueue(index: index, entries: entries, count: 1, hold: true)
                        phases[index] = result.id.map(Phase.holding) ?? .completed
                        transitions += result.transitions
                    } else {
                        phases[index] = control.longPressBehavior == .burst ? .burst : .completed
                        let result = enqueue(index: index, entries: entries,
                                             count: control.longPressBehavior == .burst ? control.longPressTapCount : 1,
                                             longBurst: control.longPressBehavior == .burst)
                        if result.id == nil { phases[index] = .completed }
                        transitions += result.transitions
                    }
                } else {
                    phases[index] = .completed
                    transitions.append(.execute(index: index, action: action))
                }
            default: break
            }
        }
        // 每次推进最多走一条连按边沿；下一期限相对实际执行时间计算，不追赶积压脉冲。
        for index in playback.keys.sorted() {
            guard var current = playback[index], time >= current.deadline else { continue }
            if current.down {
                transitions.append(.end(index: index))
                if current.remaining == 0 {
                    complete(current.job, index: index)
                    scheduleNext(index: index, at: time + 0.08)
                } else {
                    current.down = false
                    current.deadline = time + 0.08
                    playback[index] = current
                }
            } else {
                transitions.append(.begin(index: index, entries: current.job.entries))
                if current.job.hold {
                    current.down = true
                    current.deadline = .infinity
                    playback[index] = current
                } else if current.job.count == 1 {
                    // 排队的单次短按仍是完整的一组 down/up。
                    transitions.append(.end(index: index))
                    complete(current.job, index: index)
                    scheduleNext(index: index, at: time + 0.08)
                } else {
                    current.down = true
                    current.remaining -= 1
                    current.deadline = time + 0.04
                    playback[index] = current
                }
            }
        }
        return transitions
    }

    mutating func receive(_ event: VendorKeyEvent, at now: TimeInterval) -> [GestureTransition] {
        // 先处理到期动作：恰好在双击截止时的 down 属于下一轮，不能依赖回调顺序。
        var transitions = advance(to: now)
        let time = lastTime
        guard let configuration, (0..<6).contains(event.index) else { return transitions }
        if event.index >= 4 {
            if event.pressed, let control = selectedControl(index: event.index) {
                transitions += trigger(index: event.index, action: control.effectivePress,
                                       behavior: control.pressBehavior, count: control.pressTapCount)
            }
            return transitions
        }
        if event.pressed {
            guard physicalDown.insert(event.index).inserted else { return transitions }
            guard !quarantined.contains(event.index) else { return transitions }
            if case .burst = phases[event.index] {
                // 长按连按不能被重按开启第二轮；切层仍跟随新的物理按住状态。
                if case .momentaryLayer(let target) = snapshots[event.index]?.effectivePress {
                    layerOwners[event.index] = target
                }
                return transitions
            }
            let control: ControlActionMap
            if case .waiting = phases[event.index], let snapshot = snapshots[event.index] {
                control = snapshot
            } else {
                guard let selected = selectedControl(index: event.index) else { return transitions }
                control = selected
                snapshots[event.index] = selected
            }
            if case .momentaryLayer(let target) = control.effectivePress {
                layerOwners[event.index] = target
                phases[event.index] = control.effectiveLongPress == nil
                    ? .layer(target) : .pressing(start: time, second: false)
            } else if control.effectiveDoublePress == nil && control.effectiveLongPress == nil {
                if case .keyboard(let entries) = control.effectivePress, control.pressBehavior == .hold {
                    let result = enqueue(index: event.index, entries: entries, count: 1, hold: true)
                    phases[event.index] = result.id.map(Phase.holding) ?? .completed
                    transitions += result.transitions
                } else {
                    phases[event.index] = .completed
                    transitions += trigger(index: event.index, action: control.effectivePress,
                                           behavior: control.pressBehavior, count: control.pressTapCount)
                }
            } else {
                let second: Bool
                if case .waiting = phases[event.index] { second = true } else { second = false }
                phases[event.index] = .pressing(start: time, second: second)
            }
        } else {
            let wasDown = physicalDown.remove(event.index) != nil
            layerOwners.removeValue(forKey: event.index)
            if quarantined.remove(event.index) != nil { return transitions }
            guard wasDown, let control = snapshots[event.index] else { return transitions }
            switch phases[event.index] {
            case .layer, .completed:
                finish(event.index)
            case .holding(let id):
                finish(event.index)
                transitions += releaseHold(index: event.index, id: id)
            case .pressing(_, let second):
                if second, let action = control.effectiveDoublePress {
                    finish(event.index)
                    transitions += trigger(index: event.index, action: action,
                                           behavior: control.doublePressBehavior, count: control.doublePressTapCount)
                } else if control.effectiveDoublePress != nil {
                    phases[event.index] = .waiting(deadline: time + configuration.doublePressWindow)
                } else {
                    finish(event.index)
                    transitions += trigger(index: event.index, action: control.effectivePress,
                                           behavior: control.pressBehavior, count: control.pressTapCount)
                }
            default: break
            }
        }
        return transitions
    }

    private mutating func trigger(index: Int, action: HostAction,
                                  behavior: LongPressBehavior, count: Int) -> [GestureTransition] {
        if case .momentaryLayer = action { return [] }
        guard case .keyboard(let entries) = action else { return [.execute(index: index, action: action)] }
        // 已松开的单/双击和旋转无法持续保持；旧 hold 设置继续解释为一次短按。
        return enqueue(index: index, entries: entries, count: behavior == .burst ? count : 1).transitions
    }

    private mutating func enqueue(index: Int, entries: [KeyEntry], count: Int, hold: Bool = false,
                                  longBurst: Bool = false) -> (id: Int?, transitions: [GestureTransition]) {
        guard playback[index] == nil || (queues[index]?.count ?? 0) < Self.maximumQueuedActions else { return (nil, []) }
        nextJobID &+= 1
        let job = KeyboardJob(id: nextJobID, entries: entries, count: count, hold: hold, longBurst: longBurst)
        if playback[index] != nil {
            queues[index, default: []].append(job)
            return (job.id, [])
        }
        if !hold && count == 1 {
            return (job.id, [.begin(index: index, entries: entries), .end(index: index)])
        }
        playback[index] = Playback(job: job, down: true, remaining: count - 1,
                                   deadline: hold ? .infinity : lastTime + 0.04)
        return (job.id, [.begin(index: index, entries: entries)])
    }

    private mutating func releaseHold(index: Int, id: Int) -> [GestureTransition] {
        // 排队期间已经松开的 hold 不再启动，不能释放其它动作持有的同一控件。
        if let current = playback[index], current.job.id == id {
            scheduleNext(index: index, at: lastTime + 0.08)
            return current.down ? [.end(index: index)] : []
        }
        queues[index]?.removeAll { $0.id == id }
        return []
    }

    private mutating func complete(_ job: KeyboardJob, index: Int) {
        guard job.longBurst else { return }
        if physicalDown.contains(index) { phases[index] = .completed }
        else { finish(index) }
    }

    private mutating func scheduleNext(index: Int, at deadline: TimeInterval) {
        guard let job = queues[index]?.first else {
            playback.removeValue(forKey: index)
            queues.removeValue(forKey: index)
            return
        }
        queues[index]?.removeFirst()
        playback[index] = Playback(job: job, down: false, remaining: job.count, deadline: deadline)
    }

    private mutating func finish(_ index: Int) {
        phases.removeValue(forKey: index)
        snapshots.removeValue(forKey: index)
    }

    private func selectedControl(index: Int) -> ControlActionMap? {
        guard let configuration else { return nil }
        guard var resolved = configuration.resolvedControl(index: index, activeLayers: Array(layerOwners.values)) else { return nil }
        resolved.pressAction = configuration.resolve(resolved.effectivePress) ?? resolved.effectivePress
        resolved.doublePressAction = configuration.resolve(resolved.effectiveDoublePress) ?? resolved.effectiveDoublePress
        resolved.longPressAction = configuration.resolve(resolved.effectiveLongPress) ?? resolved.effectiveLongPress
        return resolved
    }

    private mutating func monotonic(_ now: TimeInterval) -> TimeInterval {
        if now.isFinite { lastTime = max(lastTime, now) }
        return lastTime
    }
}
