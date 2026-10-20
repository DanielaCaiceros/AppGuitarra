//
//  ChordSynth.swift
//  AppGuitarra
//
//  Plays a strummed chord with Karplus–Strong plucked-string synthesis,
//  so every sound is generated from the chord data (no recordings).
//

import AVFoundation

final class ChordSynth {
    static let shared = ChordSynth()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var cache: [String: AVAudioPCMBuffer] = [:]

    private init() {
        format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// Strums the chord from the lowest played string to the highest.
    /// - Parameter stringDelay: seconds between one string and the next.
    func strum(_ chord: Chord, stringDelay: Double) {
        play(midiNotes: chord.midiNotes, key: "\(chord.id)-\(Int(stringDelay * 1000))", stringDelay: stringDelay)
    }

    /// Plucks a single open string (0 = low E).
    func pluck(stringIndex: Int, fret: Int = 0) {
        var notes = [Int?](repeating: nil, count: Chord.stringCount)
        notes[stringIndex] = Chord.standardTuning[stringIndex] + fret
        play(midiNotes: notes, key: "string-\(stringIndex)-\(fret)", stringDelay: 0)
    }

    /// Stops sound and releases the audio hardware.
    func shutdown() {
        player.stop()
        engine.stop()
    }

    private func play(midiNotes: [Int?], key: String, stringDelay: Double) {
        do {
            let session = AVAudioSession.sharedInstance()
            if session.category != .playback {
                try session.setCategory(.playback, mode: .default)
            }
            try session.setActive(true)
            if !engine.isRunning {
                try engine.start()
            }
        } catch {
            return
        }

        let buffer: AVAudioPCMBuffer
        if let cached = cache[key] {
            buffer = cached
        } else {
            let samples = Self.renderStrum(midiNotes: midiNotes, stringDelay: stringDelay, sampleRate: format.sampleRate)
            guard let made = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = made.floatChannelData?[0] else { return }
            made.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress!, count: samples.count)
            }
            cache[key] = made
            buffer = made
        }

        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player.play()
    }

    /// Karplus–Strong: a burst of noise circulates in a delay line one period long,
    /// and averaging neighbouring samples makes it decay like a real string.
    nonisolated static func renderStrum(
        midiNotes: [Int?],
        stringDelay: Double,
        sampleRate: Double,
        duration: Double = 3
    ) -> [Float] {
        let total = Int(sampleRate * duration)
        var output = [Float](repeating: 0, count: total)
        var generator = SystemRandomNumberGenerator()
        var order = 0

        for note in midiNotes {
            guard let note else { continue }
            let frequency = 440 * pow(2, Double(note - 69) / 12)
            // The averaging filter adds half a sample of delay.
            let period = max(2, Int((sampleRate / frequency - 0.5).rounded()))
            var ring = (0..<period).map { _ in Float.random(in: -1...1, using: &generator) }
            for i in 1..<period { ring[i] = 0.5 * (ring[i] + ring[i - 1]) }   // softer pick attack

            let start = Int(Double(order) * stringDelay * sampleRate)
            order += 1
            guard start < total else { continue }

            var position = 0
            for n in start..<total {
                let current = ring[position]
                let nextIndex = position + 1 == period ? 0 : position + 1
                ring[position] = 0.996 * 0.5 * (current + ring[nextIndex])
                output[n] += 0.25 * current
                position = nextIndex
            }
        }

        // Normalize and fade out the tail.
        let peak = output.reduce(0) { max($0, abs($1)) }
        let gain: Float = peak > 0.8 ? 0.8 / peak : 1
        let fadeLength = Int(sampleRate * 0.3)
        for n in 0..<total {
            let fade: Float = n > total - fadeLength ? Float(total - n) / Float(fadeLength) : 1
            output[n] *= gain * fade
        }
        return output
    }
}
