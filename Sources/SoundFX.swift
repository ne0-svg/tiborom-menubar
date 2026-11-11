import AppKit
import AVFoundation

/// 交互音效：所有按钮点击都播放「单音」版本的下课铃
/// （从 pomo-chime.mp3 截取第一个音，`Resources/click.wav`）。
final class SoundFX {

    static let shared = SoundFX()

    /// 点击音 = 提醒音量的 30%（短促克制）
    static let volumeRatio: Float = 0.30

    private var player: AVAudioPlayer?
    private var debugLogging = false

    private init() {
        load()
    }

    func setDebugLogging(_ enabled: Bool) {
        debugLogging = enabled
    }

    /// 提示音时长（退出时等它响完）
    var quitDuration: TimeInterval {
        player?.duration ?? 0.11
    }

    /// 单次点击音：所有按钮共用
    func click() {
        play(player, name: "click")
    }

    /// 退出也复用同一个短音
    func quitChime() {
        play(player, name: "click")
    }

    private func play(_ player: AVAudioPlayer?, name: String) {
        guard let player = player else {
            NSSound.beep()
            return
        }
        if debugLogging {
            NSLog("TIBOROM_SFX %@ volume=%.2f (alert=%.2f)", name, player.volume, WatchBeep.alertVolume)
        }
        player.stop()
        player.currentTime = 0
        player.play()
    }

    // MARK: - 加载

    private func load() {
        // 1) 从提示音截取的单音
        if let url = Bundle.main.url(forResource: "click", withExtension: "wav") {
            do {
                let custom = try AVAudioPlayer(contentsOf: url)
                custom.volume = Self.volumeRatio * WatchBeep.alertVolume
                custom.prepareToPlay()
                player = custom
            } catch {
                NSLog("TIBOROM_SFX 点击音加载失败: %@", error.localizedDescription)
            }
        }

        // 2) 兜底：合成的短促「啪嗒」
        if player == nil {
            do {
                let fallback = try AVAudioPlayer(data: Self.fallbackTickWAV())
                fallback.volume = Self.volumeRatio * WatchBeep.alertVolume
                fallback.prepareToPlay()
                player = fallback
            } catch {
                NSLog("TIBOROM_SFX 兜底音初始化失败: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - 合成兜底音

    /// 极短噪声爆点 + 165Hz 闷击，共 90ms
    static func fallbackTickWAV() -> Data {
        let sampleRate = 44100
        let count = Int(0.09 * Double(sampleRate))
        var pcm = [Int16]()
        pcm.reserveCapacity(count)

        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for i in 0..<count {
            let t = Double(i) / Double(sampleRate)

            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Double((seed >> 40) % 2001) / 1000.0 - 1.0
            let noiseEnv = exp(-t / 0.006)
            let thump = sin(2 * Double.pi * 165 * t) * exp(-t / 0.018)

            var value = noise * noiseEnv * 0.55 + thump * 0.45
            value *= min(1.0, Double(i) / 22.0)
            value *= min(1.0, Double(count - i) / 44.0)
            value *= 0.9

            pcm.append(Int16(max(-1, min(1, value)) * 32767))
        }
        return wavData(pcm: pcm, sampleRate: sampleRate)
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
        appendUInt16(1)
        appendUInt16(1)
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate * bytesPerSample))
        appendUInt16(UInt16(bytesPerSample))
        appendUInt16(16)
        appendASCII("data")
        appendUInt32(UInt32(dataSize))
        for sample in pcm {
            appendUInt16(UInt16(bitPattern: sample))
        }
        return data
    }
}
