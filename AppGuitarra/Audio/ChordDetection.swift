//
//  ChordDetection.swift
//  AppGuitarra
//
//  Recognizes chords from a power spectrum by comparing its chroma
//  (energy per pitch class, C...B) with the chroma each chord should have.
//  Pure math, no audio I/O, so everything here is unit-tested.
//

import Foundation

// MARK: - Chroma

nonisolated enum ChromaExtractor {
    /// 12-bin chroma (C = 0 ... B = 11), L2-normalized; all zeros when there is no signal.
    ///
    /// Only spectral peaks count, each placed on its nearest semitone with
    /// parabolic interpolation. Peak heights are log-compressed so a loud bass
    /// note does not hide the rest of the chord.
    static func chroma(
        power: [Float],
        binHz: Double,
        minFrequency: Double = 70,
        maxFrequency: Double = 1000,
        relativeFloor: Float = 0.03
    ) -> [Float] {
        var chroma = [Float](repeating: 0, count: 12)
        guard power.count > 3, binHz > 0 else { return chroma }
        let lowBin = max(1, Int(minFrequency / binHz))
        let highBin = min(power.count - 2, Int(maxFrequency / binHz) + 1)
        guard highBin > lowBin else { return chroma }

        let magnitude = power.map { $0.squareRoot() }
        let peak = magnitude[lowBin...highBin].max() ?? 0
        guard peak > 0 else { return chroma }

        for k in lowBin...highBin {
            let m = magnitude[k]
            guard m > magnitude[k - 1], m >= magnitude[k + 1], m > relativeFloor * peak else { continue }
            let a = log(Double(magnitude[k - 1]) + 1e-12)
            let b = log(Double(m) + 1e-12)
            let c = log(Double(magnitude[k + 1]) + 1e-12)
            let denominator = a - 2 * b + c
            let shift = abs(denominator) > 1e-9 ? 0.5 * (a - c) / denominator : 0
            let frequency = (Double(k) + shift) * binHz
            guard frequency >= minFrequency, frequency <= maxFrequency else { continue }
            chroma[pitchClass(of: frequency)] += Float(log(1 + 20 * Double(m / peak)))
        }
        return normalized(chroma)
    }

    static func pitchClass(of frequency: Double) -> Int {
        let midi = Int((69 + 12 * log2(frequency / 440)).rounded())
        return ((midi % 12) + 12) % 12
    }

    static func normalized(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? vector.map { $0 / norm } : vector
    }

    /// Cosine similarity of two normalized vectors.
    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }
}

// MARK: - Templates

/// The chroma a chord is expected to produce.
nonisolated struct ChordTemplate: Hashable, Sendable {
    let id: String
    let profile: [Float]

    init(id: String, profile: [Float]) {
        self.id = id
        self.profile = ChromaExtractor.normalized(profile)
    }

    /// Guitar voicing with its first harmonics (1/h weights), limited to the
    /// band the detector listens to. Harmonics matter: the 3rd harmonic of a
    /// root is its fifth, the 5th harmonic its major third.
    init(id: String, midiNotes: [Int], minFrequency: Double = 70, maxFrequency: Double = 1000, harmonics: Int = 6) {
        var profile = [Float](repeating: 0, count: 12)
        for note in midiNotes {
            let f0 = 440 * pow(2, Double(note - 69) / 12)
            for h in 1...harmonics {
                let f = f0 * Double(h)
                guard f >= minFrequency, f <= maxFrequency else { continue }
                profile[ChromaExtractor.pitchClass(of: f)] += 1 / Float(h)
            }
        }
        self.init(id: id, profile: profile)
    }

    init(chord: Chord) {
        self.init(id: chord.id, midiNotes: chord.midiNotes.compactMap { $0 })
    }
}

nonisolated struct ChordMatch: Hashable, Sendable {
    let id: String
    let similarity: Float
}

// MARK: - Live verdicts

/// How picky the microphone check is. Stored with @AppStorage("detectionTolerance").
nonisolated enum DetectionTolerance: String, CaseIterable, Identifiable, Sendable {
    case relaxed, normal, strict

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    /// Minimum similarity between what is heard and the chord.
    var threshold: Float {
        switch self {
        case .relaxed: 0.72
        case .normal: 0.80
        case .strict: 0.87
        }
    }
}

nonisolated enum ChordVerdict: Equatable, Sendable {
    /// Nothing loud enough to judge.
    case silence
    /// The expected chord is what sounds.
    case match(similarity: Float)
    /// Another chord from the library sounds clearly better.
    case other(String)
    /// Something sounds, but not clearly the expected chord.
    case unclear(similarity: Float)

    var isMatch: Bool { if case .match = self { true } else { false } }
}

/// Compares a frame against the chords of the library.
nonisolated struct ChordJudge: Sendable {
    let templates: [ChordTemplate]
    var threshold: Float
    /// How far below the best match the expected chord may be and still count
    /// (G and G7 sound almost the same, for example).
    var margin: Float = 0.03

    init(templates: [ChordTemplate], threshold: Float) {
        self.templates = templates
        self.threshold = threshold
    }

    init(chords: [Chord], tolerance: DetectionTolerance = .normal) {
        self.init(templates: chords.map(ChordTemplate.init(chord:)), threshold: tolerance.threshold)
    }

    /// All templates from most to least similar.
    func ranking(_ chroma: [Float]) -> [ChordMatch] {
        templates
            .map { ChordMatch(id: $0.id, similarity: ChromaExtractor.similarity(chroma, $0.profile)) }
            .sorted { $0.similarity > $1.similarity }
    }

    func verdict(chroma: [Float], isSilent: Bool, expected: String) -> ChordVerdict {
        guard !isSilent else { return .silence }
        let ranking = ranking(chroma)
        guard let best = ranking.first,
              let expectedSimilarity = ranking.first(where: { $0.id == expected })?.similarity else {
            return .unclear(similarity: 0)
        }
        if expectedSimilarity >= threshold, expectedSimilarity >= best.similarity - margin {
            return .match(similarity: expectedSimilarity)
        }
        if best.id != expected, best.similarity >= threshold, best.similarity - expectedSimilarity > margin {
            return .other(best.id)
        }
        return .unclear(similarity: expectedSimilarity)
    }

    func verdict(_ frame: ListenFrame, expected: String) -> ChordVerdict {
        verdict(chroma: frame.chroma, isSilent: frame.isSilent, expected: expected)
    }

    /// Which of a few chords is sounding (nil when none clearly does).
    func bestChord(chroma: [Float], isSilent: Bool, among ids: [String], minimumLead: Float = 0.02) -> String? {
        guard !isSilent else { return nil }
        let scores = templates
            .filter { ids.contains($0.id) }
            .map { ChordMatch(id: $0.id, similarity: ChromaExtractor.similarity(chroma, $0.profile)) }
            .sorted { $0.similarity > $1.similarity }
        guard let best = scores.first, best.similarity >= threshold else { return nil }
        if scores.count > 1, best.similarity - scores[1].similarity < minimumLead { return nil }
        return best.id
    }
}

// MARK: - Per-string check

nonisolated struct StringReport: Hashable, Sendable {
    nonisolated enum Status: Hashable, Sendable {
        /// Sounds as it should (or is correctly left out).
        case ok
        /// Should ring but is barely heard: muted by a finger, or not pressed hard enough.
        case quiet
        /// Should not be strummed, but is ringing.
        case shouldBeMuted
        /// Cannot be told apart from another string's overtones, or too low for the iPad mic.
        case notChecked
    }

    /// 0 = low E ... 5 = high E.
    let stringIndex: Int
    let status: Status
}

/// Looks at each string's own frequency to guess which string failed.
///
/// A string can only be judged when its note is not an overtone of a lower
/// string in the same chord (in C, the B string's C4 is the 2nd harmonic of the
/// A string's C3, so a muted B string would be hidden) and when it is high
/// enough for the iPad microphone, which barely hears below ~140 Hz.
nonisolated enum StringChecker {
    /// Semitone distances of harmonics 2...6.
    static let harmonicIntervals: Set<Int> = [12, 19, 24, 28, 31]
    static let lowestCheckedFrequency = 140.0
    /// A string this far below the median string (−20 dB) counts as not ringing.
    static let quietRatio: Float = 0.01
    /// A muted string louder than this (−5 dB) is ringing when it should not.
    static let ringingRatio: Float = 0.3

    static func frequency(ofMIDI midi: Int) -> Double {
        440 * pow(2, Double(midi - 69) / 12)
    }

    /// Strings whose sound can be judged on their own.
    static func checkableStrings(of chord: Chord) -> [Int] {
        let notes = chord.midiNotes
        return notes.indices.filter { index in
            guard let note = notes[index], frequency(ofMIDI: note) >= lowestCheckedFrequency else { return false }
            return !notes.indices.contains { other in
                guard other != index, let lower = notes[other] else { return false }
                let interval = note - lower
                return harmonicIntervals.contains(interval) || (interval == 0 && other < index)
            }
        }
    }

    /// Highest power within ±`cents` of a frequency.
    static func level(_ power: [Float], binHz: Double, frequency: Double, cents: Double = 35) -> Float {
        let low = max(1, Int((frequency * pow(2, -cents / 1200) / binHz).rounded(.down)))
        let high = min(power.count - 1, Int((frequency * pow(2, cents / 1200) / binHz).rounded(.up)))
        guard high >= low else { return 0 }
        return power[low...high].max() ?? 0
    }

    static func check(power: [Float], binHz: Double, chord: Chord) -> [StringReport] {
        let notes = chord.midiNotes
        var levels: [Int: Float] = [:]
        for (index, note) in notes.enumerated() {
            if let note { levels[index] = level(power, binHz: binHz, frequency: frequency(ofMIDI: note)) }
        }
        let sorted = levels.values.sorted()
        let reference = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let checkable = Set(checkableStrings(of: chord))
        let chordPitchClasses = chord.pitchClasses

        return (0..<Chord.stringCount).map { index in
            if let level = levels[index] {
                guard checkable.contains(index), reference > 0 else {
                    return StringReport(stringIndex: index, status: .notChecked)
                }
                return StringReport(stringIndex: index, status: level < reference * quietRatio ? .quiet : .ok)
            }
            // Muted string: only a problem if its open note is foreign to the chord.
            let open = Chord.standardTuning[index]
            guard !chordPitchClasses.contains(open % 12), reference > 0 else {
                return StringReport(stringIndex: index, status: .ok)
            }
            let f = frequency(ofMIDI: open)
            let ringing = max(level(power, binHz: binHz, frequency: f), level(power, binHz: binHz, frequency: 2 * f))
            return StringReport(stringIndex: index, status: ringing > reference * ringingRatio ? .shouldBeMuted : .ok)
        }
    }
}
