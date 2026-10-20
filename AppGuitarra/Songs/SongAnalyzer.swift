//
//  SongAnalyzer.swift
//  AppGuitarra
//
//  Finds the tempo and the chords of a recorded song (mono samples, ~22 kHz).
//
//  1. Tempo: an onset curve (spectral flux) and its autocorrelation give the
//     beat period; the phase with the strongest onsets gives where beats fall.
//  2. Chords: chroma is averaged between beats, compared with the 24 major and
//     minor triads (with a bonus when the bass note is the root), and a Viterbi
//     pass picks the most likely sequence, which keeps chords from flickering.
//
//  It is approximate (vocals and other instruments get in the way), so the
//  user can correct every chord afterwards.
//

import Foundation

nonisolated struct SongAnalysis: Sendable {
    let bpm: Double?
    /// Time of the first beat.
    let beatOffset: Double
    let chords: [SongChord]
}

nonisolated enum SongAnalyzer {
    // Tuned on synthetic songs (see the tests); adjust with real ones.
    static let switchPenalty: Float = 0.1
    static let bassWeight: Float = 0.4
    static let quietShare: Float = 0.05

    static func analyze(samples: [Float], sampleRate: Double, progress: (@Sendable (Double) -> Void)? = nil) -> SongAnalysis {
        let duration = Double(samples.count) / sampleRate
        guard duration > 1 else { return SongAnalysis(bpm: nil, beatOffset: 0, chords: []) }

        // Normalize so the fixed log compression below behaves the same for quiet and loud files.
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        let audio = peak > 0 ? samples.map { $0 / peak } : samples
        progress?(0.05)

        let tempo = estimateTempo(samples: audio, sampleRate: sampleRate)
        progress?(0.25)

        let beat = tempo.map { 60 / $0.bpm } ?? 0.5
        let edges = segmentEdges(firstBeat: tempo?.offset ?? 0, beat: beat, duration: duration)
        let frames = chromaFrames(samples: audio, sampleRate: sampleRate) { fraction in
            progress?(0.25 + 0.65 * fraction)
        }

        let path = decode(frames: frames, edges: edges)
        progress?(0.95)

        var chords: [SongChord] = []
        for (index, state) in path.enumerated() {
            let name = state < triadNames.count ? triadNames[state] : ChordSymbol.noChord
            if chords.last?.name != name {
                chords.append(SongChord(start: edges[index], name: name))
            }
        }
        chords = removeShortChords(chords, minimumLength: beat * 1.5, duration: duration)
        progress?(1)
        return SongAnalysis(bpm: tempo?.bpm, beatOffset: tempo?.offset ?? 0, chords: chords)
    }

    // MARK: - Tempo

    static func estimateTempo(samples: [Float], sampleRate: Double, minBPM: Double = 60, maxBPM: Double = 180) -> (bpm: Double, offset: Double)? {
        let size = 1024
        let hop = 512
        guard samples.count > size * 8 else { return nil }
        let spectrum = PowerSpectrum(size: size, sampleRate: sampleRate)
        let hopSeconds = Double(hop) / sampleRate

        // Spectral flux: how much the log spectrum grows from one frame to the next.
        var flux: [Float] = []
        var previous: [Float]?
        samples.withUnsafeBufferPointer { buffer in
            var start = 0
            while start + size <= buffer.count {
                let power = spectrum.compute(UnsafeBufferPointer(rebasing: buffer[start..<start + size]))
                let logMagnitude = power.map { log(1 + 100 * $0.squareRoot()) }
                if let previous {
                    var sum: Float = 0
                    for k in 0..<logMagnitude.count { sum += max(0, logMagnitude[k] - previous[k]) }
                    flux.append(sum)
                } else {
                    flux.append(0)
                }
                previous = logMagnitude
                start += hop
            }
        }

        // Keep only what rises above the local average (≈0.4 s).
        let window = max(1, Int((0.4 / hopSeconds).rounded()))
        var onsets = [Float](repeating: 0, count: flux.count)
        var running: Float = 0
        for i in 0..<flux.count {
            running += flux[i]
            if i >= window { running -= flux[i - window] }
            let centered = i - window / 2
            if centered >= 0 {
                onsets[centered] = max(0, flux[centered] - running / Float(min(i + 1, window)))
            }
        }

        let minLag = max(1, Int((60 / maxBPM / hopSeconds).rounded(.down)))
        let maxLag = Int((60 / minBPM / hopSeconds).rounded(.up))
        guard onsets.count > maxLag * 2 else { return nil }

        // Autocorrelation, weighted toward common tempos (log-Gaussian around 110 bpm).
        var scores: [Double] = []
        for lag in minLag...maxLag {
            var sum: Double = 0
            for i in 0..<(onsets.count - lag) { sum += Double(onsets[i] * onsets[i + lag]) }
            let bpm = 60 / (Double(lag) * hopSeconds)
            let weight = exp(-0.5 * pow(log2(bpm / 110) / 0.9, 2))
            scores.append(sum / Double(onsets.count - lag) * weight)
        }
        guard let bestIndex = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[bestIndex] > 0 else { return nil }

        var shift = 0.0
        if bestIndex > 0, bestIndex < scores.count - 1 {
            let a = scores[bestIndex - 1], b = scores[bestIndex], c = scores[bestIndex + 1]
            let denominator = a - 2 * b + c
            if abs(denominator) > 1e-12 { shift = 0.5 * (a - c) / denominator }
        }
        let period = Double(minLag + bestIndex) + shift
        let bpm = 60 / (period * hopSeconds)

        // Phase: the offset whose beat grid lands on the strongest onsets.
        var bestPhase = 0
        var bestPhaseScore: Float = -1
        for phase in 0..<max(1, Int(period)) {
            var sum: Float = 0
            var position = Double(phase)
            while Int(position.rounded()) < onsets.count {
                sum += onsets[Int(position.rounded())]
                position += period
            }
            if sum > bestPhaseScore {
                bestPhaseScore = sum
                bestPhase = phase
            }
        }
        // Onset frames are stamped at their start; the attack sits half a window later.
        let offset = Double(bestPhase) * hopSeconds + Double(size / 2) / sampleRate
        return (bpm, offset)
    }

    /// Boundaries of the blocks chords are decided on: 0, every beat, the end.
    static func segmentEdges(firstBeat: Double, beat: Double, duration: Double) -> [Double] {
        var edges: [Double] = [0]
        var time = firstBeat.truncatingRemainder(dividingBy: beat)
        while time < duration {
            if time > edges.last! + 0.05 { edges.append(time) }
            time += beat
        }
        if duration > edges.last! { edges.append(duration) }
        return edges
    }

    // MARK: - Chroma

    nonisolated struct ChromaFrame: Sendable {
        let time: Double
        let treble: [Float]
        let bass: [Float]
        let energy: Float
    }

    static func chromaFrames(samples: [Float], sampleRate: Double, progress: (Double) -> Void = { _ in }) -> [ChromaFrame] {
        let size = PowerSpectrum.size(forSeconds: 0.3, sampleRate: sampleRate)   // 8192 at 22–24 kHz
        let hop = size / 4
        guard samples.count >= size else { return [] }
        let spectrum = PowerSpectrum(size: size, sampleRate: sampleRate)
        let total = (samples.count - size) / hop + 1
        var frames: [ChromaFrame] = []
        frames.reserveCapacity(total)

        samples.withUnsafeBufferPointer { buffer in
            for index in 0..<total {
                let start = index * hop
                let power = spectrum.compute(UnsafeBufferPointer(rebasing: buffer[start..<start + size]))
                let treble = ChromaExtractor.chroma(power: power, binHz: spectrum.binHz, minFrequency: 100, maxFrequency: 1000)
                let bass = ChromaExtractor.chroma(power: power, binHz: spectrum.binHz, minFrequency: 40, maxFrequency: 250)
                let energy = power.reduce(0) { $0 + $1.squareRoot() }
                frames.append(ChromaFrame(
                    time: (Double(start) + Double(size) / 2) / sampleRate,
                    treble: treble, bass: bass, energy: energy
                ))
                if index % 64 == 0 { progress(Double(index) / Double(total)) }
            }
        }
        return frames
    }

    // MARK: - Chords

    /// "C", "Cm", "C#", "C#m", ... in the order of `triadTemplates`.
    static let triadNames: [String] = (0..<12).flatMap { root in
        [ChordSymbol(root: root, quality: .major).name, ChordSymbol(root: root, quality: .minor).name]
    }

    static let triadTemplates: [[Float]] = (0..<12).flatMap { root in
        [ChordSymbol.Quality.major, .minor].map { quality in
            var template = [Float](repeating: 0, count: 12)
            for (position, interval) in quality.intervals.enumerated() {
                template[(root + interval) % 12] = position == 1 ? 0.9 : 1   // the third weighs a bit less
            }
            return ChromaExtractor.normalized(template)
        }
    }

    /// Most likely state per block: 0..<24 = triads, 24 = no chord.
    static func decode(frames: [ChromaFrame], edges: [Double]) -> [Int] {
        let blockCount = edges.count - 1
        guard blockCount > 0 else { return [] }
        let stateCount = triadTemplates.count + 1
        let noChord = triadTemplates.count

        var trebles: [[Float]] = []
        var basses: [[Float]] = []
        var energies: [Float] = []
        var cursor = 0
        for block in 0..<blockCount {
            var treble = [Float](repeating: 0, count: 12)
            var bass = [Float](repeating: 0, count: 12)
            var energy: Float = 0
            var count = 0
            while cursor < frames.count, frames[cursor].time < edges[block] { cursor += 1 }
            var i = cursor
            while i < frames.count, frames[i].time < edges[block + 1] {
                for k in 0..<12 {
                    treble[k] += frames[i].treble[k]
                    bass[k] += frames[i].bass[k]
                }
                energy += frames[i].energy
                count += 1
                i += 1
            }
            let bassPeak = bass.max() ?? 0
            trebles.append(ChromaExtractor.normalized(treble))
            basses.append(bassPeak > 0 ? bass.map { $0 / bassPeak } : bass)
            energies.append(count > 0 ? energy / Float(count) : 0)
        }

        let loudest = energies.max() ?? 0
        let emissions: [[Float]] = (0..<blockCount).map { block in
            let quiet = energies[block] < quietShare * loudest || energies[block] == 0
            var row = [Float](repeating: 0, count: stateCount)
            if !quiet {
                for state in 0..<triadTemplates.count {
                    let root = state / 2
                    row[state] = (1 - bassWeight) * ChromaExtractor.similarity(trebles[block], triadTemplates[state])
                        + bassWeight * basses[block][root]
                }
            }
            row[noChord] = quiet ? 1 : 0.2
            return row
        }
        return viterbi(emissions: emissions, switchPenalty: switchPenalty)
    }

    /// Best path where staying costs nothing and switching costs `switchPenalty`.
    static func viterbi(emissions: [[Float]], switchPenalty: Float) -> [Int] {
        guard let first = emissions.first else { return [] }
        let stateCount = first.count
        var score = first
        var back = [[Int]](repeating: [Int](repeating: 0, count: stateCount), count: emissions.count)
        for t in 1..<emissions.count {
            let best = score.indices.max { score[$0] < score[$1] } ?? 0
            let switchScore = score[best] - switchPenalty
            var next = [Float](repeating: 0, count: stateCount)
            for state in 0..<stateCount {
                if score[state] >= switchScore {
                    next[state] = score[state] + emissions[t][state]
                    back[t][state] = state
                } else {
                    next[state] = switchScore + emissions[t][state]
                    back[t][state] = best
                }
            }
            score = next
        }
        var state = score.indices.max { score[$0] < score[$1] } ?? 0
        var path = [Int](repeating: 0, count: emissions.count)
        for t in stride(from: emissions.count - 1, through: 0, by: -1) {
            path[t] = state
            state = back[t][state]
        }
        return path
    }

    /// Chords shorter than `minimumLength` are usually passing notes or mistakes:
    /// they join the chord before them (or after, for the first one).
    static func removeShortChords(_ chords: [SongChord], minimumLength: Double, duration: Double) -> [SongChord] {
        var result = chords
        var changed = true
        while changed, result.count > 1 {
            changed = false
            for index in result.indices {
                let end = index + 1 < result.count ? result[index + 1].start : duration
                guard end - result[index].start < minimumLength else { continue }
                if index == 0 {
                    result[1].start = 0
                    result.remove(at: 0)
                } else {
                    result.remove(at: index)
                }
                changed = true
                break
            }
            // Merge neighbours that now have the same name.
            var merged: [SongChord] = []
            for chord in result where merged.last?.name != chord.name { merged.append(chord) }
            result = merged
        }
        return result
    }
}
