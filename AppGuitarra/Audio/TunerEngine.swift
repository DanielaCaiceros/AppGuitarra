//
//  TunerEngine.swift
//  AppGuitarra
//
//  Captures the microphone with AVAudioEngine and publishes tuner output.
//

import AVFoundation
import Observation

@Observable
final class TunerEngine {
    enum Status: Equatable {
        case idle
        case listening
        case permissionDenied
        case failed(String)
    }

    nonisolated enum TunerError: LocalizedError {
        case noInput
        var errorDescription: String? { "No microphone input is available." }
    }

    private(set) var status: Status = .idle
    private(set) var output: TunerOutput?

    /// nil = auto-detect the string being played.
    var lockedString: Int? {
        get { state.lockedString }
        set {
            state.lockedString = newValue
            state.reset()
            output = nil
        }
    }

    @ObservationIgnored private let engine = AVAudioEngine()
    private var state = TuningState()
    @ObservationIgnored private var silentBuffers = 0

    func start() async {
        guard status != .listening else { return }

        guard await AVAudioApplication.requestRecordPermission() else {
            status = .permissionDenied
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            // .measurement turns off voice processing and automatic gain, which distort pitch.
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw TunerError.noInput }

            let analyzer = PitchAnalyzer(sampleRate: format.sampleRate)
            Self.installTap(on: input, format: format, analyzer: analyzer) { [weak self] frequency in
                Task { @MainActor in self?.handle(frequency) }
            }

            engine.prepare()
            try engine.start()
            status = .listening
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        guard status == .listening else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        status = .idle
        output = nil
        state.reset()
    }

    private func handle(_ frequency: Double?) {
        guard let frequency else {
            silentBuffers += 1
            if silentBuffers > 12 {   // keep the last reading on screen for about a second
                output = nil
                state.reset()
            }
            return
        }
        silentBuffers = 0
        output = state.update(frequency)
    }

    /// Installed from a nonisolated context so the tap block does not inherit
    /// main-actor isolation: AVAudioEngine calls it on its own audio thread.
    nonisolated private static func installTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        analyzer: PitchAnalyzer,
        onResult: @escaping @Sendable (Double?) -> Void
    ) {
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            onResult(analyzer.process(buffer))
        }
    }
}
