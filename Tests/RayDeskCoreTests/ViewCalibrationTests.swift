import Foundation
import Testing
import simd
@testable import RayDeskCore

private let degree = Double.pi / 180
private let identity = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)

@Test func zeroCalibrationLeavesHeadUnchanged() {
    let head = yawPitchQuat(yaw: 20 * degree, pitch: -10 * degree)
    let corrected = ViewCalibration().apply(to: head)
    #expect(abs(corrected.yawPitch.yaw - head.yawPitch.yaw) < 1e-12)
    #expect(abs(corrected.yawPitch.pitch - head.yawPitch.pitch) < 1e-12)
}

@Test func yawOffsetTurnsWorldAroundVertical() {
    let calibration = ViewCalibration(yaw: 10 * degree, pitch: 0, roll: 0)
    let gaze = calibration.apply(to: identity).yawPitch
    #expect(abs(gaze.yaw - 10 * degree) < 1e-12)
    #expect(abs(gaze.pitch) < 1e-12)
}

@Test func pitchOffsetIsAppliedInHeadFrame() {
    let calibration = ViewCalibration(yaw: 0, pitch: 5 * degree, roll: 0)
    let head = yawPitchQuat(yaw: 90 * degree, pitch: 0)
    let gaze = calibration.apply(to: head).yawPitch
    #expect(abs(gaze.pitch - 5 * degree) < 1e-9)
    #expect(abs(gaze.yaw - 90 * degree) < 1e-9)
}

@Test func rollOffsetKeepsGazeDirectionAndTiltsUp() {
    let calibration = ViewCalibration(yaw: 0, pitch: 0, roll: 3 * degree)
    let corrected = calibration.apply(to: identity)
    #expect(abs(corrected.yawPitch.yaw) < 1e-12)
    #expect(abs(corrected.yawPitch.pitch) < 1e-12)
    let up = corrected.act(SIMD3(0, 1, 0))
    #expect(abs(atan2(-up.x, up.y) - 3 * degree) < 1e-9)
}

@Test func calibrationRoundTripsThroughCodable() throws {
    let calibration = ViewCalibration(yaw: 0.1, pitch: -0.05, roll: 0.02)
    let decoded = try JSONDecoder().decode(ViewCalibration.self, from: JSONEncoder().encode(calibration))
    #expect(decoded == calibration)
}
