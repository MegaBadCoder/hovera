import Foundation
import Testing
@testable import RayDeskCore

private let sampleRate = 48_000.0

private func render(_ synth: inout AmbientSynth, seconds: Double) -> (left: [Float], right: [Float]) {
    let frames = Int(seconds * sampleRate)
    var left = [Float](repeating: 0, count: frames)
    var right = [Float](repeating: 0, count: frames)
    let block = 512
    var offset = 0
    while offset < frames {
        let count = min(block, frames - offset)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                synth.render(left: l.baseAddress! + offset, right: r.baseAddress! + offset, frames: count)
            }
        }
        offset += count
    }
    return (left, right)
}

private func rms(_ samples: ArraySlice<Float>) -> Double {
    sqrt(samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(samples.count, 1)))
}

private func pulsation(atHz frequency: Double, in samples: [Float]) -> Double {
    let window = Int(sampleRate / 120)
    let envelope = stride(from: 0, to: samples.count - window, by: window).map { rms(samples[$0..<($0 + window)]) }
    let mean = envelope.reduce(0, +) / Double(envelope.count)
    var re = 0.0
    var im = 0.0
    for (k, value) in envelope.enumerated() {
        let t = Double(k * window) / sampleRate
        re += (value - mean) * cos(2 * .pi * frequency * t)
        im -= (value - mean) * sin(2 * .pi * frequency * t)
    }
    return 2 * sqrt(re * re + im * im) / Double(envelope.count) / mean
}

@Test func silentUntilVolumeIsRaised() {
    var synth = AmbientSynth(sampleRate: sampleRate, seed: 1)
    let out = render(&synth, seconds: 1)
    #expect(out.left.allSatisfy { $0 == 0 } && out.right.allSatisfy { $0 == 0 })
}

@Test func neverLouderThanMinusOneDecibel() {
    var synth = AmbientSynth(sampleRate: sampleRate, seed: 7)
    synth.targetVolume = 1
    synth.neuralEffect = .high
    let out = render(&synth, seconds: 40)
    let peak = (out.left + out.right).map { abs($0) }.max() ?? 0
    #expect(peak <= AmbientSynth.peakLimit)
    #expect(peak > 0.05)
}

@Test func fadesInSmoothlyWithoutAClick() {
    var synth = AmbientSynth(sampleRate: sampleRate, seed: 3)
    synth.targetVolume = 1
    let out = render(&synth, seconds: 4.5)
    let start = rms(out.left[0..<Int(0.25 * sampleRate)])
    let settled = rms(out.left[Int(4 * sampleRate)..<Int(4.5 * sampleRate)])
    #expect(start < 0.02 * settled)
    let firstTenth = out.left[0..<Int(0.1 * sampleRate)]
    let jumps = zip(firstTenth.dropFirst(), firstTenth).map { abs($0 - $1) }
    #expect((jumps.max() ?? 0) < 0.001)
}

@Test func fadesOutToSilence() {
    var synth = AmbientSynth(sampleRate: sampleRate, seed: 3)
    synth.targetVolume = 1
    _ = render(&synth, seconds: 5)
    synth.targetVolume = 0
    let out = render(&synth, seconds: 4.5)
    #expect(rms(out.left[Int(4.1 * sampleRate)...]) == 0)
    let halfway = rms(out.left[Int(1.9 * sampleRate)..<Int(2.1 * sampleRate)])
    #expect(halfway > 0)
}

@Test func sameSeedSameSound() {
    var a = AmbientSynth(sampleRate: sampleRate, seed: 42)
    var b = AmbientSynth(sampleRate: sampleRate, seed: 42)
    var c = AmbientSynth(sampleRate: sampleRate, seed: 43)
    a.targetVolume = 1
    b.targetVolume = 1
    c.targetVolume = 1
    let first = render(&a, seconds: 2)
    let second = render(&b, seconds: 2)
    let other = render(&c, seconds: 2)
    #expect(first.left == second.left && first.right == second.right)
    #expect(first.left != other.left)
}

@Test func neuralGainDipsSixTimesASecondByTheChosenDepth() {
    #expect(AmbientSynth.neuralGain(time: 0, depth: 0.3) == 1)
    #expect(abs(AmbientSynth.neuralGain(time: 1.0 / 12, depth: 0.3) - 0.7) < 1e-9)
    #expect(abs(AmbientSynth.neuralGain(time: 1.0 / 6, depth: 0.3) - 1) < 1e-9)
    #expect(AmbientSynth.neuralGain(time: 0.37, depth: 0) == 1)
}

@Test func strongerNeuralEffectPulsesMusicHarder() {
    func measured(_ effect: NeuralEffect) -> Double {
        var synth = AmbientSynth(sampleRate: sampleRate, seed: 5)
        synth.waveLevel = 0
        synth.targetVolume = 1
        synth.neuralEffect = effect
        _ = render(&synth, seconds: 4.5)
        return pulsation(atHz: AmbientSynth.modulationHz, in: render(&synth, seconds: 3).left)
    }
    let off = measured(.off)
    let low = measured(.low)
    let high = measured(.high)
    #expect(off < 0.03)
    #expect(low > 0.08)
    #expect(high > 2 * low)
}
