import Foundation
import Testing
import simd
@testable import RayDeskCore

private let cameraDegree = Double.pi / 180

@Test func referenceWaitsForStablePositionAndContinuousFrames() {
    var learner = CameraReferenceLearner(window: 1, maxSpread: 3 * cameraDegree, minSamples: 20, maxPositionSpread: 0.02)
    for i in 0..<90 {
        #expect(learner.add(neck: SIMD3(0, 0, Double(i) * 0.003), yaw: 0, pitch: 0, time: Double(i) / 30) == nil)
    }
    learner.reset()
    for i in 0..<20 { _ = learner.add(neck: .zero, yaw: 0, pitch: 0, time: Double(i) / 30) }
    #expect(learner.add(neck: .zero, yaw: 0, pitch: 0, time: 3) == nil)
    var reference: CameraReferenceLearner.Reference?
    for i in 1...31 { reference = learner.add(neck: .zero, yaw: 0, pitch: 0, time: 3 + Double(i) / 30) }
    #expect(reference != nil)
}

@Test func referenceRejectsInvalidPositionWithoutPoisoningNextWindow() {
    var learner = CameraReferenceLearner()
    #expect(learner.add(neck: SIMD3(.nan, 0, 0), yaw: 0, pitch: 0, time: 0) == nil)
    var found: CameraReferenceLearner.Reference?
    for i in 1...35 { found = learner.add(neck: .zero, yaw: 0, pitch: 0, time: Double(i) / 30) }
    #expect(found != nil)
}

@Test func yawScaleNeedsBothDirectionsAndRejectsGaps() {
    var scale = FaceYawScale()
    for i in 0...90 {
        let yaw = (-20 + Double(i) * 0.4) * cameraDegree
        scale.add(time: Double(i) / 30, gyroYaw: yaw, faceYaw: 1.15 * yaw)
    }
    #expect(scale.scale == 1)
    scale.interrupt()
    scale.add(time: 4, gyroYaw: 0, faceYaw: 0)
    scale.add(time: 6, gyroYaw: 20 * cameraDegree, faceYaw: 23 * cameraDegree)
    #expect(scale.count == 0)
    scale.add(time: 6.03, gyroYaw: .nan, faceYaw: 0)
    #expect(scale.scale == 1)
}

@Test func yawScaleLearnsSmoothlyAndIgnoresWorldCorrections() {
    var scale = FaceYawScale()
    var world = 0.0
    var previous = scale.scale
    for i in 0..<3600 {
        let time = Double(i) / 30
        let yaw = 20 * cameraDegree * sin(time * 1.2)
        scale.add(time: time, gyroYaw: yaw + world, faceYaw: yaw * 1.15)
        #expect(abs(scale.scale - previous) <= 0.01 / 30 + 1e-10)
        previous = scale.scale
        let delta = 0.5 * cameraDegree / 30
        scale.worldYawChanged(by: delta)
        world += delta
    }
    #expect(abs(scale.scale - 1.15) < 0.01)
    let learned = scale.scale
    scale.interrupt()
    #expect(scale.scale == learned)
    #expect(scale.count == 0)
}

@Test func yawCorrectionsKeepCameraHistoryInTheCurrentWorld() {
    let filter = OrientationFilter()
    for _ in 0..<50 { filter.update(gyro: .zero, accel: SIMD3(0, 1, 0), dt: 0.01) }
    filter.rotateWorldYaw(by: 0.1)
    #expect(abs(filter.orientation(atUptime: 0).yawPitch.yaw - 0.1) < 1e-9)
    filter.alignYaw(to: -0.2)
    #expect(abs(filter.orientation(atUptime: 0).yawPitch.yaw + 0.2) < 1e-9)
}
