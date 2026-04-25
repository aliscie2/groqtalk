import Foundation

struct ConfigManager {
    static let sampleRate = 16_000
    static let silenceThreshold: Float = 0.003
    static let silenceAboveRatio: Float = 0.02
}

enum Log {
    static func debug(_ message: String) {}
    static func info(_ message: String) {}
    static func error(_ message: String) {}
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

func makePCM16WAV(samples: [Int16], sampleRate: UInt32 = 16_000) -> Data {
    let channels: UInt16 = 1
    let bitsPerSample: UInt16 = 16
    let blockAlign = channels * (bitsPerSample / 8)
    let byteRate = sampleRate * UInt32(blockAlign)
    let pcmDataSize = samples.count * Int(blockAlign)

    var data = Data()
    func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

    data.append(contentsOf: "RIFF".utf8)
    u32(UInt32(36 + pcmDataSize))
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
    u32(UInt32(pcmDataSize))

    for sample in samples {
        withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
    }
    return data
}

func readPCM16Samples(_ wav: Data) -> [Int16] {
    let dataSize = Int(wav.subdata(in: 40..<44).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian)
    let pcm = wav.subdata(in: 44..<(44 + dataSize))
    return pcm.withUnsafeBytes { raw in
        let ptr = raw.bindMemory(to: Int16.self)
        return Array(ptr.map { Int16(littleEndian: $0) })
    }
}

@main
struct AudioProcessorWAVTests {
    static func main() {
        let wavA = makePCM16WAV(samples: [1000, 2000, -1000, -2000])
        let wavB = makePCM16WAV(samples: [3000, 4000])

        guard let merged = AudioProcessor.concatenateWAVFiles([wavA, wavB]) else {
            fatalError("Expected WAV merge to succeed")
        }

        expect(merged.prefix(4) == Data("RIFF".utf8), "Merged file should remain a RIFF/WAVE file")
        expect(readPCM16Samples(merged) == [1000, 2000, -1000, -2000, 3000, 4000],
               "Merged PCM samples should concatenate in order")
        expect(abs((AudioProcessor.wavDuration(merged) ?? 0) - 0.000375) < 0.000001,
               "Expected WAV duration to be derived from PCM frame count")

        let mismatched = makePCM16WAV(samples: [1, 2], sampleRate: 24_000)
        expect(AudioProcessor.concatenateWAVFiles([wavA, mismatched]) == nil,
               "Mismatched sample rates should not be merged into a bogus WAV")

        let silent = AudioProcessor.silentWAV(seconds: 0.5, sampleRate: 16_000)
        let silentSamples = readPCM16Samples(silent)
        expect(silentSamples.count == 8_000, "Expected 0.5 seconds of 16 kHz mono PCM")
        expect(silentSamples.allSatisfy { $0 == 0 }, "Expected generated warmup WAV to contain silence")

        print("AudioProcessor WAV tests passed")
    }
}
