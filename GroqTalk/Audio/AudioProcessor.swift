import AVFoundation
import Foundation

enum AudioProcessor {
    private struct WAVDescriptor {
        let channels: UInt16
        let sampleRate: UInt32
        let byteRate: UInt32
        let blockAlign: UInt16
        let bitsPerSample: UInt16
        let pcmData: Data
    }

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
        var pcmData = Data(capacity: samples.count * 2)
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            let i16 = Int16(clamped * 32767)
            withUnsafeBytes(of: i16.littleEndian) { pcmData.append(contentsOf: $0) }
        }
        return makePCM16MonoWAV(pcmData: pcmData, sampleRate: sampleRate)
    }

    static func silentWAV(seconds: Double, sampleRate: Int = ConfigManager.sampleRate) -> Data {
        let frames = max(0, Int(seconds * Double(sampleRate)))
        return makePCM16MonoWAV(pcmData: Data(count: frames * 2), sampleRate: sampleRate)
    }

    static func concatenateWAVFiles(_ wavFiles: [Data]) -> Data? {
        guard let first = wavFiles.first,
              let reference = parseWAV(first) else { return nil }

        var mergedPCM = Data()
        mergedPCM.reserveCapacity(wavFiles.reduce(0) { $0 + max(0, $1.count - 44) })
        mergedPCM.append(reference.pcmData)

        for wav in wavFiles.dropFirst() {
            guard let descriptor = parseWAV(wav),
                  descriptor.channels == reference.channels,
                  descriptor.sampleRate == reference.sampleRate,
                  descriptor.byteRate == reference.byteRate,
                  descriptor.blockAlign == reference.blockAlign,
                  descriptor.bitsPerSample == reference.bitsPerSample else {
                Log.error("[AUDIO] cannot merge WAV chunks with mismatched formats")
                return nil
            }
            mergedPCM.append(descriptor.pcmData)
        }

        return makeWAV(
            pcmData: mergedPCM,
            channels: reference.channels,
            sampleRate: reference.sampleRate,
            byteRate: reference.byteRate,
            blockAlign: reference.blockAlign,
            bitsPerSample: reference.bitsPerSample
        )
    }

    static func wavDuration(_ wavData: Data) -> TimeInterval? {
        guard let descriptor = parseWAV(wavData),
              descriptor.sampleRate > 0,
              descriptor.blockAlign > 0 else {
            return nil
        }
        let frameCount = Double(descriptor.pcmData.count) / Double(descriptor.blockAlign)
        return frameCount / Double(descriptor.sampleRate)
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

    private static func parseWAV(_ data: Data) -> WAVDescriptor? {
        guard data.count >= 44,
              data.prefix(4) == Data("RIFF".utf8),
              data.subdata(in: 8..<12) == Data("WAVE".utf8) else {
            return nil
        }

        var cursor = 12
        var channels: UInt16?
        var sampleRate: UInt32?
        var byteRate: UInt32?
        var blockAlign: UInt16?
        var bitsPerSample: UInt16?
        var pcmData: Data?

        while cursor + 8 <= data.count {
            let chunkID = String(data: data.subdata(in: cursor..<(cursor + 4)), encoding: .ascii) ?? ""
            let chunkSize = Int(readUInt32LE(data, at: cursor + 4))
            cursor += 8
            guard cursor + chunkSize <= data.count else { return nil }

            if chunkID == "fmt " {
                guard chunkSize >= 16 else { return nil }
                let audioFormat = readUInt16LE(data, at: cursor)
                guard audioFormat == 1 else { return nil }
                channels = readUInt16LE(data, at: cursor + 2)
                sampleRate = readUInt32LE(data, at: cursor + 4)
                byteRate = readUInt32LE(data, at: cursor + 8)
                blockAlign = readUInt16LE(data, at: cursor + 12)
                bitsPerSample = readUInt16LE(data, at: cursor + 14)
            } else if chunkID == "data" {
                pcmData = data.subdata(in: cursor..<(cursor + chunkSize))
            }

            cursor += chunkSize + (chunkSize % 2)
        }

        guard let channels,
              let sampleRate,
              let byteRate,
              let blockAlign,
              let bitsPerSample,
              let pcmData else {
            return nil
        }

        return WAVDescriptor(
            channels: channels,
            sampleRate: sampleRate,
            byteRate: byteRate,
            blockAlign: blockAlign,
            bitsPerSample: bitsPerSample,
            pcmData: pcmData
        )
    }

    private static func makeWAV(
        pcmData: Data,
        channels: UInt16,
        sampleRate: UInt32,
        byteRate: UInt32,
        blockAlign: UInt16,
        bitsPerSample: UInt16
    ) -> Data {
        var data = Data(capacity: 44 + pcmData.count)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        data.append(contentsOf: "RIFF".utf8)
        u32(UInt32(36 + pcmData.count))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        u32(16)
        u16(1)
        u16(channels)
        u32(sampleRate)
        u32(byteRate)
        u16(blockAlign)
        u16(bitsPerSample)
        data.append(contentsOf: "data".utf8)
        u32(UInt32(pcmData.count))
        data.append(pcmData)
        return data
    }

    private static func makePCM16MonoWAV(pcmData: Data, sampleRate: Int) -> Data {
        makeWAV(
            pcmData: pcmData,
            channels: 1,
            sampleRate: UInt32(sampleRate),
            byteRate: UInt32(sampleRate * 2),
            blockAlign: 2,
            bitsPerSample: 16
        )
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        data.withUnsafeBytes { rawBuffer in
            let ptr = rawBuffer.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt16.self)
            return UInt16(littleEndian: ptr.pointee)
        }
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { rawBuffer in
            let ptr = rawBuffer.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt32.self)
            return UInt32(littleEndian: ptr.pointee)
        }
    }
}
