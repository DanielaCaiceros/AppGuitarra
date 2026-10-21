//
//  StrumDetectionTests.swift
//  AppGuitarraTests
//
//  Strum pattern guessed from an imported song, the pattern position during
//  playback, and old song.json files without the new fields.
//

import XCTest
@testable import AppGuitarra

final class StrumDetectionTests: XCTestCase {
    /// A synthetic song strummed with the folk pattern (D-DU-UDU), one chord per bar.
    func testFindsTheFolkPatternAndTheBarStart() throws {
        let library = Dictionary(uniqueKeysWithValues: try ChordLibrary.loadChords().map { ($0.id, $0) })
        let rate = 22_050.0
        let bpm = 100.0
        let beat = 60 / bpm
        let slot = beat / 2
        let lead = 0.7
        let progression = Array(repeating: ["G", "D", "Em", "C"], count: 4).flatMap { $0 }
        let pattern = Array("D-DU-UDU")

        var audio = [Float](repeating: 0, count: Int(rate * (lead + Double(progression.count * 4) * beat + 1)))
        var downs: [String: [Float]] = [:]
        var ups: [String: [Float]] = [:]
        for id in Set(progression) {
            let notes = library[id]!.midiNotes
            downs[id] = ChordSynth.renderStrum(midiNotes: notes, stringDelay: 0.012, sampleRate: rate, duration: beat * 1.2)
            ups[id] = ChordSynth.renderStrum(midiNotes: Array(notes.reversed()), stringDelay: 0.010, sampleRate: rate, duration: beat * 1.2)
        }
        for (bar, id) in progression.enumerated() {
            for (index, stroke) in pattern.enumerated() where stroke != "-" {
                let start = Int((lead + Double(bar * 8 + index) * slot) * rate)
                let sound = stroke == "D" ? downs[id]! : ups[id]!
                let gain: Float = stroke == "D" ? 1 : 0.6
                for (i, sample) in sound.enumerated() where start + i < audio.count {
                    audio[start + i] += sample * gain
                }
            }
        }

        let analysis = SongAnalyzer.analyze(samples: audio, sampleRate: rate)
        XCTAssertEqual(try XCTUnwrap(analysis.bpm), bpm, accuracy: bpm * 0.03)
        let strum = try XCTUnwrap(analysis.strum)
        XCTAssertEqual(strum.strokes, "D-DU-UDU", "strengths: \(strum.slotStrengths.map { String(format: "%.2f", $0) })")
        // The "1" lands on a bar start (within a third of a beat).
        let bars = (strum.barOffset - lead) / (4 * beat)
        XCTAssertEqual(bars, bars.rounded(), accuracy: 0.33 / 4, "barOffset \(strum.barOffset)")
        XCTAssertGreaterThan(strum.confidence, 0.25)

        // Re-running only the strum keeps the chords.
        let again = SongAnalyzer.analyzeStrum(samples: audio, sampleRate: rate, chords: analysis.chords)
        XCTAssertEqual(again.chords, analysis.chords)
        XCTAssertEqual(again.strum?.strokes, "D-DU-UDU")
    }

    func testFoldingAndDownbeatOnAHandMadeOnsetCurve() throws {
        // 120 bpm, hop 10 ms: an eighth every 25 hops. Pattern D-D-D-DU (slots 0,2,4,6,7), bars start at 2.5 s,
        // so the "1" is the second beat of the grid (phase 1).
        let hop = 0.01
        let bpm = 120.0
        let slot = 0.25
        var onsets = [Float](repeating: 0, count: 2400)
        var chords = [SongChord(start: 0, name: "N")]
        for bar in 0..<10 {
            let barStart = 2.5 + Double(bar) * 2
            chords.append(SongChord(start: barStart, name: bar % 2 == 0 ? "G" : "C"))
            for (index, value) in [(0, 1.0), (2, 0.8), (4, 0.9), (6, 0.8), (7, 0.6)] {
                onsets[Int(((barStart + Double(index) * slot) / hop).rounded())] = Float(value)
            }
        }
        let guess = try XCTUnwrap(StrumDetector.detect(
            onsets: onsets, hopSeconds: hop, frameTime: 0, bpm: bpm, beatOffset: 0.5,
            chords: chords, duration: 22.5
        ))
        XCTAssertEqual(guess.strokes, "D-D-D-DU")
        XCTAssertEqual(guess.barOffset.truncatingRemainder(dividingBy: 2), 0.5, accuracy: 0.01)
    }

    func testClosestLessonPattern() {
        let patterns = [
            StrumPattern(id: "folk", name: "Folk pattern", strokes: "D-DU-UDU"),
            StrumPattern(id: "eighths", name: "Down-up eighths", strokes: "DUDUDUDU"),
            StrumPattern(id: "arpeggio", name: "Arpeggio", strokes: "B3212321"),
        ]
        XCTAssertEqual(StrumDetector.closest(to: "D-DU-UDU", in: patterns)?.pattern.id, "folk")
        XCTAssertEqual(StrumDetector.closest(to: "D-DU-UDU", in: patterns)?.distance, 0)
        XCTAssertEqual(StrumDetector.closest(to: "D-DUDUDU", in: patterns)?.distance, 1)
        XCTAssertNil(StrumDetector.closest(to: "D---D---", in: patterns))
    }

    func testStrumPositionFollowsTheSong() {
        var song = Song(title: "t", audioFileName: "a.m4a", duration: 60)
        song.bpm = 120          // eighth = 0.25 s
        song.barOffset = 1      // bars at 1, 3, 5…
        let pattern = StrumPattern(id: "folk", name: "Folk", strokes: "D-DU-UDU")
        XCTAssertEqual(song.strumPosition(at: 1.0, pattern: pattern)?.slot, 0)
        XCTAssertEqual(song.strumPosition(at: 1.3, pattern: pattern)?.slot, 1)
        XCTAssertEqual(song.strumPosition(at: 2.9, pattern: pattern)?.slot, 7)
        XCTAssertEqual(song.strumPosition(at: 3.05, pattern: pattern)?.slot, 0)
        XCTAssertEqual(song.strumPosition(at: 0.9, pattern: pattern)?.slot, 7, "before the first bar it wraps")
        XCTAssertEqual(try XCTUnwrap(song.strumPosition(at: 1.125, pattern: pattern)?.fraction), 0.5, accuracy: 1e-9)

        song.patternID = "folk"
        XCTAssertEqual(song.strumPattern(library: ["folk": pattern])?.id, "folk")
        song.patternID = nil
        XCTAssertNil(song.strumPattern(library: ["folk": pattern]), "no guess yet")
    }

    func testOldSongFilesStillLoad() throws {
        var song = Song(title: "Old", audioFileName: "audio.mp3", duration: 30)
        song.status = .ready
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(song)) as? [String: Any])
        for key in ["strum", "barOffset", "patternID"] { json.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(Song.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.title, "Old")
        XCTAssertNil(decoded.strum)
        XCTAssertNil(decoded.barOffset)
    }
}
