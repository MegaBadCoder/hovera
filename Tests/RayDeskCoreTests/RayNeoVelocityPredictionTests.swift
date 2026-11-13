import Foundation
import MetalKit
import Testing
import simd
@testable import RayDeskCore
@testable import RayDesk

private final class VelocityPredictionClock: @unchecked Sendable {
    var now = 1.0
}

@Test @MainActor func rayNeoWorldLockCompensatesSmallRealRotationWithoutPoseDamping() throws {
    let view = MTKView(frame: CGRect(x: 0, y: 0, width: 16, height: 16))
    let filter = OrientationFilter()
    let screen = ScreenPose(yaw: 0, pitch: 0, distance: 2, width: 1, aspect: 1)
    let renderer = try Renderer(view: view, scene: SpatialScene(screens: [screen]), filter: filter)
    renderer.headPipeline.predictionSeconds = 0
    renderer.headPipeline.maxPrediction = 0
    renderer.draw(in: view, targetTime: CACurrentMediaTime())
    let angle = 0.05 * Double.pi / 180
    filter.alignYaw(to: angle)
    renderer.draw(in: view, targetTime: CACurrentMediaTime())
    #expect(abs(renderer.currentHead.yawPitch.yaw - angle) < 1e-8)
}

@Test func worldLockPredictionSmoothsVelocityInsteadOfCurrentPose() {
    var predictor = WorldLockPrediction()
    _ = predictor.predict(yawPitchQuat(yaw: 0, pitch: 0), at: 1, horizon: 0.02)
    let first = predictor.predict(yawPitchQuat(yaw: 0.01, pitch: 0), at: 1.01, horizon: 0.02)
    let second = predictor.predict(yawPitchQuat(yaw: 0.02, pitch: 0), at: 1.02, horizon: 0.02)
    #expect(abs(first.yawPitch.yaw - 0.018) < 1e-10)
    #expect(abs(second.yawPitch.yaw - 0.0328) < 1e-10)
}

@Test(arguments: [1.2, 8.0, 12.0])
func worldLockPredictionDoesNotDampRealHeartbeatRotation(frequency: Double) {
    var predictor = WorldLockPrediction()
    let scene = yawPitchQuat(yaw: 0.2, pitch: -0.1)
    for step in 0..<360 {
        let time = 1 + Double(step) / 60
        let angle = 0.1 * Double.pi / 180 * sin(2 * .pi * frequency * time)
        let actualHead = yawPitchQuat(yaw: angle, pitch: angle * 0.4)
        let displayHead = predictor.predict(actualHead, at: time, horizon: 0)
        let expected = RotationalReprojection(scene: scene, display: actualHead, verticalFOV: 0.5,
                                             aspect: 16.0 / 9, overscan: SIMD2(1.25, 1.25))
        let actual = RotationalReprojection(scene: scene, display: displayHead, verticalFOV: 0.5,
                                           aspect: 16.0 / 9, overscan: SIMD2(1.25, 1.25))
        let center = SIMD2<Float>(0.5, 0.5)
        #expect(actual.textureCoordinate(at: center) == expected.textureCoordinate(at: center))
    }
}

@Test func worldLockPredictionTracksFastTurnsInTheCalibratedWorldFrame() {
    var predictor = WorldLockPrediction()
    let mount = ViewCalibration(yaw: 0.4, pitch: 0.1, roll: -0.05)
    let axis = normalize(SIMD3<Double>(0.2, 1, -0.3))
    let rate = 2.0
    let horizon = 0.025
    for step in 0..<150 {
        let time = Double(step) / 120
        let head = mount.apply(to: simd_quatd(angle: rate * time, axis: axis))
        let predicted = predictor.predict(head, at: time, horizon: horizon)
        if step > 35 {
            let expected = mount.apply(to: simd_quatd(angle: rate * (time + horizon), axis: axis))
            let error = 2 * acos(min(1, abs(simd_dot(predicted.vector, expected.vector))))
            #expect(error < 1e-6)
        }
    }
}

@Test func worldLockPredictionResetsVelocityAfterAFrameGap() {
    var predictor = WorldLockPrediction()
    _ = predictor.predict(yawPitchQuat(yaw: 0, pitch: 0), at: 1, horizon: 0.02)
    _ = predictor.predict(yawPitchQuat(yaw: 0.02, pitch: 0), at: 1.01, horizon: 0.02)
    let head = yawPitchQuat(yaw: 0.1, pitch: 0.03)
    let resumed = predictor.predict(head, at: 1.3, horizon: 0.045)
    #expect(resumed.vector == head.vector)
    let still = predictor.predict(head, at: 1.31, horizon: 0.045)
    #expect(still.vector == head.vector)
}

@Test func worldLockPredictionTreatsOppositeQuaternionSignsAsTheSamePose() {
    var predictor = WorldLockPrediction()
    let head = yawPitchQuat(yaw: .pi - 0.01, pitch: 0.1)
    _ = predictor.predict(head, at: 1, horizon: 0.02)
    let same = simd_quatd(vector: -head.vector)
    let predicted = predictor.predict(same, at: 1.01, horizon: 0.02)
    #expect(predicted.vector == same.vector)
}

@Test func worldLockPredictionCanDisableOnlyVelocitySmoothing() {
    var predictor = WorldLockPrediction()
    _ = predictor.predict(yawPitchQuat(yaw: 0, pitch: 0), at: 1, horizon: 0.02)
    let predicted = predictor.predict(yawPitchQuat(yaw: 0.01, pitch: 0), at: 1.01,
                                      horizon: 0.02, smoothing: false)
    #expect(abs(predicted.yawPitch.yaw - 0.03) < 1e-10)
}

@Test func rayNeoReprojectionCarriesCurrentPoseWithoutRawGyroExtrapolation() throws {
    let filter = OrientationFilter()
    let clock = VelocityPredictionClock()
    filter.clock = { clock.now }
    filter.kp = 0
    filter.restoresFirmwareZero = false
    filter.update(gyro: .zero, accel: SIMD3(0, 1, 0), dt: 0.002)
    for _ in 0..<40 {
        clock.now += 0.002
        filter.update(gyro: SIMD3(0, 1, 0), accel: SIMD3(0, 1, 0), dt: 0.002)
    }
    let current = filter.orientation(predictAhead: 0)
    let source = ReprojectionPoseSource.rayNeo(filter, bias: 0, limit: 0.045, fallback: 0.018)
    let sample = try #require(source.sample(clock.now + 0.02))
    let error = 2 * acos(min(1, abs(simd_dot(current.vector, sample.orientation.vector))))
    #expect(error < 1e-8)
    #expect(abs(sample.horizon - 0.02) < 1e-10)
}
