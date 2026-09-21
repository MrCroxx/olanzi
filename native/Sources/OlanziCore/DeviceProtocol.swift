import Foundation

public enum DeviceProtocolError: Error, LocalizedError, Equatable {
    case invalidFrame
    case invalidEntries
    case invalidControl
    case unsupportedKey
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFrame: return "设备报文格式无效。"
        case .invalidEntries: return "按键配置回复不完整或格式无效。"
        case .invalidControl: return "只能修改设备上的六个控件。"
        case .unsupportedKey: return "此键码尚未支持。"
        case .message(let message): return message
        }
    }
}

/// 已确认的 AU05 协议；不包含待验证的亮度、OTA 等写命令。
public enum DeviceProtocol {
    public static let vendorID = 0xFFF1
    public static let productID = 0x00DD
    public static let vendorUsagePage = 0xFFFC
    public static let reportID: UInt8 = 0x55
    public static let defaultCodes: [UInt8] = [0x01, 0x28, 0x29, 0x46, 0x4F, 0x2A]
    public static let heartbeat: [UInt8] = [0x06, 0x01, 0x23, 0x00, 0x01]
    public static let onlineRequest: [UInt8] = [0x06, 0x03, 0x0A, 0x01]
    public static let batteryRequest: [UInt8] = [0x01, 0x01, 0x02, 0x01]
    private static let key: [UInt32] = [0xCAA5BACA, 0xBC2A8A6D, 0xCA5A9EBA, 0x9BB88BCA]
    private static let delta: UInt32 = 0x9E3779B9

    public static func isAllowedKey(_ code: UInt8) -> Bool {
        code == 0 || code == 1 || (0x04...0x63).contains(code) || code == 0x65
            || (0x68...0x73).contains(code) || (0xE0...0xE7).contains(code)
    }

    /// 分组按小端字节序解释，所有加减都显式采用 UInt32 溢出语义。
    public static func teaEncrypt(_ bytes: [UInt8]) -> [UInt8] { tea(bytes, decrypt: false) }
    public static func teaDecrypt(_ bytes: [UInt8]) -> [UInt8] { tea(bytes, decrypt: true) }

    private static func tea(_ bytes: [UInt8], decrypt: Bool) -> [UInt8] {
        var output = bytes
        for offset in stride(from: 0, to: bytes.count - bytes.count % 8, by: 8) {
            var left = word(bytes, offset)
            var right = word(bytes, offset + 4)
            var sum: UInt32 = decrypt ? 0xC6EF3720 : 0
            for _ in 0..<32 {
                if decrypt {
                    right = right &- (((left << 4) &+ key[2]) ^ (left &+ sum) ^ ((left >> 5) &+ key[3]))
                    left = left &- (((right << 4) &+ key[0]) ^ (right &+ sum) ^ ((right >> 5) &+ key[1]))
                    sum = sum &- delta
                } else {
                    sum = sum &+ delta
                    left = left &+ (((right << 4) &+ key[0]) ^ (right &+ sum) ^ ((right >> 5) &+ key[1]))
                    right = right &+ (((left << 4) &+ key[2]) ^ (left &+ sum) ^ ((left >> 5) &+ key[3]))
                }
            }
            for index in 0..<4 {
                output[offset + index] = UInt8(truncatingIfNeeded: left >> (index * 8))
                output[offset + 4 + index] = UInt8(truncatingIfNeeded: right >> (index * 8))
            }
        }
        return output
    }

    private static func word(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
    }

    public static func encodeReport(_ request: [UInt8]) throws -> [UInt8] {
        guard request.count <= 64 else { throw DeviceProtocolError.invalidFrame }
        let plaintext = request + Array(repeating: 0, count: 64 - request.count)
        return [reportID] + teaEncrypt(plaintext).prefix(63)
    }

    /// 只解密完整的七个分组，绝不把最后七个填充字节作为协议字段。
    public static func decodeReport(reportID id: UInt32, bytes: [UInt8]) -> [UInt8]? {
        guard id == UInt32(reportID) else { return nil }
        let payload: [UInt8]
        if bytes.count == 64, bytes[0] == reportID { payload = Array(bytes.dropFirst()) }
        else if bytes.count == 63 { payload = bytes }
        else { return nil }
        return teaDecrypt(Array(payload.prefix(56)))
    }

    public static func readRequest(index: Int) throws -> [UInt8] {
        guard (0..<6).contains(index) else { throw DeviceProtocolError.invalidControl }
        return [0x01, 0x06, 0x50, 0x01, UInt8(index)]
    }

    public static func writeRequest(index: Int, entries: [[UInt8]]) throws -> [UInt8] {
        guard (0..<6).contains(index) else { throw DeviceProtocolError.invalidControl }
        guard entries.count == 1, entries[0].count == 2, entries[0][0] == 0x02 else {
            throw DeviceProtocolError.invalidEntries
        }
        guard isAllowedKey(entries[0][1]) else { throw DeviceProtocolError.unsupportedKey }
        return [0x01, 0x06, 0x50, 0x04, UInt8(index), 0x01, 0x01] + entries[0]
    }

    public static func matchesReply(_ frame: [UInt8], access: UInt8, index: Int) -> Bool {
        frame.count >= 5 && frame[0] & 0x1F == 1 && frame[1] == 6
            && frame[2] == 0x50 && frame[3] == access && Int(frame[4]) == index
    }

    public static func parseEntries(_ frame: [UInt8]) throws -> [[UInt8]] {
        guard frame.count >= 7, frame[5] == 1 else { throw DeviceProtocolError.invalidEntries }
        let count = Int(frame[6])
        guard count <= 24, 7 + count * 2 <= frame.count else { throw DeviceProtocolError.invalidEntries }
        return (0..<count).map { [frame[7 + $0 * 2], frame[8 + $0 * 2]] }
    }

    public static func matchesOnlineReply(_ frame: [UInt8]) -> Bool {
        frame.count >= 5 && frame[0] & 0x1F == 6 && Array(frame[1...3]) == [3, 0x0A, 0x11]
    }

    public static func parseOnline(_ frame: [UInt8]) throws -> Bool {
        guard matchesOnlineReply(frame), frame[4] <= 1 else { throw DeviceProtocolError.invalidFrame }
        return frame[4] == 1
    }

    public static func matchesBatteryReply(_ frame: [UInt8]) -> Bool {
        frame.count >= 4 && frame[0] & 0x1F == 1 && Array(frame[1...3]) == [1, 2, 0x11]
    }

    /// Studio 的解析器将电压、电量分别读作小端 UInt16，充电状态位于整帧偏移 10。
    /// 只接受确认过的范围；不把未知值夹成满电，也不猜测其余状态位。
    public static func parseBattery(_ frame: [UInt8]) throws -> DeviceBattery {
        guard matchesBatteryReply(frame), frame.count >= 8 else { throw DeviceProtocolError.invalidFrame }
        let millivolts = Int(frame[4]) | Int(frame[5]) << 8
        guard millivolts != 0xFFFF else { throw DeviceProtocolError.invalidFrame }
        let level = Int(frame[6]) | Int(frame[7]) << 8
        let charging: Bool? = frame.count > 10 && frame[10] <= 1 ? frame[10] == 1 : nil
        return DeviceBattery(millivolts: millivolts, percentage: level <= 100 ? level : nil,
                             isCharging: charging)
    }
}
