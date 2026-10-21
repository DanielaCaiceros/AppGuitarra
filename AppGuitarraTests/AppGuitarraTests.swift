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

    func testLoadsAllMVPChords() throws {
        let chords = try loadChords()
        XCTAssertEqual(chords.count, 30)
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
            "F": [5, 9, 0], "Fmaj7": [5, 9, 0, 4], "Bm": [11, 2, 6],
            // Barre chords: every other major and minor triad.
            "Bb": [10, 2, 5], "B": [11, 3, 6], "C#": [1, 5, 8], "Eb": [3, 7, 10], "F#": [6, 10, 1], "Ab": [8, 0, 3],
            "Cm": [0, 3, 7], "C#m": [1, 4, 8], "Ebm": [3, 6, 10], "Fm": [5, 8, 0], "F#m": [6, 9, 1],
            "Gm": [7, 10, 2], "Abm": [8, 11, 3], "Bbm": [10, 1, 5],
        ]
        let chords = try loadChords()
        XCTAssertEqual(Set(chords.map(\.id)), Set(expected.keys))
        for chord in chords {
            XCTAssertEqual(chord.pitchClasses, expected[chord.id], chord.id)
        }
    }

    func testEveryMajorAndMinorTriadHasAShape() throws {
        let ids = Set(try loadChords().map(\.id))
        for root in 0..<12 {
            for quality in [ChordSymbol.Quality.major, .minor] {
                let name = ChordSymbol(root: root, quality: quality).name
                XCTAssertTrue(ids.contains(name), "\(name) has no diagram")
            }
        }
    }

    func testBarreShapesListMatchesTheJSON() throws {
        let chords = try loadChords()
        XCTAssertEqual(Set(chords.filter(\.isFullBarre).map(\.id)), ChordLibrary.barreShapes)
        for chord in chords where chord.isFullBarre {
            let barre = try XCTUnwrap(chord.barre)
            XCTAssertEqual(barre.fret, chord.baseFret, chord.id)
            XCTAssertEqual(barre.fret, chord.frets.filter { $0 > 0 }.min(), "\(chord.id): the barre is the lowest fret")
            XCTAssertLessThanOrEqual(chord.highestFret - chord.baseFret, 3, "\(chord.id) fits in 4 frets")
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

// MARK: - Phase 1: lessons and practice timing

final class LessonCatalogTests: XCTestCase {
    func testLessonContentIsValid() throws {
        let catalog = try LessonCatalog.load()
        XCTAssertFalse(catalog.lessons.isEmpty)
        XCTAssertEqual(catalog.validationErrors(), [])
        XCTAssertEqual(Set(catalog.lessons.map(\.id)).count, catalog.lessons.count, "Lesson ids must be unique")
    }

    func testEveryLessonEndsWithACheck() throws {
        for lesson in try LessonCatalog.load().lessons {
            XCTAssertEqual(lesson.steps.last?.kind, .check, lesson.id)
        }
    }

    func testCheckInheritsPatternAndProgressionFromPractice() throws {
        let lesson = try XCTUnwrap(try LessonCatalog.load().lessons.first { $0.id == "L01" })
        let checkIndex = try XCTUnwrap(lesson.steps.lastIndex { $0.kind == .check })
        let resolved = try XCTUnwrap(lesson.resolvedCheck(at: checkIndex))
        XCTAssertEqual(resolved.pattern, "quarter-downs")
        XCTAssertEqual(resolved.progression.map(\.chord), ["Em", "Am"])
        XCTAssertEqual(lesson.practiceIndex(before: checkIndex), checkIndex - 1)
    }

    func testDecodesStepTypes() throws {
        let json = """
        [{ "id": "X", "number": 1, "module": "M", "title": "T", "summary": "S", "chords": ["G"],
           "steps": [
             { "type": "show", "title": "a", "text": "b", "chord": "G" },
             { "type": "practice", "title": "a", "text": "b", "pattern": "folk", "bpm": 70,
               "progression": [{ "chord": "G", "bars": 2 }] },
             { "type": "check", "title": "a", "goal": "g", "bars": 4, "bpm": 70 }
           ] }]
        """
        let lessons = try JSONDecoder().decode([Lesson].self, from: Data(json.utf8))
        XCTAssertEqual(lessons.first?.steps.map(\.kind), [.show, .practice, .check])
    }
}

final class StrumPatternTests: XCTestCase {
    func testFolkPatternParses() {
        let folk = StrumPattern(id: "folk", name: "Folk", strokes: "D-DU -UDU")
        XCTAssertTrue(folk.isValid)
        XCTAssertEqual(folk.slots, [.down, .miss, .down, .up, .miss, .up, .down, .up])
        XCTAssertEqual((0..<8).map(folk.countLabel), ["1", "&", "2", "&", "3", "&", "4", "&"])
    }

    func testInvalidPatterns() {
        XCTAssertFalse(StrumPattern(id: "x", name: "x", strokes: "D-D").isValid)
        XCTAssertFalse(StrumPattern(id: "x", name: "x", strokes: "D-DX-UDU").isValid)
        XCTAssertFalse(StrumPattern(id: "x", name: "x", strokes: "D-DU-UDU", accents: [8]).isValid)
    }
}

final class PracticeTimelineTests: XCTestCase {
    private func timeline(bpm: Double = 60, totalBars: Int? = nil) throws -> PracticeTimeline {
        let chords = try ChordLibrary.loadChords()
        let g = try XCTUnwrap(chords.first { $0.id == "G" })
        let d = try XCTUnwrap(chords.first { $0.id == "D" })
        let folk = StrumPattern(id: "folk", name: "Folk", strokes: "D-DU-UDU", accents: [0])
        return PracticeTimeline(config: PracticeConfig(
            pattern: folk,
            segments: [PracticeSegment(chord: g, bars: 2), PracticeSegment(chord: d, bars: 1)],
            bpm: bpm, countInBars: 1, totalBars: totalBars
        ))
    }

    func testCountIn() throws {
        // 60 bpm: one beat per second, count-in lasts 4 s.
        let t = try timeline()
        XCTAssertEqual(t.position(at: 0).countInBeat, 1)
        XCTAssertTrue(t.position(at: 2.5).isCountIn)
        XCTAssertEqual(t.position(at: 2.5).countInBeat, 3)
        XCTAssertFalse(t.position(at: 4.0).isCountIn)
    }

    func testBarsSlotsAndSegments() throws {
        let t = try timeline()
        let p = t.position(at: 4 + 1.75)   // bar 0, beat 1, second half → slot 3
        XCTAssertEqual(p.bar, 0)
        XCTAssertEqual(p.beat, 1)
        XCTAssertEqual(p.slot, 3)
        XCTAssertEqual(p.slotFraction, 0.5, accuracy: 1e-9)
        XCTAssertEqual(t.position(at: 4 + 4.1).segmentIndex, 0)    // bar 1: still G
        XCTAssertEqual(t.position(at: 4 + 8.1).segmentIndex, 1)    // bar 2: D
        XCTAssertEqual(t.position(at: 4 + 12.1).segmentIndex, 0)   // loops back to G
    }

    func testChangeIsAnnouncedOnTheLastBeat() throws {
        let t = try timeline()
        XCTAssertFalse(t.position(at: 4 + 3.5).isChangeComing)    // bar 0 → bar 1 is still G
        XCTAssertFalse(t.position(at: 4 + 6.5).isChangeComing)    // bar 1, beat 3
        XCTAssertTrue(t.position(at: 4 + 7.5).isChangeComing)     // bar 1, beat 4 → D next
        XCTAssertEqual(t.position(at: 4 + 7.5).nextSegmentIndex, 1)
    }

    func testFiniteRunEnds() throws {
        let t = try timeline(totalBars: 4)
        XCTAssertEqual(try XCTUnwrap(t.duration), 4 + 16, accuracy: 1e-9)
        XCTAssertFalse(t.position(at: 19.9).isFinished)
        XCTAssertTrue(t.position(at: 20.0).isFinished)
        XCTAssertFalse(t.position(at: 4 + 15.5).isChangeComing, "No change announced at the very end")
    }

    func testSoundsFollowThePattern() throws {
        let t = try timeline()
        XCTAssertEqual(t.countInSounds.count, 4)
        XCTAssertEqual(t.countInSounds.first?.sound, .clickAccent)
        // 3 bars × (4 clicks + 6 strokes)
        XCTAssertEqual(t.cycleSounds.count, 30)
        let strums = t.cycleSounds.filter { !$0.isClick }
        XCTAssertEqual(strums.prefix(6).map(\.sound), [.down("G"), .down("G"), .up("G"), .up("G"), .down("G"), .up("G")])
        XCTAssertEqual(strums.last?.sound, .up("D"))
        XCTAssertEqual(strums.first?.gain, 1, "Slot 0 is accented")
    }

    func testFramesDoNotDrift() throws {
        let t = try timeline(bpm: 70)
        // 1000 bars of eighth notes at 70 bpm, 48 kHz: exact to the sample.
        let slots = 1000 * 8
        let expected = Int((Double(slots) * 60 / 70 / 2 * 48_000).rounded())
        XCTAssertEqual(t.frame(forSlot: slots, sampleRate: 48_000), expected)
    }

    func testRenderProgramIsSortedAndInsideTheCycle() throws {
        let t = try timeline(bpm: 90)
        let ids: [PracticeTimeline.SoundID] = [.clickAccent, .click, .down("G"), .up("G"), .down("D"), .up("D")]
        let bank = SoundBank(ids: ids, samples: ids.map { _ in [Float](repeating: 0.1, count: 10) })
        let program = RenderProgram(timeline: t, bank: bank, sampleRate: 44_100)
        XCTAssertEqual(program.cycle.count, t.cycleSounds.count)
        XCTAssertEqual(program.cycle.map(\.frame), program.cycle.map(\.frame).sorted())
        XCTAssertTrue(program.cycle.allSatisfy { $0.frame < program.cycleFrames })
        XCTAssertEqual(program.endFrame, .max)
    }
}
