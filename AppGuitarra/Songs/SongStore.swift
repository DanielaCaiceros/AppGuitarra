//
//  SongStore.swift
//  AppGuitarra
//
//  Imported songs live in Documents/Songs/<id>/ (audio file + song.json).
//  Nothing leaves the iPad.
//

import AVFoundation
import Foundation
import Observation
import UniformTypeIdentifiers

nonisolated enum AudioDecoder {
    nonisolated enum DecodeError: LocalizedError {
        case unreadable
        case noAudioTrack

        var errorDescription: String? {
            switch self {
            case .unreadable: "This file can't be played. Try an MP3, M4A or MP4."
            case .noAudioTrack: "This video has no sound to extract."
            }
        }
    }

    /// Duration in seconds, or an error if the file can't be decoded.
    static func duration(of url: URL) throws -> Double {
        do {
            let file = try AVAudioFile(forReading: url)
            return Double(file.length) / file.processingFormat.sampleRate
        } catch {
            throw DecodeError.unreadable
        }
    }

    /// Whole file as mono samples, downsampled by an integer factor to ≤ ~24 kHz
    /// (plenty for chords and beats, and twice as fast to analyze).
    static func loadMono(url: URL, maxSampleRate: Double = 24_000) throws -> (samples: [Float], sampleRate: Double) {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw DecodeError.unreadable }
        let format = file.processingFormat
        let sourceRate = format.sampleRate
        let factor = max(1, Int((sourceRate / maxSampleRate).rounded(.up)))
        let channels = Int(format.channelCount)
        let chunk: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw DecodeError.unreadable }

        var output: [Float] = []
        output.reserveCapacity(Int(file.length) / factor + 1)
        var accumulator: Float = 0
        var accumulated = 0

        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunk)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            for i in 0..<frames {
                var mono: Float = 0
                for channel in 0..<channels { mono += data[channel][i] }
                accumulator += mono / Float(channels)
                accumulated += 1
                if accumulated == factor {
                    output.append(accumulator / Float(factor))
                    accumulator = 0
                    accumulated = 0
                }
            }
        }
        return (output, sourceRate / Double(factor))
    }

    /// Several files of the same song mixed to mono (the separated guitar and bass).
    static func loadMono(urls: [URL]) throws -> (samples: [Float], sampleRate: Double) {
        var mixed: [Float] = []
        var rate = 0.0
        for url in urls {
            let audio = try loadMono(url: url)
            if mixed.isEmpty {
                mixed = audio.samples
                rate = audio.sampleRate
            } else {
                for i in 0..<min(mixed.count, audio.samples.count) { mixed[i] += audio.samples[i] }
            }
        }
        return (mixed, rate)
    }

    /// Saves the sound of a video as an .m4a file.
    static func extractAudio(from movie: URL, to output: URL) async throws {
        let asset = AVURLAsset(url: movie)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw DecodeError.noAudioTrack }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw DecodeError.unreadable
        }
        try await session.export(to: output, as: .m4a)
    }
}

@Observable
final class SongStore {
    private(set) var songs: [Song] = []
    /// 0...1 while a song is being analyzed.
    private(set) var progress: [UUID: Double] = [:]
    /// 0...1 while a song is being split into tracks.
    private(set) var separation: [UUID: Double] = [:]
    /// Why the last separation failed, per song.
    private(set) var separationErrors: [UUID: String] = [:]
    @ObservationIgnored private var separationTasks: [UUID: Task<Void, Never>] = [:]
    /// Chord ids that have a diagram in the app.
    let library: Set<String>
    let chords: [String: Chord]
    /// Lesson strum patterns, in lesson-file order (to pick instead of the guess).
    let patterns: [StrumPattern]
    let patternsByID: [String: StrumPattern]

    @ObservationIgnored private let root: URL

    init(root: URL? = nil) {
        self.root = root ?? URL.documentsDirectory.appending(path: "Songs", directoryHint: .isDirectory)
        let loaded = (try? ChordLibrary.loadChords()) ?? []
        library = Set(loaded.map(\.id))
        chords = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        let patternList: [StrumPattern] = Bundle.main.url(forResource: "patterns", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([StrumPattern].self, from: $0) } ?? []
        patterns = patternList
        patternsByID = Dictionary(patternList.map { ($0.id, $0) }) { first, _ in first }
        load()
    }

    func folder(for id: UUID) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    func audioURL(for song: Song) -> URL {
        folder(for: song.id).appending(path: song.audioFileName)
    }

    func song(id: UUID) -> Song? {
        songs.first { $0.id == id }
    }

    func stemURL(_ stem: Stem, for song: Song) -> URL {
        folder(for: song.id).appending(path: stem.fileName)
    }

    /// The song was separated and its track files are all there.
    func hasStems(_ song: Song) -> Bool {
        song.stems != nil && Stem.allCases.allSatisfy { FileManager.default.fileExists(atPath: stemURL($0, for: song).path) }
    }

    /// Audio to read chords and strums from (guitar + bass when separated),
    /// and the full mix to find the beat in when they differ.
    private func analysisSources(for song: Song) -> (chords: [URL], tempo: URL?) {
        if hasStems(song) {
            return ([stemURL(.other, for: song), stemURL(.bass, for: song)], audioURL(for: song))
        }
        return ([audioURL(for: song)], nil)
    }

    // MARK: - Persistence

    func load() {
        let manager = FileManager.default
        try? manager.createDirectory(at: root, withIntermediateDirectories: true)
        let folders = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        var loaded: [Song] = []
        for folder in folders {
            guard let data = try? Data(contentsOf: folder.appending(path: "song.json")),
                  var song = try? decoder.decode(Song.self, from: data) else { continue }
            // An analysis cut short by quitting the app is retried from the song screen.
            if case .analyzing = song.status {
                song.status = .failed("Analysis was interrupted.")
            }
            loaded.append(song)
        }
        songs = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ song: Song) {
        var song = song
        song.normalizeChords()
        do {
            try FileManager.default.createDirectory(at: folder(for: song.id), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(song).write(to: folder(for: song.id).appending(path: "song.json"), options: .atomic)
        } catch {
            assertionFailure("Could not save song: \(error)")
        }
        if let index = songs.firstIndex(where: { $0.id == song.id }) {
            songs[index] = song
        } else {
            songs.insert(song, at: 0)
        }
    }

    func delete(_ song: Song) {
        separationTasks[song.id]?.cancel()
        try? FileManager.default.removeItem(at: folder(for: song.id))
        songs.removeAll { $0.id == song.id }
        progress[song.id] = nil
    }

    // MARK: - Import

    /// Copies an audio or video file into the app. Videos keep only their sound.
    func importFile(at url: URL) async throws -> Song {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }

        let id = UUID()
        let folder = folder(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        do {
            let type = UTType(filenameExtension: url.pathExtension.lowercased())
            let fileName: String
            if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true {
                fileName = "audio.m4a"
                try await AudioDecoder.extractAudio(from: url, to: folder.appending(path: fileName))
            } else {
                fileName = "audio." + (url.pathExtension.isEmpty ? "m4a" : url.pathExtension.lowercased())
                try FileManager.default.copyItem(at: url, to: folder.appending(path: fileName))
            }
            let duration = try AudioDecoder.duration(of: folder.appending(path: fileName))
            let title = url.deletingPathExtension().lastPathComponent
            let song = Song(id: id, title: title, audioFileName: fileName, duration: duration)
            save(song)
            return song
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    // MARK: - Analysis

    /// Detects tempo and chords. Replaces the song's chords.
    func analyze(_ song: Song) async {
        var pending = song
        pending.status = .analyzing
        save(pending)
        let id = song.id
        let sources = analysisSources(for: song)
        progress[id] = 0

        let store = self
        let outcome: Result<SongAnalysis, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let audio = try AudioDecoder.loadMono(urls: sources.chords)
                let tempo = try sources.tempo.map { try AudioDecoder.loadMono(url: $0) }
                let analysis = SongAnalyzer.analyze(samples: audio.samples, sampleRate: audio.sampleRate, tempoAudio: tempo) { value in
                    Task { @MainActor in store.progress[id] = value }
                }
                return .success(analysis)
            } catch {
                return .failure(error)
            }
        }.value

        progress[id] = nil
        guard var current = self.song(id: id) else { return }   // deleted meanwhile
        switch outcome {
        case .success(let analysis):
            current.bpm = analysis.bpm
            current.chords = analysis.chords
            current.strum = analysis.strum
            current.barOffset = analysis.strum?.barOffset
            let best = CapoAdvisor.best(for: analysis.chords, duration: current.duration, library: library)
            current.suggestedCapo = (best?.capo ?? 0) > 0 ? best?.capo : nil
            current.status = analysis.chords.isEmpty ? .failed("No chords found. Add them by hand with Edit.") : .ready
            current.chordsFromStems = sources.tempo != nil
        case .failure(let error):
            current.status = .failed(error.localizedDescription)
        }
        save(current)
    }

    /// Guesses only the tempo and strum pattern, keeping the chords as they are
    /// (for songs imported before pattern detection, or after editing chords).
    func findStrum(_ song: Song) async {
        let id = song.id
        let sources = analysisSources(for: song)
        let chords = song.chords
        progress[id] = 0.1
        let outcome: SongAnalysis? = await Task.detached(priority: .userInitiated) {
            guard let audio = try? AudioDecoder.loadMono(urls: sources.chords) else { return nil }
            let tempo = sources.tempo.flatMap { try? AudioDecoder.loadMono(url: $0) }
            return SongAnalyzer.analyzeStrum(samples: audio.samples, sampleRate: audio.sampleRate, chords: chords, tempoAudio: tempo)
        }.value
        progress[id] = nil
        guard var current = self.song(id: id), let outcome else { return }
        if let bpm = outcome.bpm { current.bpm = bpm }
        current.strum = outcome.strum
        current.barOffset = outcome.strum?.barOffset
        save(current)
    }

    // MARK: - Separation

    /// Splits the song into drums, bass, guitar & others and vocals (on the
    /// iPad, about as long as the song or less). Keeps the chords as they are.
    func separate(_ song: Song) {
        let id = song.id
        guard separationTasks[id] == nil else { return }
        let input = audioURL(for: song)
        let folder = folder(for: id)
        separation[id] = 0
        separationErrors[id] = nil

        let store = self
        let work = Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
            do {
                let separator = try StemSeparator()
                try separator.separateFile(at: input, into: folder) { value in
                    Task { @MainActor in
                        if store.separation[id] != nil { store.separation[id] = value }
                    }
                }
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        separationTasks[id] = Task {
            // A detached task doesn't follow its parent's cancellation, so pass it on.
            let outcome = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            store.separation[id] = nil
            store.separationTasks[id] = nil
            guard var current = store.song(id: id) else { return }   // deleted meanwhile
            switch outcome {
            case .success:
                current.stems = current.stems ?? StemMix.Preset.guitarUp.mix
                store.save(current)
            case .failure(let error) where error is CancellationError:
                break
            case .failure(let error):
                store.separationErrors[id] = error.localizedDescription
            }
        }
    }

    func cancelSeparation(_ song: Song) {
        separationTasks[song.id]?.cancel()
    }

    /// Deletes the separated tracks (to free space); the song plays as before.
    func removeStems(_ song: Song) {
        for stem in Stem.allCases { try? FileManager.default.removeItem(at: stemURL(stem, for: song)) }
        var current = song
        current.stems = nil
        current.chordsFromStems = nil
        save(current)
    }
}
