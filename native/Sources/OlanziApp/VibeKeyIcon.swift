import AppKit

/// 以设备的旋钮和三个纵向按键为识别特征；模板图由系统适配菜单栏明暗。
enum VibeKeyIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let body = NSBezierPath(roundedRect: NSRect(x: 4, y: 0.75, width: 10, height: 16.5),
                                    xRadius: 2.2, yRadius: 2.2)
            body.lineWidth = 1.3
            body.stroke()

            let knob = NSBezierPath(ovalIn: NSRect(x: 6.75, y: 11.2, width: 4.5, height: 4.5))
            knob.lineWidth = 1.2
            knob.stroke()
            for y in [2.6, 5.3, 8.0] {
                NSBezierPath(roundedRect: NSRect(x: 6.6, y: y, width: 4.8, height: 1.5),
                             xRadius: 0.6, yRadius: 0.6).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Vibe Key"
        return image
    }()
}
