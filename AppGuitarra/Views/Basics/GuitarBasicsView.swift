//
//  GuitarBasicsView.swift
//  AppGuitarra
//
//  "Start here" for people who have never held a guitar.
//

import SwiftUI
import UIKit

struct GuitarBasicsView: View {
    @State private var selectedPart: GuitarPart? = .fretboard

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("New to guitar? Start here. Four things you need before your first chord.")
                        .font(.title3)
                        .foregroundStyle(.secondary)

                    BasicsSection(number: 1, title: "Parts of the guitar",
                                  subtitle: "Tap a number on the guitar, or a name in the list, to learn what each part does.") {
                        HStack(alignment: .top, spacing: 28) {
                            VStack(spacing: 6) {
                                GuitarIllustration(selected: $selectedPart)
                                    .frame(height: 600)
                                Text(GuitarIllustration.credit)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: 340)

                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(GuitarPart.allCases) { part in
                                    partRow(part)
                                }
                                partDetail
                                    .padding(.top, 8)
                            }
                        }
                    }

                    BasicsSection(number: 2, title: "The six strings",
                                  subtitle: "Strings are numbered from the thinnest (1) to the thickest (6). Tap one to hear it.") {
                        VStack(alignment: .leading, spacing: 12) {
                            StringsDiagram()
                            Label("Remember E-A-D-G-B-E with: \"Eddie Ate Dynamite, Good Bye Eddie\".", systemImage: "brain.head.profile")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    BasicsSection(number: 3, title: "Your finger numbers",
                                  subtitle: "Every diagram in the app uses these numbers for the hand on the neck.") {
                        HStack(alignment: .center, spacing: 32) {
                            HandDiagram()
                                .frame(width: 240)
                            VStack(alignment: .leading, spacing: 10) {
                                fingerRow("1", "Index")
                                fingerRow("2", "Middle")
                                fingerRow("3", "Ring")
                                fingerRow("4", "Pinky")
                                fingerRow("T", "Thumb: rests behind the neck, it doesn't press strings in our chords")
                            }
                        }
                    }

                    BasicsSection(number: 4, title: "Reading a chord diagram",
                                  subtitle: "A chord diagram is a picture of the neck standing up, with the strings facing you.") {
                        ChordDiagramExplainer()
                    }

                    BasicsSection(number: 5, title: "Holding and strumming",
                                  subtitle: "Quick tips for your first minutes.") {
                        VStack(alignment: .leading, spacing: 12) {
                            tip("chair", "Sit up straight and rest the guitar's body on your right leg, neck pointing left.")
                            tip("hand.point.up.left", "Press with your fingertips, just behind the metal fret, and keep your nails short.")
                            tip("arrow.down", "Strum down with a pick or your thumb over the sound hole, moving from the thick string to the thin one.")
                            tip("waveform", "If a string buzzes, press a bit harder or move your finger closer to the fret.")
                            tip("tuningfork", "Tune first, every time. Even perfect fingers sound wrong on an out-of-tune guitar.")
                        }
                    }
                }
                .padding(32)
                .frame(maxWidth: 1000)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Guitar Basics")
        }
    }

    @ViewBuilder
    private var partDetail: some View {
        if let part = selectedPart {
            HStack(alignment: .top, spacing: 14) {
                Text("\(part.number)")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.accentColor))
                VStack(alignment: .leading, spacing: 4) {
                    Text(part.title).font(.title3.bold())
                    Text(part.explanation)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.1)))
            .transition(.opacity)
        } else {
            Text("Tap a number on the guitar.")
                .foregroundStyle(.secondary)
        }
    }

    private func partRow(_ part: GuitarPart) -> some View {
        let isSelected = part == selectedPart
        return Button {
            withAnimation(.snappy) { selectedPart = isSelected ? nil : part }
        } label: {
            HStack(spacing: 12) {
                Text("\(part.number)")
                    .font(.subheadline.bold())
                    .foregroundStyle(isSelected ? .white : Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(isSelected ? Color.accentColor : Color.accentColor.opacity(0.12)))
                Text(part.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? Color.accentColor.opacity(0.1) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func fingerRow(_ badge: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Text(badge)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Color.accentColor)
        }
    }
}

/// Card with a numbered header.
struct BasicsSection<Content: View>: View {
    let number: Int
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "\(number).circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title2.bold())
                    Text(subtitle).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(uiColor: .secondarySystemBackground)))
    }
}

/// A real chord diagram (C) next to a legend of every symbol.
struct ChordDiagramExplainer: View {
    private var example: Chord? {
        (try? ChordLibrary.loadChords())?.first { $0.id == "C" }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            if let example {
                VStack(spacing: 8) {
                    ChordDiagramView(chord: example)
                        .frame(width: 200)
                    Text("Example: C major").font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                legend(symbol: AnyView(Image(systemName: "line.3.horizontal").rotationEffect(.degrees(90))),
                       text: "Vertical lines are the strings: thickest (6, low E) on the left, thinnest (1) on the right.")
                legend(symbol: AnyView(Image(systemName: "line.3.horizontal")),
                       text: "Horizontal lines are the frets. The thick bar on top is the nut.")
                legend(symbol: AnyView(numberDot("1")),
                       text: "A numbered dot: press that string in that space with that finger.")
                legend(symbol: AnyView(Text("○").font(.title2.bold())),
                       text: "Circle above a string: play it open, without pressing.")
                legend(symbol: AnyView(Text("✕").font(.title2.bold())),
                       text: "Cross above a string: don't play it.")
                legend(symbol: AnyView(Capsule().fill(.primary).frame(width: 30, height: 12)),
                       text: "A bar across several strings: one finger lies flat and presses all of them (a barre).")
                Text("In the Chords demo the neck is turned sideways, the way you see it when you look down at your guitar: the thick string is on top.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    private func numberDot(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.bold())
            .foregroundStyle(Color(uiColor: .systemBackground))
            .frame(width: 26, height: 26)
            .background(Circle().fill(.primary))
    }

    private func legend(symbol: AnyView, text: String) -> some View {
        HStack(alignment: .center, spacing: 14) {
            symbol.frame(width: 36)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    GuitarBasicsView()
}
