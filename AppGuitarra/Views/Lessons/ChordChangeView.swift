//
//  ChordChangeView.swift
//  AppGuitarra
//
//  Illustration of a chord change, drawn from the chord data: the fingers slide
//  from one shape to the other on the neck, anchors get a green ring, and a list
//  says what each finger does.
//

import SwiftUI

struct ChordChangeView: View {
    let from: Chord
    let to: Chord

    @AppStorage("soundOn") private var soundOn = true
    @State private var showingTarget = false
    @State private var isPlaying = true

    private var transition: ChordTransition { ChordTransition(from: from, to: to) }
    private var current: Chord { showingTarget ? to : from }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            FretboardView(
                chord: current,
                anchoredPlacements: transition.anchoredPlacements(in: current),
                dotsFollowFingers: true
            )
            .animation(.spring(duration: 0.7, bounce: 0.15), value: showingTarget)

            Label(transition.summary, systemImage: "lightbulb.fill")
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(transition.moves) { move in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Image(systemName: symbol(move.move))
                            .foregroundStyle(tint(move.move))
                            .frame(width: 28)
                        Text(move.description)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.title3)
                }
            }
        }
        .task(id: isPlaying) {
            guard isPlaying else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(showingTarget ? 2.2 : 1.6))
                guard !Task.isCancelled else { return }
                showingTarget.toggle()
                if soundOn { ChordSynth.shared.strum(current, stringDelay: 0.02) }
            }
        }
        .onDisappear { isPlaying = false }
    }

    private var header: some View {
        HStack(spacing: 16) {
            chordChip(from, isOn: !showingTarget) { pick(target: false) }
            Image(systemName: "arrow.right")
                .font(.title.weight(.bold))
                .foregroundStyle(.secondary)
            chordChip(to, isOn: showingTarget) { pick(target: true) }
            Spacer()
            Button {
                isPlaying.toggle()
            } label: {
                Label(isPlaying ? "Pause" : "Play change", systemImage: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3.weight(.semibold))
                    .frame(minWidth: 150, minHeight: 44)
            }
            .buttonStyle(.bordered)
        }
    }

    private func chordChip(_ chord: Chord, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(chord.id)
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .frame(minWidth: 90, minHeight: 60)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 16).fill(isOn ? Color.accentColor : Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show \(chord.name)")
    }

    private func pick(target: Bool) {
        isPlaying = false
        showingTarget = target
        if soundOn { ChordSynth.shared.strum(current, stringDelay: 0.02) }
    }

    private func symbol(_ move: ChordTransition.Move) -> String {
        switch move {
        case .anchor: "pin.fill"
        case .slide: "arrow.left.and.right"
        case .move: "arrow.turn.down.right"
        case .lift: "arrow.up"
        case .place: "plus.circle.fill"
        }
    }

    private func tint(_ move: ChordTransition.Move) -> Color {
        switch move {
        case .anchor: .green
        case .slide: .blue
        case .move: .orange
        case .lift, .place: .secondary
        }
    }
}

#Preview {
    if let chords = try? ChordLibrary.loadChords(),
       let c = chords.first(where: { $0.id == "C" }), let am = chords.first(where: { $0.id == "Am" }) {
        ChordChangeView(from: c, to: am).padding(32)
    }
}
