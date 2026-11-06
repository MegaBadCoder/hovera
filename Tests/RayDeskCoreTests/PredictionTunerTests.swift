import Foundation
import Testing
import simd
@testable import RayDeskCore

private let yawAxis = SIMD3<Double>(0, 1, 0)
private let yawRate = SIMD3<Double>(0, 1, 0)

@Test func undershootMovesTheBiasForward() {
    var tuner = PredictionTuner()
    let predicted = simd_quatd(angle: -0.001, axis: yawAxis)
    for _ in 0..<40 {
        tuner.observe(predicted: predicted, actual: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), angularVelocity: yawRate)
    }
    #expect(tuner.value > 0.0005)
    #expect(tuner.value < 0.0011)
    #expect(tuner.sampleCount == 40)
}

@Test func overshootMovesTheBiasBackwards() {
    var tuner = PredictionTuner()
    let predicted = simd_quatd(angle: 0.001, axis: yawAxis)
    for _ in 0..<40 {
        tuner.observe(predicted: predicted, actual: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), angularVelocity: yawRate)
    }
    #expect(tuner.value < -0.0005)
    #expect(tuner.value > -0.0011)
}

@Test func biasIsClampedToItsLimit() {
    var tuner = PredictionTuner()
    let predicted = simd_quatd(angle: -0.2, axis: yawAxis)
    for _ in 0..<200 {
        tuner.observe(predicted: predicted, actual: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), angularVelocity: yawRate)
    }
    #expect(abs(tuner.value - tuner.maxBias) < 1e-12)
}

@Test func stillHeadLearnsNothing() {
    var tuner = PredictionTuner()
    let predicted = simd_quatd(angle: -0.01, axis: yawAxis)
    for _ in 0..<20 {
        tuner.observe(predicted: predicted, actual: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), angularVelocity: SIMD3(0, 0.1, 0))
    }
    #expect(tuner.value == 0)
    #expect(tuner.sampleCount == 0)
}

@Test func matchingPredictionLeavesTheBiasAlone() {
    var tuner = PredictionTuner()
    for _ in 0..<20 {
        tuner.observe(predicted: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1),
                      actual: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1),
                      angularVelocity: yawRate)
    }
    #expect(tuner.value == 0)
    #expect(tuner.sampleCount == 0)
}
