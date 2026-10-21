//
//  Phase2Tests.swift
//  AppGuitarraTests
//
//  Chord detection, mic scoring, change counting, chord names, capo advice
//  and song analysis. Audio comes from the app's own Karplus–Strong synth.
//

import XCTest
@testable import AppGuitarra

private let sampleRate = 48_000.0

private func chords() throws -> [String: Chord] {
    Dictionary(uniqueKeysWithValues: try ChordLibrary.loadChords().map { ($0.id, $0) })
}

/// A strum of the given strings (nil = not played), as heard `at` seconds after the pick.
private func strumSpectrum(_ notes: [Int?], at seconds: Double = 0.35) -> (power: [Float], binHz: Double) {
    let audio = ChordSynth.renderStrum(midiNotes: notes, stringDelay: 0.012, sampleRate: sampleRate, duration: 0.6)
    let spectrum = PowerSpectrum(size: 8192, sampleRate: sampleRate)
    let end = Int(seconds * sampleRate)
    let window = Array(audio[(end - 8192)..<end])
    return (spectrum.compute(window), spectrum.binHz)
}

final class ChordDetectionTests: XCTestCase {
    func testPowerSpectrumFindsASine() {
        let spectrum = PowerSpectrum(size: 4096, sampleRate: sampleRate)
        let frequency = 440.0
        let tone = (0..<4096).map { Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
        let power = spectrum.compute(tone)
        let peak = power.indices.max { power[$0] < power[$1] }!
        XCTAssertEqual(Double(peak) * spectrum.binHz, frequency, accuracy: spectrum.binHz)
    }

    func testChromaOfASingleNote() {
        let (power, binHz) = strumSpectrum([nil, 45, nil, nil, nil, nil])   // open A string
        let chroma = ChromaExtractor.chroma(power: power, binHz: binHz)
        XCTAssertEqual(chroma.indices.max { chroma[$0] < chroma[$1] }, 9, "A is pitch class 9")
    }

    func testEveryLibraryChordIsRecognized() throws {
        let library = try chords()
        let judge = ChordJudge(chords: Array(library.values), tolerance: .normal)
        for chord in library.values {
            // Average three strums, like a bar of playing (each synthetic strum is a bit different).
            var sum = [Float](repeating: 0, count: 12)
            for _ in 0..<3 {
                let (power, binHz) = strumSpectrum(chord.midiNotes)
                for (k, value) in ChromaExtractor.chroma(power: power, binHz: binHz).enumerated() { sum[k] += value }
            }
            let chroma = ChromaExtractor.normalized(sum)
            let verdict = judge.verdict(chroma: chroma, isSilent: false, expected: chord.id)
            XCTAssertTrue(verdict.isMatch, "\(chord.id): \(verdict)")
        }
    }

    func testWrongChordIsNotAccepted() throws {
        let library = try chords()
        let judge = ChordJudge(chords: Array(library.values), tolerance: .normal)
        let (power, binHz) = strumSpectrum(library["D"]!.midiNotes)
        let chroma = ChromaExtractor.chroma(power: power, binHz: binHz)
        XCTAssertFalse(judge.verdict(chroma: chroma, isSilent: false, expected: "G").isMatch)
        XCTAssertFalse(judge.verdict(chroma: chroma, isSilent: false, expected: "Am").isMatch)
        XCTAssertEqual(judge.bestChord(chroma: chroma, isSilent: false, among: ["G", "D"]), "D")
        XCTAssertEqual(judge.verdict(chroma: chroma, isSilent: true, expected: "D"), .silence)
    }

    func testCheckableStringsSkipOvertones() throws {
        let library = try chords()
        // C: the B string (C4) is the octave of the A string (C3), the high e (E4) of the D string (E3).
        XCTAssertEqual(StringChecker.checkableStrings(of: library["C"]!), [2, 3])
        XCTAssertEqual(StringChecker.checkableStrings(of: library["D"]!), [2, 3, 5])
    }

    func testMutedHighStringInD() throws {
        let d = try chords()["D"]!
        var notes = d.midiNotes
        notes[5] = nil   // high e muted by the ring finger
        let (power, binHz) = strumSpectrum(notes)
        let reports = StringChecker.check(power: power, binHz: binHz, chord: d)
        XCTAssertEqual(reports[5].status, .quiet)
        XCTAssertEqual(reports[2].status, .ok)
    }

    func testLowEShouldNotRingInD() throws {
        let d = try chords()["D"]!
        var notes = d.midiNotes
        notes[0] = 40   // low E strummed by mistake
        let (power, binHz) = strumSpectrum(notes)
        let reports = StringChecker.check(power: power, binHz: binHz, chord: d)
        XCTAssertEqual(reports[0].status, .shouldBeMuted)
    }

    func testCleanDHasNoProblems() throws {
        let d = try chords()["D"]!
        let (power, binHz) = strumSpectrum(d.midiNotes)
        let problems = StringChecker.check(power: power, binHz: binHz, chord: d)
            .filter { $0.status == .quiet || $0.status == .shouldBeMuted }
        XCTAssertEqual(problems, [])
    }

    func testListenAnalyzerSilenceAndSound() {
        let analyzer = ListenAnalyzer(sampleRate: sampleRate)
        let silence = [Float](repeating: 0, count: analyzer.windowSize)
        let frame = silence.withUnsafeBufferPointer { analyzer.process($0) }
        XCTAssertEqual(frame?.isSilent, true)

        let strum = ChordSynth.renderStrum(midiNotes: [nil, 45, 52, 57, 60, 64], stringDelay: 0.01, sampleRate: sampleRate, duration: 0.5)
        let sounding = strum.withUnsafeBufferPointer { analyzer.process($0) }
        XCTAssertEqual(sounding?.isSilent, false)
        XCTAssertEqual(sounding?.chroma.count, 12)
        XCTAssertFalse(sounding?.power.isEmpty ?? true)
    }
}

final class CheckScoringTests: XCTestCase {
    private func timeline(bars: Int = 4) throws -> PracticeTimeline {
        let library = try chords()
        let pattern = StrumPattern(id: "down", name: "Down", strokes: "D-D-D-D-")
        return PracticeTimeline(config: PracticeConfig(
            pattern: pattern,
            segments: [PracticeSegment(chord: library["G"]!, bars: 1), PracticeSegment(chord: library["D"]!, bars: 1)],
            bpm: 60, countInBars: 1, totalBars: bars
        ))
    }

    /// 60 bpm, 4/4: count-in 0–4 s, bar n from 4 + 4n.
    private func feed(_ scorer: inout CheckScorer, bar: Int, _ verdict: ChordVerdict) {
        for step in stride(from: 0.0, to: 4.0, by: 0.05) {
            scorer.add(verdict, at: 4 + Double(bar) * 4 + step)
        }
    }

    func testCleanRunPasses() throws {
        var scorer = CheckScorer(timeline: try timeline())
        for bar in 0..<4 { feed(&scorer, bar: bar, .match(similarity: 0.9)) }
        let result = scorer.result
        XCTAssertEqual(result.cleanBars, 4)
        XCTAssertTrue(result.passed)
        XCTAssertNil(result.advice)
        XCTAssertEqual(result.bars.map(\.expected), ["G", "D", "G", "D"])
    }

    func testLateChangeAndSilenceAreReported() throws {
        var scorer = CheckScorer(timeline: try timeline())
        feed(&scorer, bar: 0, .match(similarity: 0.9))
        feed(&scorer, bar: 1, .other("G"))
        feed(&scorer, bar: 2, .silence)
        feed(&scorer, bar: 3, .unclear(similarity: 0.5))
        let result = scorer.result
        XCTAssertEqual(result.bars.map(\.outcome), [.clean, .wrongChord("G"), .silent, .messy])
        XCTAssertFalse(result.passed)
        XCTAssertNotNil(result.advice)
    }

    func testCountInAndSettleTimeAreIgnored() throws {
        let scorer = CheckScorer(timeline: try timeline())
        XCTAssertNil(scorer.bar(at: 2))          // count-in
        XCTAssertNil(scorer.bar(at: 4.1))        // just after the change
        XCTAssertEqual(scorer.bar(at: 4.5), 0)
        XCTAssertEqual(scorer.bar(at: 19.9), 3)
        XCTAssertNil(scorer.bar(at: 20.5))       // after the end
    }

    func testChangeCounter() {
        var counter = ChangeCounter(first: "G", second: "D")
        let frames: [String?] = ["G", "G", "G", nil, "D", "D", "D", "D", "C", "G", "D", "G", "G", "G"]
        for frame in frames { counter.add(frame) }
        XCTAssertEqual(counter.changes, 2, "G→D and D→G; single stray frames don't count")
        XCTAssertEqual(counter.current, "G")
    }

    func testTrainerRecords() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "Phase2Tests"))
        defaults.removePersistentDomain(forName: "Phase2Tests")
        XCTAssertEqual(TrainerRecords.record("G", "D", defaults: defaults), 0)
        XCTAssertTrue(TrainerRecords.submit(12, "G", "D", defaults: defaults))
        XCTAssertFalse(TrainerRecords.submit(10, "D", "G", defaults: defaults))
        XCTAssertEqual(TrainerRecords.record("D", "G", defaults: defaults), 12)
    }
}

final class SongTests: XCTestCase {
    func testChordSymbolParsing() {
        XCTAssertEqual(ChordSymbol("F#m")?.name, "F#m")
        XCTAssertEqual(ChordSymbol("Bbmaj7")?.name, "Bbmaj7")
        XCTAssertEqual(ChordSymbol("A#")?.name, "Bb")
        XCTAssertEqual(ChordSymbol("Bm")?.root, 11)
        XCTAssertEqual(ChordSymbol("G7")?.pitchClasses, [7, 11, 2, 5])
        XCTAssertNil(ChordSymbol("Hm"))
        XCTAssertNil(ChordSymbol("Csus4"))
        XCTAssertEqual(ChordSymbol("A")?.transposed(by: -2).name, "G")
        XCTAssertEqual(ChordSymbol("C")?.transposed(by: -1).name, "B")
    }

    func testCapoTurnsAMajorSongIntoOpenShapes() throws {
        let library = Set(try chords().keys)
        let song = [SongChord(start: 0, name: "A"), SongChord(start: 4, name: "E"),
                    SongChord(start: 8, name: "F#m"), SongChord(start: 12, name: "D")]
        let best = try XCTUnwrap(CapoAdvisor.best(for: song, duration: 16, library: library))
        XCTAssertEqual(best.capo, 2)
        XCTAssertEqual(best.shapes, ["G", "D", "Em", "C"])
        XCTAssertEqual(best.coverage, 1, accuracy: 0.001)
    }

    func testBarreChordsHaveDiagramsButCapoIsStillPreferred() throws {
        let library = Set(try chords().keys)
        XCTAssertEqual(CapoAdvisor.ease(of: "F#m", library: library), 0.4, accuracy: 1e-9)
        XCTAssertEqual(CapoAdvisor.ease(of: "Bb7", library: library), 0.32, accuracy: 1e-9, "7th without shape → barre triad")
        // Bb F Gm Eb: with capo 3 it's G D Em C.
        let song = [SongChord(start: 0, name: "Bb"), SongChord(start: 4, name: "F"),
                    SongChord(start: 8, name: "Gm"), SongChord(start: 12, name: "Eb")]
        XCTAssertEqual(CapoAdvisor.best(for: song, duration: 16, library: library)?.capo, 3)
    }

    func testNoCapoWhenSongIsAlreadyEasy() throws {
        let library = Set(try chords().keys)
        let song = [SongChord(start: 0, name: "G"), SongChord(start: 4, name: "C"), SongChord(start: 8, name: "D")]
        XCTAssertEqual(CapoAdvisor.best(for: song, duration: 12, library: library)?.capo, 0)
    }

    func testEasyShapes() throws {
        let library = Set(try chords().keys)
        XCTAssertEqual(CapoAdvisor.easierShape("F", library: library), "Fmaj7")
        XCTAssertEqual(CapoAdvisor.easierShape("Cmaj7", library: library), "C")
        XCTAssertEqual(CapoAdvisor.easierShape("Am7", library: library), "Am")
        XCTAssertEqual(CapoAdvisor.easierShape("Bm", library: library), "Bm")
        XCTAssertEqual(CapoAdvisor.shape(for: "A", capo: 2, easy: true, library: library), "G")
    }

    func testChordIndexAndNormalize() {
        var song = Song(title: "Test", audioFileName: "audio.m4a", duration: 20)
        song.chords = [SongChord(start: 8, name: "D"), SongChord(start: 0, name: "G"),
                       SongChord(start: 4, name: "G"), SongChord(start: 12, name: "Em")]
        song.normalizeChords()
        XCTAssertEqual(song.chords.map(\.name), ["G", "D", "Em"])
        XCTAssertNil(Song(title: "x", audioFileName: "a", duration: 1).chordIndex(at: 1))
        XCTAssertEqual(song.chordIndex(at: 9), 1)
        XCTAssertEqual(song.chordIndex(at: 100), 2)
        XCTAssertEqual(song.end(ofChordAt: 2), 20)
    }

    func testViterbiPrefersStableChords() {
        // A single noisy block in the middle should not create a new chord.
        let a: [Float] = [1, 0], b: [Float] = [0, 1], noisy: [Float] = [0.45, 0.5]
        XCTAssertEqual(SongAnalyzer.viterbi(emissions: [a, a, noisy, a, a], switchPenalty: 0.1), [0, 0, 0, 0, 0])
        XCTAssertEqual(SongAnalyzer.viterbi(emissions: [a, a, b, b, b], switchPenalty: 0.1), [0, 0, 1, 1, 1])
    }

    func testAnalyzesASyntheticSong() throws {
        let library = try chords()
        let rate = 22_050.0
        let bpm = 100.0
        let beat = 60 / bpm
        let progression = ["G", "D", "Em", "C", "G", "D", "Em", "C"]
        let lead = 0.7
        var audio = [Float](repeating: 0, count: Int(rate * (lead + Double(progression.count * 8) * beat + 1)))
        var strums: [String: [Float]] = [:]
        for id in Set(progression) {
            strums[id] = ChordSynth.renderStrum(midiNotes: library[id]!.midiNotes, stringDelay: 0.012, sampleRate: rate, duration: beat * 1.2)
        }
        var time = lead
        for id in progression {
            for count in 0..<8 {   // two bars of quarter-note downstrokes
                let start = Int(time * rate)
                let gain: Float = count % 4 == 0 ? 1 : 0.7
                for (i, sample) in strums[id]!.enumerated() where start + i < audio.count {
                    audio[start + i] += sample * gain
                }
                time += beat
            }
        }

        let analysis = SongAnalyzer.analyze(samples: audio, sampleRate: rate)
        XCTAssertEqual(try XCTUnwrap(analysis.bpm), bpm, accuracy: bpm * 0.03)

        let found = analysis.chords.filter { !$0.isNoChord }.map(\.name)
        XCTAssertEqual(found, progression, "chords: \(analysis.chords.map { "\($0.name)@\(String(format: "%.1f", $0.start))" })")
        // Changes land within a beat of the truth.
        for (index, chord) in analysis.chords.filter({ !$0.isNoChord }).enumerated() where index > 0 {
            XCTAssertEqual(chord.start, lead + Double(index * 8) * beat, accuracy: beat * 1.5, chord.name)
        }
    }
}
