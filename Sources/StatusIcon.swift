import AppKit

/// 菜单栏图标：计时态是像素番茄，休息态是像素咖啡杯。
/// 两者都是模板图，随菜单栏明暗自动反色。
enum StatusIcon {

    /// 计时态
    static let timer: NSImage = PixelIcon.tomato

    /// 休息态
    static let coffee: NSImage = PixelIcon.coffee
}
