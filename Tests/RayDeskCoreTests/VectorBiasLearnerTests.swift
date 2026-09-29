import Foundation
import Testing
import simd
@testable import RayDeskCore

private let degree = Double.pi / 180
private let earthField = simd_normalize(SIMD3(0.3, -0.64, -0.77)) * 34
private let hardIron = SIMD3(19.7, 77.3, -28.9)

private func feed(_ learner: inout VectorBiasLearner, seconds: Double, bias: SIMD3<Double>, start: simd_quatd = simd_quatd(angle: 0, axis: SIMD3(0, 1, 0)),
                  yawRate: Double = 0, field: (Double) -> SIMD3<Double> = { _ in earthField }) -> simd_quatd {
    let dt = 0.002
    var head = start
    for step in 0..<Int(seconds / dt) {
        let turn = simd_quatd(angle: yawRate * dt, axis: SIMD3(0, 1, 0))
        head = simd_normalize(turn * head)
        let bodyRate = head.inverse.act(SIMD3(0, yawRate, 0))
        learner.add(gyro: bodyRate + bias, accel: head.inverse.act(SIMD3(0, 1, 0)),
                    field: head.inverse.act(field(Double(step) * dt)), dt: dt)
    }
    return head
}

@Test func offsetStepOnEveryAxisIsLearnedAtRestInDistortedField() {
    var learner = VectorBiasLearner()
    let tilted = simd_quatd(angle: 20 * degree, axis: simd_normalize(SIMD3(1, 0.3, 0.2)))
    let distorted = simd_quatd(angle: 40 * degree, axis: SIMD3(0, 1, 0)).act(earthField) * 1.15
    let offset = SIMD3(2.6, -0.5, 0.4) * degree
    _ = feed(&learner, seconds: 25, bias: offset, start: tilted, field: { _ in distorted })
    #expect(abs(learner.bias - offset).max() / degree < 0.05)
}

@Test func slowHeadTurnIsNotTakenForOffset() {
    var learner = VectorBiasLearner()
    _ = feed(&learner, seconds: 60, bias: .zero, yawRate: 0.3 * degree)
    #expect(abs(learner.bias).max() / degree < 0.02)
}

@Test func fieldChangingByItselfDoesNotTeachOffset() {
    var learner = VectorBiasLearner()
    let magnet: (Double) -> SIMD3<Double> = { time in
        let share = min(1, max(0, (time - 10) / 3))
        return simd_quatd(angle: 4 * share * degree, axis: SIMD3(0, 1, 0)).act(earthField) * (1 + 0.2 * share)
    }
    _ = feed(&learner, seconds: 30, bias: .zero, field: magnet)
    #expect(abs(learner.bias).max() / degree < 0.02)
}

@Test func gyroOffsetStepDoesNotTiltOrTurnTheWorldWithCompass() {
    let filter = OrientationFilter()
    filter.magnetometerCalibration = MagnetometerCalibration(center: hardIron, radius: 34,
                                                             dip: acos(simd_dot(simd_normalize(earthField), SIMD3(0, 1, 0))))
    let head = simd_quatd(angle: -15 * degree, axis: SIMD3(1, 0, 0))
    let dt = 0.002
    for step in 0..<Int(120 / dt) {
        let offset = step < Int(30 / dt) ? SIMD3<Double>.zero : SIMD3(2.6, -0.5, 0.4) * degree
        filter.update(gyro: offset, accel: head.inverse.act(SIMD3(0, 1, 0)),
                      magnetometer: head.inverse.act(earthField) + hardIron, dt: dt)
    }
    let estimated = filter.orientation(predictAhead: 0).yawPitch
    #expect(abs(estimated.pitch / degree + 15) < 0.3)
    #expect(abs(estimated.yaw) / degree < 1.5)
}
