//
//  SongPlayer.swift
//  AppGuitarra
//
//  Plays an imported song at 50–100 % speed without changing its pitch
//  (AVAudioUnitTimePitch), with an optional A–B loop. A separated song plays
//  as its four tracks in sync, each with its own volume.
//

import AVFoundation
import Observation

@Observable
final class SongPlayer {
    private(set) var isPlaying = false
    private(set) var duration: Double = 0
    private(set) var errorMessage: String?
    /// Tracks loaded (empty = the original file).
    private(set) var stems: [Stem] = []
    /// 0.5...1. Changes speed, not pitch.
    var rate: Double = 1 {
        didSet { timePitch.rate = Float(rate) }
    }
    /// Section repeated while playing.
    var loop: ClosedRange<Double>?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let mixer = AVAudioMixerNode()
    @ObservationIgnored private let timePitch = AVAudioUnitTimePitch()
    /// One player per file; all scheduled and started together.
    @ObservationIgnored private var tracks: [(file: AVAudioFile, node: AVAudioPlayerNode)] = []
    /// Song time where the current scheduled segment starts.
    @ObservationIgnored private var segmentStart: Double = 0
    @ObservationIgnored private var pausedAt: Double = 0
    @ObservationIgnored private var watchTask: Task<Void, Never>?

    init() {
        engine.attach(mixer)
        engine.attach(timePitch)
    }

    /// The original file.
    func load(url: URL) {
        load(files: [url], stems: [])
    }

    /// The separated tracks, at the given volumes.
    func load(stems urls: [Stem: URL], mix: StemMix) {
        let order = Stem.allCases.filter { urls[$0] != nil }
        load(files: order.compactMap { urls[$0] }, stems: order)
        setMix(mix)
    }

    func setMix(_ mix: StemMix) {
        for (stem, track) in zip(stems, tracks) {
            track.node.volume = Float(mix.volume(stem))
        }
    }

    private func load(files urls: [URL], stems: [Stem]) {
        let resume = isPlaying
        let position = currentTime()
        stop()
        for track in tracks {
            engine.detach(track.node)
        }
        tracks = []
        self.stems = []
        do {
            let files = try urls.map { try AVAudioFile(forReading: $0) }
            guard let first = files.first else { throw AudioDecoder.DecodeError.unreadable }
            engine.disconnectNodeOutput(mixer)
            engine.disconnectNodeOutput(timePitch)
            for file in files {
                let node = AVAudioPlayerNode()
                engine.attach(node)
                engine.connect(node, to: mixer, format: file.processingFormat)
                tracks.append((file, node))
            }
            engine.connect(mixer, to: timePitch, format: first.processingFormat)
            engine.connect(timePitch, to: engine.mainMixerNode, format: first.processingFormat)
            duration = files.map { Double($0.length) / $0.processingFormat.sampleRate }.min() ?? 0
            self.stems = stems
            pausedAt = min(position, duration)
            errorMessage = nil
            if resume { play() }
        } catch {
            errorMessage = AudioDecoder.DecodeError.unreadable.localizedDescription
        }
    }

    /// Current position in song seconds.
    func currentTime() -> Double {
        guard isPlaying,
              let node = tracks.first?.node,
              let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else { return pausedAt }
        let time = segmentStart + Double(playerTime.sampleTime) / playerTime.sampleRate
        return min(max(0, time), duration)
    }

    func play() {
        guard !tracks.isEmpty, !isPlaying else { return }
        do {
            try AudioSessionHelper.activate(recording: false)
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        var start = pausedAt
        if let loop, !(loop.lowerBound..<loop.upperBound).contains(start) { start = loop.lowerBound }
        if start >= duration - 0.05 { start = 0 }
        scheduleAndStart(from: start)
        isPlaying = true
        startWatching()
    }

    func pause() {
        guard isPlaying else { return }
        pausedAt = currentTime()
        for track in tracks { track.node.stop() }
        isPlaying = false
        watchTask?.cancel()
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func seek(to time: Double) {
        let target = min(max(0, time), max(0, duration - 0.01))
        if isPlaying {
            for track in tracks { track.node.stop() }
            scheduleAndStart(from: target)
        } else {
            pausedAt = target
        }
    }

    func stop() {
        watchTask?.cancel()
        for track in tracks { track.node.stop() }
        engine.stop()
        isPlaying = false
        pausedAt = 0
    }

    /// Schedules every track from `time` and starts them on the same render
    /// time, so the separated tracks stay sample-aligned.
    private func scheduleAndStart(from time: Double) {
        segmentStart = time
        for track in tracks {
            let rate = track.file.processingFormat.sampleRate
            let startFrame = AVAudioFramePosition(time * rate)
            let frames = AVAudioFrameCount(max(0, track.file.length - startFrame))
            guard frames > 0 else { continue }
            track.node.scheduleSegment(track.file, startingFrame: startFrame, frameCount: frames, at: nil)
        }
        if tracks.count == 1 {
            tracks[0].node.play()
            return
        }
        let start = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05))
        for track in tracks { track.node.play(at: start) }
    }

    /// Checks the loop end and the end of the song while playing.
    private func startWatching() {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(25))
                guard let self, self.isPlaying else { return }
                let now = self.currentTime()
                if let loop = self.loop, now >= loop.upperBound {
                    self.seek(to: loop.lowerBound)
                } else if now >= self.duration - 0.02 {
                    self.pause()
                    self.pausedAt = 0
                    return
                }
            }
        }
    }
}
