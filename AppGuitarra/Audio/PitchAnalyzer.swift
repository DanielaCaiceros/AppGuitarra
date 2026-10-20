//
//  PitchAnalyzer.swift
//  AppGuitarra
//
//  Monophonic pitch detection with the YIN algorithm
//  (de Cheveigné & Kawahara, 2002), accelerated with vDSP.
//  Runs on the audio tap thread, so it is not tied to the main actor.
//

import Accelerate
import AVFoundation

nonisolated final class PitchAnalyzer: @unchecked Sendable {
    let sampleRate: Double
    /// Below this RMS level the input counts as silence.
    var silenceThreshold: Float = 0.015
    /// YIN absolute threshold; lower is stricter.
    var yinThreshold: Float = 0.12

    private let windowSize: Int
    private let minLag: Int
    private let maxLag: Int
    private var samples: [Float] = []
    private var difference: [Float]

    /// Number of samples needed for one analysis.
    var requiredSampleCount: Int { windowSize + maxLag }

    init(sampleRate: Double, minFrequency: Double = 60, maxFrequency: Double = 1200) {
        self.sampleRate = sampleRate
        windowSize = Int(sampleRate * 0.025)          // 25 ms ≈ 2 periods of low E
        maxLag = Int(sampleRate / minFrequency) + 2
        minLag = max(2, Int(sampleRate / maxFrequency))
        difference = [Float](repeating: 0, count: maxLag)
        samples.reserveCapacity(windowSize + maxLag * 4)
    }

    /// Appends a buffer from the microphone and returns the detected frequency in Hz,
    /// or nil when there is silence or no clear pitch.
    func process(_ buffer: AVAudioPCMBuffer) -> Double? {
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        return process(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    func process(_ newSamples: UnsafeBufferPointer<Float>) -> Double? {
        samples.append(contentsOf: newSamples)
        let needed = requiredSampleCount
        if samples.count > needed {
            samples.removeFirst(samples.count - needed)
        }
        guard samples.count == needed else { return nil }
        return detect()
    }

    func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    // MARK: - YIN

    private func detect() -> Double? {
        samples.withUnsafeBufferPointer { buffer -> Double? in
            guard let x = buffer.baseAddress else { return nil }

            var rms: Float = 0
            vDSP_rmsqv(x, 1, &rms, vDSP_Length(buffer.count))
            guard rms > silenceThreshold else { return nil }

            // 1. Difference function d(τ) = Σ (x[j] − x[j+τ])²
            let window = vDSP_Length(windowSize)
            difference[0] = 0
            for lag in 1..<maxLag {
                var sum: Float = 0
                vDSP_distancesq(x, 1, x + lag, 1, &sum, window)
                difference[lag] = sum
            }

            // 2. Cumulative mean normalized difference d'(τ)
            difference[0] = 1
            var runningSum: Float = 0
            for lag in 1..<maxLag {
                runningSum += difference[lag]
                difference[lag] = runningSum > 0 ? difference[lag] * Float(lag) / runningSum : 1
            }

            // 3. First dip under the threshold, then walk down to its local minimum
            var estimate = -1
            var lag = minLag
            while lag < maxLag - 1 {
                if difference[lag] < yinThreshold {
                    while lag + 1 < maxLag - 1, difference[lag + 1] < difference[lag] {
                        lag += 1
                    }
                    estimate = lag
                    break
                }
                lag += 1
            }
            guard estimate > 0 else { return nil }

            // 4. Parabolic interpolation for sub-sample precision
            let s0 = difference[estimate - 1]
            let s1 = difference[estimate]
            let s2 = difference[estimate + 1]
            let denominator = s0 + s2 - 2 * s1
            let shift = abs(denominator) > .ulpOfOne ? 0.5 * (s0 - s2) / denominator : 0
            let period = Double(estimate) + Double(shift)
            return period > 0 ? sampleRate / period : nil
        }
    }
}

/// A detected pitch expressed as the nearest note plus a cents offset.
nonisolated struct PitchReading: Equatable, Sendable {
    let frequency: Double
    var referenceA4: Double = 440

    /// Fractional MIDI note number (69 = A4).
    var exactMIDI: Double { 69 + 12 * log2(frequency / referenceA4) }
    var midi: Int { Int(exactMIDI.rounded()) }
    /// −50...+50: how far the pitch is from the nearest note.
    var cents: Double { (exactMIDI - Double(midi)) * 100 }
    var noteName: String { NoteName.name(forMIDI: midi) }
    var octave: Int { NoteName.octave(forMIDI: midi) }
    var isInTune: Bool { abs(cents) <= 5 }

    /// Closest open string in standard tuning (0 = low E ... 5 = high E).
    var nearestStringIndex: Int {
        Chord.standardTuning.indices.min { a, b in
            abs(Double(Chord.standardTuning[a]) - exactMIDI) < abs(Double(Chord.standardTuning[b]) - exactMIDI)
        } ?? 0
    }
}

/// Median filter over the last few detections.
nonisolated struct PitchSmoother {
    let capacity: Int
    private var recent: [Double] = []

    init(capacity: Int = 5) {
        self.capacity = capacity
    }

    mutating func add(_ frequency: Double) -> Double {
        // A jump of more than a semitone means a new note: start over.
        if let last = recent.last, abs(12 * log2(frequency / last)) > 1 {
            recent.removeAll()
        }
        recent.append(frequency)
        if recent.count > capacity { recent.removeFirst() }
        return recent.sorted()[recent.count / 2]
    }

    mutating func reset() { recent.removeAll() }
}

/// What the tuner shows for one update.
nonisolated struct TunerOutput: Equatable, Sendable {
    /// String being tuned (0 = low E ... 5 = high E).
    let stringIndex: Int
    /// Smoothed detected frequency in Hz.
    let frequency: Double
    /// Smoothed offset from the target string, in cents (not clamped).
    let cents: Double
    let isInTune: Bool
    /// In tune for several updates in a row: safe to move to the next string.
    let isSettled: Bool
    let isLocked: Bool

    var noteName: String { PitchReading(frequency: frequency).noteName }
}

/// Guitar-mode tuning logic, independent of audio so it can be unit tested.
///
/// It steadies the raw pitch in three ways:
/// 1. a median filter removes single bad detections,
/// 2. the target string only changes after the same new string is heard several times,
/// 3. "in tune" uses hysteresis: enter within ±`inTuneEnter` cents, leave beyond ±`inTuneExit`.
nonisolated struct TuningState {
    /// Fixed target string chosen by the user; nil = pick the closest string automatically.
    var lockedString: Int?
    var inTuneEnter = 5.0
    var inTuneExit = 9.0
    /// Updates in a row a new string must win before the tuner switches to it.
    var switchAfter = 3
    /// 0...1, weight of each new reading in the needle's moving average.
    var needleSmoothing = 0.3

    private var smoother = PitchSmoother(capacity: 7)
    private(set) var currentString: Int?
    private var candidate: Int?
    private var candidateCount = 0
    private var smoothedCents: Double?
    private var inTune = false
    private var inTuneCount = 0

    init(lockedString: Int? = nil) {
        self.lockedString = lockedString
    }

    static func frequency(ofString index: Int) -> Double {
        440 * pow(2, (Double(Chord.standardTuning[index]) - 69) / 12)
    }

    static func cents(_ frequency: Double, fromString index: Int) -> Double {
        1200 * log2(frequency / Self.frequency(ofString: index))
    }

    static func nearestString(to frequency: Double) -> Int {
        Chord.standardTuning.indices.min { a, b in
            abs(cents(frequency, fromString: a)) < abs(cents(frequency, fromString: b))
        } ?? 0
    }

    mutating func update(_ rawFrequency: Double) -> TunerOutput {
        let frequency = smoother.add(rawFrequency)
        let target = chooseTarget(for: frequency)

        let raw = Self.cents(frequency, fromString: target)
        let previous = smoothedCents ?? raw
        // Big jumps (a new pluck far from the last one) skip the averaging.
        let cents = abs(raw - previous) > 30 ? raw : previous + needleSmoothing * (raw - previous)
        smoothedCents = cents

        if inTune {
            if abs(cents) > inTuneExit { inTune = false }
        } else if abs(cents) <= inTuneEnter {
            inTune = true
        }
        inTuneCount = inTune ? inTuneCount + 1 : 0

        return TunerOutput(
            stringIndex: target,
            frequency: frequency,
            cents: cents,
            isInTune: inTune,
            isSettled: inTuneCount >= 3,
            isLocked: lockedString != nil
        )
    }

    /// Forget the current note (after silence). Keeps the locked string.
    mutating func reset() {
        smoother.reset()
        currentString = nil
        candidate = nil
        candidateCount = 0
        smoothedCents = nil
        inTune = false
        inTuneCount = 0
    }

    private mutating func chooseTarget(for frequency: Double) -> Int {
        if let lockedString {
            if currentString != lockedString { resetNeedle() }
            currentString = lockedString
            return lockedString
        }

        let nearest = Self.nearestString(to: frequency)
        guard let current = currentString else {
            currentString = nearest
            return nearest
        }
        guard nearest != current else {
            candidate = nil
            candidateCount = 0
            return current
        }

        if nearest == candidate {
            candidateCount += 1
        } else {
            candidate = nearest
            candidateCount = 1
        }
        if candidateCount >= switchAfter {
            currentString = nearest
            candidate = nil
            candidateCount = 0
            resetNeedle()
            return nearest
        }
        return current
    }

    private mutating func resetNeedle() {
        smoothedCents = nil
        inTune = false
        inTuneCount = 0
    }
}
