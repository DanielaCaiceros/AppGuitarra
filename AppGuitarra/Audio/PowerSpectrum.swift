//
//  PowerSpectrum.swift
//  AppGuitarra
//
//  Power spectrum of a block of audio (Hann window + real FFT with vDSP).
//  Shared by live chord detection (microphone) and song analysis (files).
//

import Accelerate
import Foundation

nonisolated final class PowerSpectrum: @unchecked Sendable {
    /// FFT length (a power of two).
    let size: Int
    let sampleRate: Double

    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]

    /// Width of one frequency bin in Hz.
    var binHz: Double { sampleRate / Double(size) }

    init(size: Int, sampleRate: Double) {
        precondition(size >= 64 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size
        self.sampleRate = sampleRate
        log2n = vDSP_Length(log2(Double(size)).rounded())
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        windowed = [Float](repeating: 0, count: size)
        real = [Float](repeating: 0, count: size / 2)
        imag = [Float](repeating: 0, count: size / 2)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// Smallest power of two whose duration is at least `seconds`.
    static func size(forSeconds seconds: Double, sampleRate: Double) -> Int {
        var size = 64
        while Double(size) < seconds * sampleRate { size *= 2 }
        return size
    }

    /// |X[k]|² for k = 0 ..< size/2, from the first `size` samples (zero-padded if shorter).
    func compute(_ samples: UnsafeBufferPointer<Float>) -> [Float] {
        let count = min(samples.count, size)
        windowed.withUnsafeMutableBufferPointer { out in
            for i in 0..<count { out[i] = samples[i] * window[i] }
            for i in count..<size { out[i] = 0 }
        }

        let half = size / 2
        var power = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
                // imagp[0] holds the Nyquist value, not part of the DC bin.
                power[0] = realPtr[0] * realPtr[0]
            }
        }
        // vDSP's real FFT is scaled by 2, so the power is scaled by 4.
        return vDSP.multiply(0.25, power)
    }

    func compute(_ samples: [Float]) -> [Float] {
        samples.withUnsafeBufferPointer { compute($0) }
    }
}
