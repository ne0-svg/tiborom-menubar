import AppKit
import SwiftUI

struct PopoverView: View {

    @ObservedObject var engine: TiboromEngine
    var onQuit: () -> Void

    private enum Field: Hashable {
        case work
        case rest
    }

    @FocusState private var focusedField: Field?
    @Environment(\.colorScheme) private var colorScheme

    private final class HoverState: ObservableObject {
        @Published var isHovering = false
    }

    @ObservedObject private var hover = HoverState()
    @ObservedObject private var flash = ResetFlash()

    /// 毫秒位自己的时钟。放在独立小视图里，高频刷新不会让整块面板重排。
    @StateObject private var hundredths = HundredthsClock()

    private var tint: Color { .accentColor }
    private var ink: Color { colorScheme == .dark ? Color(white: 0.92) : Color(white: 0.13) }
    private var paper: Color { colorScheme == .dark ? Color(white: 0.13) : Color(white: 0.97) }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.top, 16)

            ring
                .padding(.top, 12)

            primaryButton
                .padding(.horizontal, 18)
                .padding(.top, 14)

            secondaryButtons
                .padding(.horizontal, 18)
                .padding(.top, 8)

            pixelRule
                .padding(.top, 14)
                .padding(.horizontal, 18)

            settings
                .padding(.horizontal, 18)
                .padding(.vertical, 6)

            pixelRule
                .padding(.horizontal, 18)

            footer
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 14)
        }
        .frame(width: 300)
        .background(paper)
        .background(pixelFrame)
        .onAppear {
            focusedField = nil
            let clock = hundredths
            engine.onPreciseTick = { [weak clock] in
                clock?.refresh(engine.preciseRemaining)
            }
        }
        .onDisappear {
            focusedField = nil
            engine.onPreciseTick = nil
            PopoverCursor.reset()
        }
    }

    /// 外框：2px 硬边 + 右下 3px 实心投影，像素界面的"厚度"靠这层投影
    private var pixelFrame: some View {
        Canvas { context, size in
            let border: CGFloat = 2
            let shadow: CGFloat = 3
            context.fill(Path(CGRect(x: shadow, y: shadow,
                                     width: size.width - shadow, height: size.height - shadow)),
                         with: .color(ink.opacity(colorScheme == .dark ? 0.55 : 0.28)))
            context.fill(Path(CGRect(x: 0, y: 0, width: size.width - shadow, height: size.height - shadow)),
                         with: .color(paper))
            var frame = Path()
            frame.addRect(CGRect(x: 0, y: 0, width: size.width - shadow, height: size.height - shadow))
            frame.addRect(CGRect(x: border, y: border,
                                 width: size.width - shadow - border * 2,
                                 height: size.height - shadow - border * 2))
            context.fill(frame, with: .color(ink), style: FillStyle(eoFill: true))
        }
        .allowsHitTesting(false)
    }

    /// 分隔线：一格一格的虚线，不用细线
    private var pixelRule: some View {
        Canvas { context, size in
            var x: CGFloat = 0
            while x < size.width {
                context.fill(Path(CGRect(x: x, y: size.height / 2 - 1, width: 4, height: 2)),
                             with: .color(ink.opacity(0.35)))
                x += 8
            }
        }
        .frame(height: 4)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            PixelText(text: "Tiborom", scale: 3, color: ink)

            statusLight

            Spacer(minLength: 8)

            HStack(spacing: 5) {
                Canvas { context, size in
                    // 像素对勾：3×3 折线方块
                    let u = size.width / 5
                    let on: [(Int, Int)] = [(0, 2), (1, 3), (2, 2), (3, 1), (4, 0)]
                    for p in on {
                        context.fill(Path(CGRect(x: CGFloat(p.0) * u, y: CGFloat(p.1) * u,
                                                 width: u, height: u)),
                                     with: .color(ink.opacity(0.6)))
                    }
                }
                .frame(width: 10, height: 10)
                Text("今日 \(engine.completedToday) 个")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 运行状态灯：计时中绿、暂停/待机红，方块而不是圆
    private var statusLight: some View {
        let color: Color = engine.isRunning ? Color(red: 0.18, green: 0.72, blue: 0.36)
                                            : Color(red: 0.94, green: 0.26, blue: 0.24)
        return Rectangle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(Rectangle().stroke(ink.opacity(0.5), lineWidth: 1).padding(-2))
    }

    // MARK: - 环形计时（点击表盘 = 开始 / 暂停 / 继续）

    private var ring: some View {
        Button(action: startOrPause) {
            ringBody
        }
        .buttonStyle(RingPressStyle())
        .help("点击表盘：开始 / 暂停 / 继续")
        .onHover { hovering in
            hover.isHovering = hovering
            PopoverCursor.set(hovering)
        }
    }

    private var ringBody: some View {
        ZStack {
            Circle()
                .fill(Color(nsColor: .textBackgroundColor))

            // 面板收起时整个背景从视图树移除，连 Canvas 都不留
            if engine.isPanelVisible {
                PixelBackdrop()
            }

            blockRing

            VStack(spacing: 4) {
                PixelText(text: engine.timeText, scale: 5, color: tint)
                PixelHundredths(engine: engine, hundredths: hundredths, tint: tint)
                Text(hover.isHovering ? engine.ringHint : engine.stateCaption)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 176, height: 176)
        .contentShape(Circle())
        .scaleEffect(hover.isHovering ? 1.012 : 1)
    }

    /// 进度环：28 个方块段，点亮的段数 = 进度。像素风不画圆弧。
    private var blockRing: some View {
        Canvas { context, size in
            let segments = 28
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 8
            let lit = Int((Double(segments) * engine.progress).rounded(.down))
            for i in 0..<segments {
                let angle = Double(i) / Double(segments) * 2 * .pi - .pi / 2
                let x = center.x + CGFloat(cos(angle)) * radius
                let y = center.y + CGFloat(sin(angle)) * radius
                let rect = CGRect(x: x - 4, y: y - 4, width: 8, height: 8)
                let color: Color = i < lit ? tint : ink.opacity(hover.isHovering ? 0.16 : 0.10)
                context.fill(Path(rect), with: .color(color))
            }
        }
    }

    /// 按下时整块往下挪 1px 并去掉投影，像素按钮的手感
    private struct RingPressStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.985 : 1)
                .opacity(configuration.isPressed ? 0.92 : 1)
        }
    }

    private func startOrPause() {
        SoundFX.shared.click()
        engine.primaryAction()
    }

    // MARK: - 主操作

    private var primaryButton: some View {
        PixelButton(title: engine.primaryTitle,
                    glyph: engine.isRunning ? .pause : .play,
                    expand: true,
                    emphasized: true,
                    ink: ink, tint: tint, dark: colorScheme == .dark) {
            startOrPause()
        }
        .padding(.horizontal, 18)
    }

    private var secondaryButtons: some View {
        HStack(spacing: 10) {
            PixelButton(title: "重置", glyph: .reset, expand: true,
                        ink: ink, tint: tint, dark: colorScheme == .dark) {
                SoundFX.shared.click()
                engine.reset()
            }
            PixelButton(title: "跳过", glyph: .skip, expand: true,
                        ink: ink, tint: tint, dark: colorScheme == .dark) {
                SoundFX.shared.click()
                engine.skip()
            }
        }
        .padding(.horizontal, 18)
    }

    // MARK: - 设置

    private var settings: some View {
        VStack(spacing: 0) {
            row("计时时长") {
                minutesEditor(workMinutesBinding, field: .work)
            }
            row("休息时长") {
                minutesEditor(restMinutesBinding, field: .rest)
            }
            row("自动循环") {
                PixelToggle(isOn: Binding(get: { engine.autoLoop },
                                          set: { engine.autoLoop = $0 }),
                            ink: ink, tint: tint)
                    .help("休息结束自动进入下一轮")
            }
            row("循环次数") {
                HStack(spacing: 8) {
                    Text(engine.autoLoop ? "\(engine.completedRounds)/\(engine.roundLimit) 轮"
                                         : "\(engine.roundLimit) 轮")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    PixelStepper(ink: ink, tint: tint) {
                        engine.roundLimit += 1
                    } onDec: {
                        engine.roundLimit -= 1
                    }
                    .help("自动循环最多跑几轮，跑满后自动停止")
                }
            }
        }
    }

    private func row<Content: View>(_ title: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            content()
        }
        .frame(height: 36)
    }

    private func minutesEditor(_ binding: Binding<Int>, field: Field) -> some View {
        HStack(spacing: 8) {
            TextField("", value: binding, format: .number)
                .focused($focusedField, equals: field)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .font(.system(size: 13, weight: .medium))
                .frame(width: 44, height: 22)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(Rectangle().stroke(ink.opacity(0.7), lineWidth: 2))
                .labelsHidden()

            Text("分钟")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            PixelStepper(ink: ink, tint: tint) {
                binding.wrappedValue += 1
            } onDec: {
                binding.wrappedValue -= 1
            }
        }
        .help("1–180 分钟，可直接输入任意数值")
    }

    private var workMinutesBinding: Binding<Int> {
        Binding(get: { engine.workMinutes },
                set: { engine.workMinutes = min(180, max(1, $0)) })
    }

    private var restMinutesBinding: Binding<Int> {
        Binding(get: { engine.restMinutes },
                set: { engine.restMinutes = min(180, max(1, $0)) })
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 8) {
            PixelButton(title: flash.didReset ? "已重置" : "重置计数",
                        glyph: flash.didReset ? .check : .reset,
                        compact: true,
                        ink: ink, tint: tint, dark: colorScheme == .dark) {
                SoundFX.shared.click()
                engine.resetCounters()
                flash.didReset = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    flash.didReset = false
                }
            }
            .help("清零循环轮数与今日完成数")

            Spacer(minLength: 0)

            PixelButton(title: "退出", glyph: .power, compact: true,
                        ink: ink, tint: tint, dark: colorScheme == .dark, action: onQuit)
        }
    }
}

// MARK: - 像素控件

/// 像素按钮：2px 硬边 + 右下 2px 实心投影；按下时内容下移、投影消失。
/// 按压态走 ButtonStyle（swiftc 直编没有 SwiftUI 宏插件，不能用 @State）。
struct PixelButton: View {

    enum Glyph { case play, pause, reset, skip, check, power }

    let title: String
    var glyph: Glyph = .play
    var compact = false
    var expand = false
    var emphasized = false
    let ink: Color
    let tint: Color
    let dark: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                glyphView
                Text(title)
                    .font(.system(size: compact ? 12 : 12.5, weight: .medium))
            }
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 4 : 7)
            .frame(maxWidth: expand ? .infinity : nil)
        }
        .buttonStyle(PixelButtonStyle(ink: ink, tint: tint,
                                      emphasized: emphasized, dark: dark))
    }

    @ViewBuilder
    private var glyphView: some View {
        Canvas { context, size in
            let u = size.width / 5
            func px(_ x: Int, _ y: Int) {
                context.fill(Path(CGRect(x: CGFloat(x) * u, y: CGFloat(y) * u,
                                         width: u, height: u)),
                             with: .color(emphasized ? tint : ink))
            }
            switch glyph {
            case .play:
                (0..<5).forEach { r in px(1 + r / 2, r); px(2 + r / 2, r) }
            case .pause:
                (0..<5).forEach { r in px(1, r); px(3, r) }
            case .reset:
                [(1,0),(2,0),(3,0),(0,1),(4,1),(0,2),(3,2),(4,2),(0,3),(4,3),(1,4),(2,4),(3,4)]
                    .forEach { px($0.0, $0.1) }
            case .skip:
                (0..<5).forEach { r in px(r / 2, r); px(r / 2 + 1, r); px(4, r) }
            case .check:
                [(0,2),(1,3),(2,2),(3,1),(4,0)].forEach { px($0.0, $0.1) }
            case .power:
                [(1,0),(3,0),(0,1),(4,1),(0,2),(4,2),(0,3),(4,3),(1,4),(3,4),(2,0),(2,1)]
                    .forEach { px($0.0, $0.1) }
            }
        }
        .frame(width: 10, height: 10)
    }
}

/// 像素按钮的外观：边框 + 实心投影，按下时整体下移 1px、投影收起
struct PixelButtonStyle: ButtonStyle {

    let ink: Color
    let tint: Color
    let emphasized: Bool
    let dark: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(emphasized ? tint : ink)
            .background(background)
            .overlay(Rectangle().stroke(ink, lineWidth: 2))
            .background(
                Rectangle()
                    .fill(configuration.isPressed ? Color.clear
                                                  : ink.opacity(dark ? 0.55 : 0.30))
                    .offset(x: 2, y: 2)
            )
            .offset(y: configuration.isPressed ? 1 : 0)
    }

    private var background: Color {
        if emphasized { return dark ? Color(white: 0.20) : Color(white: 0.90) }
        return dark ? Color(white: 0.17) : Color(white: 0.93)
    }
}

/// 像素开关：方轨 + 方滑块
struct PixelToggle: View {
    let isOn: Binding<Bool>
    let ink: Color
    let tint: Color

    var body: some View {
        Button {
            SoundFX.shared.click()
            isOn.wrappedValue.toggle()
        } label: {
            ZStack(alignment: isOn.wrappedValue ? .trailing : .leading) {
                Rectangle()
                    .fill(isOn.wrappedValue ? tint.opacity(0.25) : ink.opacity(0.12))
                Rectangle()
                    .fill(isOn.wrappedValue ? tint : ink.opacity(0.55))
                    .frame(width: 12, height: 12)
                    .padding(2)
            }
            .frame(width: 34, height: 16)
            .overlay(Rectangle().stroke(ink, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}

/// 像素步进器：上下两个方块按钮，箭头是 3 行像素
struct PixelStepper: View {
    let ink: Color
    let tint: Color
    var onInc: () -> Void
    var onDec: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            arrow(up: true, action: onInc)
            arrow(up: false, action: onDec)
        }
    }

    private func arrow(up: Bool, action: @escaping () -> Void) -> some View {
        Button {
            SoundFX.shared.click()
            action()
        } label: {
            Canvas { context, size in
                let u = size.width / 5
                let rows: [(Int, Int)] = up
                    ? [(2, 0), (1, 1), (2, 1), (3, 1), (0, 2), (1, 2), (2, 2), (3, 2), (4, 2)]
                    : [(0, 0), (1, 0), (2, 0), (3, 0), (4, 0), (1, 1), (2, 1), (3, 1), (2, 2)]
                for p in rows {
                    context.fill(Path(CGRect(x: CGFloat(p.0) * u, y: CGFloat(p.1) * u,
                                             width: u, height: u)),
                                 with: .color(ink))
                }
            }
            .frame(width: 12, height: 8)
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .background(ink.opacity(0.10))
            .overlay(Rectangle().stroke(ink.opacity(0.7), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// 「重置计数」按钮的短暂确认态
final class ResetFlash: ObservableObject {
    @Published var didReset = false
}

/// 表盘 hover 的光标管理。push/pop 必须成对：面板是 .transient，
/// 鼠标停在表盘上点别处会让面板直接消失，onHover(false) 不触发。
enum PopoverCursor {

    private static var isPushed = false

    static func set(_ hovering: Bool) {
        if hovering, !isPushed {
            NSCursor.pointingHand.push()
            isPushed = true
        } else if !hovering, isPushed {
            NSCursor.pop()
            isPushed = false
        }
    }

    static func reset() {
        guard isPushed else { return }
        NSCursor.pop()
        isPushed = false
        NSCursor.arrow.set()
    }
}

/// 毫秒位的独立时钟：只有它自己被高频刷新，整块面板不跟着重排
final class HundredthsClock: ObservableObject {
    @Published var text = "00"

    func refresh(_ remaining: TimeInterval) {
        let hundredths = Int((max(0, remaining) * 100).rounded(.down)) % 100
        let next = String(format: "%02d", hundredths)
        if next != text { text = next }
    }
}


/// 只负责渲染毫秒位（像素版）。它订阅 HundredthsClock，
/// 高频刷新被限制在这个小视图内部，不牵动整块面板。
struct PixelHundredths: View {

    let engine: TiboromEngine
    @ObservedObject var hundredths: HundredthsClock
    let tint: Color

    var body: some View {
        PixelText(text: "." + hundredths.text, scale: 2, color: tint.opacity(0.6))
            .onAppear { hundredths.refresh(engine.preciseRemaining) }
    }
}
