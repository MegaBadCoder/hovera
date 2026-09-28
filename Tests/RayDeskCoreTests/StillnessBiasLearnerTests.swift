import Foundation
import Testing
import simd
@testable import RayDeskCore

private let degree = Double.pi / 180
private let dt = 0.002
private let earthField = SIMD3(0.0, -22.0, -26.0)
private let hardIron = SIMD3(21.0, 79.0, -28.0)

struct SeededNoise {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return Double(z ^ (z >> 31)) / Double(UInt64.max)
    }
    mutating func gaussian() -> Double {
        (-2 * log(max(next(), 1e-12))).squareRoot() * cos(2 * .pi * next())
    }
    mutating func vector(_ sigma: Double) -> SIMD3<Double> { SIMD3(gaussian(), gaussian(), gaussian()) * sigma }
}

private func feed(_ learner: inout StillnessBiasLearner, seconds: Double, offset: SIMD3<Double>, yawRate: Double = 0,
                  yaw: inout Double, noise: inout SeededNoise, magnetometer: Bool) {
    for _ in 0..<Int(seconds / dt) {
        yaw += yawRate * dt
        let head = simd_quatd(angle: yaw, axis: SIMD3(0, 1, 0))
        let gyro = SIMD3(0, yawRate, 0) + offset + noise.vector(0.8 * degree)
        let accel = 1 + noise.gaussian() * 0.003
        let field = magnetometer ? head.inverse.act(earthField) + hardIron + noise.vector(0.1) : nil
        learner.add(gyro: gyro, accelNorm: accel, magnetometer: field, dt: dt)
    }
}

@Test func offsetIsLearnedWhenHeadIsStill() {
    var learner = StillnessBiasLearner()
    var noise = SeededNoise(seed: 1)
    var yaw = 0.0
    let offset = SIMD3(0.2, 0.3, -0.1) * degree
    feed(&learner, seconds: 12, offset: offset, yaw: &yaw, noise: &noise, magnetometer: false)
    #expect(length(learner.bias - offset) / degree < 0.05)
}

@Test func jumpAfterAdjustingGlassesIsCaughtWithinSeconds() {
    var learner = StillnessBiasLearner()
    var noise = SeededNoise(seed: 2)
    var yaw = 0.0
    feed(&learner, seconds: 12, offset: SIMD3(0, 0.2, 0) * degree, yaw: &yaw, noise: &noise, magnetometer: true)
    feed(&learner, seconds: 12, offset: SIMD3(0, -0.4, 0) * degree, yaw: &yaw, noise: &noise, magnetometer: true)
    #expect(abs(learner.bias.y / degree - -0.4) < 0.05)
}

@Test func largerJumpIsCaughtWhenCompassConfirmsStillness() {
    var learner = StillnessBiasLearner()
    var noise = SeededNoise(seed: 3)
    var yaw = 0.0
    feed(&learner, seconds: 12, offset: .zero, yaw: &yaw, noise: &noise, magnetometer: true)
    feed(&learner, seconds: 15, offset: SIMD3(0, 1.5, 0) * degree, yaw: &yaw, noise: &noise, magnetometer: true)
    #expect(abs(learner.bias.y / degree - 1.5) < 0.1)
}

@Test func slowPanIsNotLearnedWhenMagnetometerSeesTheTurn() {
    var learner = StillnessBiasLearner()
    var noise = SeededNoise(seed: 4)
    var yaw = 0.0
    feed(&learner, seconds: 12, offset: .zero, yaw: &yaw, noise: &noise, magnetometer: true)
    for rate in [0.5, 1.0, 1.5] {
        feed(&learner, seconds: 10, offset: .zero, yawRate: rate * degree, yaw: &yaw, noise: &noise, magnetometer: true)
        #expect(abs(learner.bias.y) / degree < 0.05)
    }
}

@Test func fastMotionIsNeverLearned() {
    var learner = StillnessBiasLearner()
    var noise = SeededNoise(seed: 5)
    var yaw = 0.0
    feed(&learner, seconds: 12, offset: .zero, yaw: &yaw, noise: &noise, magnetometer: false)
    feed(&learner, seconds: 10, offset: .zero, yawRate: 20 * degree, yaw: &yaw, noise: &noise, magnetometer: false)
    #expect(length(learner.bias) / degree < 0.05)
}

@Test func seededBiasIsKeptUntilStillnessSaysOtherwise() {
    var learner = StillnessBiasLearner(bias: SIMD3(0, 0.3, 0) * degree)
    #expect(abs(learner.bias.y / degree - 0.3) < 1e-9)
    var noise = SeededNoise(seed: 6)
    var yaw = 0.0
    feed(&learner, seconds: 10, offset: .zero, yawRate: 30 * degree, yaw: &yaw, noise: &noise, magnetometer: true)
    #expect(abs(learner.bias.y / degree - 0.3) < 1e-9)
}

@Test func afterRecenterAnyQuietMomentTeachesTheNewZero() {
    var learner = StillnessBiasLearner()
    var noise = SeededNoise(seed: 7)
    var yaw = 0.0
    feed(&learner, seconds: 12, offset: SIMD3(0, -0.25, 0) * degree, yaw: &yaw, noise: &noise, magnetometer: true)
    learner.trustNextStillness()
    for _ in 0..<10 {
        feed(&learner, seconds: 1, offset: SIMD3(0, 0.35, 0) * degree, yaw: &yaw, noise: &noise, magnetometer: true)
        feed(&learner, seconds: 0.5, offset: SIMD3(0, 0.35, 0) * degree, yawRate: 20 * degree, yaw: &yaw, noise: &noise, magnetometer: true)
    }
    #expect(abs(learner.bias.y / degree - 0.35) < 0.05)
}
