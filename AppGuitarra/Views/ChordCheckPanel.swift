//
//  ChordCheckPanel.swift
//  AppGuitarra
//
//  "Check my chord": strum the chord and the mic says whether it sounds right
//  and, when it can, which string is muted or should not ring.
//

import SwiftUI

struct ChordCheckPanel: View {
    let chord: Chord

    @State private var listener = ChordListener()
    @State private var judge: ChordJudge?
    @State private var verdict: ChordVerdict?
    @State private var reports: [StringReport] = []
    /// Frames since the last strum, averaged so the result does not flicker.
    @State private var recent: [ListenFrame] = []
    @AppStorage("detectionTolerance") private var tolerance: DetectionTolerance = .normal

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Label("Check my chord", systemImage: "ear")
                    .font(.title2.weight(.bold))
                Spacer()
                Picker("Tolerance", selection: $tolerance) {
                    ForEach(DetectionTolerance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
            }

            Text("Place the iPad about an arm's length away, press Listen and strum \(chord.id) once. Let it ring.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 14) {
                    listenButton
                    if listener.isListening {
                        ProgressView(value: Double(listener.level)) {
                            Text("Mic level").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(width: 200)
                    }
                }
                verdictView
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !reports.isEmpty {
                stringRows
            }
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(uiColor: .secondarySystemBackground)))
        .onDisappear { listener.stop() }
        .onChange(of: tolerance) { rebuildJudge() }
    }

    // MARK: - Pieces

    private var listenButton: some View {
        Button {
            if listener.isListening {
                listener.stop()
            } else {
                Task { await startListening() }
            }
        } label: {
            Label(listener.isListening ? "Stop" : "Listen", systemImage: listener.isListening ? "stop.fill" : "mic.fill")
                .font(.title2.weight(.bold))
                .frame(minWidth: 160, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(listener.isListening ? .red : .accentColor)
        .controlSize(.extraLarge)
    }

    @ViewBuilder
    private var verdictView: some View {
        switch listener.status {
        case .permissionDenied:
            Label("Allow microphone access in Settings to check your chord.", systemImage: "mic.slash")
                .font(.title3)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        case .idle, .listening:
            if let verdict {
                verdictLabel(verdict)
            } else if listener.isListening {
                Label("Strum the chord…", systemImage: "waveform")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .symbolEffect(.variableColor.iterative, isActive: true)
            }
        }
    }

    @ViewBuilder
    private func verdictLabel(_ verdict: ChordVerdict) -> some View {
        let problems = reports.filter { $0.status == .quiet || $0.status == .shouldBeMuted }
        switch verdict {
        case .match where problems.isEmpty:
            Label("Sounds like \(chord.id)!", systemImage: "checkmark.circle.fill")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.green)
        case .match:
            Label("Almost: \(chord.id) is there, but check the strings below.", systemImage: "checkmark.circle")
                .font(.title.weight(.bold))
                .foregroundStyle(.orange)
        case .other(let heard):
            VStack(alignment: .leading, spacing: 6) {
                Label("That sounded like \(heard)", systemImage: "arrow.left.arrow.right.circle.fill")
                    .font(.title.weight(.bold))
                    .foregroundStyle(.orange)
                Text("Compare your fingers with the diagram: same frets, same strings?")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        case .unclear, .silence:
            VStack(alignment: .leading, spacing: 6) {
                Label("Not clear yet", systemImage: "questionmark.circle.fill")
                    .font(.title.weight(.bold))
                    .foregroundStyle(.orange)
                Text("Press right behind the frets, use your fingertips, and check the tuner if it still sounds off.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var stringRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("String by string")
                .font(.headline)
            ForEach(reports.reversed(), id: \.stringIndex) { report in
                let info = StringInfo.all[report.stringIndex]
                HStack(spacing: 12) {
                    Image(systemName: symbol(report.status))
                        .foregroundStyle(color(report.status))
                        .frame(width: 28)
                    Text("\(info.ordinal) · \(info.shortName)")
                        .font(.body.monospaced().weight(.semibold))
                        .frame(width: 80, alignment: .leading)
                    Text(message(report, info: info))
                        .foregroundStyle(report.status == .ok || report.status == .notChecked ? .secondary : .primary)
                }
                .font(.title3)
            }
            Text("Some strings can't be told apart by ear from the others; they show a dash.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func symbol(_ status: StringReport.Status) -> String {
        switch status {
        case .ok: "checkmark.circle.fill"
        case .quiet: "speaker.slash.fill"
        case .shouldBeMuted: "xmark.octagon.fill"
        case .notChecked: "minus.circle"
        }
    }

    private func color(_ status: StringReport.Status) -> Color {
        switch status {
        case .ok: .green
        case .quiet, .shouldBeMuted: .orange
        case .notChecked: .secondary
        }
    }

    private func message(_ report: StringReport, info: StringInfo) -> String {
        switch report.status {
        case .ok: chord.isMuted(report.stringIndex) ? "Not strummed. Good." : "Rings"
        case .quiet: "Barely ringing: press closer to the fret and keep other fingers off it."
        case .shouldBeMuted: "Don't strum this one. Start from the \(firstPlayedOrdinal) string."
        case .notChecked: "—"
        }
    }

    private var firstPlayedOrdinal: String {
        chord.playedStringIndexes.first.map { StringInfo.all[$0].ordinal } ?? "first"
    }

    // MARK: - Listening

    private func rebuildJudge() {
        let chords = (try? ChordLibrary.loadChords()) ?? [chord]
        judge = ChordJudge(chords: chords, tolerance: tolerance)
    }

    private func startListening() async {
        if judge == nil { rebuildJudge() }
        verdict = nil
        reports = []
        recent = []
        listener.onFrame = { frame in handle(frame) }
        await listener.start()
    }

    private func handle(_ frame: ListenFrame) {
        guard !frame.isSilent, let judge else { return }
        // A clearly louder frame is a new strum: forget the previous one.
        if let last = recent.last, frame.rms > last.rms * 2 {
            recent.removeAll()
        }
        recent.append(frame)
        if recent.count > 8 { recent.removeFirst() }
        // The pick attack is noisy: wait for the second frame of a strum.
        guard recent.count >= 2 else { return }

        let chroma = ChromaExtractor.normalized(average(recent.map(\.chroma)))
        verdict = judge.verdict(chroma: chroma, isSilent: false, expected: chord.id)

        let powers = recent.map(\.power).filter { !$0.isEmpty }
        if let binHz = recent.last?.binHz, !powers.isEmpty {
            reports = StringChecker.check(power: average(powers), binHz: binHz, chord: chord)
        }
    }

    private func average(_ vectors: [[Float]]) -> [Float] {
        let length = vectors.map(\.count).min() ?? 0
        guard length > 0 else { return [] }
        var sum = [Float](repeating: 0, count: length)
        for vector in vectors {
            for i in 0..<length { sum[i] += vector[i] }
        }
        return sum.map { $0 / Float(vectors.count) }
    }
}
