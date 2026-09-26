import Testing
import simd
@testable import RayDeskCore

private let degree = Double.pi / 180

@Test func restingWithGravityUpYieldsZeroPitch() {
    let filter = OrientationFilter()
    filter.update(gyro: .zero, accel: SIMD3(0, 1, 0), dt: 0.01)
    for _ in 0..<50 {
        filter.update(gyro: .zero, accel: SIMD3(0, 1, 0), dt: 0.01)
    }
    let yp = filter.orientation(predictAhead: 0).yawPitch
    #expect(abs(yp.pitch) < 1 * degree)
    #expect(abs(yp.yaw) < 1 * degree)
}

@Test func gravityAlongPlusZLooksDown() {
    let filter = OrientationFilter()
    filter.update(gyro: .zero, accel: SIMD3(0, 0, 1), dt: 0.01)
    for _ in 0..<50 {
        filter.update(gyro: .zero, accel: SIMD3(0, 0, 1), dt: 0.01)
    }
    let yp = filter.orientation(predictAhead: 0).yawPitch
    #expect(yp.pitch < -80 * degree)
}

@Test func yawingLeftAtNinetyDegreesPerSecondForOneSecondYieldsNinetyYaw() {
    let filter = OrientationFilter()
    filter.update(gyro: .zero, accel: SIMD3(0, 1, 0), dt: 0.002)
    let gyro = SIMD3(0.0, Double.pi / 2, 0.0)
    let dt = 0.002
    for _ in 0..<Int(1.0 / dt) {
        filter.update(gyro: gyro, accel: SIMD3(0, 1, 0), dt: dt)
    }
    let yp = filter.orientation(predictAhead: 0).yawPitch
    #expect(abs(yp.yaw - .pi / 2) < 2 * degree)
}

@Test func gyroscopeBiasIsLearnedWhileStill() {
    let filter = OrientationFilter()
    let dt = 0.002
    let offset = SIMD3(0.0, 0.01, 0.0)
    filter.update(gyro: .zero, accel: SIMD3(0, 1, 0), dt: dt)

    for _ in 0..<Int(3.0 / dt) {
        filter.update(gyro: offset, accel: SIMD3(0, 1, 0), dt: dt)
    }
    let yawBeforeDrift = filter.orientation(predictAhead: 0).yawPitch.yaw

    let driftSeconds = 2.0
    for _ in 0..<Int(driftSeconds / dt) {
        filter.update(gyro: offset, accel: SIMD3(0, 1, 0), dt: dt)
    }
    let yawAfterDrift = filter.orientation(predictAhead: 0).yawPitch.yaw

    let observedDrift = abs(yawAfterDrift - yawBeforeDrift)
    let uncorrectedDrift = length(offset) * driftSeconds
    #expect(observedDrift < uncorrectedDrift / 5)
}
