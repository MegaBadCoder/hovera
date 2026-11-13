import Foundation
import Testing
import simd
@testable import RayDeskCore

private func filterWithSample(at time: Double, yawRate: Double = 0) -> OrientationFilter {
    let filter = OrientationFilter()
    filter.clock = { time }
    filter.update(gyro: .zero, accel: SIMD3(0, 1, 0), dt: 0.002)
    filter.update(gyro: SIMD3(0, yawRate, 0), accel: SIMD3(0, 1, 0), dt: 0.002)
    if yawRate != 0 {
        for _ in 0..<10 {
            filter.update(gyro: SIMD3(0, yawRate, 0), accel: SIMD3(0, 1, 0), dt: 0.002)
        }
    }
    return filter
}

@Test func horizonFallsBackToPredictionSecondsWithoutSamples() {
    let pipeline = HeadPipeline(filter: OrientationFilter())
    #expect(abs(pipeline.predictionHorizon(at: 50) - pipeline.predictionSeconds) < 1e-12)
}

@Test func horizonIsTheDistanceToThePresentTime() {
    let pipeline = HeadPipeline(filter: filterWithSample(at: 100))
    #expect(abs(pipeline.predictionHorizon(at: 100.010) - 0.010) < 1e-9)
}

@Test func horizonNeverGoesBackwards() {
    let pipeline = HeadPipeline(filter: filterWithSample(at: 100))
    #expect(pipeline.predictionHorizon(at: 99.5) == 0)
}

@Test func horizonStopsAtTheCapEvenAfterAStall() {
    let pipeline = HeadPipeline(filter: filterWithSample(at: 100))
    #expect(abs(pipeline.predictionHorizon(at: 100.5) - pipeline.maxPrediction) < 1e-12)
}

@Test func stabilizedOutputEqualsFilterPredictionWhenStabilizationIsOff() {
    let filter = filterWithSample(at: 100, yawRate: 0.5)
    let pipeline = HeadPipeline(filter: filter)
    pipeline.stabilizer = OrientationStabilizer(level: .off)
    let presentTime = 100.012
    let rendered = pipeline.renderedOrientation(at: presentTime, frameInterval: 1.0 / 60)
    let expected = filter.orientation(predictAhead: pipeline.predictionHorizon(at: presentTime))
    let difference = rendered * expected.inverse
    #expect(abs(2 * acos(min(1, abs(difference.real)))) < 1e-6)
}

@Test func pathWithoutPresentTimeKeepsTheOldPrediction() {
    let filter = filterWithSample(at: 100, yawRate: 0.5)
    let pipeline = HeadPipeline(filter: filter)
    pipeline.stabilizer = OrientationStabilizer(level: .off)
    let rendered = pipeline.renderedOrientation(frameInterval: 1.0 / 60)
    let expected = filter.orientation(predictAhead: pipeline.predictionSeconds)
    let difference = rendered * expected.inverse
    #expect(abs(2 * acos(min(1, abs(difference.real)))) < 1e-6)
}

@Test func predictionBiasShiftsTheHorizon() {
    let pipeline = HeadPipeline(filter: filterWithSample(at: 100))
    pipeline.predictionBias = 0.003
    #expect(abs(pipeline.predictionHorizon(at: 100.005) - 0.008) < 1e-9)
}

@Test func predictionBiasNeverPushesPastTheCap() {
    let pipeline = HeadPipeline(filter: filterWithSample(at: 100))
    pipeline.predictionBias = 0.5
    #expect(abs(pipeline.predictionHorizon(at: 100.005) - pipeline.maxPrediction) < 1e-12)
}

@Test func externalOrientationIsPassedThroughWhenStabilizationIsOff() {
    let pipeline = HeadPipeline(filter: filterWithSample(at: 100))
    pipeline.stabilizer = OrientationStabilizer(level: .off)
    let external = simd_normalize(simd_quatd(ix: 0.1, iy: 0.2, iz: 0.3, r: 0.9))
    let output = pipeline.stabilizedExternal(external, dt: 1.0 / 120)
    let difference = output * external.inverse
    #expect(abs(2 * acos(min(1, abs(difference.real)))) < 1e-6)
}

@Test func externalOrientationIsSmoothedWhenStabilizationIsOn() {
    let pipeline = HeadPipeline(filter: filterWithSample(at: 100))
    pipeline.stabilizer = OrientationStabilizer(level: .strong)
    var output = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    for step in 0..<120 {
        let pulse = simd_quatd(angle: (step.isMultiple(of: 2) ? 0.002 : -0.002), axis: SIMD3(0, 1, 0))
        output = pipeline.stabilizedExternal(pulse, dt: 1.0 / 120)
    }
    let angle = 2 * acos(min(1, abs(output.real)))
    #expect(angle < 0.001)
}

@Test func externalOrientationAppliesManualSceneAngles() {
    let pipeline = HeadPipeline(filter: OrientationFilter())
    pipeline.stabilizer = OrientationStabilizer(level: .off)
    pipeline.calibration = ViewCalibration(yaw: 0.2, pitch: -0.1, roll: 0.05)
    let external = yawPitchQuat(yaw: 0.5, pitch: 0.3)
    let output = pipeline.stabilizedExternal(external, dt: 1.0 / 120)
    let expected = pipeline.calibration.apply(to: external)
    #expect(abs(simd_dot(output.vector, expected.vector)) > 1 - 1e-10)
}

@Test func worldLockedSampleUsesOneTimestampAndAppliesCalibrationOnce() {
    let filter = filterWithSample(at: 100, yawRate: 0.7)
    let pipeline = HeadPipeline(filter: filter)
    pipeline.predictionBias = 0.003
    pipeline.calibration = ViewCalibration(yaw: 0.2, pitch: -0.1, roll: 0.05)
    pipeline.stabilizer.level = .strong
    let sample = pipeline.worldLockedSample(at: 100.012)
    let expected = pipeline.calibration.apply(to: filter.orientation(predictAhead: 0.015))
    #expect(abs(sample.horizon - 0.015) < 1e-9)
    #expect(abs(simd_dot(sample.orientation.vector, expected.vector)) > 1 - 1e-10)
    #expect(sample.angularVelocity == filter.angularVelocity)
    #expect(pipeline.worldLockedSample(at: 101).horizon == pipeline.maxPrediction)
    #expect(pipeline.worldLockedSample(at: 99).horizon == 0)
}
