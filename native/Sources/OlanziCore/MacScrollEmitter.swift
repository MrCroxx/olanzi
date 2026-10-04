import CoreGraphics
import Foundation

public enum MacScrollEmitterError: LocalizedError, Equatable {
    case invalidAmount, sourceUnavailable, eventUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidAmount: return "每次滚动应为 1–600 像素，不能为零。"
        case .sourceUnavailable: return "无法创建 macOS 滚动事件源。"
        case .eventUnavailable: return "无法创建 macOS 滚动事件。"
        }
    }
}

/// 按每格旋转发布一个垂直像素滚动事件；正值向上，负值向下。
public final class MacScrollEmitter {
    private let sourceFactory: () -> CGEventSource?
    private let eventFactory: (CGEventSource, Int32) -> CGEvent?
    private let post: (CGEvent) throws -> Void
    private var source: CGEventSource?

    public convenience init() {
        self.init(post: { $0.post(tap: .cghidEventTap) })
    }

    // 测试替换发布器，不向桌面发送事件。
    init(sourceFactory: @escaping () -> CGEventSource? = { CGEventSource(stateID: .privateState) },
         eventFactory: @escaping (CGEventSource, Int32) -> CGEvent? = {
             CGEvent(scrollWheelEvent2Source: $0, units: .pixel, wheelCount: 1, wheel1: $1, wheel2: 0, wheel3: 0)
         }, post: @escaping (CGEvent) throws -> Void) {
        self.sourceFactory = sourceFactory
        self.eventFactory = eventFactory
        self.post = post
    }

    public static func validate(vertical: Int) throws {
        guard (-600...600).contains(vertical), vertical != 0 else {
            throw MacScrollEmitterError.invalidAmount
        }
    }

    public func emit(vertical: Int) throws {
        try Self.validate(vertical: vertical)
        if source == nil { source = sourceFactory() }
        guard let source else { throw MacScrollEmitterError.sourceUnavailable }
        guard let event = eventFactory(source, Int32(vertical)) else {
            throw MacScrollEmitterError.eventUnavailable
        }
        // 不把听写的 Ctrl/Option/Shift 或真实修饰键带入滚动，避免缩放或横向滚动。
        // 这里只设置本次事件的旗标，不改变键盘控件的按住所有权。
        event.flags = []
        try post(event)
    }
}
