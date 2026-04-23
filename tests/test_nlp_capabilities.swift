#!/usr/bin/env swift
// Smoke test for Apple's NaturalLanguage framework.
//
// Validates the claims made about adding intelligent styling to TTSDialog
// WITHOUT an LLM. For each claim, run the API on realistic text, print the
// raw output, and measure wall-clock time. If output quality is poor or
// timing is slow, we should NOT add the feature.
//
// Run:  swift tests/test_nlp_capabilities.swift
//
// Success criteria (per-feature, gut-call thresholds):
//   - Named entities: correctly tags people, places, orgs in mixed prose
//   - Sentiment: discriminates clearly positive vs negative sentences
//   - Parts of speech: correctly identifies noun/verb for common words
//   - Timing: any feature slower than ~5 ms per 200-char chunk is rejected
//     (the TTS dialog shows 10-20 chunks; total budget is sub-100 ms).
//
// When in doubt, read the raw printed output below and judge visually.

import Foundation
import NaturalLanguage

// MARK: - Test fixtures (real-world messy text)

let fixtures: [String] = [
    "Ali bought a MacBook at the Apple Store in San Francisco last Tuesday. He paid $2,499.",
    "Dr. Smith from Stanford said the results were absolutely terrible and disappointing.",
    "I'm SO excited about the trip to Paris! It's going to be amazing.",
    "The meeting with Google and Microsoft is scheduled for 3:30 PM on October 15th.",
    "This is a perfectly normal sentence with no special entities or feelings.",
    "She quietly whispered, \"I don't trust them\", and walked out of the room.",
    "We deployed v1.2.3 to production. The API latency dropped from 250 ms to 42 ms.",
    "Is this actually going to work? I have my doubts.",
]

// MARK: - Utilities

func bench<T>(_ label: String, _ block: () -> T) -> (T, Double) {
    let t0 = CFAbsoluteTimeGetCurrent()
    let out = block()
    let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000  // ms
    print(String(format: "  [timing] %@ → %.2f ms", label, elapsed))
    return (out, elapsed)
}

func section(_ name: String) {
    print("")
    print(String(repeating: "═", count: 72))
    print(" \(name)")
    print(String(repeating: "═", count: 72))
}

// MARK: - Test 1: Named entities (people / places / orgs)

section("1. NAMED ENTITIES — NLTagger(.nameType)")
print("Claim: identify people, places, organizations in prose.")
print("")

func namedEntities(_ text: String) -> [(String, NLTag)] {
    let tagger = NLTagger(tagSchemes: [.nameType])
    tagger.string = text
    var out: [(String, NLTag)] = []
    let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]
    tagger.enumerateTags(
        in: text.startIndex..<text.endIndex,
        unit: .word, scheme: .nameType, options: options
    ) { tag, range in
        if let tag, [.personalName, .placeName, .organizationName].contains(tag) {
            out.append((String(text[range]), tag))
        }
        return true
    }
    return out
}

var totalEntityTime: Double = 0
for s in fixtures {
    print("  INPUT : \(s)")
    let (entities, t) = bench("named entities") { namedEntities(s) }
    totalEntityTime += t
    if entities.isEmpty {
        print("  OUTPUT: (none)")
    } else {
        for (token, tag) in entities {
            print("  OUTPUT: \(token) → \(tag.rawValue)")
        }
    }
    print("")
}
print(String(format: "  ★ total for %d chunks: %.2f ms (avg %.2f ms/chunk)",
             fixtures.count, totalEntityTime, totalEntityTime / Double(fixtures.count)))

// MARK: - Test 2: Sentiment

section("2. SENTIMENT — NLTagger(.sentimentScore)")
print("Claim: score -1.0 (negative) to +1.0 (positive) per sentence.")
print("")

func sentiment(_ text: String) -> Double {
    let tagger = NLTagger(tagSchemes: [.sentimentScore])
    tagger.string = text
    let (tag, _) = tagger.tag(at: text.startIndex, unit: .paragraph, scheme: .sentimentScore)
    return Double(tag?.rawValue ?? "0") ?? 0
}

var totalSentTime: Double = 0
for s in fixtures {
    let (score, t) = bench("sentiment") { sentiment(s) }
    totalSentTime += t
    let bar = score > 0.3 ? "😊 POS" : score < -0.3 ? "😠 NEG" : "😐 NEU"
    print(String(format: "  %@ (%.2f)  %@", bar, score, s))
}
print(String(format: "  ★ total: %.2f ms (avg %.2f ms/chunk)",
             totalSentTime, totalSentTime / Double(fixtures.count)))

// MARK: - Test 3: Parts of speech

section("3. PARTS OF SPEECH — NLTagger(.lexicalClass)")
print("Claim: tag each word as noun/verb/adj/etc. on-device.")
print("")

func lexicalClasses(_ text: String) -> [(String, NLTag)] {
    let tagger = NLTagger(tagSchemes: [.lexicalClass])
    tagger.string = text
    var out: [(String, NLTag)] = []
    tagger.enumerateTags(
        in: text.startIndex..<text.endIndex,
        unit: .word, scheme: .lexicalClass, options: [.omitPunctuation, .omitWhitespace]
    ) { tag, range in
        if let tag { out.append((String(text[range]), tag)) }
        return true
    }
    return out
}

let posSample = fixtures[0]   // Ali bought a MacBook…
print("  INPUT : \(posSample)")
let (poses, posTime) = bench("lexical class") { lexicalClasses(posSample) }
for (token, tag) in poses {
    print("  \(token.padding(toLength: 14, withPad: " ", startingAt: 0)) → \(tag.rawValue)")
}
print(String(format: "  ★ %.2f ms for 15-word sentence", posTime))

// MARK: - Test 4: Throughput — worst-case full dialog

section("4. THROUGHPUT — 20 chunks × 200 chars each (realistic TTS dialog)")
print("Claim: under 100 ms total to run named-entity + sentiment on all chunks.")
print("")

let longChunk = String(repeating: "Ali met Sarah at the Google office in Mountain View. They discussed the iPhone launch. ", count: 3)
    .prefix(200)
let many = Array(repeating: String(longChunk), count: 20)

let (_, totalT) = bench("20 chunks: named-entity + sentiment each") {
    for c in many {
        _ = namedEntities(c)
        _ = sentiment(c)
    }
}
print(String(format: "  → %.2f ms total · %.2f ms per chunk", totalT, totalT / 20))

// MARK: - Verdict

section("VERDICT")
print("""
  Look above at the raw output for each feature:

    • Named entities: did "Ali", "Apple", "San Francisco", "Stanford",
      "Google", "Microsoft", "Paris" all get tagged correctly?
      If most are right, ship the "highlight entities" feature.

    • Sentiment: did the "terrible and disappointing" sentence score
      negative, the "SO excited" sentence score positive, and the
      neutral one score near zero? If yes, ship sentiment-aware accent.
      If the scores are mushy (all near 0), skip this feature.

    • Parts of speech: did "bought" come back as a verb and "MacBook"
      as a noun? If yes, we have enough granularity for first-mention
      bolding. If everything is "otherWord", skip.

    • Throughput: total for 20 chunks should be well under 100 ms. If
      any single feature is over 5 ms per 200-char chunk, it's too slow.

  If all three features pass, append them to Use Full Capabilities.txt.
  If any fail, report specifically which one and we'll decide per-feature.
""")
