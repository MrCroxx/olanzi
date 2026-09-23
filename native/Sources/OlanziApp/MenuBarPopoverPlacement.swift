import AppKit

/// 使用全局屏幕坐标，让整个弹窗（含箭头）位于菜单栏和刘海下方。
enum MenuBarPopoverPlacement {
    static func constrainedFrame(_ frame: NSRect, anchor: NSRect, screenFrame: NSRect,
                                 visibleFrame: NSRect, safeTop: CGFloat) -> NSRect {
        let gap: CGFloat = 4
        let top = min(anchor.minY, visibleFrame.maxY, screenFrame.maxY - safeTop) - gap
        var result = frame
        result.origin.y = min(frame.maxY, top) - frame.height
        // 多屏排列时不能使用主屏的坐标；左右边界同样取图标所在屏幕。
        result.origin.x = max(visibleFrame.minX,
                              min(frame.minX, visibleFrame.maxX - frame.width))
        return result
    }
}
