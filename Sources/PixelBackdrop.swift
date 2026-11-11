import SwiftUI

/// 表盘背后的像素噪点：粗网格上的方块按慢节奏明灭，代替原版的水银液体。
/// 像素风不需要平滑过渡，8fps 的硬切换就是它的质感。
///
/// 性能沿用 v1.3.4 的结论：`isActive` 为 false 时不建立 TimelineView，
/// 面板收起后视图树里连这个 Canvas 都不存在（见 PopoverView 的条件挂载）。
struct PixelBackdrop: View {

    var isActive: Bool = true

    /// 网格边长（点）。越大越"粗像素"
    private static let cell: CGFloat = 7

    /// 每秒帧数。噪点明灭是慢动作，8fps 足够
    private static let fps: TimeInterval = 1.0 / 8.0

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if isActive {
                TimelineView(.periodic(from: .now, by: Self.fps)) { timeline in
                    let bucket = Int(timeline.date.timeIntervalSinceReferenceDate / Self.fps)
                    grid(bucket: bucket)
                }
            } else {
                grid(bucket: 0)
            }
        }
        .clipShape(Circle())
        .allowsHitTesting(false)
    }

    private func grid(bucket: Int) -> some View {
        Canvas { context, size in
            let cell = Self.cell
            let cols = Int(size.width / cell) + 1
            let rows = Int(size.height / cell) + 1
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2
            let dark = colorScheme == .dark
            let base = dark ? Color(white: 0.92) : Color(red: 0.42, green: 0.50, blue: 0.62)

            for row in 0..<rows {
                for col in 0..<cols {
                    let x = CGFloat(col) * cell
                    let y = CGFloat(row) * cell
                    // 只画圆盘内部，靠圆心距离做一层衰减
                    let dx = x + cell / 2 - center.x
                    let dy = y + cell / 2 - center.y
                    let dist = sqrt(dx * dx + dy * dy)
                    guard dist < radius * 0.92 else { continue }

                    let h = hash(col, row, bucket)
                    // 约 14% 的格子点亮，越靠外越稀疏
                    let threshold = 0.14 * (1.0 - dist / radius * 0.6)
                    guard h < threshold else { continue }

                    let alpha = (dark ? 0.10 : 0.16) * (1.0 - dist / radius * 0.5)
                    context.fill(Path(CGRect(x: x, y: y, width: cell - 1, height: cell - 1)),
                                 with: .color(base.opacity(alpha)))
                }
            }
        }
    }

    /// 整数哈希到 [0,1)。不用随机数，保证同一 bucket 内画面稳定
    private func hash(_ x: Int, _ y: Int, _ bucket: Int) -> Double {
        var h = UInt64(x &* 374761393 &+ y &* 668265263 &+ bucket &* 1274126177)
        h = (h ^ (h >> 13)) &* 1103515245
        h = h ^ (h >> 16)
        return Double(h % 1000) / 1000.0
    }
}
