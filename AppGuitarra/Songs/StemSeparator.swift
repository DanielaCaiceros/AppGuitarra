//
//  StemSeparator.swift
//  AppGuitarra
//
//  Splits an imported song into four tracks (drums, bass, guitar & others,
//  vocals) with HTDemucs, Meta's open-source model (MIT license), converted
//  to Core ML. It runs on the iPad, once per song, and the tracks are saved
//  next to the song. Nothing leaves the device.
//
//  The Core ML model (HTDemucs.mlpackage) is only the neural network. Around
//  it, this file does what demucs does in Python, step for step. The steps
//  were checked against demucs itself (tools/demucs/README.md):
//  1. Whole song → 44.1 kHz stereo, normalized with the mean and std of its
//     mono mix.
//  2. 7.8 s segments with 25 % overlap, joined back with triangle weights.
//  3. For each segment: STFT (4096 points, hop 1024, Hann, "normalized"),
//     the model, then iSTFT plus the model's time-domain branch.
//

import Accelerate
import AVFoundation
import CoreML
import Foundation

/// The four tracks, in the order the model outputs them.
nonisolated enum Stem: String, CaseIterable, Codable, Sendable, Identifiable {
    case drums, bass, other, vocals

    var id: String { rawValue }

    var title: String {
        switch self {
        case .drums: "Drums"
        case .bass: "Bass"
        case .other: "Guitar & others"
        case .vocals: "Vocals"
        }
    }

    var systemImage: String {
        switch self {
        case .drums: "music.quarternote.3"
        case .bass: "waveform.path"
        case .other: "guitars"
        case .vocals: "music.mic"
        }
    }

    var fileName: String { "stem-\(rawValue).m4a" }
}

// MARK: - STFT / iSTFT

/// HTDemucs' spectrogram and its inverse (`_spec` and `_ispec` in
/// demucs/htdemucs.py), matching torch.stft / torch.istft with
/// n_fft 4096, hop 1024, periodic Hann window, normalized, center, reflect.
nonisolated struct SpectrogramTransform {
    static let size = 4096
    static let hop = 1024
    /// The model drops the Nyquist bin.
    static let bins = 2048

    let window: [Float]
    private let forward: vDSP.DFT<Float>
    private let inverse: vDSP.DFT<Float>

    init() {
        let n = Self.size
        window = (0..<n).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(n)) }
        forward = vDSP.DFT(count: n, direction: .forward, transformType: .complexComplex, ofType: Float.self)!
        inverse = vDSP.DFT(count: n, direction: .inverse, transformType: .complexComplex, ofType: Float.self)!
    }

    /// Spectrogram frames for a signal of `length` samples.
    static func frames(for length: Int) -> Int {
        (length + hop - 1) / hop
    }

    /// torch's "reflect" padding: mirrors around the edge sample without repeating it.
    static func reflectPad(_ x: [Float], left: Int, right: Int) -> [Float] {
        let n = x.count
        precondition(left < n && right < n, "Signal too short to reflect-pad")
        var out = [Float]()
        out.reserveCapacity(n + left + right)
        if left > 0 {
            for i in stride(from: left, through: 1, by: -1) { out.append(x[i]) }
        }
        out.append(contentsOf: x)
        for i in 0..<right { out.append(x[n - 2 - i]) }
        return out
    }

    /// Spectrogram of one channel into `real` and `imag`, each `bins × frames`
    /// row-major (bin, frame), the layout the model reads.
    func spectrogram(of x: [Float], real: UnsafeMutablePointer<Float>, imag: UnsafeMutablePointer<Float>) {
        let n = Self.size
        let hop = Self.hop
        let bins = Self.bins
        let frames = Self.frames(for: x.count)
        let pad = hop / 2 * 3
        // HTDemucs pads first (so frames line up with the time branch), then torch.stft centers.
        let once = Self.reflectPad(x, left: pad, right: pad + frames * hop - x.count)
        let padded = Self.reflectPad(once, left: n / 2, right: n / 2)

        let scale = 1 / Float(n).squareRoot()
        var inReal = [Float](repeating: 0, count: n)
        let inImag = [Float](repeating: 0, count: n)
        var outReal = [Float](repeating: 0, count: n)
        var outImag = [Float](repeating: 0, count: n)
        // Frame-major (frame, bin) first, transposed at the end.
        var byFrameReal = [Float](repeating: 0, count: frames * bins)
        var byFrameImag = [Float](repeating: 0, count: frames * bins)

        padded.withUnsafeBufferPointer { signal in
            for t in 0..<frames {
                // HTDemucs keeps frames 2..<2+frames of torch's output.
                let start = (t + 2) * hop
                vDSP.multiply(UnsafeBufferPointer(rebasing: signal[start..<start + n]), window, result: &inReal)
                forward.transform(inputReal: inReal, inputImaginary: inImag, outputReal: &outReal, outputImaginary: &outImag)
                byFrameReal.withUnsafeMutableBufferPointer { dst in
                    var row = UnsafeMutableBufferPointer(rebasing: dst[t * bins..<(t + 1) * bins])
                    vDSP.multiply(scale, outReal[0..<bins], result: &row)
                }
                byFrameImag.withUnsafeMutableBufferPointer { dst in
                    var row = UnsafeMutableBufferPointer(rebasing: dst[t * bins..<(t + 1) * bins])
                    vDSP.multiply(scale, outImag[0..<bins], result: &row)
                }
            }
        }
        // (frames × bins) → (bins × frames)
        vDSP_mtrans(byFrameReal, 1, real, 1, vDSP_Length(bins), vDSP_Length(frames))
        vDSP_mtrans(byFrameImag, 1, imag, 1, vDSP_Length(bins), vDSP_Length(frames))
    }

    /// Inverse of `spectrogram`: `length` samples from `bins × frames` real and
    /// imaginary parts, added into `output`.
    func addSignal(real: UnsafePointer<Float>, imag: UnsafePointer<Float>, frames: Int, length: Int, into output: UnsafeMutablePointer<Float>) {
        let n = Self.size
        let hop = Self.hop
        let bins = Self.bins
        let pad = hop / 2 * 3
        // HTDemucs adds 2 empty frames on each side before torch.istft.
        let total = frames + 4
        let bufferLength = n + hop * (total - 1)
        precondition(n / 2 + pad + length <= bufferLength, "Length does not fit the frames")

        var byFrameReal = [Float](repeating: 0, count: frames * bins)
        var byFrameImag = [Float](repeating: 0, count: frames * bins)
        vDSP_mtrans(real, 1, &byFrameReal, 1, vDSP_Length(frames), vDSP_Length(bins))
        vDSP_mtrans(imag, 1, &byFrameImag, 1, vDSP_Length(frames), vDSP_Length(bins))

        var buffer = [Float](repeating: 0, count: bufferLength)
        var envelope = [Float](repeating: 0, count: bufferLength)
        var spectrumReal = [Float](repeating: 0, count: n)
        var spectrumImag = [Float](repeating: 0, count: n)
        var outReal = [Float](repeating: 0, count: n)
        var outImag = [Float](repeating: 0, count: n)
        var windowed = [Float](repeating: 0, count: n)
        // Unscaled inverse DFT × 1/N (irfft) × √N (undo "normalized") = 1/√N.
        let windowScaled = vDSP.multiply(1 / Float(n).squareRoot(), window)
        let windowSquared = vDSP.square(window)

        for t in 0..<total {
            let start = t * hop
            envelope.withUnsafeMutableBufferPointer { env in
                let slice = UnsafeMutableBufferPointer(rebasing: env[start..<start + n])
                var result = slice
                vDSP.add(slice, windowSquared, result: &result)
            }
            guard t >= 2, t < 2 + frames else { continue }   // the padding frames are silent
            let frame = t - 2
            // Full Hermitian spectrum: bins 0..<2048, Nyquist 0, mirror of 1..<2048 above it.
            for b in 0..<bins {
                spectrumReal[b] = byFrameReal[frame * bins + b]
                spectrumImag[b] = byFrameImag[frame * bins + b]
            }
            spectrumImag[0] = 0
            spectrumReal[bins] = 0
            spectrumImag[bins] = 0
            for b in 1..<bins {
                spectrumReal[n - b] = spectrumReal[b]
                spectrumImag[n - b] = -spectrumImag[b]
            }
            inverse.transform(inputReal: spectrumReal, inputImaginary: spectrumImag, outputReal: &outReal, outputImaginary: &outImag)
            vDSP.multiply(outReal, windowScaled, result: &windowed)
            buffer.withUnsafeMutableBufferPointer { buf in
                let slice = UnsafeMutableBufferPointer(rebasing: buf[start..<start + n])
                var result = slice
                vDSP.add(slice, windowed, result: &result)
            }
        }

        let first = n / 2 + pad
        for j in 0..<length {
            output[j] += buffer[first + j] / envelope[first + j]
        }
    }
}

// MARK: - Separator

nonisolated final class StemSeparator {
    static let sampleRate = 44_100.0
    /// HTDemucs' training segment: 7.8 s.
    static let segment = 343_980
    static let overlap = 0.25
    static let modelName = "HTDemucs"

    enum SeparationError: LocalizedError {
        case modelMissing
        case unexpectedOutput

        var errorDescription: String? {
            switch self {
            case .modelMissing: "The separation model isn't installed in this build of the app."
            case .unexpectedOutput: "The separation model returned something unexpected."
            }
        }
    }

    static var isAvailable: Bool {
        Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") != nil
    }

    private let model: MLModel
    private let transform = SpectrogramTransform()

    init(computeUnits: MLComputeUnits = .all) throws {
        guard let url = Bundle.main.url(forResource: Self.modelName, withExtension: "mlmodelc") else {
            throw SeparationError.modelMissing
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: url, configuration: configuration)
    }

    /// Separates a 44.1 kHz stereo song. `emit` receives the finished audio in
    /// order, about 6 s at a time: left and right samples for each stem.
    /// `progress` goes from 0 to 1. Throws `CancellationError` if the task is cancelled.
    func separate(
        left: [Float],
        right: [Float],
        progress: (Double) -> Void,
        emit: ([Stem: (left: [Float], right: [Float])]) throws -> Void
    ) throws {
        let count = min(left.count, right.count)
        guard count > 0 else { return }
        let segment = Self.segment
        let stride = Int((1 - Self.overlap) * Double(segment))

        // Normalize with the mono mix's mean and std (demucs/separate.py).
        let mono = vDSP.multiply(0.5, vDSP.add(left[0..<count], right[0..<count]))
        let mean = vDSP.mean(mono)
        let std = Self.standardDeviation(mono, mean: mean)
        let scale = std > 0 ? 1 / std : 1
        let songLeft = vDSP.multiply(scale, vDSP.add(-mean, left[0..<count]))
        let songRight = vDSP.multiply(scale, vDSP.add(-mean, right[0..<count]))

        // Triangle weights, peaking in the middle of the segment.
        let half = segment / 2
        var weight = (1...half).map { Float($0) } + Swift.stride(from: segment - half, through: 1, by: -1).map { Float($0) }
        weight = vDSP.divide(weight, Float(half))

        // Accumulators for song samples [offset, offset + segment).
        var sums = [[Float]](repeating: [Float](repeating: 0, count: segment), count: Stem.allCases.count * 2)
        var weights = [Float](repeating: 0, count: segment)

        let offsets = Array(Swift.stride(from: 0, to: count, by: stride))
        for (index, offset) in offsets.enumerated() {
            try Task.checkCancellation()
            let length = min(segment, count - offset)
            let delta = segment - length
            let start = offset - delta / 2
            let chunk = [Self.window(songLeft, start: start, length: segment),
                         Self.window(songRight, start: start, length: segment)]
            let stems = try run(chunk: chunk)

            // Keep the middle `length` samples (the chunk was padded around them).
            let keep = delta / 2
            for track in 0..<sums.count {
                stems[track].withUnsafeBufferPointer { piece in
                    let trimmed = UnsafeBufferPointer(rebasing: piece[keep..<keep + length])
                    sums[track].withUnsafeMutableBufferPointer { sum in
                        let target = UnsafeMutableBufferPointer(rebasing: sum[0..<length])
                        var result = target
                        vDSP.add(multiplication: (trimmed, weight[0..<length]), target, result: &result)
                    }
                }
            }
            weights.withUnsafeMutableBufferPointer { sum in
                let target = UnsafeMutableBufferPointer(rebasing: sum[0..<length])
                var result = target
                vDSP.add(target, weight[0..<length], result: &result)
            }

            // Samples before the next chunk's offset get no more contributions.
            let isLast = index == offsets.count - 1
            let finished = isLast ? length : min(stride, length)
            var output: [Stem: (left: [Float], right: [Float])] = [:]
            let divisor = Array(weights[0..<finished])
            for (stemIndex, stem) in Stem.allCases.enumerated() {
                let channels = (0..<2).map { channel in
                    let values = vDSP.divide(sums[stemIndex * 2 + channel][0..<finished], divisor)
                    return vDSP.add(mean, vDSP.multiply(std, values))
                }
                output[stem] = (channels[0], channels[1])
            }
            try emit(output)

            // Slide the accumulators forward.
            if !isLast {
                for track in 0..<sums.count {
                    sums[track] = Array(sums[track][stride...]) + [Float](repeating: 0, count: stride)
                }
                weights = Array(weights[stride...]) + [Float](repeating: 0, count: stride)
            }
            progress(Double(index + 1) / Double(offsets.count))
        }
    }

    /// One 7.8 s stereo chunk through the model. Returns 8 tracks of `segment`
    /// samples: for each stem in `Stem.allCases` order, left then right.
    private func run(chunk: [[Float]]) throws -> [[Float]] {
        let segment = Self.segment
        let bins = SpectrogramTransform.bins
        let frames = SpectrogramTransform.frames(for: segment)
        let plane = bins * frames

        // Inputs: the waveform and its spectrogram, each normalized here in
        // Float32 (the model was converted without those reductions).
        let mixArray = try MLMultiArray(shape: [1, 2, NSNumber(value: segment)], dataType: .float32)
        let specArray = try MLMultiArray(shape: [1, 4, NSNumber(value: bins), NSNumber(value: frames)], dataType: .float32)

        let (mixMean, mixStd) = mixArray.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            for channel in 0..<2 {
                chunk[channel].withUnsafeBufferPointer { source in
                    _ = memcpy(buffer.baseAddress! + channel * segment, source.baseAddress!, segment * MemoryLayout<Float>.size)
                }
            }
            return Self.normalize(buffer)
        }
        let (specMean, specStd) = specArray.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            for channel in 0..<2 {
                // Channels: left real, left imaginary, right real, right imaginary.
                transform.spectrogram(of: chunk[channel],
                                      real: buffer.baseAddress! + (2 * channel) * plane,
                                      imag: buffer.baseAddress! + (2 * channel + 1) * plane)
            }
            return Self.normalize(buffer)
        }

        let inputs = try MLDictionaryFeatureProvider(dictionary: [
            "mix": MLFeatureValue(multiArray: mixArray),
            "spec": MLFeatureValue(multiArray: specArray),
        ])
        let result = try model.prediction(from: inputs)
        guard let specOut = result.featureValue(for: "specOut")?.multiArrayValue,
              let waveOut = result.featureValue(for: "wave")?.multiArrayValue else {
            throw SeparationError.unexpectedOutput
        }
        var spectra = try Self.floats(specOut)
        var waves = try Self.floats(waveOut)
        let stems = Stem.allCases.count
        guard spectra.count == stems * 4 * plane, waves.count == stems * 2 * segment else {
            throw SeparationError.unexpectedOutput
        }
        // Undo the normalization.
        spectra = vDSP.add(specMean, vDSP.multiply(specStd, spectra))
        waves = vDSP.add(mixMean, vDSP.multiply(mixStd, waves))

        var tracks: [[Float]] = []
        tracks.reserveCapacity(stems * 2)
        spectra.withUnsafeBufferPointer { spec in
            for stem in 0..<stems {
                for channel in 0..<2 {
                    // Time branch + frequency branch.
                    var track = Array(waves[(stem * 2 + channel) * segment..<(stem * 2 + channel + 1) * segment])
                    let base = spec.baseAddress! + (stem * 4 + 2 * channel) * plane
                    track.withUnsafeMutableBufferPointer { out in
                        transform.addSignal(real: base, imag: base + plane, frames: frames, length: segment, into: out.baseAddress!)
                    }
                    tracks.append(track)
                }
            }
        }
        return tracks
    }

    /// `length` samples from `start` (may be negative or run past the end; zeros there).
    private static func window(_ x: [Float], start: Int, length: Int) -> [Float] {
        var out = [Float](repeating: 0, count: length)
        let from = max(0, start)
        let to = min(x.count, start + length)
        if to > from {
            out.replaceSubrange((from - start)..<(to - start), with: x[from..<to])
        }
        return out
    }

    /// Normalizes in place to mean 0 and std 1 (std as torch: n − 1, plus 1e-5).
    /// Returns the mean and the divisor used.
    private static func normalize(_ buffer: UnsafeMutableBufferPointer<Float>) -> (mean: Float, std: Float) {
        let mean = vDSP.mean(buffer)
        let std = standardDeviation(buffer, mean: mean) + 1e-5
        var target = buffer
        vDSP.add(-mean, buffer, result: &target)
        let centered = target
        vDSP.divide(centered, std, result: &target)
        return (mean, std)
    }

    /// All values of a Float32 or Float16 multiarray in row-major order,
    /// whatever its strides (Core ML may pad rows for the Neural Engine).
    static func floats(_ array: MLMultiArray) throws -> [Float] {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        guard let width = shape.last, let step = strides.last, width > 0 else { return [] }
        let count = shape.reduce(1, *)
        let rows = count / width
        var out = [Float](repeating: 0, count: count)

        func eachRow(_ body: (_ row: Int, _ offset: Int) -> Void) {
            var index = [Int](repeating: 0, count: shape.count - 1)
            for row in 0..<rows {
                var offset = 0
                for d in 0..<index.count { offset += index[d] * strides[d] }
                body(row, offset)
                var d = index.count - 1
                while d >= 0 {
                    index[d] += 1
                    if index[d] < shape[d] { break }
                    index[d] = 0
                    d -= 1
                }
            }
        }

        switch array.dataType {
        case .float32:
            array.withUnsafeBufferPointer(ofType: Float.self) { source in
                out.withUnsafeMutableBufferPointer { target in
                    eachRow { row, offset in
                        for i in 0..<width { target[row * width + i] = source[offset + i * step] }
                    }
                }
            }
        case .float16:
            array.withUnsafeBufferPointer(ofType: Float16.self) { source in
                out.withUnsafeMutableBufferPointer { target in
                    eachRow { row, offset in
                        for i in 0..<width { target[row * width + i] = Float(source[offset + i * step]) }
                    }
                }
            }
        default:
            throw SeparationError.unexpectedOutput
        }
        return out
    }

    /// Unbiased standard deviation, accumulated in Double (millions of samples).
    private static func standardDeviation<C: AccelerateBuffer>(_ values: C, mean: Float) -> Float where C.Element == Float {
        values.withUnsafeBufferPointer { buffer in
            guard buffer.count > 1 else { return 0 }
            var sum = 0.0
            let m = Double(mean)
            for value in buffer {
                let d = Double(value) - m
                sum += d * d
            }
            return Float((sum / Double(buffer.count - 1)).squareRoot())
        }
    }
}

// MARK: - Files

nonisolated extension StemSeparator {
    /// Separates an audio file into one .m4a per stem inside `folder`.
    /// Files are written under temporary names and renamed at the end, so a
    /// cancelled or failed run leaves nothing half-done.
    func separateFile(at url: URL, into folder: URL, progress: (Double) -> Void) throws {
        progress(0)
        let audio = try Self.loadStereo(url: url)
        progress(0.03)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ]
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2) else {
            throw AudioDecoder.DecodeError.unreadable
        }
        let manager = FileManager.default
        let temporary = Stem.allCases.map { folder.appending(path: "partial-" + $0.fileName) }
        defer { for file in temporary { try? manager.removeItem(at: file) } }

        do {
            var writers: [Stem: AVAudioFile] = [:]
            for (stem, file) in zip(Stem.allCases, temporary) {
                try? manager.removeItem(at: file)
                writers[stem] = try AVAudioFile(forWriting: file, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            }
            try separate(left: audio.left, right: audio.right, progress: { progress(0.03 + 0.97 * $0) }) { pieces in
                for (stem, piece) in pieces {
                    let frames = AVAudioFrameCount(piece.left.count)
                    guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                          let channels = buffer.floatChannelData else { continue }
                    buffer.frameLength = frames
                    piece.left.withUnsafeBufferPointer { channels[0].update(from: $0.baseAddress!, count: Int(frames)) }
                    piece.right.withUnsafeBufferPointer { channels[1].update(from: $0.baseAddress!, count: Int(frames)) }
                    try writers[stem]?.write(from: buffer)
                }
            }
            // Releasing the writers finishes the files.
            writers.removeAll()
        }

        for (stem, file) in zip(Stem.allCases, temporary) {
            let destination = folder.appending(path: stem.fileName)
            try? manager.removeItem(at: destination)
            try manager.moveItem(at: file, to: destination)
        }
    }

    /// Whole file as 44.1 kHz stereo (mono files are copied to both sides).
    static func loadStereo(url: URL) throws -> (left: [Float], right: [Float]) {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw AudioDecoder.DecodeError.unreadable }
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let chunk: AVAudioFrameCount = 1 << 16
        guard channels > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw AudioDecoder.DecodeError.unreadable
        }
        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(Int(file.length))
        right.reserveCapacity(Int(file.length))
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunk)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            left.append(contentsOf: UnsafeBufferPointer(start: data[0], count: frames))
            right.append(contentsOf: UnsafeBufferPointer(start: data[min(1, channels - 1)], count: frames))
        }
        guard format.sampleRate != sampleRate else { return (left, right) }
        return try resample(left: left, right: right, from: format.sampleRate)
    }

    private static func resample(left: [Float], right: [Float], from rate: Double) throws -> (left: [Float], right: [Float]) {
        guard let input = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
              let output = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let converter = AVAudioConverter(from: input, to: output) else {
            throw AudioDecoder.DecodeError.unreadable
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let chunk = 1 << 16
        let outCapacity = AVAudioFrameCount(Double(chunk) * sampleRate / rate) + 1024
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(chunk)),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: outCapacity) else {
            throw AudioDecoder.DecodeError.unreadable
        }
        var position = 0
        var newLeft: [Float] = []
        var newRight: [Float] = []
        let expected = Int(Double(left.count) * sampleRate / rate) + 1
        newLeft.reserveCapacity(expected)
        newRight.reserveCapacity(expected)

        while true {
            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in
                let frames = min(chunk, left.count - position)
                guard frames > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                let data = inBuffer.floatChannelData!
                left.withUnsafeBufferPointer { data[0].update(from: $0.baseAddress! + position, count: frames) }
                right.withUnsafeBufferPointer { data[1].update(from: $0.baseAddress! + position, count: frames) }
                inBuffer.frameLength = AVAudioFrameCount(frames)
                position += frames
                inputStatus.pointee = .haveData
                return inBuffer
            }
            if let error { throw error }
            let frames = Int(outBuffer.frameLength)
            if frames > 0, let data = outBuffer.floatChannelData {
                newLeft.append(contentsOf: UnsafeBufferPointer(start: data[0], count: frames))
                newRight.append(contentsOf: UnsafeBufferPointer(start: data[1], count: frames))
            }
            if status == .endOfStream || status == .error || (frames == 0 && position >= left.count) { break }
        }
        return (newLeft, newRight)
    }
}
