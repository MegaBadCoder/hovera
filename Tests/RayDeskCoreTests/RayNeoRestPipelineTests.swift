import Foundation
import Testing
import simd
@testable import RayDesk
@testable import RayDeskCore

private final class RayNeoRestClock: @unchecked Sendable {
    var time = 10.0
}

@Test func rayNeoRestSourceRequiresReadyAndRecentIMU() throws {
    let clock = RayNeoRestClock()
    let filter = OrientationFilter()
    filter.clock = { clock.time }
    let source = ReprojectionPoseSource.rayNeo(filter, bias: 0, limit: 0.045, fallback: 0.018)
    #expect(try #require(source.sample(clock.time + 0.01)).isStable == false)
    filter.update(gyro: .zero, accel: SIMD3(0, 1, 0), dt: 0.002)
    #expect(try #require(source.sample(clock.time + 0.01)).isStable == false)
    for _ in 0..<250 {
        clock.time += 0.002
        filter.update(gyro: .zero, accel: SIMD3(0, 1, 0), dt: 0.002)
    }
    #expect(try #require(source.sample(clock.time + 0.01)).isStable)
    clock.time += 0.2
    #expect(try #require(source.sample(clock.time + 0.01)).isStable == false)
}

@Test func rayNeoPredictionAndRestSmoothingPreserveFastPitchTurns() throws {
    let clock = RayNeoRestClock()
    let filter = OrientationFilter()
    filter.clock = { clock.time }
    filter.kp = 0
    filter.restoresFirmwareZero = false
    let source = ReprojectionPoseSource.rayNeo(filter, bias: 0, limit: 0.045, fallback: 0.018)
    var predictor = WorldLockPrediction()
    var rest = RestPoseStabilizer()
    var observedRest = false
    var movingFrames = 0
    for tick in 0..<1000 {
        clock.time = 10 + Double(tick) * 0.002
        let moving = tick >= 500
        filter.update(gyro: moving ? SIMD3(0.4, 0, 0) : .zero, accel: SIMD3(0, 1, 0), dt: 0.002)
        guard tick.isMultiple(of: 4) else { continue }
        let sample = try #require(source.sample(clock.time + 0.01))
        let predicted = predictor.predict(sample.orientation, at: clock.time, horizon: sample.horizon, smoothing: false)
        let output = rest.filter(predicted, motion: sample.orientation, at: clock.time, enabled: true, stable: sample.isStable)
        if !moving, rest.isResting { observedRest = true }
        if moving {
            movingFrames += 1
            #expect(!rest.isResting)
            #expect(abs(simd_dot(output.vector, predicted.vector)) > 1 - 1e-12)
            if movingFrames > 1 {
                let expected = sample.orientation * simd_quatd(angle: 0.4 * sample.horizon, axis: SIMD3(1, 0, 0))
                #expect(abs(simd_dot(output.vector, expected.vector)) > 1 - 1e-10)
            }
        }
    }
    #expect(observedRest)
    #expect(movingFrames > 100)
}
