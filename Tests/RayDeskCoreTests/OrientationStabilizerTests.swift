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
