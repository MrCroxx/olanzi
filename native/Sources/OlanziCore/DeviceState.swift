import Foundation

public struct KeyEntry: Codable, Equatable, Sendable {
    public let type: UInt8
    public let code: UInt8
    public init(type: UInt8 = 2, code: UInt8) { self.type = type; self.code = code }
}

public struct KeyBinding: Codable, Equatable, Identifiable, Sendable {
    public let index: Int
    public var entries: [KeyEntry]
    public var id: Int { index }
    public var code: UInt8? { entries.count == 1 && entries[0].type == 2 ? entries[0].code : nil }
    public init(index: Int, entries: [KeyEntry]) { self.index = index; self.entries = entries }
}

public struct KeyChange: Sendable {
    public let index: Int
    public let code: UInt8
    public init(index: Int, code: UInt8) { self.index = index; self.code = code }
}

public struct HostSaveResult: Equatable, Sendable {
    public let requestID: UUID
    public let error: String?
    public init(requestID: UUID, error: String? = nil) {
        self.requestID = requestID
        self.error = error
    }
}

public struct DeviceBattery: Equatable, Sendable {
    public let millivolts: Int
    public let percentage: Int?
    public let isCharging: Bool?

    public init(millivolts: Int, percentage: Int?, isCharging: Bool? = nil) {
        self.millivolts = millivolts
        self.percentage = percentage
        self.isCharging = isCharging
    }
}

public struct DeviceSnapshot: Equatable, Sendable {
    public var connected = false
    public var online: Bool? = nil
    public var demo = false
    public var keys: [KeyBinding] = []
    public var hostKeymap: HostKeymap? = nil
    public var hostConfigurationMissing = false
    public var hostSaveResult: HostSaveResult? = nil
    public var heartbeatPausedForInactivity = false
    public var controlHandoffFailed = false
    public var heartbeatEnabled = false
    public var lastHeartbeat: Date? = nil
    public var lastRead: Date? = nil
    public var battery: DeviceBattery? = nil
    public var batteryUpdatedAt: Date? = nil
    public var batteryError: String? = nil
    public var error: String? = nil
    public var usageDays: [UsageDay] = []
    public var usageError: String? = nil
    public var busy = false
    public var fn = FnStatus()
    public init() {}
}
