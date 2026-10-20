//
//  StringsDiagram.swift
//  AppGuitarra
//
//  The six strings, thickest on top as you see them when holding the guitar.
//  Tap a string to hear it.
//

import SwiftUI

struct StringsDiagram: View {
    @State private var lastPlayed: Int?

    var body: some View {
        VStack(spacing: 6) {
            ForEach(StringInfo.all) { info in
                Button {
                    ChordSynth.shared.pluck(stringIndex: info.index)
                    withAnimation(.easeOut(duration: 0.15)) { lastPlayed = info.index }
                    Task {
                        try? await Task.sleep(for: .seconds(0.8))
                        withAnimation(.easeOut(duration: 0.4)) {
                            if lastPlayed == info.index { lastPlayed = nil }
                        }
                    }
                } label: {
                    row(info)
                }
                .buttonStyle(.plain)
            }
        }
        .onDisappear { ChordSynth.shared.shutdown() }
    }

    private func row(_ info: StringInfo) -> some View {
        let isPlaying = lastPlayed == info.index
        return HStack(spacing: 16) {
            Text("\(info.number)")
                .font(.title3.weight(.bold).monospacedDigit())
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))

            Text(info.fullName)
                .font(.headline)
                .frame(width: 70, alignment: .leading)

            Capsule()
                .fill(isPlaying ? Color.yellow : Color(red: 0.78, green: 0.72, blue: 0.6))
                .frame(height: 2 + CGFloat(Chord.stringCount - 1 - info.index) * 1.2)
                .frame(maxWidth: .infinity)
                .scaleEffect(y: isPlaying ? 2 : 1)

            Text(note(for: info))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 170, alignment: .leading)

            Image(systemName: "speaker.wave.2")
                .foregroundStyle(Color.accentColor)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func note(for info: StringInfo) -> String {
        switch info.number {
        case 6: "thickest · lowest sound"
        case 1: "thinnest · highest sound"
        default: "\(info.ordinal) string"
        }
    }
}

#Preview {
    StringsDiagram().padding()
}
