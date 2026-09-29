import Foundation
import Testing
import simd
@testable import RayDeskCore

private let dt = 0.002
private let degree = Double.pi / 180
private let bias = SIMD3(0.3, -0.2, 0.25) * degree

private func turnGlasses(_ calibration: inout GyroScaleCalibration, trueDegrees: Double, gyroScale: Double, up: SIMD3<Double> = SIMD3(0, 1, 0)) {
    let accel = normalize(up)
    for _ in 0..<Int(3.5 / dt) { calibration.add(gyro: bias, accel: accel, dt: dt) }
    let seconds = 8.0
    let rate = trueDegrees * degree / seconds
    for _ in 0..<Int(seconds / dt) { calibration.add(gyro: bias + normalize(up) * rate * gyroScale, accel: accel, dt: dt) }
    for _ in 0..<Int(2.5 / dt) { calibration.add(gyro: bias, accel: accel, dt: dt) }
}

@Test func twoFullTurnsRevealTheGyroScale() {
    var calibration = GyroScaleCalibration(turns: 2)
    turnGlasses(&calibration, trueDegrees: 720, gyroScale: 1.042)
    guard case .finished(let scale, let measured) = calibration.stage else {
        Issue.record("calibration did not finish: \(calibration.stage)")
        return
    }
    #expect(abs(scale - 1 / 1.042) < 0.002)
    #expect(abs(measured - 720 * 1.042) < 1.5)
}

@Test func waitsForTheGlassesToLieStill() {
    var calibration = GyroScaleCalibration()
    for _ in 0..<Int(5 / dt) { calibration.add(gyro: SIMD3(0, 0.5, 0), accel: SIMD3(0, 1, 0), dt: dt) }
    #expect(calibration.stage == .waitingForRest)
    for _ in 0..<Int(3.2 / dt) { calibration.add(gyro: bias, accel: SIMD3(0, 1, 0), dt: dt) }
    #expect(calibration.stage == .readyToTurn)
}

@Test func glassesLyingOnTheirSideAreRejected() {
    var calibration = GyroScaleCalibration()
    for _ in 0..<Int(3.5 / dt) { calibration.add(gyro: bias, accel: SIMD3(1, 0, 0), dt: dt) }
    #expect(calibration.stage == .failed(.notUpright))
}

@Test func oneTurnInsteadOfTwoIsRejected() {
    var calibration = GyroScaleCalibration(turns: 2)
    turnGlasses(&calibration, trueDegrees: 360, gyroScale: 1)
    guard case .failed(.wrongTurnCount) = calibration.stage else {
        Issue.record("expected wrong turn count, got \(calibration.stage)")
        return
    }
}
