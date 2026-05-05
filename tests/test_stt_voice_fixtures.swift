import Foundation

struct STTManifest: Decodable {
    let fixtures: [STTFixture]
}

struct STTFixture: Decodable {
    let name: String
    let wavPath: String
    let mode: String?
    let expectedText: String
    let requiredPhrases: [String]?
    let maxEditDistanceRatio: Double?
}

func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fail(message) }
}

func normalizedForComparison(_ text: String) -> String {
    let lowered = text.lowercased()
    let scalarView = lowered.unicodeScalars.map { scalar -> Character in
        if CharacterSet.alphanumerics.contains(scalar) || scalar == "'" {
            return Character(scalar)
        }
        return " "
    }
    return String(scalarView)
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func levenshteinDistance(_ left: String, _ right: String) -> Int {
    let a = Array(left)
    let b = Array(right)
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }

    var previous = Array(0...b.count)
    var current = Array(repeating: 0, count: b.count + 1)

    for i in 1...a.count {
        current[0] = i
        for j in 1...b.count {
            let substitutionCost = a[i - 1] == b[j - 1] ? 0 : 1
            current[j] = min(
                previous[j] + 1,
                current[j - 1] + 1,
                previous[j - 1] + substitutionCost
            )
        }
        swap(&previous, &current)
    }

    return previous[b.count]
}

func resolveMode(_ rawMode: String?) -> ConfigManager.STTMode {
    guard let rawMode else { return .whisperLarge }
    guard let mode = ConfigManager.STTMode(rawValue: rawMode) else {
        fail("Unknown STT mode `\(rawMode)`")
    }
    return mode
}

func transcribe(fixture: STTFixture, repoRoot: URL, api: GroqAPIClient) async throws -> (raw: String, cleaned: String) {
    let wavURL = repoRoot.appendingPathComponent(fixture.wavPath)
    let wavData = try Data(contentsOf: wavURL)
    let mode = resolveMode(fixture.mode)

    let transcript: StructuredTranscript
    switch mode {
    case .parakeet:
        transcript = try await api.transcribeMLXAudioDetails(
            wavData: wavData,
            model: ConfigManager.parakeetModel,
            verbose: true,
            timeout: 90
        )
    case .whisperSmall, .whisperLarge:
        transcript = try await api.transcribeWhisperServerDetails(
            wavData: wavData,
            baseURL: ConfigManager.sttServerURL(for: mode),
            verbose: false,
            timeout: 90
        )
    }

    return (
        raw: transcript.text.trimmingCharacters(in: .whitespacesAndNewlines),
        cleaned: TranscriptPostProcessor.clean(transcript)
    )
}

@main
struct STTVoiceFixtureTests {
    static func main() async {
        let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let manifestURL = repoRoot.appendingPathComponent("tests/fixtures/stt/manifest.json")

        let manifest: STTManifest
        do {
            let data = try Data(contentsOf: manifestURL)
            manifest = try JSONDecoder().decode(STTManifest.self, from: data)
        } catch {
            fail("Could not load STT fixture manifest: \(error)")
        }

        expect(!manifest.fixtures.isEmpty, "Expected at least one STT voice fixture")

        let api = GroqAPIClient()
        for fixture in manifest.fixtures {
            do {
                let result = try await transcribe(fixture: fixture, repoRoot: repoRoot, api: api)
                let actualComparable = normalizedForComparison(result.cleaned)
                let expectedComparable = normalizedForComparison(fixture.expectedText)
                let distance = levenshteinDistance(actualComparable, expectedComparable)
                let denominator = max(expectedComparable.count, 1)
                let ratio = Double(distance) / Double(denominator)
                let maxRatio = fixture.maxEditDistanceRatio ?? 0.2

                expect(
                    ratio <= maxRatio,
                    """
                    \(fixture.name) drifted too far from expected text.
                    raw: \(result.raw)
                    cleaned: \(result.cleaned)
                    expected: \(fixture.expectedText)
                    edit ratio: \(String(format: "%.3f", ratio)) > \(maxRatio)
                    """
                )

                let actualPhraseHaystack = result.cleaned.lowercased()
                for phrase in fixture.requiredPhrases ?? [] {
                    expect(
                        actualPhraseHaystack.contains(phrase.lowercased()),
                        """
                        \(fixture.name) is missing required phrase `\(phrase)`.
                        raw: \(result.raw)
                        cleaned: \(result.cleaned)
                        """
                    )
                }

                print("STT fixture passed: \(fixture.name) -> \(result.cleaned)")
            } catch {
                fail("\(fixture.name) failed: \(error)")
            }
        }

        print("STT voice fixture tests passed")
    }
}
