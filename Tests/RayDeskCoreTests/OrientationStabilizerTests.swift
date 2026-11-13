import Foundation
import Testing
import simd
@testable import RayDeskCore

private let degree = Double.pi / 180
private let frame = 1.0 / 120

private func yaw(_ q: simd_quatd) -> Double { q.yawPitch.yaw }

@Test func heartbeatWobbleIsDampedOnMediumLevel() {
    var stabilizer = OrientationStabilizer(level: .medium)
    var peak = 0.0
    for step in 0..<Int(10 / frame) {
        let t = Double(step) * frame
        let wobble = 0.1 * degree * sin(2 * .pi * 1.2 * t)
        let output = stabilizer.filter(yawPitchQuat(yaw: wobble, pitch: 0), dt: frame)
        if t > 5 { peak = max(peak, abs(yaw(output))) }
    }
    #expect(peak < 0.2 * 0.1 * degree)
}

@Test func fastTurnLagsLittle() {
    var stabilizer = OrientationStabilizer(level: .medium)
    var input = 0.0
    var output = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    for _ in 0..<Int(1 / frame) {
        input += 90 * degree * frame
        output = stabilizer.filter(yawPitchQuat(yaw: input, pitch: 0), dt: frame)
    }
    #expect((input - yaw(output)) / degree < 2.5)
}

@Test func smallStepSettles() {
    var stabilizer = OrientationStabilizer(level: .medium)
    _ = stabilizer.filter(yawPitchQuat(yaw: 0, pitch: 0), dt: frame)
    var output = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    for _ in 0..<Int(3 / frame) {
        output = stabilizer.filter(yawPitchQuat(yaw: 0.5 * degree, pitch: 0), dt: frame)
    }
    #expect(abs(yaw(output) / degree - 0.5) < 0.05)
}

@Test func offLevelPassesOrientationThrough() {
    var stabilizer = OrientationStabilizer(level: .off)
    let input = yawPitchQuat(yaw: 0.3, pitch: -0.2)
    _ = stabilizer.filter(yawPitchQuat(yaw: 0, pitch: 0), dt: frame)
    let output = stabilizer.filter(input, dt: frame)
    #expect(abs(simd_dot(output.vector, input.vector)) > 1 - 1e-12)
}

@Test func largeJumpIsNotSmoothed() {
    var stabilizer = OrientationStabilizer(level: .strong)
    _ = stabilizer.filter(yawPitchQuat(yaw: 0, pitch: 0), dt: frame)
    let output = stabilizer.filter(yawPitchQuat(yaw: 30 * degree, pitch: 0), dt: frame)
    #expect(abs(yaw(output) / degree - 30) < 1e-6)
}

@Test func worldLockedSmoothingReducesHighFrequencyNoiseAt60And120Hz() {
    for rate in [60.0, 120.0] {
        var stabilizer = OrientationStabilizer.worldLocked
        var peak = 0.0
        for step in 0..<240 {
            let input = (step.isMultiple(of: 2) ? 0.05 : -0.05) * degree
            let output = stabilizer.filter(yawPitchQuat(yaw: input, pitch: 0), dt: 1 / rate)
            if step > 120 { peak = max(peak, abs(output.yawPitch.yaw)) }
        }
        #expect(peak < 0.025 * degree)
    }
}

@Test func worldLockedSmoothingBoundsLagDuringTurnsAndSettlesAfterStopping() {
    for rate in [60.0, 120.0] {
        var stabilizer = OrientationStabilizer.worldLocked
        var input = yawPitchQuat(yaw: 0, pitch: 0)
        for step in 0..<240 {
            input = yawPitchQuat(yaw: Double(step) / rate * 90 * degree, pitch: Double(step) / rate * 20 * degree)
            let output = stabilizer.filter(input, dt: 1 / rate)
            let error = 2 * acos(min(1, abs(simd_dot(input.vector, output.vector))))
            #expect(error <= OrientationStabilizer.worldLockMaximumDeviation + 1e-8)
        }
        var output = input
        for _ in 0..<Int(rate / 10) { output = stabilizer.filter(input, dt: 1 / rate) }
        let residual = 2 * acos(min(1, abs(simd_dot(input.vector, output.vector))))
        #expect(residual < 0.01 * degree)
    }
}

@Test func worldLockedSmoothingDampsHeartbeatWithPrediction() {
    for rate in [60.0, 120.0] {
        for frequency in [1.0, 1.2, 2.0] {
            for axis in [SIMD3<Double>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)] {
                var stabilizer = OrientationStabilizer.worldLocked
                var peak = 0.0
                let amplitude = 0.1 * degree
                let prediction = 0.04
                for step in 0..<Int(10 * rate) {
                    let t = Double(step) / rate
                    let phase = 2 * Double.pi * frequency * t
                    let angle = amplitude * (sin(phase) + prediction * 2 * Double.pi * frequency * cos(phase))
                    let output = stabilizer.filter(simd_quatd(angle: angle, axis: axis), dt: 1 / rate)
                    if t > 5 { peak = max(peak, 2 * acos(min(1, abs(output.real)))) }
                }
                #expect(peak < 0.4 * amplitude)
            }
        }
    }
}

@Test func worldLockedSmoothingBoundsLagDuringSlowTurns() {
    for rate in [60.0, 120.0] {
        for speed in [0.5, 2.0, 10.0] {
            var stabilizer = OrientationStabilizer.worldLocked
            for step in 0..<Int(4 * rate) {
                let input = yawPitchQuat(yaw: Double(step) / rate * speed * degree, pitch: 0)
                let output = stabilizer.filter(input, dt: 1 / rate)
                let error = 2 * acos(min(1, abs(simd_dot(input.vector, output.vector))))
                #expect(error <= OrientationStabilizer.worldLockMaximumDeviation + 1e-8)
            }
        }
    }
}
