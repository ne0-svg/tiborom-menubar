import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let engine = TiboromEngine()
    private var lastTitle = ""
    private var lastToolTip = ""
    private var isQuitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        SoundFX.shared.setDebugLogging(ProcessInfo.processInfo.environment["TIBOROM_DEBUG"] != nil)

        statusItem = NSStatusBar.system.statusItem(withLength: Self.statusItemLength)

        if let button = statusItem.button {
            button.imagePosition = .imageLeading
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

        engine.onUpdate = { [weak self] in self?.updateStatusItem() }
        updateStatusItem()

        runDebugHooksIfNeeded()
    }

    /// 状态栏字号。原先 12.5pt 比系统菜单栏文字偏大，也让 item 更宽。
    private static let statusFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)

    /// 状态栏 item 固定宽度：倒计时位数变化（5:00 → 25:00 → 180:00）或
    /// 计时 / 休息之间切换图标时，item 都不变宽，锚定其上的 popover 也就不会左右跳。
    ///
    /// 宽度按「最长实际取值」算，不按全 8 预留：分钟上限 180 → 最长就是 `180:00`。
    /// 左右留白从 20 收到 8，配合 11.5pt 字号，实测比原来的 83pt 窄了约 17pt。
    private static var statusItemLength: CGFloat {
        let textWidth = ceil(NSAttributedString(string: "180:00",
                                                attributes: [.font: statusFont]).size().width)
        let timerWidth = ceil(StatusIcon.timer.size.width)
        let coffeeIconWidth = ceil(StatusIcon.coffee.size.width)
        // 两种状态都是「图标 + 时间」，取更宽的一档图标
        return max(timerWidth, coffeeIconWidth) + textWidth + 8
    }

    // MARK: - 状态栏

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }

        let isRest = engine.phase == .rest
        let timeText = TiboromEngine.format(engine.displayRemaining)
        let title = timeText

        if title != lastTitle {
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
    }

    /// 面板收起：刷新率降回去，并兜底还原可能卡住的手型光标
    func popoverDidClose(_ notification: Notification) {
        engine.setPanelVisible(false)
        PopoverCursor.reset()
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
