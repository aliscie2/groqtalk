import AVFoundation
import Foundation

final class AudioRecorder: @unchecked Sendable {

    private let engine = AVAudioEngine()
    private var buffers: [AVAudioPCMBuffer] = []
    private let lock = NSLock()
    private var isRecording = false

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

    func liveBuffers() -> [AVAudioPCMBuffer] {
        lock.lock()
        let copy = buffers
        lock.unlock()
        return copy
    }
}
