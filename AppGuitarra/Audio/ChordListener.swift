//
//  ChordListener.swift
//  AppGuitarra
//
//  Listens to the guitar through the microphone and publishes, about 20 times
//  a second, a ListenFrame: loudness, chroma and a low-frequency spectrum.
//  Whoever owns the listener decides what to compare it with
//  (the lesson check, the change trainer, the chord check in the library).
//

import AVFoundation
import Observation

/// One analysis of the last ~170 ms of microphone audio.
nonisolated struct ListenFrame: Sendable {
    /// Loudness of the newest audio (RMS, 0...1).
    let rms: Float
    let isSilent: Bool
    /// 12 pitch classes, normalized (all zero when silent).
    let chroma: [Float]
    /// Power spectrum up to ~1.3 kHz, for the per-string check.
    let power: [Float]
    let binHz: Double
}

/// Turns microphone buffers into frames. Runs on the audio thread.
nonisolated final class ListenAnalyzer: @unchecked Sendable {
    let sampleRate: Double
    let windowSize: Int
    let hopSize: Int
    /// Below this RMS the input counts as silence.
    var silenceThreshold: Float = 0.004
    /// Highest frequency kept in `ListenFrame.power`.
    var keptFrequency = 1300.0

    private let spectrum: PowerSpectrum
    private var samples: [Float] = []
    private var newSamples = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        // ~170 ms: enough resolution to separate the low strings (≈5.9 Hz bins at 48 kHz).
        windowSize = PowerSpectrum.size(forSeconds: 0.16, sampleRate: sampleRate)
        hopSize = windowSize / 4
        spectrum = PowerSpectrum(size: windowSize, sampleRate: sampleRate)
        samples.reserveCapacity(windowSize * 2)
    }

    func process(_ buffer: AVAudioPCMBuffer) -> ListenFrame? {
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        return process(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    /// Adds new audio and returns a frame once a hop's worth of it has arrived.
    func process(_ input: UnsafeBufferPointer<Float>) -> ListenFrame? {
        samples.append(contentsOf: input)
        if samples.count > windowSize {
            samples.removeFirst(samples.count - windowSize)
        }
        newSamples += input.count
        guard samples.count == windowSize, newSamples >= hopSize else { return nil }
        newSamples = 0
        return analyze()
    }

    func reset() {
        samples.removeAll(keepingCapacity: true)
        newSamples = 0
    }

    private func analyze() -> ListenFrame {
        let recent = samples.suffix(hopSize)
        let rms = (recent.reduce(0) { $0 + $1 * $1 } / Float(recent.count)).squareRoot()
        let binHz = spectrum.binHz
        let keptBins = min(windowSize / 2, Int(keptFrequency / binHz) + 2)
        guard rms >= silenceThreshold else {
            return ListenFrame(rms: rms, isSilent: true, chroma: [Float](repeating: 0, count: 12), power: [], binHz: binHz)
        }
        let power = spectrum.compute(samples)
        return ListenFrame(
            rms: rms,
            isSilent: false,
            chroma: ChromaExtractor.chroma(power: power, binHz: binHz),
            power: Array(power.prefix(keptBins)),
            binHz: binHz
        )
    }
}

@Observable
final class ChordListener {
    enum Status: Equatable {
        case idle
        case listening
        case permissionDenied
        case failed(String)
    }

    private(set) var status: Status = .idle
    /// 0...1, for a level meter.
    private(set) var level: Float = 0
    private(set) var latest: ListenFrame?
    /// Called on the main actor for every frame.
    @ObservationIgnored var onFrame: ((ListenFrame) -> Void)?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var continuation: AsyncStream<ListenFrame>.Continuation?
    @ObservationIgnored private var listenTask: Task<Void, Never>?

    var isListening: Bool { status == .listening }

    func start() async {
        guard status != .listening else { return }

        guard await AVAudioApplication.requestRecordPermission() else {
            status = .permissionDenied
            return
        }

        do {
            // Play-and-record so lessons can keep the metronome going while we listen.
            try AudioSessionHelper.activate(recording: true)

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw TunerEngine.TunerError.noInput }

            let analyzer = ListenAnalyzer(sampleRate: format.sampleRate)
            let (stream, continuation) = AsyncStream.makeStream(of: ListenFrame.self, bufferingPolicy: .bufferingNewest(8))
            self.continuation = continuation
            Self.installTap(on: input, format: format, analyzer: analyzer) { frame in
                continuation.yield(frame)
            }
            listenTask = Task { [weak self] in
                for await frame in stream {
                    self?.handle(frame)
                }
            }

            engine.prepare()
            try engine.start()
            status = .listening
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            finishStream()
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        guard status == .listening else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        finishStream()
        status = .idle
        level = 0
        latest = nil
    }

    private func finishStream() {
        continuation?.finish()
        continuation = nil
        listenTask?.cancel()
        listenTask = nil
    }

    private func handle(_ frame: ListenFrame) {
        guard status == .listening else { return }
        // Roughly −50 dB ... −10 dB mapped to 0...1.
        let db = 20 * log10(max(frame.rms, 1e-6))
        level = max(0, min(1, (db + 50) / 40))
        latest = frame
        onFrame?(frame)
    }

    nonisolated private static func installTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        analyzer: ListenAnalyzer,
        onFrame: @escaping @Sendable (ListenFrame) -> Void
    ) {
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            if let frame = analyzer.process(buffer) {
                onFrame(frame)
            }
        }
    }
}

/// One place that decides the audio session category, so the metronome,
/// the synth and the microphone do not switch it under each other.
enum AudioSessionHelper {
    static func activate(recording: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        if recording {
            if session.category != .playAndRecord || session.mode != .measurement {
                // .measurement turns off automatic gain and voice processing, which distort chords.
                try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            }
        } else if session.category != .playback && session.category != .playAndRecord {
            // If the mic is in use (playAndRecord), keep it: playback works there too.
            try session.setCategory(.playback, mode: .default)
        }
        try session.setActive(true)
    }
}
