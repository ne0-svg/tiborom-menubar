import AppKit
import Combine

enum TiboromPhase: Equatable {
    case idle
    case work
    case rest
}

final class TiboromEngine: ObservableObject {

    // MARK: - 对外状态

    @Published private(set) var phase: TiboromPhase = .idle
    @Published private(set) var remaining: TimeInterval = 25 * 60 {
        didSet {
            displayRemaining = remaining
            preciseRemaining = remaining
        }
    }
    @Published private(set) var isRunning = false
    @Published private(set) var completedToday = 0
    /// 提示音播放中：此时不开始下一阶段、也不计时
    @Published private(set) var isChiming = false

    @Published var workMinutes: Int = 25 {
        didSet {
            guard !isLoading else { return }
            guard workMinutes != oldValue else { return }
            if phase == .idle { remaining = TimeInterval(workMinutes * 60) }
            persist()
            notifyUpdate()
        }
    }

    @Published var restMinutes: Int = 5 {
        didSet {
            guard !isLoading else { return }
            guard restMinutes != oldValue else { return }
            if phase == .rest && !isRunning { remaining = TimeInterval(restMinutes * 60) }
            persist()
            notifyUpdate()
        }
    }

    /// 自动循环：一轮 = 一次计时 + 一次休息。
    /// 开启时休息结束自动进入下一轮；关闭时休息结束即停止，回到待机。
    @Published var autoLoop: Bool = true {
        didSet {
            guard !isLoading else { return }
            persist()
            notifyUpdate()
        }
    }

    /// 自动循环最多跑几轮（一轮 = 一次计时 + 一次休息）
    @Published var roundLimit: Int = 4 {
        didSet {
            guard !isLoading else { return }
            if roundLimit < 1 { roundLimit = 1 }
            if roundLimit > 99 { roundLimit = 99 }
            persist()
            notifyUpdate()
        }
    }

    /// 本次运行已完成的轮数
    @Published private(set) var completedRounds = 0

    /// 状态栏标题刷新回调
    var onUpdate: (() -> Void)?

    // MARK: - 内部

    private enum Key {
        static let work = "workMinutes"
        static let rest = "restMinutes"
        static let autoLoop = "autoStartNext"   // 沿用旧键名，保留用户已有设置
        static let roundLimit = "roundLimit"
    }

    private let defaults = UserDefaults.standard
    private var endDate: Date?
    private var ticker: Timer?
    /// 面板可见时 20ms（毫秒位要跳），面板收起时降到 250ms（状态栏只显示到秒）
    private static let preciseInterval: TimeInterval = 0.25
    private static let coarseInterval: TimeInterval = 0.25
    /// 启动时面板是关的，初始就用低频；打开面板时再由 setPanelVisible 提到 20ms
    private var tickInterval: TimeInterval = 0.25
    /// 面板是否可见。液体动效据此决定要不要逐帧渲染（收起时动画不停会白烧 CPU）。
    @Published private(set) var isPanelVisible = false
    /// 高精度剩余时间，非 @Published：只给毫秒位用的独立通道读，不触发整树重排
    private(set) var preciseRemaining: TimeInterval = 25 * 60
    /// 状态栏标题用的剩余时间，非 @Published：面板收起时靠它更新，不惊动 SwiftUI
    private(set) var displayRemaining: TimeInterval = 25 * 60
    /// 每 tick 调用（面板可见时 20ms 一次），供毫秒位这种极小视图订阅
    var onPreciseTick: (() -> Void)?
    /// 整块面板的发布节流间隔：5Hz 足够让进度环看起来连续
    private static let uiInterval: TimeInterval = 0.5
    private var lastPublish = Date.distantPast
    private var midnightTimer: Timer?
    private var pendingWork: DispatchWorkItem?
    private var pendingAction: (() -> Void)?
    private var todayKey = ""
    private var isLoading = true
    private let debugLogging = ProcessInfo.processInfo.environment["TIBOROM_DEBUG"] != nil

    init() {
        WatchBeep.shared.setDebugLogging(ProcessInfo.processInfo.environment["TIBOROM_DEBUG"] != nil)
        let d = UserDefaults.standard

        // 先把持久化的值读出来，再一次性赋值，避免初始化过程中触发 didSet 把设置写坏
        let storedWork = d.object(forKey: Key.work) != nil ? max(1, d.integer(forKey: Key.work)) : 25
        let storedRest = d.object(forKey: Key.rest) != nil ? max(1, d.integer(forKey: Key.rest)) : 5
        let storedLoop = d.object(forKey: Key.autoLoop) != nil ? d.bool(forKey: Key.autoLoop) : true
        let storedLimit = d.object(forKey: Key.roundLimit) != nil ? max(1, d.integer(forKey: Key.roundLimit)) : 4
        let storedDayKey = Self.dayKey()
        let storedCount = d.integer(forKey: "count.\(storedDayKey)")

        workMinutes = storedWork
        restMinutes = storedRest
        autoLoop = storedLoop
        roundLimit = storedLimit
        todayKey = storedDayKey
        completedToday = storedCount
        remaining = TimeInterval(storedWork * 60)
        isLoading = false

        if d.object(forKey: Key.work) == nil { persist() }
        scheduleMidnightRollover()
        if debugLogging {
            NSLog("TIBOROM_INIT work=%d rest=%d autoLoop=%d roundLimit=%d",
                  workMinutes, restMinutes, autoLoop ? 1 : 0, roundLimit)
        }
    }

    // MARK: - 派生显示

    var totalSeconds: TimeInterval {
        switch phase {
        case .idle, .work: return TimeInterval(workMinutes * 60)
        case .rest: return TimeInterval(restMinutes * 60)
        }
    }

    var progress: Double {
        let total = totalSeconds
        guard total > 0 else { return 0 }
        return min(1, max(0, 1 - remaining / total))
    }

    var timeText: String { Self.format(remaining) }

    /// 百分秒（两位），面板里跟在秒后面显示，状态栏不用。
    /// 读 preciseRemaining（非 @Published），由独立的极小视图高频刷新
    var fractionText: String {
        let total = max(0, preciseRemaining)
        let hundredths = Int((total * 100).rounded(.down)) % 100
        return String(format: "%02d", hundredths)
    }

    var stateCaption: String {
        if isChiming { return "提醒中" }
        switch phase {
        case .idle: return "准备开始"
        case .work: return isRunning ? "计时中" : "已暂停"
        case .rest: return isRunning ? "休息中" : "已暂停"
        }
    }

    /// 鼠标悬停在表盘上时显示的点击提示
    var ringHint: String {
        if isChiming { return "点击跳过提醒" }
        if isRunning { return "点击暂停" }
        if phase == .idle { return "点击开始" }
        return "点击继续"
    }

    var primaryTitle: String {
        if isChiming { return "跳过提醒，立即开始" }
        if isRunning { return "暂停" }
        switch phase {
        case .idle: return "开始计时"
        case .work: return "继续计时"
        case .rest: return "继续休息"
        }
    }

    var isPaused: Bool { phase != .idle && !isRunning }

    var phaseName: String {
        switch phase {
        case .idle: return "idle"
        case .work: return "work"
        case .rest: return "rest"
        }
    }

    // MARK: - 操作

    func primaryAction() {
        if isChiming {
            WatchBeep.shared.stop()
            runPendingAction()
            return
        }
        stopChime()
        if isRunning {
            pause()
        } else if phase == .idle {
            startWork()
        } else {
            begin()
        }
    }

    func startWork() {
        if phase == .idle { completedRounds = 0 }
        phase = .work
        remaining = TimeInterval(workMinutes * 60)
        begin()
    }

    func pause() {
        guard isRunning else { return }
        if let end = endDate {
            remaining = max(0, end.timeIntervalSinceNow)
        }
        stop()
        notifyUpdate()
    }

    func reset() {
        stopChime()
        stop()
        phase = .idle
        remaining = TimeInterval(workMinutes * 60)
        notifyUpdate()
    }

    func skip() {
        // 提示音期间当前阶段已经结束，phase 已经指向下一阶段；
        // 这时「跳过」只跳过提醒，立即开始已经排好的下一阶段。
        // 否则会按下一阶段的类型再跳一次：休息刚结束就又跳进休息，工作刚结束则直接终止整轮。
        if isChiming {
            runPendingAction()
            return
        }
        stopChime()
        stop()
        if phase == .work {
            phase = .rest
            remaining = TimeInterval(restMinutes * 60)
        } else {
            phase = .idle
            remaining = TimeInterval(workMinutes * 60)
        }
        notifyUpdate()
    }

    /// 重置计数：轮数归零，同时清掉今日完成数
    @discardableResult
    func resetCounters() -> Bool {
        let hadSomething = completedRounds > 0 || completedToday > 0
        completedRounds = 0
        completedToday = 0
        saveCount()
        notifyUpdate()
        return hadSomething
    }

    // MARK: - 计时

    /// 调试用：直接进入休息状态，便于截图、检查图标与配色。
    func debugRestState(remaining: TimeInterval = 4 * 60 + 12) {
        stopChime()
        phase = .rest
        self.remaining = remaining
        begin()
    }

    /// 调试用：伪造跨天，验证计数归零。
    func debugSimulateDayRollover() {
        todayKey = "1999-01-01"
        completedToday = 99
        refreshDayIfNeeded()
        NSLog("TIBOROM_ROLLOVER todayKey=%@ completed=%d", todayKey, completedToday)
    }

    /// 调试用：立即结束当前阶段，用于验证提示音与阶段切换。
    func debugFinish() {
        finishPhase()
    }

    /// 调试用：以指定「已过时间」直接进入专注状态，便于截图检查运行态。
    func debugBeginWork(elapsed: TimeInterval) {
        phase = .work
        remaining = max(1, TimeInterval(workMinutes * 60) - elapsed)
        begin()
    }

    private func begin() {
        endDate = Date().addingTimeInterval(remaining)
        isRunning = true
        startTicker()
        notifyUpdate()
    }

    private func stop() {
        isRunning = false
        endDate = nil
        ticker?.invalidate()
        ticker = nil
    }

    private func startTicker() {
        ticker?.invalidate()
        let t = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    /// 面板展开 / 收起时切换刷新频率。
    /// 毫秒位只有面板打开才看得见，关着还按 20ms 跑，25 分钟就是七万多次多余唤醒。
    func setPanelVisible(_ visible: Bool) {
        guard isPanelVisible != visible else { return }
        isPanelVisible = visible
        if visible {
            // 收起期间 remaining 是不更新的，重新打开时先补上当前值
            remaining = preciseRemaining
        }
        let interval = visible ? Self.preciseInterval : Self.coarseInterval
        guard interval != tickInterval else { return }
        tickInterval = interval
        if isRunning { startTicker() }
    }

    private func tick() {
        guard isRunning, let end = endDate else { return }
        let left = end.timeIntervalSinceNow
        if left <= 0 {
            preciseRemaining = 0
            displayRemaining = 0
            remaining = 0
            notifyUpdate()
            finishPhase()
        } else {
            preciseRemaining = left
            displayRemaining = left

            if isPanelVisible {
                // 面板可见：毫秒位走独立通道，只有那个小 Text 重绘
                onPreciseTick?()
                // 整块面板按 uiInterval 合并发布。每次 @Published 变化都会让
                // SwiftUI 重排整棵视图树，实测每次约 0.5% CPU。
                let now = Date()
                if now.timeIntervalSince(lastPublish) >= Self.uiInterval {
                    lastPublish = now
                    remaining = left
                    notifyUpdate()
                }
            } else {
                // 面板收起：一个字都不往 SwiftUI 发，只更新菜单栏标题。
                // 视图树不再重排，CPU 从 5%+ 掉到空闲水位。
                let now = Date()
                if now.timeIntervalSince(lastPublish) >= 1.0 {
                    lastPublish = now
                    notifyUpdate()
                }
            }
        }
    }

    private func finishPhase() {
        let finished = phase
        stop()
        remaining = 0
        refreshDayIfNeeded()

        switch finished {
        case .work:
            completedToday += 1
            saveCount()
            chime()
            // 提示音期间先不开始；听到提示音就说明该休息了，响完再走
            phase = .rest
            remaining = TimeInterval(restMinutes * 60)
            scheduleAfterChime { [weak self] in self?.begin() }

        case .rest:
            completedRounds += 1
            chime()
            let canContinue = autoLoop && completedRounds < roundLimit
            if canContinue {
                // 自动循环且还没到设定轮数：响完进入下一轮
                phase = .work
                remaining = TimeInterval(workMinutes * 60)
                scheduleAfterChime { [weak self] in self?.begin() }
            } else {
                // 手动循环 / 已跑满轮数：响完回到待机
                scheduleAfterChime { [weak self] in
                    guard let self = self else { return }
                    self.phase = .idle
                    self.remaining = TimeInterval(self.workMinutes * 60)
                    self.notifyUpdate()
                }
            }

        case .idle:
            notifyUpdate()
        }
    }

    // MARK: - 提示

    /// 播放提示音：优先用内置 pomo-chime.mp3，缺失时退回合成的电子表蜂鸣
    private func chime() {
        stopChime()
        WatchBeep.shared.play()
    }

    func stopChime() {
        WatchBeep.shared.stop()
        pendingWork?.cancel()
        pendingWork = nil
        pendingAction = nil
        if isChiming {
            isChiming = false
            notifyUpdate()
        }
    }

    /// 提示音结束后再执行的动作（开始下一阶段 / 收工）
    private func scheduleAfterChime(_ action: @escaping () -> Void) {
        pendingWork?.cancel()
        pendingAction = action
        isChiming = true
        let item = DispatchWorkItem { [weak self] in self?.runPendingAction() }
        pendingWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + WatchBeep.shared.duration + 0.05,
                                      execute: item)
        notifyUpdate()
    }

    private func runPendingAction() {
        pendingWork?.cancel()
        pendingWork = nil
        let action = pendingAction
        pendingAction = nil
        isChiming = false
        notifyUpdate()
        action?()
    }

    // MARK: - 持久化

    private func persist() {
        defaults.set(workMinutes, forKey: Key.work)
        defaults.set(restMinutes, forKey: Key.rest)
        defaults.set(autoLoop, forKey: Key.autoLoop)
        defaults.set(roundLimit, forKey: Key.roundLimit)
    }

    private func saveCount() {
        defaults.set(completedToday, forKey: "count.\(todayKey)")
    }

    // MARK: - 每日归零（北京时间 00:00）

    /// 跨天时把计数切换到新的一天（新的一天默认 0）。
    func refreshDayIfNeeded() {
        let key = Self.dayKey()
        guard key != todayKey else { return }
        todayKey = key
        completedToday = defaults.integer(forKey: "count.\(key)")
        notifyUpdate()
    }

    private func scheduleMidnightRollover() {
        midnightTimer?.invalidate()
        let now = Date()
        guard let nextMidnight = Self.beijingCalendar.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) else { return }

        let interval = max(1, nextMidnight.timeIntervalSince(now))
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.refreshDayIfNeeded()
            self?.scheduleMidnightRollover()
        }
        RunLoop.main.add(timer, forMode: .common)
        midnightTimer = timer
    }

    private func notifyUpdate() {
        onUpdate?()
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// 计数器以北京时间 00:00 为一天的分界
    private static let beijingCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }()

    private static func dayKey() -> String {
        let formatter = DateFormatter()
        formatter.calendar = beijingCalendar
        formatter.timeZone = beijingCalendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
