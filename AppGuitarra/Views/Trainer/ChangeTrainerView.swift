//
//  ChangeTrainerView.swift
//  AppGuitarra
//
//  60-second change trainer: switch between two chords as many times as you
//  can. The mic only counts a change when the new chord rings clearly.
//

import SwiftUI

struct ChangeTrainerView: View {
    private static let presets: [(String, String)] = [
        ("G", "D"), ("C", "Am"), ("G", "C"), ("Em", "C"), ("D", "A"), ("Am", "F"), ("C", "Fmaj7"), ("E7", "A7"),
    ]
    private static let duration = 60

    nonisolated enum Phase: Equatable {
        case idle
        case countdown(Int)
        case running
        case finished(score: Int, isRecord: Bool)
    }

    @State private var chords: [String: Chord] = [:]
    @State private var allChords: [Chord] = []
    @State private var first = "G"
    @State private var second = "D"
    @State private var phase: Phase = .idle
    @State private var remaining = Double(duration)
    @State private var counter = ChangeCounter(first: "G", second: "D")
    @State private var listener = ChordListener()
    @State private var judge: ChordJudge?
    @State private var runTask: Task<Void, Never>?
    @AppStorage("detectionTolerance") private var tolerance: DetectionTolerance = .normal

    private var record: Int { TrainerRecords.record(first, second) }
    private var isBusy: Bool {
        switch phase {
        case .running, .countdown: true
        case .idle, .finished: false
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    pairPicker
                    HStack(alignment: .center, spacing: 32) {
                        chordCard(first)
                        scoreBoard
                        chordCard(second)
                    }
                    controls
                    tips
                }
                .padding(32)
            }
            .navigationTitle("Change Trainer")
        }
        .onAppear(perform: load)
        .onDisappear(perform: stop)
    }

    // MARK: - Pair

    private var pairPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Self.presets.indices, id: \.self) { index in
                        let pair = Self.presets[index]
                        let selected = Set([pair.0, pair.1]) == Set([first, second])
                        Button("\(pair.0) ↔ \(pair.1)") { choose(pair.0, pair.1) }
                            .buttonStyle(.bordered)
                            .tint(selected ? .accentColor : .secondary)
                            .font(.title3.weight(selected ? .bold : .regular))
                    }
                }
            }
            HStack(spacing: 16) {
                Text("Or pick your own:")
                    .foregroundStyle(.secondary)
                Picker("First chord", selection: Binding(get: { first }, set: { choose($0, second) })) {
                    ForEach(allChords) { Text($0.id).tag($0.id) }
                }
                Image(systemName: "arrow.left.arrow.right")
                Picker("Second chord", selection: Binding(get: { second }, set: { choose(first, $0) })) {
                    ForEach(allChords) { Text($0.id).tag($0.id) }
                }
                Spacer()
                Picker("Tolerance", selection: $tolerance) {
                    ForEach(DetectionTolerance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
            }
        }
        .disabled(isBusy)
    }

    private func choose(_ a: String, _ b: String) {
        guard a != b else { return }
        first = a
        second = b
        counter = ChangeCounter(first: a, second: b)
        phase = .idle
    }

    // MARK: - Board

    private func chordCard(_ id: String) -> some View {
        let isHeard = phase == .running && counter.current == id
        return VStack(spacing: 10) {
            Text(id)
                .font(.system(size: 48, weight: .bold, design: .rounded))
            if let chord = chords[id] {
                ChordDiagramView(chord: chord)
                    .frame(width: 170)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(isHeard ? Color.green.opacity(0.18) : Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(isHeard ? Color.green : .clear, lineWidth: 4)
        )
        .animation(.easeOut(duration: 0.15), value: isHeard)
    }

    private var scoreBoard: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 14)
                Circle()
                    .trim(from: 0, to: remaining / Double(Self.duration))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.1), value: remaining)
                VStack(spacing: 0) {
                    switch phase {
                    case .countdown(let n):
                        Text("\(n)")
                            .font(.system(size: 90, weight: .heavy, design: .rounded))
                            .contentTransition(.numericText())
                        Text("Get ready")
                            .font(.title3.weight(.semibold))
                    default:
                        Text("\(counter.changes)")
                            .font(.system(size: 90, weight: .heavy, design: .rounded))
                            .contentTransition(.numericText())
                            .animation(.snappy, value: counter.changes)
                        Text("clean changes")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 240, height: 240)

            Text("\(Int(remaining.rounded(.up))) s")
                .font(.title2.monospacedDigit().weight(.semibold))
            Label("Best: \(record)", systemImage: "trophy.fill")
                .font(.title3)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        if case .finished(let score, let isRecord) = phase {
            Label(isRecord ? "New record: \(score) changes!" : "\(score) changes. Record: \(record).",
                  systemImage: isRecord ? "star.fill" : "flag.checkered")
                .font(.title.weight(.bold))
                .foregroundStyle(isRecord ? Color.orange : Color.primary)
        }

        switch listener.status {
        case .permissionDenied:
            Label("The trainer needs the microphone. Allow it in Settings.", systemImage: "mic.slash")
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        case .idle, .listening:
            EmptyView()
        }

        Button {
            if isBusy { stop() } else { start() }
        } label: {
            Label(isBusy ? "Stop" : "Start 60 seconds", systemImage: isBusy ? "stop.fill" : "play.fill")
                .font(.title2.weight(.bold))
                .frame(minWidth: 240, minHeight: 50)
        }
        .buttonStyle(.borderedProminent)
        .tint(isBusy ? .red : .accentColor)
        .controlSize(.extraLarge)
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Strum once, switch, strum again. Speed comes from moving all fingers together.", systemImage: "hand.raised")
            Label("Only changes where the new chord rings clearly count. Lift your fingers just enough to move.", systemImage: "ear")
            Label("Keep the iPad about an arm's length away, in a quiet room.", systemImage: "ipad.landscape")
        }
        .font(.title3)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Run

    private func load() {
        guard allChords.isEmpty, let loaded = try? ChordLibrary.loadChords() else { return }
        allChords = loaded
        chords = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
    }

    private func start() {
        counter = ChangeCounter(first: first, second: second)
        remaining = Double(Self.duration)
        judge = ChordJudge(chords: allChords, tolerance: tolerance)
        runTask?.cancel()
        runTask = Task {
            await listener.start()
            guard listener.isListening else { phase = .idle; return }
            listener.onFrame = { frame in
                guard phase == .running, let judge else { return }
                let heard = judge.bestChord(chroma: frame.chroma, isSilent: frame.isSilent, among: [first, second])
                counter.add(heard)
            }
            for n in stride(from: 3, through: 1, by: -1) {
                phase = .countdown(n)
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            phase = .running
            let begin = Date()
            while !Task.isCancelled {
                remaining = max(0, Double(Self.duration) - Date().timeIntervalSince(begin))
                if remaining <= 0 { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled else { return }
            listener.stop()
            let score = counter.changes
            let isRecord = TrainerRecords.submit(score, first, second)
            phase = .finished(score: score, isRecord: isRecord)
        }
    }

    private func stop() {
        runTask?.cancel()
        runTask = nil
        listener.stop()
        if phase != .idle, !isFinished { phase = .idle }
        remaining = Double(Self.duration)
    }

    private var isFinished: Bool {
        if case .finished = phase { true } else { false }
    }
}

#Preview {
    ChangeTrainerView()
}
