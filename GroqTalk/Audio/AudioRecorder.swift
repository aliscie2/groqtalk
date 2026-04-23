import AVFoundation
import Foundation

final class AudioRecorder: @unchecked Sendable {

    private let engine = AVAudioEngine()
    private var buffers: [AVAudioPCMBuffer] = []
    private let lock = NSLock()
    private var isRecording = false

    /// Fired on the audio tap thread with the current buffer's RMS level
    /// (roughly [0, 1]). Consumers should hop to main if they touch UI.
    /// Set on the main thread; do not reassign while recording is active.
    var onLevel: ((Float) -> Void)?

    func start() throws {
        // Remove any leftover tap to avoid "tap already installed" crash
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        } else {
            engine.inputNode.removeTap(onBus: 0)
        }

        lock.lock()
        buffers.removeAll()
        isRecording = true
        lock.unlock()

        let inputNode = engine.inputNode
        let nativeFormat = inputNode.inputFormat(forBus: 0)

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(ConfigManager.sampleRate),
            channels: 1,
            interleaved: false
        )!

        let needsConversion = nativeFormat.sampleRate != targetFormat.sampleRate || nativeFormat.channelCount != 1
        let converter: AVAudioConverter? = needsConversion ? AVAudioConverter(from: nativeFormat, to: targetFormat) : nil

        inputNode.installTap(onBus: 0, bufferSize: 1600, format: nativeFormat) { [weak self] buffer, _ in
            guard let self else { return }

            let outputBuffer: AVAudioPCMBuffer
            if let converter, let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 1600) {
                var error: NSError?
                converter.convert(to: converted, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                outputBuffer = converted
            } else {
                outputBuffer = buffer
            }

            lock.lock()
            buffers.append(outputBuffer)
            lock.unlock()

            // Fire RMS level for the recording indicator. Computed from the
            // converted mono buffer so the number matches what's stored.
            if let cb = self.onLevel,
               let ch = outputBuffer.floatChannelData?[0] {
                let n = Int(outputBuffer.frameLength)
                if n > 0 {
                    var sum: Float = 0
                    for i in 0..<n { sum += ch[i] * ch[i] }
                    let rms = (sum / Float(n)).squareRoot()
                    cb(rms)
                }
            }
        }

        try engine.start()
        Log.info("[REC] AVAudioEngine started — format: \(nativeFormat)")
    }

    @discardableResult
    func stop() -> [AVAudioPCMBuffer] {
        guard engine.isRunning else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        lock.lock()
        let captured = buffers
        isRecording = false
        lock.unlock()

        Log.info("[REC] AVAudioEngine stopped — \(captured.count) buffers captured")
        return captured
    }

    func liveBuffers(maxDuration: Double? = nil) -> [AVAudioPCMBuffer] {
        lock.lock()
        let copy = buffers
        lock.unlock()

        guard let maxDuration, maxDuration > 0 else { return copy }

        let maxFrames = Int(maxDuration * Double(ConfigManager.sampleRate))
        var selected: [AVAudioPCMBuffer] = []
        var collectedFrames = 0

        for buffer in copy.reversed() {
            selected.append(buffer)
            collectedFrames += Int(buffer.frameLength)
            if collectedFrames >= maxFrames { break }
        }

        return selected.reversed()
    }
}
