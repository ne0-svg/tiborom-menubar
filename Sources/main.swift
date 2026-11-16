import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let engine = TiboromEngine()
    private var lastTitle = ""
    private var lastToolTip = ""
    private var isQuitting = false
    /// 正在测量状态栏宽度：此时不许改标题，否则量到的是短标题的宽度
    private var isMeasuringWidth = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        SoundFX.shared.setDebugLogging(ProcessInfo.processInfo.environment["TIBOROM_DEBUG"] != nil)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            // 默认 image/title 之间会插一段间距，这里让它贴紧，靠下面的 padding 精确定宽
            button.imageHugsTitle = true
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Tiborom"
        }

        let hosting = NSHostingController(
            rootView: PopoverView(engine: engine, onQuit: { [weak self] in self?.quitWithSound() })
        )
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        lockStatusItemWidth()
        engine.onUpdate = { [weak self] in self?.updateStatusItem() }
        updateStatusItem()

        runDebugHooksIfNeeded()
    }

    /// 状态栏字号 = macOS 官方菜单栏字号。
    /// `NSStatusBarButton` 默认字体实测是 `.AppleSystemUIFont` 13.0pt，
    /// 天气、时钟那些系统项都是这个尺寸，所以这里也用 13pt。
    ///
    /// 用 monospacedDigit 版本而不是 systemFont：官方字体的数字是比例宽度
    /// （实测 `111:11` 比 `888:88` 窄 11.36pt），倒计时会左右抖；
    /// 等宽数字版同为 13pt、字形尺寸一致，只是把数字advance拉齐。
    private static let statusFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)

    /// 状态栏 item 宽度在启动时锁定一次，之后不再变化：
    /// 倒计时位数（5:00 → 25:00 → 180:00）和计时/休息图标切换都不会让 item 伸缩，
    /// 锚定其上的 popover 因此不会左右跳。
    ///
    /// 不加这个锁定、交给 variableLength 的话，每秒钟标题变化都会让 item 重算宽度。
    private var lockedLength: CGFloat = 0

    /// 用「最长可能取值 180:00」让 AppKit 自己量一次宽度，然后锁死。
    ///
    /// 试过但不行的两种办法：
    /// - 手算 `图标 + 文字 + 固定留白`：NSStatusBarButton 的内边距随字号变
    ///   （11.5pt 时 3.5pt，13pt 时 7.5pt），手算必漏。
    /// - 设长标题后立刻读 `statusItem.length`：那时 AppKit 还没排版，读到旧值。
    ///
    /// 可行做法：真实 item 用 variableLength，先塞最长标题，等一次 runloop 转完
    /// 让 AppKit 完成布局，再读 button.bounds.width 锁住。
    /// 启动瞬间那 50ms 本来也没有内容要显示，不会看到闪动。
    private func lockStatusItemWidth() {
        isMeasuringWidth = true
        statusItem.length = NSStatusItem.variableLength
        statusItem.button?.attributedTitle = NSAttributedString(
            string: "180:00", attributes: [.font: Self.statusFont])

        // 等两轮 runloop，保证 AppKit 完成排版后再读
        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let button = self.statusItem.button else { return }
                let textWidth = ceil(NSAttributedString(string: "180:00",
                                     attributes: [.font: Self.statusFont]).size().width)
                let fitted = ceil(button.bounds.width)
                // 兜底：没排好版就用 图标18 + 间距2 + 文字 + 内边距16
                self.lockedLength = fitted >= textWidth + 18 ? fitted
                                                           : 18 + 2 + textWidth + 16
                self.statusItem.length = self.lockedLength
                self.isMeasuringWidth = false
                self.lastTitle = ""
                self.updateStatusItem()
            }
        }
    }

    // MARK: - 状态栏

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }

        let isRest = engine.phase == .rest
        let timeText = TiboromEngine.format(engine.displayRemaining)
        let title = timeText

        if !isMeasuringWidth, title != lastTitle {
            lastTitle = title
            button.attributedTitle = NSAttributedString(string: title,
                                                        attributes: [.font: Self.statusFont])
        }

        let icon: NSImage = isRest ? StatusIcon.coffee : StatusIcon.timer
        if button.image !== icon {
            button.image = icon
        }
        // toolTip 每秒都可能被重设一次，内容没变就别重新建字符串
        let toolTip = "Tiborom · \(engine.stateCaption)"
        if toolTip != lastToolTip {
            lastToolTip = toolTip
            button.toolTip = toolTip
        }
    }

    // MARK: - 交互

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        positionPopover(under: button)
        NSApp.activate(ignoringOtherApps: true)
        engine.setPanelVisible(true)
    }

    /// NSPopover 在菜单栏上的自动定位不可靠（实测会顶出屏幕上沿，顶部被裁掉），
    /// 这里按屏幕几何强制摆到图标正下方，并夹在可见区域内。
    private func positionPopover(under button: NSStatusBarButton) {
        guard let window = popover.contentViewController?.view.window,
              let screen = button.window?.screen ?? NSScreen.main else { return }

        let anchor = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) ?? .zero
        let size = window.frame.size
        let visible = screen.visibleFrame
        let gap: CGFloat = 4

        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)

        var y = min(visible.maxY, anchor.minY) - size.height - gap
        y = max(y, visible.minY + 8)

        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// 面板打开时不要把键盘焦点吸到分钟输入框上（保持面板本身为 key window）
    func popoverDidShow(_ notification: Notification) {
        engine.refreshDayIfNeeded()
        engine.setPanelVisible(true)
        guard let window = popover.contentViewController?.view.window else { return }
        window.makeFirstResponder(window.contentView)

        // 显示瞬间 SwiftUI 的真实尺寸往往还没定稿，这里再钉一次；
        // 之后尺寸每变一次都会通过 frameDidChange 重新钉住（见 watchPopoverSize）
        if let button = statusItem.button {
            positionPopover(under: button)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let b = self.statusItem.button else { return }
                self.positionPopover(under: b)
            }
        }
        watchPopoverSize()
    }

    // MARK: - 面板尺寸变化时重新钉位置
    //
    // NSPopover 自己有一套锚定算法：内容尺寸一变它就重新定位，并且会覆盖这里
    // 在 showPopover 做的屏幕几何校正（原版注释就记过「会顶出屏幕上沿」）。
    // 往分钟输入框里打字时 SwiftUI 会重算理想尺寸 → NSPopover 重新定位
    // → 面板往下掉一截。监听 contentView 的 frame 变化，每次变化后重新钉住。

    private var sizeObserver: NSObjectProtocol?

    private func watchPopoverSize() {
        unwatchPopoverSize()
        guard let view = popover.contentViewController?.view else { return }
        view.postsFrameChangedNotifications = true
        sizeObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: view,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.popover.isShown,
                  let button = self.statusItem.button else { return }
            // 让 NSPopover 先把自身定位跑完，再覆盖成屏幕几何校正后的位置
            DispatchQueue.main.async {
                self.positionPopover(under: button)
            }
        }
    }

    private func unwatchPopoverSize() {
        if let token = sizeObserver {
            NotificationCenter.default.removeObserver(token)
            sizeObserver = nil
        }
    }

    /// 面板收起：刷新率降回去，并兜底还原可能卡住的手型光标
    func popoverDidClose(_ notification: Notification) {
        engine.setPanelVisible(false)
        PopoverCursor.reset()
        unwatchPopoverSize()
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let quit = NSMenuItem(title: "退出 Tiborom", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func quit() {
        quitWithSound()
    }

    /// 播放点击音，响完再退出
    private func quitWithSound() {
        guard !isQuitting else { return }
        isQuitting = true
        SoundFX.shared.quitChime()
        DispatchQueue.main.asyncAfter(deadline: .now() + SoundFX.shared.quitDuration + 0.05) {
            NSApp.terminate(nil)
        }
    }

    // MARK: - 调试钩子（TIBOROM_DEBUG / TIBOROM_SNAPSHOT）

    private func runDebugHooksIfNeeded() {
        let env = ProcessInfo.processInfo.environment

        if let prefix = env["TIBOROM_SNAPSHOT"] {
            let dark = env["TIBOROM_SNAPSHOT_APPEARANCE"] == "dark"
            if dark {
                NSApp.appearance = NSAppearance(named: .darkAqua)
                popover.contentViewController?.view.appearance = NSAppearance(named: .darkAqua)
            }
            if env["TIBOROM_SNAPSHOT_REST"] != nil {
                engine.debugRestState()
            } else if env["TIBOROM_SNAPSHOT_PAUSED"] != nil {
                engine.debugBeginWork(elapsed: TimeInterval(engine.workMinutes * 60) * 0.35)
                engine.pause()
            } else if env["TIBOROM_SNAPSHOT_RUNNING"] != nil {
                engine.debugBeginWork(elapsed: TimeInterval(engine.workMinutes * 60) * 0.35)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self = self else { return }
                if dark {
                    self.popover.contentViewController?.view.appearance = NSAppearance(named: .darkAqua)
                }
                self.showPopover()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    let view = self.popover.contentViewController?.view
                    let canvas: NSColor = dark
                        ? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
                        : .windowBackgroundColor
                    let okPopover = view.map {
                        self.capture($0, to: prefix + "-popover.png", background: canvas)
                    } ?? false

                    let button = self.statusItem.button!
                    button.appearance = NSAppearance(named: .aqua)
                    let okLight = self.capture(button, to: prefix + "-status-light.png", background: .white)
                    button.appearance = NSAppearance(named: .darkAqua)
                    let okDark = self.capture(button, to: prefix + "-status-dark.png", background: .black)
                    button.appearance = nil

                    NSLog("TIBOROM_SNAPSHOT popover=%d light=%d dark=%d appAppearance=%@",
                          okPopover ? 1 : 0, okLight ? 1 : 0, okDark ? 1 : 0,
                          NSApp.effectiveAppearance.name.rawValue)

                    if env["TIBOROM_SNAPSHOT_TWICE"] != nil, let view = view {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            self.capture(view, to: prefix + "-b-popover.png", background: canvas)
                            NSLog("TIBOROM_SNAPSHOT second frame written")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                NSApp.terminate(nil)
                            }
                        }
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
        }

        if env["TIBOROM_DEBUG_POPOVER"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self, let button = self.statusItem.button else { return }
                self.showPopover()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    let window = self.popover.contentViewController?.view.window
                    let buttonScreen = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) ?? .zero
                    NSLog("TIBOROM_GEOM popoverWindow=%@ buttonScreen=%@ screen=%@ visible=%@ hostFrame=%@",
                          window.map { NSStringFromRect($0.frame) } ?? "-",
                          NSStringFromRect(buttonScreen),
                          NSStringFromRect(NSScreen.main?.frame ?? .zero),
                          NSStringFromRect(NSScreen.main?.visibleFrame ?? .zero),
                          self.popover.contentViewController.map { NSStringFromRect($0.view.frame) } ?? "-")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
                }
            }
        }


        if let path = env["TIBOROM_DUMP_BEEP"] {
            try? WatchBeep.fallbackWAV().write(to: URL(fileURLWithPath: path))
            NSLog("TIBOROM_DUMP_BEEP wrote %@", path)
        }

        if env["TIBOROM_DEBUG_RESIZE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                self.showPopover()
                let values = [1, 9, 25, 60, 180, 25]
                for (i, v) in values.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + Double(i) * 0.35) {
                        self.engine.workMinutes = v
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            let host = self.popover.contentViewController
                            let win = host?.view.window
                            NSLog("TIBOROM_RESIZE v=%d button=%@ title=%@ window=%@",
                                  v,
                                  NSStringFromRect(self.statusItem.button?.frame ?? .zero),
                                  self.statusItem.button?.attributedTitle.string ?? "-",
                                  win.map { NSStringFromRect($0.frame) } ?? "-")
                        }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + Double(values.count) * 0.35 + 0.4) {
                    NSApp.terminate(nil)
                }
            }
        }




        if env["TIBOROM_DEBUG_QUIT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                NSLog("TIBOROM_QUIT sound-then-terminate")
                self?.quitWithSound()
            }
        }


        if let prefix = env["TIBOROM_DUMP_ICONS"] {
            let icons: [(String, NSImage)] = [("timer", StatusIcon.timer), ("coffee", PixelIcon.coffee)]
            for (name, icon) in icons {
                let scale: CGFloat = 8
                let size = NSSize(width: icon.size.width * scale, height: icon.size.height * scale)
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                           pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSGraphicsContext.current?.shouldAntialias = false
                NSColor.white.setFill()
                NSRect(origin: .zero, size: size).fill()
                icon.draw(in: NSRect(origin: .zero, size: size))
                NSGraphicsContext.restoreGraphicsState()
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "\(prefix)-\(name).png"))
                }
            }
            NSLog("TIBOROM_DUMP_ICONS wrote \(prefix)-*.png")
        }

        if let prefix = env["TIBOROM_DUMP_SFX"] {
            try? SoundFX.fallbackTickWAV().write(to: URL(fileURLWithPath: prefix + "-tick.wav"))
            NSLog("TIBOROM_DUMP_SFX wrote %@-tick.wav", prefix)
        }

        if env["TIBOROM_DEBUG_CHIMEWAIT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.engine.debugBeginWork(elapsed: TimeInterval(self?.engine.workMinutes ?? 25) * 60 - 1)
            }
            for (i, t) in [2.5, 6.0, 9.5, 13.0].enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                    guard let self = self else { return }
                    NSLog("TIBOROM_WAIT #%d phase=%@ running=%d chiming=%d remaining=%.1f",
                          i + 1, self.engine.phaseName,
                          self.engine.isRunning ? 1 : 0,
                          self.engine.isChiming ? 1 : 0,
                          self.engine.remaining)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 14.5) { NSApp.terminate(nil) }
        }



        if env["TIBOROM_DEBUG_CLICK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self = self else { return }
                self.showPopover()

                func clickRing(_ index: Int) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8 + Double(index) * 0.8) {
                        guard let window = self.popover.contentViewController?.view.window,
                              let content = window.contentView else { return }
                        let point = NSPoint(x: content.bounds.midX, y: content.bounds.maxY - 125)
                        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                            if let event = NSEvent.mouseEvent(
                                with: type, location: point, modifierFlags: [],
                                timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: window.windowNumber, context: nil,
                                eventNumber: 0, clickCount: 1, pressure: 1
                            ) { window.sendEvent(event) }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            NSLog("TIBOROM_CLICK #%d phase=%@ running=%d remaining=%.0f",
                                  index + 1, self.engine.phaseName,
                                  self.engine.isRunning ? 1 : 0, self.engine.remaining)
                        }
                    }
                }

                for i in 0..<3 { clickRing(i) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) { NSApp.terminate(nil) }
            }
        }

        if env["TIBOROM_DEBUG_CHIME"] != nil {
            engine.autoLoop = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self = self else { return }
                self.engine.debugBeginWork(elapsed: TimeInterval(self.engine.workMinutes * 60) - 1)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
                self?.engine.debugFinish()
            }
        }

        if env["TIBOROM_DEBUG_LOOP"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self = self else { return }
                self.engine.debugBeginWork(elapsed: TimeInterval(self.engine.workMinutes * 60) - 1)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 17.0) { [weak self] in
                self?.engine.debugFinish()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 28.5) { [weak self] in
                guard let self = self else { return }
                NSLog("TIBOROM_LOOP autoLoop=%d phase=%@ running=%d",
                      self.engine.autoLoop ? 1 : 0, self.engine.phaseName, self.engine.isRunning ? 1 : 0)
                NSApp.terminate(nil)
            }
        }

        if env["TIBOROM_DEBUG_ROLLOVER"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.engine.debugSimulateDayRollover()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            }
        }

        if env["TIBOROM_DEBUG_START"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.engine.debugBeginWork(elapsed: 0)
            }
        }

        if env["TIBOROM_DEBUG"] != nil {
            for delay in [1.5, 3.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self, let button = self.statusItem?.button else { return }
                    NSLog("TIBOROM_DEBUG t=%.1f mounted=%@ frame=%@ icon=%@ title=%@ state=%@ autoLoop=%d defaults=%d",
                          delay,
                          button.window != nil ? "yes" : "no",
                          NSStringFromRect(button.frame),
                          button.image?.name() ?? "-",
                          button.attributedTitle.string,
                          self.engine.stateCaption,
                          self.engine.autoLoop ? 1 : 0,
                          UserDefaults.standard.bool(forKey: "autoStartNext") ? 1 : 0)
                }
            }
        }
    }

    @discardableResult
    private func capture(_ view: NSView, to path: String, background: NSColor) -> Bool {
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return false }

        view.cacheDisplay(in: bounds, to: rep)

        let source = NSImage(size: bounds.size)
        source.addRepresentation(rep)

        let output = NSImage(size: bounds.size)
        output.lockFocus()
        background.setFill()
        NSRect(origin: .zero, size: bounds.size).fill()
        source.draw(in: NSRect(origin: .zero, size: bounds.size))
        output.unlockFocus()

        guard let tiff = output.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            NSLog("TIBOROM_SNAPSHOT write failed: %@", error.localizedDescription)
            return false
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
