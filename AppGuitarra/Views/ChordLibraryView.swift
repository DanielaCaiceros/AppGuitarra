//
//  ChordLibraryView.swift
//  AppGuitarra
//

import SwiftUI
import UIKit

struct ChordLibraryView: View {
    @State private var chords: [Chord] = []
    @State private var loadError: String?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 24)]

    var body: some View {
        NavigationStack {
            Group {
                if let loadError {
                    ContentUnavailableView("Chords unavailable", systemImage: "exclamationmark.triangle", description: Text(loadError))
                } else {
                    ScrollView {
                        Label("Tap a chord to watch how to play it and hear how it sounds.", systemImage: "hand.tap")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 32)
                            .padding(.top, 8)
                        LazyVGrid(columns: columns, spacing: 28) {
                            ForEach(chords) { chord in
                                NavigationLink(value: chord) {
                                    ChordCard(chord: chord)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(32)
                    }
                }
            }
            .navigationTitle("Chords")
            .navigationDestination(for: Chord.self) { chord in
                ChordDetailView(chord: chord)
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard chords.isEmpty else { return }
        do {
            chords = try ChordLibrary.loadChords()
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct ChordCard: View {
    let chord: Chord

    var body: some View {
        VStack(spacing: 8) {
            ChordDiagramView(chord: chord)
            Text(chord.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(uiColor: .secondarySystemBackground)))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct ChordDetailView: View {
    let chord: Chord

    @AppStorage("hasSeenChordGuide") private var hasSeenGuide = false
    @State private var showsGuide = false
    @State private var demoRestart = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HStack(alignment: .top, spacing: 40) {
                    VStack(spacing: 12) {
                        ChordDiagramView(chord: chord)
                            .frame(width: 180)
                        Text(chord.name)
                            .font(.headline)
                        Text("Notes: " + chord.pitchClasses.sorted().map { NoteName.sharps[$0] }.joined(separator: " · "))
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                        Button {
                            showsGuide = true
                        } label: {
                            Label("How to read this", systemImage: "questionmark.circle")
                        }
                        .padding(.top, 8)
                    }
                    AnimatedChordView(chord: chord, restartToken: demoRestart)
                }
                ChordCheckPanel(chord: chord)
            }
            .padding(40)
        }
        .navigationTitle(chord.id)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsGuide = true
                } label: {
                    Label("How it works", systemImage: "questionmark.circle")
                }
            }
        }
        .sheet(isPresented: $showsGuide, onDismiss: {
            hasSeenGuide = true
            demoRestart += 1
        }) {
            ChordGuideSheet()
        }
        .onAppear {
            if !hasSeenGuide { showsGuide = true }
        }
    }
}

#Preview {
    ChordLibraryView()
}
