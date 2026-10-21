//
//  StemSeparatorTests.swift
//  AppGuitarraTests
//
//  The STFT/iSTFT around the model against torch, and the whole separation
//  against demucs in Python (values in separator_fixture.json, made with
//  tools/demucs/fixtures.py from the same synthetic signals as below).
//

import XCTest
@testable import AppGuitarra

final class StemSeparatorTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Point: Decodable { let channel: Int; let bin: Int; let frame: Int; let re: Double; let im: Double }
        struct StemValues: Decodable { let name: String; let rms: [Double]; let samples: [[Double]] }
        struct SongValues: Decodable { let length: Int; let indices: [Int]; let stems: [StemValues] }
        let stft: [Point]
        let song: SongValues
    }

    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "separator_fixture", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    /// Same formulas as `stft_signal` in tools/demucs/fixtures.py.
    private func stftSignal(_ count: Int) -> [[Float]] {
        let rate = StemSeparator.sampleRate
        let a = (0..<count).map { i -> Float in
            let t = Double(i) / rate
            return Float(0.3 * sin(2 * .pi * 220 * t) + 0.1 * sin(2 * .pi * 3150 * t) * cos(2 * .pi * 0.5 * t))
        }
        let b = (0..<count).map { i -> Float in Float(0.2 * sin(2 * .pi * 330 * Double(i) / rate + 1)) }
        return [a, b]
    }

    /// Same formulas as `song_signal`: a G chord, a bass note and a kick twice a second.
    private func songSignal(_ count: Int) -> [[Float]] {
        let rate = StemSeparator.sampleRate
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / rate
            let other = 0.12 * [196.0, 246.94, 293.66, 392.0].reduce(0) { $0 + sin(2 * .pi * $1 * t) }
            let bass = 0.25 * sin(2 * .pi * 98 * t)
            let u = t.truncatingRemainder(dividingBy: 0.5)
            let drum = 0.6 * exp(-30 * u) * sin(2 * .pi * 80 * u)
            left[i] = Float(other + bass + drum)
            right[i] = Float(0.8 * other + bass + drum)
        }
        return [left, right]
    }

    func testReflectPadMatchesTorch() {
        // torch: F.pad([1,2,3,4,5], (2, 3), mode="reflect") = [3,2,1,2,3,4,5,4,3,2]
        XCTAssertEqual(SpectrogramTransform.reflectPad([1, 2, 3, 4, 5], left: 2, right: 3), [3, 2, 1, 2, 3, 4, 5, 4, 3, 2])
    }

    func testSpectrogramMatchesTorch() throws {
        let fixture = try fixture()
        let segment = StemSeparator.segment
        let frames = SpectrogramTransform.frames(for: segment)
        XCTAssertEqual(frames, 336)
        let signal = stftSignal(segment)
        let transform = SpectrogramTransform()
        let plane = SpectrogramTransform.bins * frames
        var real = [[Float]](repeating: [Float](repeating: 0, count: plane), count: 2)
        var imag = real
        for channel in 0..<2 {
            transform.spectrogram(of: signal[channel], real: &real[channel], imag: &imag[channel])
        }
        for point in fixture.stft {
            let index = point.bin * frames + point.frame
            XCTAssertEqual(Double(real[point.channel][index]), point.re, accuracy: 1e-4, "re at \(point)")
            XCTAssertEqual(Double(imag[point.channel][index]), point.im, accuracy: 1e-4, "im at \(point)")
        }
    }

    func testInverseGivesTheSignalBack() {
        let segment = StemSeparator.segment
        let frames = SpectrogramTransform.frames(for: segment)
        let signal = stftSignal(segment)[0]
        let transform = SpectrogramTransform()
        let plane = SpectrogramTransform.bins * frames
        var real = [Float](repeating: 0, count: plane)
        var imag = [Float](repeating: 0, count: plane)
        transform.spectrogram(of: signal, real: &real, imag: &imag)
        var back = [Float](repeating: 0, count: segment)
        transform.addSignal(real: real, imag: imag, frames: frames, length: segment, into: &back)
        // Only the dropped Nyquist bin is lost, which is nearly empty here.
        let error = zip(signal, back).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(error, 1e-3)
    }

    /// Runs the real model: needs HTDemucs.mlpackage in the app. Takes a few seconds.
    func testSeparationMatchesDemucs() throws {
        try XCTSkipUnless(StemSeparator.isAvailable, "HTDemucs.mlpackage is not in the app")
        let fixture = try fixture()
        let signal = songSignal(fixture.song.length)
        let separator = try StemSeparator()
        var output: [Stem: [[Float]]] = [:]
        try separator.separate(left: signal[0], right: signal[1], progress: { _ in }) { pieces in
            for (stem, piece) in pieces {
                var channels = output[stem] ?? [[], []]
                channels[0] += piece.left
                channels[1] += piece.right
                output[stem] = channels
            }
        }
        let loudest = fixture.song.stems.flatMap(\.rms).max() ?? 1
        for expected in fixture.song.stems {
            let stem = try XCTUnwrap(Stem(rawValue: expected.name))
            let channels = try XCTUnwrap(output[stem])
            for channel in 0..<2 {
                XCTAssertEqual(channels[channel].count, fixture.song.length, "\(stem) length")
                let rms = (channels[channel].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(channels[channel].count)).squareRoot()
                // Silent stems (vocals here) only need to stay silent.
                guard expected.rms[channel] > loudest * 0.1 else {
                    XCTAssertLessThan(rms, loudest * 0.1, "\(stem) should stay quiet")
                    continue
                }
                XCTAssertEqual(rms, expected.rms[channel], accuracy: expected.rms[channel] * 0.15, "\(stem) loudness")
                let ours = fixture.song.indices.map { Double(channels[channel][$0]) }
                XCTAssertGreaterThan(correlation(ours, expected.samples[channel]), 0.95, "\(stem) shape")
            }
        }
    }

    func testPresetsAndOldSongFiles() throws {
        XCTAssertEqual(StemMix().preset, .original)
        XCTAssertEqual(StemMix.Preset.guitarOnly.mix.volume(.vocals), 0)
        var mix = StemMix.Preset.guitarUp.mix
        XCTAssertEqual(mix.preset, .guitarUp)
        mix.setVolume(2, for: .drums)
        XCTAssertEqual(mix.volume(.drums), 1)
        XCTAssertNil(mix.preset)

        // song.json from before separation still loads.
        let song = Song(title: "Old", audioFileName: "audio.mp3", duration: 10)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(song)) as? [String: Any])
        json["stems"] = nil
        json["chordsFromStems"] = nil
        let decoded = try JSONDecoder().decode(Song.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.stems)
    }

    private func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let ma = a.reduce(0, +) / Double(a.count)
        let mb = b.reduce(0, +) / Double(b.count)
        var ab = 0.0, aa = 0.0, bb = 0.0
        for (x, y) in zip(a, b) {
            ab += (x - ma) * (y - mb)
            aa += (x - ma) * (x - ma)
            bb += (y - mb) * (y - mb)
        }
        return ab / (aa * bb).squareRoot()
    }
}
