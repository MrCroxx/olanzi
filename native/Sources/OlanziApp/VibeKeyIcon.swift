import AppKit

/// 以设备的旋钮和三个纵向按键为识别特征；模板图由系统适配菜单栏明暗。
enum VibeKeyIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            let body = NSBezierPath(roundedRect: NSRect(x: 3.35, y: 0.1, width: 11.3, height: 17.8),
                                    xRadius: 2.85, yRadius: 2.85)
            // 偶奇填充让旋钮和按键真正透明，深浅菜单栏都能透出背景。
            body.windingRule = .evenOdd
            body.append(NSBezierPath(ovalIn: NSRect(x: 6.4, y: 10.9, width: 5.2, height: 5.2)))
            for y in [2.4, 5.1, 7.8] {
                body.append(NSBezierPath(roundedRect: NSRect(x: 6.4, y: y, width: 5.2, height: 1.7),
                                         xRadius: 0.65, yRadius: 0.65))
            }
            body.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Vibe Key"
        return image
    }()
}
