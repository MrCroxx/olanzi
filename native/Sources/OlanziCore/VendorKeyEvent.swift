import Foundation

/// Studio 在线模式通过厂商通道报告物理控件，而不是标准 HID 键码。
struct VendorKeyEvent: Equatable, Sendable {
    let index: Int
    let pressed: Bool

    static func decode(_ frame: [UInt8]) -> VendorKeyEvent? {
        guard frame.count >= 5, frame[0] & 0x1f == 0x0b, frame[1] == 0x10,
              frame[3] <= 1, frame[4] < 6 else { return nil }
        // AU05 在 Studio 中使用 isSwitchKeyIndex；[2] 是逻辑动作号，不能作键码。
        return VendorKeyEvent(index: Int(frame[4]), pressed: frame[3] == 1)
    }
}
