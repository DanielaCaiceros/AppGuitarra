//
//  ContentView.swift
//  AppGuitarra
//
//  Created by Daniela Caiceros on 19/10/26.
//

import SwiftUI

struct ContentView: View {
    @State private var progress = LessonProgress()

    var body: some View {
        TabView {
            Tab("Lessons", systemImage: "graduationcap") {
                LessonsView()
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
    }
}

#Preview {
    ContentView()
}
