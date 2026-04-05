import AVFoundation
import Foundation

enum AudioProcessor {

    static func concatenate(_ buffers: [AVAudioPCMBuffer]) -> [Float] {
        var samples: [Float] = []
        for buf in buffers {
            guard let ptr = buf.floatChannelData?[0] else { continue }
            samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: Int(buf.frameLength)))
        }
        return samples
    }

    static func isAudioSilent(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return true }
        let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))
        let aboveThreshold = samples.filter { abs($0) > ConfigManager.silenceThreshold }.count
        let ratio = Float(aboveThreshold) / Float(samples.count)
        Log.debug("[ENERGY] RMS=\(String(format: "%.4f", rms)) above=\(String(format: "%.1f", ratio * 100))% silent=\(ratio < ConfigManager.silenceAboveRatio)")
        return ratio < ConfigManager.silenceAboveRatio
    }

    static func trimSilence(_ samples: [Float], threshold: Float = 0.003) -> [Float] {
        let start = samples.firstIndex(where: { abs($0) > threshold }) ?? 0
        let end = (samples.lastIndex(where: { abs($0) > threshold }) ?? (samples.count - 1)) + 1
        let trimmed = Array(samples[start..<min(end, samples.count)])
        Log.debug("[trim] \(samples.count) -> \(trimmed.count) samples (removed \(String(format: "%.1f", Double(samples.count - trimmed.count) / Double(ConfigManager.sampleRate)))s)")
        return trimmed
    }

    static func encodeWAV(_ samples: [Float], sampleRate: Int = ConfigManager.sampleRate) -> Data {
        let numSamples = samples.count
        let dataSize = numSamples * 2
        let fileSize = 44 + dataSize

        var data = Data(capacity: fileSize)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        data.append(contentsOf: "RIFF".utf8)
        u32(UInt32(fileSize - 8))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2))
        u16(2); u16(16)
        data.append(contentsOf: "data".utf8)
        u32(UInt32(dataSize))

        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            let i16 = Int16(clamped * 32767)
            withUnsafeBytes(of: i16.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func prepareForWhisper(_ buffers: [AVAudioPCMBuffer]) -> (Data, Double) {
        let start = CFAbsoluteTimeGetCurrent()
        let raw = concatenate(buffers)
        let trimmed = trimSilence(raw)
        let wav = encodeWAV(trimmed)
        let duration = Double(trimmed.count) / Double(ConfigManager.sampleRate)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let originalDuration = Double(raw.count) / Double(ConfigManager.sampleRate)
        Log.info("[prep] \(String(format: "%.1f", duration))s (trimmed from \(String(format: "%.1f", originalDuration))s) -> \(wav.count) bytes WAV in \(String(format: "%.3f", elapsed))s")
        return (wav, duration)
    }
}
