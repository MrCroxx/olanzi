import AppKit

// Finder 文件图标存于资源分支；挂载卷另用内嵌的 .VolumeIcon.icns。
guard CommandLine.arguments.count == 3,
      let icon = NSImage(contentsOfFile: CommandLine.arguments[1]),
      NSWorkspace.shared.setIcon(icon, forFile: CommandLine.arguments[2], options: []) else {
    fatalError("Could not set Finder icon. Usage: set-file-icon.swift ICON.icns FILE")
}
