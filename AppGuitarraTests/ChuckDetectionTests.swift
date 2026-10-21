//
//  ChuckDetectionTests.swift
//  AppGuitarraTests
//
//  Chucks (muted strums) found in an imported song: they die at once, while
//  strummed chords keep ringing.
//

import XCTest
@testable import AppGuitarra

final class ChuckDetectionTests: XCTestCase {
    /// A synthetic song with the chuck pattern (D-xUD-xU), one chord per bar.
    /// The left hand mutes every string on a chuck, so what was ringing stops.
    func testFindsTheChucks() throws {
        let library = Dictionary(uniqueKeysWithValues: try ChordLibrary.loadChords().map { ($0.id, $0) })
        let rate = 22_050.0
        let bpm = 90.0
        let beat = 60 / bpm
        let slot = beat / 2
        let lead = 0.7
        let progression = Array(repeating: ["G", "D", "Em", "C"], count: 4).flatMap { $0 }
        let pattern = Array("D-xUD-xU")

        var audio = [Float](repeating: 0, count: Int(rate * (lead + Double(progression.count * 4) * beat + 1)))
        var generator = SystemRandomNumberGenerator()
        let burstLength = Int(0.025 * rate)
        for (bar, id) in progression.enumerated() {
            let notes = library[id]!.midiNotes
            let down = ChordSynth.renderStrum(midiNotes: notes, stringDelay: 0.012, sampleRate: rate, duration: beat * 1.2)
            let up = ChordSynth.renderStrum(midiNotes: Array(notes.reversed()), stringDelay: 0.010, sampleRate: rate, duration: beat * 1.2)
            for (index, stroke) in pattern.enumerated() where stroke != "-" {
                let start = Int((lead + Double(bar * 8 + index) * slot) * rate)
                if stroke == "x" {
                    // Muted: everything stops, and a short percussive burst.
                    for i in start..<audio.count { audio[i] = 0 }
                    for i in 0..<burstLength where start + i < audio.count {
                        let fade = Float(exp(-Double(i) / (0.006 * rate)))
                        audio[start + i] += Float.random(in: -0.8...0.8, using: &generator) * fade
                    }
                    continue
                }
                let sound = stroke == "D" ? down : up
                let gain: Float = stroke == "D" ? 1 : 0.6
                for (i, sample) in sound.enumerated() where start + i < audio.count {
                    audio[start + i] += sample * gain
                }
            }
        }

        let analysis = SongAnalyzer.analyze(samples: audio, sampleRate: rate)
        let strum = try XCTUnwrap(analysis.strum)
        XCTAssertEqual(strum.strokes, "D-xUD-xU",
                       "muting: \(strum.slotMuting?.map { String(format: "%.2f", $0) } ?? []), strengths: \(strum.slotStrengths.map { String(format: "%.2f", $0) })")
    }

    func testMutingOfASingleHit() {
        let rate = 22_050.0
        var ringing = [Float](repeating: 0, count: Int(rate))
        var muted = ringing
        for i in 0..<ringing.count {
            let t = Double(i) / rate
            ringing[i] = Float(sin(2 * .pi * 196 * t) * exp(-t * 3))
            muted[i] = i < Int(0.025 * rate) ? Float(sin(2 * .pi * 900 * t) * exp(-t / 0.006)) : 0
        }
        XCTAssertEqual(StrumDetector.muting(samples: ringing, sampleRate: rate, at: 0.1) ?? -1, 0, accuracy: 0.01)
        XCTAssertGreaterThan(StrumDetector.muting(samples: muted, sampleRate: rate, at: 0.005) ?? 0, 0.9)
        // Too close to the end of the audio: no answer.
        XCTAssertNil(StrumDetector.muting(samples: ringing, sampleRate: rate, at: 0.95))
    }
}
