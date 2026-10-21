//
//  ContentView.swift
//  AppGuitarra
//
//  Created by Daniela Caiceros on 19/10/26.
//

import SwiftUI

struct ContentView: View {
    @State private var progress = LessonProgress()
    @State private var songs = SongStore()
    @State private var path = PathStore()

    var body: some View {
        TabView {
            Tab("Path", systemImage: "map") {
                PathView()
            }
            Tab("Lessons", systemImage: "graduationcap") {
                LessonsView()
            }
            Tab("Songs", systemImage: "music.note.list") {
                SongsView()
            }
            Tab("Trainer", systemImage: "stopwatch") {
                ChangeTrainerView()
            }
            Tab("Basics", systemImage: "book") {
                GuitarBasicsView()
            }
            Tab("Chords", systemImage: "guitars") {
                ChordLibraryView()
            }
            Tab("Tuner", systemImage: "tuningfork") {
                TunerView()
            }
        }
        .environment(progress)
        .environment(songs)
        .environment(path)
    }
}

#Preview {
    ContentView()
}
