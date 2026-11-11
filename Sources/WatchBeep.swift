import AppKit
import AVFoundation

/// 提示音：优先播放内置的 `pomo-chime.mp3`；找不到音频时退回合成的电子表蜂鸣。
final class WatchBeep {

    static let shared = WatchBeep()

    // 合成兜底音参数
    static let intraPairGap: TimeInterval = 0.28
    static let interPairGap: TimeInterval = 0.65
    static let toneDuration: TimeInterval = 0.055
    static let fallbackPairs = 10
    /// 提醒音量基准（点击音按它的 60% 播放）
    static let alertVolume: Float = 1.0

    private var player: AVAudioPlayer?
    private var debugLogging = false

    private init() {
        load()
    }

    func setDebugLogging(_ enabled: Bool) {
        debugLogging = enabled
    }

    /// 整段提示音时长，用于「响完再开始下一阶段」
    var duration: TimeInterval {
        player?.duration ?? Self.fallbackDuration
    }

    func play() {
        guard let player = player else {
            NSSound.beep()
            return
        }
        if debugLogging {
            NSLog("TIBOROM_CHIME duration=%.2f", player.duration)
        }
        player.stop()
        player.currentTime = 0
        player.play()
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
    }

    // MARK: - 加载

    private func load() {
        // 1) 内置音频文件
        if let url = Bundle.main.url(forResource: "pomo-chime", withExtension: "mp3") {
            do {
                let custom = try AVAudioPlayer(contentsOf: url)
                custom.volume = Self.alertVolume
                custom.prepareToPlay()
                player = custom
                return
            } catch {
                NSLog("TIBOROM_CHIME 内置音频加载失败: %@", error.localizedDescription)
            }
        }

        // 2) 合成兜底
        do {
            let fallback = try AVAudioPlayer(data: Self.fallbackWAV())
            fallback.volume = Self.alertVolume
            fallback.prepareToPlay()
            player = fallback
        } catch {
            NSLog("TIBOROM_CHIME 兜底音频初始化失败: %@", error.localizedDescription)
        }
    }

    // MARK: - 合成兜底音

    static var fallbackDuration: TimeInterval {
        Double(fallbackPairs) * (toneDuration * 2 + intraPairGap + interPairGap)
    }

    /// 老式电子表蜂鸣：「滴滴。。」节奏，10 组共 20 声
    static func fallbackWAV() -> Data {
        let sampleRate = 44100
        let tone = toneSamples(sampleRate: sampleRate)
        let intra = silenceSamples(seconds: intraPairGap, sampleRate: sampleRate)
        let inter = silenceSamples(seconds: interPairGap, sampleRate: sampleRate)

        var pcm: [Int16] = []
        pcm.reserveCapacity(fallbackPairs * (tone.count * 2 + intra.count + inter.count))

        for _ in 0..<fallbackPairs {
            pcm.append(contentsOf: tone)
            pcm.append(contentsOf: intra)
            pcm.append(contentsOf: tone)
            pcm.append(contentsOf: inter)
        }

        return wavData(pcm: pcm, sampleRate: sampleRate)
    }

    /// 方波 4000Hz，55ms，带淡入淡出避免爆音
    private static func toneSamples(sampleRate: Int) -> [Int16] {
        let frequency = 4000.0
        let sampleCount = Int(Double(sampleRate) * toneDuration)
        let fadeIn = 22.0
        let fadeOut = 350.0

        var samples = [Int16]()
        samples.reserveCapacity(sampleCount)

        for i in 0..<sampleCount {
            let t = Double(i) / Double(sampleRate)
            let phase = (t * frequency).truncatingRemainder(dividingBy: 1.0)
            var value: Double = phase < 0.5 ? 1.0 : -1.0
            value *= min(1.0, Double(i) / fadeIn)
            value *= min(1.0, Double(sampleCount - i) / fadeOut)
            value *= 0.80
            samples.append(Int16(max(-1, min(1, value)) * 32767))
        }
        return samples
    }

    private static func silenceSamples(seconds: TimeInterval, sampleRate: Int) -> [Int16] {
        Array(repeating: 0, count: Int(Double(sampleRate) * seconds))
    }

    private static func wavData(pcm: [Int16], sampleRate: Int) -> Data {
        let bytesPerSample = 2
        let dataSize = pcm.count * bytesPerSample
        var data = Data()

        func appendASCII(_ text: String) {
            data.append(contentsOf: Array(text.utf8))
        }
        func appendUInt32(_ value: UInt32) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ value: UInt16) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }

        appendASCII("RIFF")
        appendUInt32(UInt32(36 + dataSize))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)
        appendUInt16(1)                                    // PCM
        appendUInt16(1)                                    // 单声道
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate * bytesPerSample))  // byte rate
        appendUInt16(UInt16(bytesPerSample))               // block align
        appendUInt16(16)                                   // 位深
        appendASCII("data")
        appendUInt32(UInt32(dataSize))
        for sample in pcm {
            appendUInt16(UInt16(bitPattern: sample))
        }
        return data
    }
}
