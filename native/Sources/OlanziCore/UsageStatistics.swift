import Foundation

public struct UsageDay: Codable, Equatable, Sendable, Identifiable {
    public let date: Date
    public var keyPresses: Int
    public var knobTurns: Int
    public var activeSeconds: Double
    public var id: Date { date }

    public init(date: Date, keyPresses: Int = 0, knobTurns: Int = 0, activeSeconds: Double = 0) {
        self.date = date
        self.keyPresses = keyPresses
        self.knobTurns = knobTurns
        self.activeSeconds = activeSeconds
    }
}

/// 只保存本地按日聚合，不保存键码、文字或逐次操作时间。
struct UsageStatisticsStore {
    let url: URL
    init(url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Olanzi/usage-statistics.json")) {
        self.url = url
    }
    func load() throws -> [UsageDay] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard data.count <= 128_000 else { throw DeviceProtocolError.message("使用统计文件过大。") }
        let days = try JSONDecoder().decode([UsageDay].self, from: data)
        guard days.count <= 30, Set(days.map(\.date)).count == days.count,
              days.allSatisfy({ $0.keyPresses >= 0 && $0.keyPresses <= 1_000_000_000 &&
                  $0.knobTurns >= 0 && $0.knobTurns <= 1_000_000_000 &&
                  $0.activeSeconds.isFinite && $0.activeSeconds >= 0 && $0.activeSeconds <= 90_000 }) else {
            throw DeviceProtocolError.message("使用统计文件内容无效。")
        }
        return days
    }
    func save(_ days: [UsageDay]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(days).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// 活跃时长是操作后 30 秒窗口的并集，只结算已经过去的时间。
struct UsageStatistics {
    private(set) var days: [UsageDay]
    private var held = Set<Int>()
    private var cursor: Date?
    private var activeUntil: Date?
    private let calendar: Calendar

    init(days: [UsageDay] = [], calendar: Calendar = .current) {
        self.calendar = calendar
        // 时区变化后重新归到本地日期，避免同一天出现两根图柱。
        var grouped: [Date: UsageDay] = [:]
        for value in days {
            let date = calendar.startOfDay(for: value.date)
            var day = grouped[date] ?? UsageDay(date: date)
            day.keyPresses += value.keyPresses
            day.knobTurns += value.knobTurns
            day.activeSeconds = min(90_000, day.activeSeconds + value.activeSeconds)
            grouped[date] = day
        }
        self.days = grouped.values.sorted { $0.date < $1.date }
    }

    mutating func receive(_ event: VendorKeyEvent, at now: Date) {
        guard (0..<6).contains(event.index) else { return }
        advance(to: now)
        if !event.pressed {
            if held.remove(event.index) != nil { activate(at: now) }
            return
        }
        if event.index < 4 {
            guard held.insert(event.index).inserted else { return }
            modifyDay(at: now) { $0.keyPresses += 1 }
        } else {
            // 旋钮每个 down 都是独立脉冲，设备不保证每次都发送 up。
            modifyDay(at: now) { $0.knobTurns += 1 }
        }
        activate(at: now)
    }

    mutating func advance(to now: Date) {
        if let start = cursor, let deadline = activeUntil {
            let end = min(now, deadline)
            var position = start
            while position < end {
                let day = calendar.startOfDay(for: position)
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                let boundary = min(nextDay, end)
                let seconds = boundary.timeIntervalSince(position)
                modifyDay(at: position) { $0.activeSeconds += seconds }
                position = boundary
            }
            // 时钟回拨不能重复计算此前已结算的区间。
            cursor = max(start, now)
            if now >= deadline { activeUntil = nil; cursor = nil }
        }
        let cutoff = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))!
        days.removeAll { $0.date < cutoff || $0.date > now }
        days.sort { $0.date < $1.date }
    }

    mutating func suspend(at now: Date) {
        advance(to: now)
        held.removeAll()
        cursor = nil
        activeUntil = nil
    }

    private mutating func activate(at now: Date) {
        cursor = max(cursor ?? now, now)
        activeUntil = now.addingTimeInterval(30)
    }

    private mutating func modifyDay(at date: Date, _ change: (inout UsageDay) -> Void) {
        let day = calendar.startOfDay(for: date)
        if let index = days.firstIndex(where: { $0.date == day }) { change(&days[index]) }
        else {
            var value = UsageDay(date: day)
            change(&value)
            days.append(value)
        }
    }
}
