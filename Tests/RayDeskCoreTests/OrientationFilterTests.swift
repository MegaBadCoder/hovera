import Foundation
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
    let offset = SIMD3(0.0, 0.1 * .pi / 180, 0.0)
    filter.update(gyro: .zero, accel: SIMD3(0, 1, 0), dt: dt)

    for _ in 0..<Int(60.0 / dt) {
        filter.update(gyro: offset, accel: SIMD3(0, 1, 0), dt: dt)
    }
    let yawBeforeDrift = filter.orientation(predictAhead: 0).yawPitch.yaw

    let driftSeconds = 20.0
    for _ in 0..<Int(driftSeconds / dt) {
        filter.update(gyro: offset, accel: SIMD3(0, 1, 0), dt: dt)
    }
    let yawAfterDrift = filter.orientation(predictAhead: 0).yawPitch.yaw

    let observedDrift = abs(yawAfterDrift - yawBeforeDrift)
    let uncorrectedDrift = length(offset) * driftSeconds
    #expect(observedDrift < uncorrectedDrift / 5)
}

@Test(arguments: [0.5, 1.0, 1.5])
func slowHeadRotationIsTrackedNotAbsorbedAsBias(degreesPerSecond: Double) {
    let filter = OrientationFilter()
    let dt = 0.002
    for _ in 0..<Int(5.0 / dt) {
        filter.update(gyro: .zero, accel: SIMD3(0, 1, 0), dt: dt)
    }
    let before = filter.orientation(predictAhead: 0).yawPitch.yaw

    let seconds = 20.0
    for _ in 0..<Int(seconds / dt) {
        filter.update(gyro: SIMD3(0, degreesPerSecond * .pi / 180, 0), accel: SIMD3(0, 1, 0), dt: dt)
    }
    let turned = (filter.orientation(predictAhead: 0).yawPitch.yaw - before) * 180 / .pi

    #expect(abs(turned - degreesPerSecond * seconds) < 0.05 * degreesPerSecond * seconds)
}

@Test func headMicroMotionIsNotLearnedAsBias() {
    let filter = OrientationFilter()
    let dt = 0.002
    for step in 0..<Int(30.0 / dt) {
        let t = Double(step) * dt
        let sway = 1.2 * .pi / 180 * sin(2 * .pi * 0.3 * t)
        filter.update(gyro: SIMD3(0, sway + 0.8 * .pi / 180, 0), accel: SIMD3(0, 1, 0), dt: dt)
    }
    let before = filter.orientation(predictAhead: 0).yawPitch.yaw
    for _ in 0..<Int(10.0 / dt) {
        filter.update(gyro: .zero, accel: SIMD3(0, 1, 0), dt: dt)
    }
    let after = filter.orientation(predictAhead: 0).yawPitch.yaw

    #expect(abs(after - before) * 180 / .pi < 0.5)
}

@Test func recordedHeadTurnsReturnToTheSamePoint() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/head-turns.csv")
    let rows = try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n")
        .dropFirst()
        .map { $0.split(separator: ",").map { Double($0)! } }
    var decoderTick = rows[0][0]
    let filter = OrientationFilter()
    var time = 0.0
    var yawAtStart: [Double] = []
    var yawAtEnd: [Double] = []
    for row in rows.dropFirst() {
        let dt = (row[0] - decoderTick) / 10_000
        decoderTick = row[0]
        guard dt > 0 else { continue }
        time += dt
        filter.update(gyro: SIMD3(row[4], row[5], row[6]) * .pi / 180, accel: SIMD3(row[1], row[2], row[3]) / 9.80665, dt: dt)
        let yaw = filter.orientation(predictAhead: 0).yawPitch.yaw * 180 / .pi
        if (2..<4).contains(time) { yawAtStart.append(yaw) }
        if (25..<29).contains(time) { yawAtEnd.append(yaw) }
    }
    let start = yawAtStart.reduce(0, +) / Double(yawAtStart.count)
    let end = yawAtEnd.reduce(0, +) / Double(yawAtEnd.count)
    #expect(abs(end - start) < 3)
}
