import AppKit

/// 8-bit 像素图标，9×9 网格 ×2 倍 = 18pt，像素整数对齐所以边缘是硬的。
/// 渲染成模板图：浅色菜单栏显示为黑、深色菜单栏显示为白，点击高亮自动反相。
enum PixelIcon {

    /// 像素番茄：顶部叶蒂，左上一格高光（留空当反光）
    static let tomato = make(tomatoArt)

    /// 像素咖啡杯：杯口热气，右侧实心把手
    static let coffee = make(coffeeArt)

    static let tomatoArt: [String] = [
        "....#....",
        "...###...",
        ".#######.",
        "#.#######",
        "#########",
        "#########",
        ".#######.",
        "..#####..",
        ".........",
    ]

    static let coffeeArt: [String] = [
        ".#...#...",
        "..#.#....",
        ".#...#...",
        ".........",
        "######...",
        "#....#...",
        "#....###.",
        "#....###.",
        "######...",
    ]

    private static func make(_ art: [String]) -> NSImage {
        let height = art.count
        let width = art.map(\.count).max() ?? 0
        let scale: CGFloat = 2

        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(CGFloat(width) * scale),
                                   pixelsHigh: Int(CGFloat(height) * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.shouldAntialias = false
        NSColor.black.setFill()

        for (row, line) in art.enumerated() {
            for (col, ch) in line.enumerated() where ch == "#" {
                NSRect(x: CGFloat(col) * scale,
                       y: CGFloat(height - 1 - row) * scale,
                       width: scale, height: scale).fill()
            }
        }

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: CGFloat(width) * scale,
                                         height: CGFloat(height) * scale))
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }
}
