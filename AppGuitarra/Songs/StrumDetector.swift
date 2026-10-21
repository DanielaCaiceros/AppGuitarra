//
//  StrumDetector.swift
//  AppGuitarra
//
//  Guesses the strum pattern of an imported song from where its hits fall.
//
//  1. Every eighth note of the beat grid gets a strength: the strongest onset
//     (spectral flux) close to it.
//  2. Where the bar starts ("1"): chords usually change on beat 1, so the beat
//     phase (of 4) that catches the most chord changes wins; stronger hits
//     break ties.
//  3. The eighths are folded into one bar and averaged over the whole song.
//     Slots that are clearly hit become strokes. Up or down can't be heard
//     reliably, so it follows the usual rule: down on the beat, up on the "and".
//
//  Drums and vocals also make onsets, so it is a guess: the user can pick
//  another pattern and move the "1".
//

import Foundation

nonisolated struct StrumGuess: Codable, Hashable, Sendable {
    /// One bar of eighths, "D-DU-UDU" style.
    let strokes: String
    let accents: [Int]
    /// Time of one "1" (bar start). Bars repeat every 4 beats from here.
    let barOffset: Double
    /// Average strength of each slot, 0...1.
    let slotStrengths: [Double]
    /// 0...1: how clearly the hit slots stand out from the missed ones.
    let confidence: Double
}

nonisolated enum StrumDetector {
    static let slotsPerBar = 8
    /// A slot counts as played when it reaches this share of the strongest slot.
    static let playedShare = 0.5

    /// - Parameters:
    ///   - onsets: onset curve, one value per hop.
    ///   - frameTime: time of onset frame 0 (half an analysis window).
    static func detect(
        onsets: [Float],
        hopSeconds: Double,
        frameTime: Double,
        bpm: Double,
        beatOffset: Double,
        chords: [SongChord],
        duration: Double
    ) -> StrumGuess? {
        guard bpm > 0, !onsets.isEmpty, duration > 0 else { return nil }
        let beat = 60 / bpm
        let slot = beat / 2
        var first = beatOffset.truncatingRemainder(dividingBy: beat)
        if first < 0 { first += beat }
        let count = Int((duration - first) / slot)
        guard count >= slotsPerBar * 2 else { return nil }

        // Strength of each eighth on the grid (nil where there is no chord).
        let reach = min(0.05, slot * 0.3)
        var strengths = [Double?](repeating: nil, count: count)
        for k in 0..<count {
            let time = first + Double(k) * slot
            if let index = chordIndex(chords, at: time), chords[index].isNoChord { continue }
            let low = max(0, Int(((time - reach - frameTime) / hopSeconds).rounded(.down)))
            let high = min(onsets.count - 1, Int(((time + reach - frameTime) / hopSeconds).rounded(.up)))
            guard low <= high else { continue }
            var peak: Float = 0
            for i in low...high { peak = max(peak, onsets[i]) }
            strengths[k] = Double(peak)
        }

        let phase = downbeatPhase(chords: chords, first: first, beat: beat, strengths: strengths)

        // Fold into one bar.
        var sums = [Double](repeating: 0, count: slotsPerBar)
        var counts = [Int](repeating: 0, count: slotsPerBar)
        for k in 0..<count {
            guard let value = strengths[k] else { continue }
            let barSlot = ((k - 2 * phase) % slotsPerBar + slotsPerBar) % slotsPerBar
            sums[barSlot] += value
            counts[barSlot] += 1
        }
        var means = (0..<slotsPerBar).map { counts[$0] > 0 ? sums[$0] / Double(counts[$0]) : 0 }
        guard let peak = means.max(), peak > 0 else { return nil }
        means = means.map { $0 / peak }

        let played = (0..<slotsPerBar).map { $0 == 0 || means[$0] >= playedShare }
        let strokes = String((0..<slotsPerBar).map { played[$0] ? ($0 % 2 == 0 ? "D" : "U") : "-" })

        let hit = (0..<slotsPerBar).filter { played[$0] }.map { means[$0] }
        let missed = (0..<slotsPerBar).filter { !played[$0] }.map { means[$0] }
        let hitMean = hit.reduce(0, +) / Double(max(1, hit.count))
        let confidence: Double = missed.isEmpty
            ? 1 - (hit.max()! - hit.min()!)   // all hit: sure only if they're even
            : max(0, min(1, hitMean - missed.reduce(0, +) / Double(missed.count)))

        // Accents: hits that clearly stand out from the rest (e.g. 2 and 4 on a backbeat).
        var accents = (0..<slotsPerBar).filter { played[$0] && means[$0] >= 0.9 }
        if accents.count * 2 > hit.count || accents.isEmpty { accents = [0] }

        return StrumGuess(
            strokes: strokes,
            accents: accents,
            barOffset: first + Double(phase) * beat,
            slotStrengths: means,
            confidence: confidence
        )
    }

    /// Beat phase (0..<4) where bars start: the one that catches the most chord changes.
    static func downbeatPhase(chords: [SongChord], first: Double, beat: Double, strengths: [Double?]) -> Int {
        var scores = [Double](repeating: 0, count: 4)
        for chord in chords where !chord.isNoChord && chord.start > 0.05 {
            let position = (chord.start - first) / beat
            let nearest = position.rounded()
            guard abs(position - nearest) < 0.3, nearest >= 0 else { continue }
            scores[Int(nearest) % 4] += 1
        }
        // Tie-break with the strength of the hits on each beat.
        var beatSums = [Double](repeating: 0, count: 4)
        var beatCounts = [Int](repeating: 0, count: 4)
        for k in stride(from: 0, to: strengths.count, by: 2) {
            guard let value = strengths[k] else { continue }
            beatSums[(k / 2) % 4] += value
            beatCounts[(k / 2) % 4] += 1
        }
        let beatMeans = (0..<4).map { beatCounts[$0] > 0 ? beatSums[$0] / Double(beatCounts[$0]) : 0 }
        let loudest = max(beatMeans.max() ?? 0, 1e-9)
        for p in 0..<4 { scores[p] += 0.5 * beatMeans[p] / loudest }
        return scores.indices.max { scores[$0] < scores[$1] } ?? 0
    }

    private static func chordIndex(_ chords: [SongChord], at time: Double) -> Int? {
        var found: Int?
        for (index, chord) in chords.enumerated() {
            if chord.start <= time { found = index } else { break }
        }
        return found
    }

    /// The lesson pattern (4/4 eighths) whose hits match best; nil if none is within one slot.
    static func closest(to strokes: String, in patterns: [StrumPattern]) -> (pattern: StrumPattern, distance: Int)? {
        let target = Array(strokes).map { $0 != "-" }
        guard target.count == slotsPerBar else { return nil }
        var best: (StrumPattern, Int)?
        for pattern in patterns where pattern.beatsPerBar == 4 && pattern.slotsPerBeat == 2 {
            let slots = pattern.slots
            guard !slots.contains(where: \.isSingleNote) else { continue }
            let distance = (0..<slotsPerBar).filter { slots[$0].isPlayed != target[$0] }.count
            if distance <= 1, distance < (best?.1 ?? .max) { best = (pattern, distance) }
        }
        return best.map { (pattern: $0.0, distance: $0.1) }
    }
}
