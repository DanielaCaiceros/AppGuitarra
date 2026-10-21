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
        let url = audioURL(for: song)
        progress[id] = 0

        let store = self
        let outcome: Result<SongAnalysis, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let audio = try AudioDecoder.loadMono(url: url)
                let analysis = SongAnalyzer.analyze(samples: audio.samples, sampleRate: audio.sampleRate) { value in
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
        case .failure(let error):
            current.status = .failed(error.localizedDescription)
        }
        save(current)
    }

    /// Guesses only the tempo and strum pattern, keeping the chords as they are
    /// (for songs imported before pattern detection, or after editing chords).
    func findStrum(_ song: Song) async {
        let id = song.id
        let url = audioURL(for: song)
        let chords = song.chords
        progress[id] = 0.1
        let outcome: SongAnalysis? = await Task.detached(priority: .userInitiated) {
            guard let audio = try? AudioDecoder.loadMono(url: url) else { return nil }
            return SongAnalyzer.analyzeStrum(samples: audio.samples, sampleRate: audio.sampleRate, chords: chords)
        }.value
        progress[id] = nil
        guard var current = self.song(id: id), let outcome else { return }
        if let bpm = outcome.bpm { current.bpm = bpm }
        current.strum = outcome.strum
        current.barOffset = outcome.strum?.barOffset
        save(current)
    }
}
