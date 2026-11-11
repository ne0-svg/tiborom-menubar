import SwiftUI

/// 5×7 点阵字体（数字 / 冒号 / 小数点 / "Tiborom" 用到的字母）。
/// 每个字形是一组字符串行，`#` 表示点亮一个像素。
/// 中文不走点阵（整套 CJK 位图太重），小字说明仍用系统字体。
enum PixelFont {

    static let glyphs: [Character: [String]] = [
        "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
        "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
        "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
        "3": ["11111", "00010", "00100", "00010", "00001", "10001", "01110"],
        "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
        "5": ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
        "6": ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
        "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
        "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
        "9": ["01110", "10001", "10001", "01111", "00001", "00010", "01100"],
        ":": ["000", "010", "010", "000", "010", "010", "000"],
        ".": ["000", "000", "000", "000", "000", "010", "010"],
        "T": ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
        "i": ["010", "000", "110", "010", "010", "010", "111"],
        "b": ["1000", "1000", "1110", "1001", "1001", "1001", "1110"],
        "o": ["0000", "0000", "0110", "1001", "1001", "1001", "0110"],
        "r": ["0000", "0000", "1011", "1100", "1000", "1000", "1000"],
        "m": ["00000", "00000", "11010", "10101", "10101", "10101", "10101"],
    ]

    /// 字符之间的空列数
    static let letterSpacing = 1

    struct Layout {
        /// 点亮的像素坐标（列, 行）
        var pixels: [(x: Int, y: Int)] = []
        var width: Int = 0
        let height: Int = 7
    }

    static func layout(_ text: String) -> Layout {
        var out = Layout()
        var cursor = 0
        for ch in text {
            guard let rows = glyphs[ch] else { continue }
            let glyphWidth = rows[0].count
            for (row, line) in rows.enumerated() {
                for (col, bit) in line.enumerated() where bit == "1" {
                    out.pixels.append((cursor + col, row))
                }
            }
            cursor += glyphWidth + letterSpacing
        }
        out.width = max(0, cursor - letterSpacing)
        return out
    }
}

/// 把一段文字画成方块像素。scale = 每个像素的边长（点）。
struct PixelText: View {

    let text: String
    var scale: CGFloat = 4
    var color: Color = .primary
    /// 像素之间的缝（0 = 完全连成块，>0 留出网格感）
    var gap: CGFloat = 0

    var body: some View {
        let lay = PixelFont.layout(text)
        Canvas { context, _ in
            for p in lay.pixels {
                let rect = CGRect(x: CGFloat(p.x) * scale + gap / 2,
                                  y: CGFloat(p.y) * scale + gap / 2,
                                  width: scale - gap,
                                  height: scale - gap)
                context.fill(Path(rect), with: .color(color))
            }
        }
        .frame(width: CGFloat(lay.width) * scale,
               height: CGFloat(lay.height) * scale)
    }
}
