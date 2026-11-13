import Foundation
import Testing
import simd
@testable import VitureSDK

private let yawAxis = SIMD3<Double>(0, 1, 0)

@Test func stablePoseDefinesTheOrientation() {
    var fusion = VitureOrientationFusion()
    let pose = simd_quatd(angle: 0.4, axis: yawAxis)
    var output: simd_quatd?
    for step in 0..<240 {
        output = fusion.update(pose: pose, stable: true, gyro: .zero, time: Double(step) / 120)
    }
    let angle = 2 * acos(min(1, abs((output ?? simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)).vector.z)))
    #expect(angle >= 0)
    let difference = (output ?? simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)) * pose.inverse
    #expect(abs(2 * acos(min(1, abs(difference.real)))) < 0.01)
}

@Test func unstablePoseDoesNotDragTheWorld() {
    var fusion = VitureOrientationFusion()
    _ = fusion.update(pose: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), stable: true, gyro: .zero, time: 0)
    let drifted = simd_quatd(angle: 0.8, axis: yawAxis)
    var output = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    for step in 1...120 {
        output = fusion.update(pose: drifted, stable: false, gyro: .zero, time: Double(step) / 120) ?? output
    }
    #expect(abs(2 * acos(min(1, abs(output.real)))) < 0.01)
}

@Test func gyroCarriesTheOrientationWhenPoseIsUnstable() {
    var fusion = VitureOrientationFusion()
    _ = fusion.update(pose: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), stable: true, gyro: .zero, time: 0)
    let rate = SIMD3<Double>(0, 1, 0)
    var output = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    for step in 1...12 {
        output = fusion.update(pose: nil, stable: false, gyro: rate, time: Double(step) / 120) ?? output
    }
    let yaw = output.yawPitch.yaw
    #expect(abs(yaw - 0.1) < 1e-6)
}

@Test func gyroBiasIsLearnedAtRest() {
    var fusion = VitureOrientationFusion()
    let bias: SIMD3<Double> = [0.01, 0, 0]
    for step in 0...2000 {
        _ = fusion.update(pose: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), stable: true, gyro: bias, time: Double(step) / 120)
    }
    #expect(abs(fusion.gyroBias.x - 0.01) < 0.002)
}


@Test func gyroBiasIsLearnedFromStillnessWithoutStableVIO() {
    var fusion = VitureOrientationFusion()
    let bias = SIMD3<Double>(0, 0.02, 0)
    for step in 0...3000 {
        _ = fusion.update(pose: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), stable: false, gyro: bias,
                          time: Double(step) / 200, still: true)
    }
    #expect(abs(fusion.gyroBias.y - 0.02) < 0.004)
}

@Test func stablePoseRemainsAuthoritativeWhileTheHeadIsMovingFast() {
    var fusion = VitureOrientationFusion()
    let start = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    _ = fusion.update(pose: start, stable: true, gyro: .zero, time: 0)
    let drifted = simd_quatd(angle: 0.3, axis: yawAxis)
    let rate = SIMD3<Double>(0, 2.0, 0)
    var output = start
    for step in 1...60 {
        output = fusion.update(pose: drifted, stable: true, gyro: rate, time: Double(step) / 120) ?? output
    }
    let yaw = output.yawPitch.yaw
    #expect(abs(yaw - 0.3) < 1e-6)
}

@Test func biasLearningDoesNotRequireAnOrientation() {
    var fusion = VitureOrientationFusion()
    for step in 0...2400 {
        _ = fusion.update(pose: nil, stable: false, gyro: SIMD3(0, 0.02, 0), time: Double(step) / 120, still: true)
    }
    #expect(abs(fusion.gyroBias.y - 0.02) < 0.001)
}

@Test func stationaryStablePoseDoesNotAccumulateGyroTilt() throws {
    var fusion = VitureOrientationFusion()
    let pose = simd_quatd(angle: 0.2, axis: yawAxis)
    var maximumError = 0.0
    for step in 0...600 {
        let result = fusion.update(pose: pose, stable: true, gyro: SIMD3(0.02, 0, 0.01),
                                   time: Double(step) / 120)
        let output = try #require(result)
        let difference = output * pose.inverse
        maximumError = max(maximumError, abs(2 * acos(min(1, abs(difference.real)))))
    }
    #expect(maximumError < 1e-6)
}

@Test func stablePoseImmediatelyCorrectsGyroAfterTrackingReturns() throws {
    var fusion = VitureOrientationFusion()
    let start = simd_quatd(angle: 0, axis: yawAxis)
    _ = fusion.update(pose: start, stable: true, gyro: .zero, time: 0)
    _ = fusion.update(pose: nil, stable: false, gyro: SIMD3(1, 0, 0), time: 0.1)
    let pose = simd_quatd(angle: 0.15, axis: yawAxis)
    let result = fusion.update(pose: pose, stable: true, gyro: SIMD3(1, 0, 0), time: 0.2)
    let output = try #require(result)
    let difference = output * pose.inverse
    #expect(abs(2 * acos(min(1, abs(difference.real)))) < 1e-6)
}

@Test func prolongedTrackingLossStopsGyroDrift() throws {
    var fusion = VitureOrientationFusion()
    _ = fusion.update(pose: simd_quatd(angle: 0, axis: yawAxis), stable: true, gyro: .zero, time: 0)
    var output: simd_quatd?
    for step in 1...600 {
        output = fusion.update(pose: nil, stable: false, gyro: SIMD3(0, 1, 0), time: Double(step) / 120)
    }
    let yaw = try #require(output).yawPitch.yaw
    #expect(abs(yaw - 0.25) < 1e-6)
}

@Test func unstablePoseDoesNotStartOrRenewGyroWindow() throws {
    var fusion = VitureOrientationFusion()
    let pose = simd_quatd(angle: 0, axis: yawAxis)
    _ = fusion.update(pose: pose, stable: false, gyro: SIMD3(0, 1, 0), time: 0)
    let initial = fusion.update(pose: pose, stable: false, gyro: SIMD3(0, 1, 0), time: 0.1)
    #expect(abs(try #require(initial).yawPitch.yaw) < 1e-6)
    #expect(fusion.remainingPredictionTime(at: 0.1) == 0)
    _ = fusion.update(pose: pose, stable: true, gyro: .zero, time: 1)
    var output: simd_quatd?
    for step in 1...120 {
        output = fusion.update(pose: pose, stable: false, gyro: SIMD3(0, 1, 0), time: 1 + Double(step) / 120)
    }
    #expect(abs(try #require(output).yawPitch.yaw - 0.25) < 1e-6)
    #expect(fusion.remainingPredictionTime(at: 2) == 0)
    fusion.reset()
    #expect(fusion.remainingPredictionTime(at: 2) == 0)
    let reset = fusion.update(pose: pose, stable: false, gyro: SIMD3(0, 1, 0), time: 2.1)
    #expect(abs(try #require(reset).yawPitch.yaw) < 1e-6)
}

@Test func delayedPollDoesNotApplyCurrentGyroToAnExpiredWindow() throws {
    var fusion = VitureOrientationFusion()
    _ = fusion.update(pose: simd_quatd(angle: 0, axis: yawAxis), stable: true, gyro: .zero, time: 0)
    let result = fusion.update(pose: nil, stable: false, gyro: SIMD3(0, 1, 0), time: 1)
    #expect(abs(try #require(result).yawPitch.yaw) < 1e-6)
}
