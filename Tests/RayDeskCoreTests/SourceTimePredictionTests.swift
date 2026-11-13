import Testing
import simd
@testable import RayDeskCore
@testable import RayDesk

@Suite struct SourceTimePredictionTests {
    @Test func rayNeoPoseAndTimestampComeFromTheSameReceivedSample() throws {
        let filter = OrientationFilter()
        filter.clock = { 100.02 }
        filter.update(gyro: .zero, accel: SIMD3(0, 1, 0), magnetometer: nil, dt: 0.002, sampleTime: 100)
        filter.update(gyro: SIMD3(0, 1, 0), accel: SIMD3(0, 1, 0), magnetometer: nil, dt: 0.002, sampleTime: 100.002)
        let pose = try #require(ReprojectionPoseSource.rayNeo(filter, bias: 0, limit: 0.05, fallback: 0).sample(100.03))
        #expect(pose.sampleTime == 100.002)
        #expect(abs(pose.horizon - 0.028) < 1e-9)
    }

    @Test func repeatedSourceSampleDoesNotDampThePredictedVelocity() {
        var predictor = WorldLockPrediction()
        _ = predictor.predict(simd_quatd(angle: 0, axis: SIMD3(0, 1, 0)), at: 100, sampleTime: 100, horizon: 0.025)
        var worstError = 0.0
        for index in 1..<240 {
            let now = 100 + Double(index) / 120
            let sample = 100 + Double(index / 2) / 60
            let head = simd_quatd(angle: sample - 100, axis: SIMD3(0, 1, 0))
            let output = predictor.predict(head, at: now, sampleTime: sample, horizon: now + 0.025 - sample)
            if index > 80 {
                worstError = max(worstError, abs(output.yawPitch.yaw - (now + 0.025 - 100)))
            }
        }
        #expect(worstError < 1e-7)
    }

    @Test func expiredSourceSampleCannotKeepPredictingMotion() {
        var predictor = WorldLockPrediction()
        let zero = simd_quatd(angle: 0, axis: SIMD3(0, 1, 0))
        let head = simd_quatd(angle: 0.01, axis: SIMD3(0, 1, 0))
        _ = predictor.predict(zero, at: 100, sampleTime: 100, horizon: 0.025)
        _ = predictor.predict(head, at: 100.01, sampleTime: 100.01, horizon: 0.025)
        let output = predictor.predict(head, at: 100.2, sampleTime: 100.01, horizon: 0.05)
        #expect(output.vector == head.vector)
    }
}
