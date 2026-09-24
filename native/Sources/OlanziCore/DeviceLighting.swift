import Foundation

public struct IndicatorLight: Equatable, Sendable {
    public var type: UInt8
    public var workTime: UInt8
    public var breatheLevel: UInt8
    public var breatheBrightness: UInt8
    public var alwaysOnBrightness: UInt8
    public init(type: UInt8, workTime: UInt8, breatheLevel: UInt8, breatheBrightness: UInt8, alwaysOnBrightness: UInt8) {
        self.type = type; self.workTime = workTime; self.breatheLevel = breatheLevel
        self.breatheBrightness = breatheBrightness; self.alwaysOnBrightness = alwaysOnBrightness
    }
    var bytes: [UInt8] { [type, workTime, breatheLevel, breatheBrightness, alwaysOnBrightness] }
}

public struct DeviceLighting: Equatable, Sendable {
    public var mode: UInt8
    public var brightness: UInt8
    public var lights: [IndicatorLight]
    /// 返回读回仍不一致的字段，避免把一次局部失败描述成整个设备离线。
    public func differingFields(from actual: DeviceLighting, ignoringKnobBrightness: Bool = false) -> [String] {
        var fields: [String] = []
        if mode != actual.mode { fields.append("灯光模式") }
        if brightness != actual.brightness { fields.append("全亮亮度") }
        guard lights.count == 4, actual.lights.count == 4 else { return fields + ["灯效配置"] }
        for index in 0..<4 {
            let name = index == 3 ? "旋钮" : "键 \(index + 1)"
            let desired = lights[index], read = actual.lights[index]
            if desired.type != read.type { fields.append(name + "灯光效果") }
            if desired.workTime != read.workTime { fields.append(name + "工作时长") }
            if desired.breatheLevel != read.breatheLevel { fields.append(name + "呼吸参数") }
            if desired.breatheBrightness != read.breatheBrightness { fields.append(name + "呼吸亮度") }
            if !(ignoringKnobBrightness && index == 3), desired.alwaysOnBrightness != read.alwaysOnBrightness { fields.append(name + "常亮亮度") }
        }
        return fields
    }

    public init(mode: UInt8, brightness: UInt8, lights: [IndicatorLight]) {
        self.mode = mode; self.brightness = brightness; self.lights = lights
    }
}

extension DeviceProtocol {
    public static let lightingRequest: [UInt8] = [1, 0x0B, 0x88, 1]

    public static func matchesLightingReply(_ frame: [UInt8]) -> Bool {
        frame.count >= 4 && frame[0] & 0x1F == 1 && Array(frame[1...3]) == [0x0B, 0x88, 0x11]
    }

    public static func matchesLightingWriteReply(_ frame: [UInt8], request: [UInt8]) -> Bool {
        guard frame.count >= 28, request.count >= 28,
              frame[0] & 0x1F == 1, Array(frame[1...3]) == [0x0B, 0x88, 0x14],
              frame[4] == request[4], frame[5] == request[5], request[5] < 4 else { return false }
        let base = 8 + 5 * Int(request[5])
        let offset: Int
        switch request[4] {
        case 1: offset = 6
        case 2: offset = 7
        case 4: offset = base
        case 0x20: offset = base + 3
        case 0x40: offset = base + 4
        default: return false
        }
        return frame[offset] == request[offset]
    }

    public static func parseLighting(_ frame: [UInt8]) throws -> DeviceLighting {
        guard matchesLightingReply(frame), frame.count >= 28 else { throw DeviceProtocolError.invalidFrame }
        // 保留未知固件字段值；只在用户修改的字段上限制写入范围。
        return DeviceLighting(mode: frame[6], brightness: frame[7], lights: (0..<4).map {
            let base = 8 + 5 * $0
            return IndicatorLight(type: frame[base], workTime: frame[base + 1], breatheLevel: frame[base + 2],
                                  breatheBrightness: frame[base + 3], alwaysOnBrightness: frame[base + 4])
        })
    }

    public static func lightingWrites(_ desired: DeviceLighting, expected: DeviceLighting, setKnobBrightness: Bool = false) throws -> [[UInt8]] {
        guard desired.lights.count == 4, expected.lights.count == 4 else { throw DeviceProtocolError.invalidFrame }
        var writes: [[UInt8]] = []
        func frame(mask: UInt8, focus: Int = 0) -> [UInt8] {
            // 每条命令携带完整四灯记录，避免固件清空未填槽；mask 只选择本次修改字段。
            [1, 0x0B, 0x88, 4, mask, UInt8(focus), desired.mode, desired.brightness]
                + desired.lights.flatMap(\.bytes)
        }
        if desired.mode != expected.mode {
            guard desired.mode <= 2 else { throw DeviceProtocolError.invalidFrame }
            writes.append(frame(mask: 1))
        }
        if desired.brightness != expected.brightness {
            guard desired.brightness <= 20 else { throw DeviceProtocolError.invalidFrame }
            writes.append(frame(mask: 2))
        }
        for index in 0..<4 {
            let old = expected.lights[index], new = desired.lights[index]
            guard old.workTime == new.workTime, old.breatheLevel == new.breatheLevel else {
                throw DeviceProtocolError.invalidFrame
            }
            // Studio 的灯效滑块直接传递 0...20 原始档位，不按百分比换算。
            if new.breatheBrightness != old.breatheBrightness {
                guard new.breatheBrightness <= 20 else { throw DeviceProtocolError.invalidFrame }
                writes.append(frame(mask: 0x20, focus: index))
            }
            if new.alwaysOnBrightness != old.alwaysOnBrightness || (setKnobBrightness && index == 3) {
                guard new.alwaysOnBrightness <= 20 else { throw DeviceProtocolError.invalidFrame }
                writes.append(frame(mask: 0x40, focus: index))
            }
            if new.type != old.type {
                guard new.type <= 1 || (index == 0 && new.type == 2) else { throw DeviceProtocolError.invalidFrame }
                writes.append(frame(mask: 4, focus: index))
            }
        }
        return writes
    }
}
