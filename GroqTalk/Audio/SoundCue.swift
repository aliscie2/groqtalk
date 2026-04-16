import AVFoundation

enum SoundCue {
    static let duckLevel: Float = 0.2

    static func recordStart() {
        play(reversed: false) { SystemVolume.duck(to: duckLevel) }
    }

    static func recordStop() {
        SystemVolume.restore()
        play(reversed: true)
    }

    static func prepare() {
        guard !ready, let buf = forwardBuffer else { return }
        _ = reversedBuffer
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: buf.format)
        engine.mainMixerNode.outputVolume = volume
        try? engine.start()
        player.play()
        ready = true
    }

    private static let soundName = "Pop"
    private static let volume: Float = 0.3
    private static let silenceThreshold: Float = 0.002
    private static let trimPaddingFrames = 64

    private static let engine = AVAudioEngine()
    private static let player = AVAudioPlayerNode()
    private static var ready = false

    private static let forwardBuffer: AVAudioPCMBuffer? = loadBuffer(reversed: false)
    private static let reversedBuffer: AVAudioPCMBuffer? = loadBuffer(reversed: true)

    private static func play(reversed: Bool, after: (() -> Void)? = nil) {
        guard let buf = reversed ? reversedBuffer : forwardBuffer else { return }
        if !engine.isRunning { try? engine.start() }
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { _ in
            after?()
        }
    }

    private static func loadBuffer(reversed: Bool) -> AVAudioPCMBuffer? {
        let url = URL(fileURLWithPath: "/System/Library/Sounds/\(soundName).aiff")
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil
        else { return nil }

        trimTrailingSilence(buffer)
        if reversed { reverseSamples(buffer) }
        return buffer
    }

    private static func trimTrailingSilence(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        var lastActive = 0
        for ch in 0..<Int(buffer.format.channelCount) {
            let p = data[ch]
            for i in stride(from: frameCount - 1, through: 0, by: -1)
            where abs(p[i]) > silenceThreshold {
                lastActive = max(lastActive, i)
                break
            }
        }
        let pad = min(trimPaddingFrames, frameCount - lastActive - 1)
        buffer.frameLength = AVAudioFrameCount(lastActive + 1 + pad)
    }

    private static func reverseSamples(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        for ch in 0..<Int(buffer.format.channelCount) {
            let p = data[ch]
            for i in 0..<(frameCount / 2) {
                let j = frameCount - 1 - i
                (p[i], p[j]) = (p[j], p[i])
            }
        }
    }
}
