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
