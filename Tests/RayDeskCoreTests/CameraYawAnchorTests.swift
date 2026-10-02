import Foundation
import Testing
import simd
@testable import RayDeskCore

private let deg = Double.pi / 180
private let frontal = CameraYawAnchor.Pose(yaw: 0, pitch: 0, roll: 0, nose: 0)

private func anchored() -> CameraYawAnchor {
    var anchor = CameraYawAnchor()
    for i in 0..<90 {
        _ = anchor.update(pose: frontal, headYaw: 0, speed: 0, time: Double(i) / 30, latency: 0.06)
    }
    return anchor
}

@Test func cameraAnchorCorrectsBothDirectionsWithoutJump() {
    for sign in [-1.0, 1.0] {
        var anchor = anchored()
        var yaw = sign * 3 * deg
        for i in 90..<990 {
            let delta = anchor.update(pose: frontal, headYaw: yaw, speed: 0,
                                      time: Double(i) / 30, latency: 0.06)
            #expect(abs(delta) <= 0.25 * deg / 30 + 1e-12)
            #expect(delta * sign <= 0)
            yaw += delta
        }
        #expect(abs(yaw) < 0.4 * deg)
    }
}

@Test func cameraAnchorDoesNotFlattenRealTurnsOrUseBadFrames() {
    let cases: [(CameraYawAnchor.Pose?, Double, Double)] = [
        (nil, 0, 0.06), (frontal, 0, 0.4), (frontal, 10 * deg, 0.06),
        (.init(yaw: 8 * deg, pitch: 0, roll: 0, nose: 0), 0, 0.06),
        (.init(yaw: 0, pitch: 0, roll: 0, nose: 0.06), 0, 0.06),
        (.init(yaw: .nan, pitch: 0, roll: 0, nose: 0), 0, 0.06)
    ]
    for (pose, speed, latency) in cases {
        var anchor = anchored()
        for i in 90..<180 {
            #expect(anchor.update(pose: pose, headYaw: 3 * deg, speed: speed,
                                  time: Double(i) / 30, latency: latency) == 0)
        }
    }
}

@Test func cameraAnchorWaitsAfterLossAndPreservesRecenter() {
    var anchor = anchored()
    _ = anchor.update(pose: nil, headYaw: 0, speed: 0, time: 3, latency: 0.06)
    #expect(anchor.update(pose: frontal, headYaw: 3 * deg, speed: 0, time: 3.03, latency: 0.06) == 0)
    anchor.worldYawChanged(by: 40 * deg)
    for i in 100..<180 {
        #expect(anchor.update(pose: frontal, headYaw: 40 * deg, speed: 0,
                              time: Double(i) / 30, latency: 0.06) == 0)
    }
    anchor.reset()
    for i in 180..<270 {
        #expect(anchor.update(pose: frontal, headYaw: 45 * deg, speed: 0,
                              time: Double(i) / 30, latency: 0.06) == 0)
    }
}

@Test func externalYawCorrectionPreservesTiltHistoryAndMagneticAnchor() {
    let filter = OrientationFilter()
    filter.magnetometerCalibration = MagnetometerCalibration(center: .zero, radius: sqrt(22 * 22 + 26 * 26), dip: acos(-22 / sqrt(22 * 22 + 26 * 26)))
    let field = SIMD3<Double>(0, -22, -26)
    for _ in 0..<50 {
        filter.update(gyro: .zero, accel: SIMD3(0, 1, 0), magnetometer: field, dt: 0.01)
    }
    let before = filter.orientation(predictAhead: 0).yawPitch
    filter.correctYaw(by: 0.5 * deg)
    let after = filter.orientation(predictAhead: 0).yawPitch
    #expect(abs(after.yaw - before.yaw - 0.5 * deg) < 1e-9)
    #expect(abs(after.pitch - before.pitch) < 1e-9)
    #expect(abs(filter.orientation(atUptime: 0).yawPitch.yaw - after.yaw) < 1e-9)
    for _ in 0..<1000 {
        filter.update(gyro: .zero, accel: SIMD3(0, 1, 0), magnetometer: field, dt: 0.01)
    }
    #expect(abs(filter.orientation(predictAhead: 0).yawPitch.yaw - after.yaw) < 1e-9)
    filter.correctYaw(by: .nan)
    filter.correctYaw(by: 20 * deg)
    #expect(abs(filter.orientation(predictAhead: 0).yawPitch.yaw - after.yaw) < 1e-9)
}

@Test func worldYawTurnRotatesHistoryWhateverTheCaller() {
    let filter = OrientationFilter()
    for _ in 0..<300 {
        filter.update(gyro: .zero, accel: SIMD3(0, 1, 0), dt: 0.01)
    }
    let past = filter.orientation(atUptime: 0).yawPitch
    let now = filter.orientation(predictAhead: 0).yawPitch
    filter.rotateWorldYaw(by: 2 * deg)
    let turnedPast = filter.orientation(atUptime: 0).yawPitch
    let turnedNow = filter.orientation(predictAhead: 0).yawPitch
    #expect(abs(turnedPast.yaw - past.yaw - 2 * deg) < 1e-9)
    #expect(abs(turnedNow.yaw - now.yaw - 2 * deg) < 1e-9)
    #expect(abs(turnedPast.pitch - past.pitch) < 1e-9)
}
