//
//  AppGuitarraTests.swift
//  AppGuitarraTests
//
//  Created by Daniela Caiceros on 19/10/26.
//

import AVFoundation
import XCTest
@testable import AppGuitarra

final class ChordLibraryTests: XCTestCase {
    private func loadChords() throws -> [Chord] {
        try ChordLibrary.loadChords()
    }

    func testLoadsAllFifteenMVPChords() throws {
        let chords = try loadChords()
        XCTAssertEqual(chords.count, 15)
        XCTAssertEqual(Set(chords.map(\.id)).count, chords.count, "Chord ids must be unique")
    }

    func testEveryChordHasSixStringsAndAFingerPerFrettedNote() throws {
        for chord in try loadChords() {
            XCTAssertEqual(chord.frets.count, 6, chord.id)
            XCTAssertEqual(chord.fingers.count, 6, chord.id)
            for (fret, finger) in zip(chord.frets, chord.fingers) {
                XCTAssertEqual(fret > 0, finger > 0, "\(chord.id): fretted notes need a finger, open/muted strings none")
                XCTAssertTrue((0...4).contains(finger), chord.id)
            }
        }
    }

    func testChordTonesAreCorrect() throws {
        // Pitch classes: C=0 C#=1 D=2 D#=3 E=4 F=5 F#=6 G=7 G#=8 A=9 A#=10 B=11
        let expected: [String: Set<Int>] = [
            "C": [0, 4, 7], "D": [2, 6, 9], "E": [4, 8, 11], "G": [7, 11, 2], "A": [9, 1, 4],
            "Am": [9, 0, 4], "Dm": [2, 5, 9], "Em": [4, 7, 11],
            "E7": [4, 8, 11, 2], "A7": [9, 1, 4, 7], "D7": [2, 6, 9, 0], "G7": [7, 11, 2, 5], "B7": [11, 3, 6, 9],
            "F": [5, 9, 0], "Fmaj7": [5, 9, 0, 4],
        ]
        let chords = try loadChords()
        XCTAssertEqual(Set(chords.map(\.id)), Set(expected.keys))
        for chord in chords {
            XCTAssertEqual(chord.pitchClasses, expected[chord.id], chord.id)
        }
    }

    func testFHasPartialBarreOnTheTwoHighStrings() throws {
        let f = try XCTUnwrap(try loadChords().first { $0.id == "F" })
        let barre = try XCTUnwrap(f.barre)
        XCTAssertEqual(barre.fret, 1)
        XCTAssertEqual(barre.stringIndexes, 4...5)
    }

    func testFingerOrderAndPlacements() throws {
        let g = try XCTUnwrap(try loadChords().first { $0.id == "G" })
        XCTAssertEqual(g.fingerOrder, [1, 2, 3])
        XCTAssertEqual(g.placements.map(\.stringIndex), [1, 0, 5])
        XCTAssertEqual(g.playedStringIndexes, [0, 1, 2, 3, 4, 5])
    }

    func testDecodesChordWithoutBarre() throws {
        let json = #"[{"id":"Em","name":"E minor","frets":[0,2,2,0,0,0],"fingers":[0,2,3,0,0,0],"baseFret":1}]"#
        let chords = try ChordLibrary.decode(Data(json.utf8))
        XCTAssertNil(chords.first?.barre)
    }
}

final class PitchTests: XCTestCase {
    private let sampleRate = 48_000.0

    /// A plucked-string-like tone: fundamental plus two harmonics.
    private func tone(_ frequency: Double, count: Int = 4096, amplitude: Float = 0.4) -> [Float] {
        (0..<count).map { i in
            let t = Double(i) / sampleRate
            let value = sin(2 * .pi * frequency * t) + 0.5 * sin(4 * .pi * frequency * t) + 0.25 * sin(6 * .pi * frequency * t)
            return amplitude * Float(value) / 1.75
        }
    }

    private func detect(_ samples: [Float]) -> Double? {
        let analyzer = PitchAnalyzer(sampleRate: sampleRate)
        return samples.withUnsafeBufferPointer { analyzer.process($0) }
    }

    func testDetectsEveryOpenString() throws {
        let openStrings = [82.41, 110.00, 146.83, 196.00, 246.94, 329.63]
        for expected in openStrings {
            let detected = try XCTUnwrap(detect(tone(expected)), "No pitch for \(expected) Hz")
            let cents = 1200 * log2(detected / expected)
            XCTAssertLessThan(abs(cents), 3, "Expected \(expected) Hz, got \(detected) Hz")
        }
    }

    func testSilenceHasNoPitch() {
        XCTAssertNil(detect([Float](repeating: 0, count: 4096)))
    }

    func testReadingNameAndCents() {
        let a = PitchReading(frequency: 440)
        XCTAssertEqual(a.noteName, "A")
        XCTAssertEqual(a.octave, 4)
        XCTAssertEqual(a.cents, 0, accuracy: 0.01)
        XCTAssertTrue(a.isInTune)

        let sharpA = PitchReading(frequency: 445)
        XCTAssertEqual(sharpA.cents, 19.56, accuracy: 0.1)
        XCTAssertFalse(sharpA.isInTune)

        XCTAssertEqual(PitchReading(frequency: 82.41).nearestStringIndex, 0)
        XCTAssertEqual(PitchReading(frequency: 329.63).nearestStringIndex, 5)
        XCTAssertEqual(PitchReading(frequency: 82.41).noteName, "E")
        XCTAssertEqual(PitchReading(frequency: 82.41).octave, 2)
    }
}

final class TuningStateTests: XCTestCase {
    private func frequency(string index: Int, cents: Double) -> Double {
        TuningState.frequency(ofString: index) * pow(2, cents / 1200)
    }

    @discardableResult
    private func feed(_ state: inout TuningState, _ frequency: Double, times: Int = 10) -> TunerOutput? {
        var last: TunerOutput?
        for _ in 0..<times { last = state.update(frequency) }
        return last
    }

    func testFindsStringAndCents() throws {
        var state = TuningState()
        let output = try XCTUnwrap(feed(&state, frequency(string: 1, cents: 12)))
        XCTAssertEqual(output.stringIndex, 1)
        XCTAssertEqual(output.cents, 12, accuracy: 0.5)
        XCTAssertFalse(output.isInTune)
    }

    func testInTuneHasHysteresis() throws {
        var state = TuningState()
        XCTAssertTrue(try XCTUnwrap(feed(&state, frequency(string: 2, cents: 3))).isInTune)
        XCTAssertTrue(try XCTUnwrap(feed(&state, frequency(string: 2, cents: 7))).isInTune, "7 cents is inside the exit band")
        XCTAssertFalse(try XCTUnwrap(feed(&state, frequency(string: 2, cents: 15))).isInTune)
        XCTAssertFalse(try XCTUnwrap(feed(&state, frequency(string: 2, cents: 7))).isInTune, "must come back under 5 cents to re-enter")
    }

    func testSettlesAfterStayingInTune() {
        var state = TuningState()
        let target = frequency(string: 4, cents: 0)
        XCTAssertFalse(state.update(target).isSettled)
        XCTAssertTrue(feed(&state, target, times: 3)?.isSettled ?? false)
    }

    func testSwitchesStringOnlyAfterSeveralReadings() {
        var state = TuningState()
        feed(&state, frequency(string: 1, cents: 0))
        let d = frequency(string: 2, cents: 0)
        XCTAssertEqual(state.update(d).stringIndex, 1)
        XCTAssertEqual(state.update(d).stringIndex, 1)
        XCTAssertEqual(state.update(d).stringIndex, 2)
    }

    func testLockedStringIgnoresOtherStrings() throws {
        var state = TuningState(lockedString: 0)
        let output = try XCTUnwrap(feed(&state, frequency(string: 1, cents: 0)))
        XCTAssertEqual(output.stringIndex, 0)
        XCTAssertEqual(output.cents, 500, accuracy: 1)
        XCTAssertTrue(output.isLocked)
    }

    func testSynthRendersAudibleStrum() {
        let samples = ChordSynth.renderStrum(midiNotes: [nil, 48, 52, 55, 60, 64], stringDelay: 0.05, sampleRate: 44_100, duration: 1)
        XCTAssertEqual(samples.count, 44_100)
        let peak = samples.map(abs).max() ?? 0
        XCTAssertGreaterThan(peak, 0.1)
        XCTAssertLessThanOrEqual(peak, 0.81)
    }
}
