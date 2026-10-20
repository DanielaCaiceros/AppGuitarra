//
//  ContentView.swift
//  AppGuitarra
//
//  Created by Daniela Caiceros on 19/10/26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
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
    }
}

#Preview {
    ContentView()
}
