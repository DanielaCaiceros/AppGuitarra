//
//  ChordGuideSheet.swift
//  AppGuitarra
//
//  In-app guidance for the chord demo. Shown automatically the first time
//  a chord is opened, and any time from the "How it works" button.
//

import SwiftUI

struct ChordGuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Every chord plays a short demo in two steps. Watch it, then copy it on your guitar.")
                        .font(.title3)
                        .foregroundStyle(.secondary)

                    row(icon: "1.circle.fill", title: "Place your fingers",
                        text: "Blue dots appear one at a time. The number in each dot is the finger to use, and the caption tells you the string and fret.") {
                        HandDiagram().frame(width: 120)
                    }

                    row(icon: "2.circle.fill", title: "Strum",
                        text: "The strings you should play light up in yellow from top to bottom while the chord sounds. That's a downstroke: brush your pick from the thick string to the thin one.") {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 50, weight: .heavy))
                            .foregroundStyle(.yellow)
                            .frame(width: 120)
                    }

                    row(icon: "xmark.circle", title: "✕ and ○ next to the strings",
                        text: "✕ means don't play that string. ○ means play it open, without pressing it.") {
                        HStack(spacing: 14) {
                            Text("✕").foregroundStyle(.red)
                            Text("○").foregroundStyle(.green)
                        }
                        .font(.system(size: 40, weight: .bold))
                        .frame(width: 120)
                    }

                    row(icon: "speedometer", title: "Demo speed",
                        text: "Slow, Medium or Normal changes how fast the demo plays, so you can follow each finger. It doesn't change the sound of your guitar.") {
                        HStack(spacing: 6) {
                            Image(systemName: "tortoise.fill")
                            Image(systemName: "hare.fill")
                        }
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .frame(width: 120)
                    }

                    row(icon: "arrow.counterclockwise", title: "Replay and Strum",
                        text: "Replay shows the whole demo again. Strum only plays the chord so you can compare it with yours. The speaker button turns sound on or off.") {
                        Image(systemName: "music.note")
                            .font(.largeTitle)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 120)
                    }
                }
                .padding(32)
            }
            .navigationTitle("How a chord lesson works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Got it") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func row<Visual: View>(icon: String, title: String, text: String, @ViewBuilder visual: () -> Visual) -> some View {
        HStack(alignment: .center, spacing: 20) {
            visual()
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: icon)
                    .font(.title3.bold())
                Text(text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.secondary.opacity(0.08)))
    }
}

#Preview {
    ChordGuideSheet()
}
