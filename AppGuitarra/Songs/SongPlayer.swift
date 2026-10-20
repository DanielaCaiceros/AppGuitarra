//
//  SongPlayer.swift
//  AppGuitarra
//
//  Plays an imported song at 50–100 % speed without changing its pitch
//  (AVAudioUnitTimePitch), with an optional A–B loop.
//

import AVFoundation
import Observation

@Observable
final class SongPlayer {
    private(set) var isPlaying = false
    private(set) var duration: Double = 0
    private(set) var errorMessage: String?
    /// 0.5...1. Changes speed, not pitch.
    var rate: Double = 1 {
        didSet { timePitch.rate = Float(rate) }
    }
    /// Section repeated while playing.
    var loop: ClosedRange<Double>?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    @ObservationIgnored private let timePitch = AVAudioUnitTimePitch()
    @ObservationIgnored private var file: AVAudioFile?
    /// Song time where the current scheduled segment starts.
    @ObservationIgnored private var segmentStart: Double = 0
    @ObservationIgnored private var pausedAt: Double = 0
    @ObservationIgnored private var watchTask: Task<Void, Never>?

    init() {
        engine.attach(player)
        engine.attach(timePitch)
    }

    func load(url: URL) {
        stop()
        do {
            let file = try AVAudioFile(forReading: url)
            self.file = file
            duration = Double(file.length) / file.processingFormat.sampleRate
            engine.disconnectNodeOutput(player)
            engine.disconnectNodeOutput(timePitch)
            engine.connect(player, to: timePitch, format: file.processingFormat)
            engine.connect(timePitch, to: engine.mainMixerNode, format: file.processingFormat)
            pausedAt = 0
            errorMessage = nil
        } catch {
            errorMessage = AudioDecoder.DecodeError.unreadable.localizedDescription
        }
    }

    /// Current position in song seconds.
    func currentTime() -> Double {
        guard isPlaying,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else { return pausedAt }
        let time = segmentStart + Double(playerTime.sampleTime) / playerTime.sampleRate
        return min(max(0, time), duration)
    }

    func play() {
        guard let file, !isPlaying else { return }
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
        schedule(file: file, from: start)
        player.play()
        isPlaying = true
        startWatching()
    }

    func pause() {
        guard isPlaying else { return }
        pausedAt = currentTime()
        player.stop()
        isPlaying = false
        watchTask?.cancel()
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func seek(to time: Double) {
        let target = min(max(0, time), max(0, duration - 0.01))
        if isPlaying, let file {
            player.stop()
            schedule(file: file, from: target)
            player.play()
        } else {
            pausedAt = target
        }
    }

    func stop() {
        watchTask?.cancel()
        player.stop()
        engine.stop()
        isPlaying = false
        pausedAt = 0
    }

    private func schedule(file: AVAudioFile, from time: Double) {
        let rate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(time * rate)
        let frames = AVAudioFrameCount(max(0, file.length - startFrame))
        guard frames > 0 else { return }
        segmentStart = time
        player.scheduleSegment(file, startingFrame: startFrame, frameCount: frames, at: nil)
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
