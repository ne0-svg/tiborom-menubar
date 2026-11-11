// 生成 Tiborom 的 App 图标：一枚 16×16 像素番茄，最近邻放大后打 icns。
// 用法：swift Scripts/make-icon.swift   （build.sh 在缺 icns 时自动调用）
import AppKit
import Foundation

// S=蒂 G=叶 R=果身 D=暗部 W=高光 .=空
let art: [String] = [
    ".......SS.......",
    "......SSS.......",
    "....GGGGGG......",
    "...GGGGGGGG.....",
    "..RRRRRRRRRR....",
    ".RRWRRRRRRRRR...",
    ".RWWRRRRRRRRR...",
    ".RWRRRRRRRRRR...",
    ".RRRRRRRRRRRR...",
    ".RRRRRRRRRRRD...",
    ".RRRRRRRRRRDD...",
    "..RRRRRRRRRDD...",
    "...RRRRRRRDD....",
    "....RRRRRDD.....",
    ".....RRRD.......",
    "................",
]

let palette: [Character: NSColor] = [
    "S": NSColor(red: 0.20, green: 0.42, blue: 0.16, alpha: 1),
    "G": NSColor(red: 0.33, green: 0.65, blue: 0.24, alpha: 1),
    "R": NSColor(red: 0.86, green: 0.20, blue: 0.16, alpha: 1),
    "D": NSColor(red: 0.62, green: 0.11, blue: 0.10, alpha: 1),
    "W": NSColor(red: 1.00, green: 0.93, blue: 0.88, alpha: 1),
]

let grid = art.count
let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let buildDir = here.appendingPathComponent("Build")
let iconsetURL = buildDir.appendingPathComponent("Tiborom.iconset")
let icnsURL = here.appendingPathComponent("Resources/AppIcon.icns")
let previewURL = here.appendingPathComponent("Resources/AppIcon-1024.png")
try? FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func pngData(size: Int) -> Data {
    let scale = size / grid
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.shouldAntialias = false
    for (row, line) in art.enumerated() {
        for (col, ch) in line.enumerated() {
            guard let color = palette[ch] else { continue }
            color.setFill()
            NSRect(x: col * scale, y: (grid - 1 - row) * scale,
                   width: scale, height: scale).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let entries: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in entries {
    try! pngData(size: px).write(to: iconsetURL.appendingPathComponent(name))
}
try! pngData(size: 1024).write(to: previewURL)

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try! proc.run()
proc.waitUntilExit()
print("AppIcon.icns 生成完成（像素番茄）")
