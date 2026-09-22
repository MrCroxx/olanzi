import Foundation

/// 只统计设备物理操作；轮询、心跳和主机合成按键不能延长空闲期限。
struct HeartbeatIdleTimer {
    private(set) var timeout: TimeInterval?
    private var lastActivity: TimeInterval = 0
    private var held = Set<Int>()

    mutating func configure(timeout: TimeInterval?, at now: TimeInterval) {
        self.timeout = timeout.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        lastActivity = now
    }

    var hasHeldControls: Bool { !held.isEmpty }

    mutating func restart(at now: TimeInterval) { lastActivity = now }

    mutating func reset(at now: TimeInterval) {
        lastActivity = now
        held.removeAll()
    }

    mutating func receive(_ event: VendorKeyEvent, at now: TimeInterval) {
        guard (0..<6).contains(event.index) else { return }
        if event.pressed {
            lastActivity = now
            if event.index < 4 { held.insert(event.index) }
        } else if held.remove(event.index) != nil {
            // 持续按住也属于操作，从松开后开始计算完整的空闲时间。
            lastActivity = now
        }
    }

    func expired(at now: TimeInterval) -> Bool {
        guard let timeout, held.isEmpty else { return false }
        return now - lastActivity >= timeout
    }
}
