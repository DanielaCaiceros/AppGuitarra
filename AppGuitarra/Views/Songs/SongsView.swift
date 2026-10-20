//
//  SongsView.swift
//  AppGuitarra
//
//  "My Songs": import an audio file or a video, the app finds its chords and
//  tempo, then you play along at your own speed.
//

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct SongsView: View {
    @Environment(SongStore.self) private var store
    @State private var showsFileImporter = false
    @State private var photoItem: PhotosPickerItem?
    @State private var isImporting = false
    @State private var importError: String?
    @State private var path: [UUID] = []

    private let columns = [GridItem(.adaptive(minimum: 320, maximum: 460), spacing: 20)]

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.songs.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                            ForEach(store.songs) { song in
                                NavigationLink(value: song.id) {
                                    SongCard(song: song, progress: store.progress[song.id], library: store.library)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Delete", systemImage: "trash", role: .destructive) { store.delete(song) }
                                }
                            }
                        }
                        .padding(32)
                    }
                }
            }
            .navigationTitle("My Songs")
            .toolbar {
                ToolbarItem(placement: .primaryAction) { importMenu }
            }
            .navigationDestination(for: UUID.self) { id in
                SongDetailView(songID: id)
            }
        }
        .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: [.audio, .movie]) { result in
            switch result {
            case .success(let url): importSong { try await store.importFile(at: url) }
            case .failure(let error): importError = error.localizedDescription
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            importSong {
                guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                    throw AudioDecoder.DecodeError.unreadable
                }
                defer { try? FileManager.default.removeItem(at: movie.url) }
                return try await store.importFile(at: movie.url)
            }
        }
        .overlay {
            if isImporting {
                ProgressView("Importing…")
                    .controlSize(.large)
                    .padding(32)
                    .background(RoundedRectangle(cornerRadius: 20).fill(.regularMaterial))
            }
        }
        .alert("Couldn't import", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    private var importMenu: some View {
        Menu {
            Button("From Files (MP3, M4A, MP4)", systemImage: "folder") { showsFileImporter = true }
            PhotosPicker(selection: $photoItem, matching: .videos) {
                Label("Video from Photos", systemImage: "photo.on.rectangle")
            }
        } label: {
            Label("Import song", systemImage: "plus")
        }
        .disabled(isImporting)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No songs yet", systemImage: "music.note.list")
        } description: {
            Text("Import a song you like (MP3, M4A or a video). The app finds its chords and tempo, and you play along at your own speed. The audio never leaves this iPad.")
        } actions: {
            Button("Import from Files", systemImage: "folder") { showsFileImporter = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            PhotosPicker(selection: $photoItem, matching: .videos) {
                Label("Video from Photos", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private func importSong(_ work: @escaping () async throws -> Song) {
        Task {
            isImporting = true
            defer { isImporting = false }
            do {
                let song = try await work()
                path = [song.id]
                Task { await store.analyze(song) }
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}

/// A video picked from Photos, copied to a temporary file.
nonisolated struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

private struct SongCard: View {
    let song: Song
    let progress: Double?
    let library: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "music.note")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text(song.title)
                    .font(.title3.weight(.bold))
                    .lineLimit(2)
                Spacer()
                Text(formatTime(song.duration))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            switch song.status {
            case .analyzing:
                ProgressView(value: progress ?? 0) {
                    Text("Finding chords…").font(.subheadline)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            case .ready:
                HStack(spacing: 8) {
                    ForEach(shapes, id: \.self) { shape in
                        Text(shape)
                            .font(.headline)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(library.contains(shape) ? Color.accentColor.opacity(0.15) : Color.orange.opacity(0.15)))
                    }
                }
                HStack(spacing: 16) {
                    if let bpm = song.bpm {
                        Label("\(Int(bpm.rounded())) bpm", systemImage: "metronome")
                    }
                    if song.capo > 0 {
                        Label("Capo \(song.capo)", systemImage: "guitars")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(uiColor: .secondarySystemBackground)))
        .contentShape(RoundedRectangle(cornerRadius: 20))
    }

    /// Distinct shapes you'd play, in order of appearance (first 6).
    private var shapes: [String] {
        var result: [String] = []
        for chord in song.chords where !chord.isNoChord {
            let shape = song.shape(for: chord.name, library: library)
            if !result.contains(shape) { result.append(shape) }
            if result.count == 6 { break }
        }
        return result
    }
}

/// "3:07"
func formatTime(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    return String(format: "%d:%02d", total / 60, total % 60)
}
