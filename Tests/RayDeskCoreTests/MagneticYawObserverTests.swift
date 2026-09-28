import Foundation
import Testing
import simd
@testable import RayDeskCore

private let degree = Double.pi / 180
private let hardIron = SIMD3(19.7, 77.3, -28.9)
private let earthField = simd_normalize(SIMD3(0.3, -0.64, -0.77)) * 34
private let calibration = MagnetometerCalibration(center: hardIron, radius: 34, dip: acos(simd_dot(simd_normalize(earthField), SIMD3(0, 1, 0))))

private func run(_ filter: OrientationFilter, seconds: Double, gyroBias: SIMD3<Double>, field: SIMD3<Double> = earthField,
                 headYawRate: (Double) -> Double = { _ in 0 }, start: Double = 0, initialYaw: Double = 0) -> Double {
    let dt = 0.002
    var trueYaw = initialYaw
    var time = start
    for _ in 0..<Int(seconds / dt) {
        let rate = headYawRate(time)
        trueYaw += rate * dt
        let head = simd_quatd(angle: trueYaw, axis: SIMD3(0, 1, 0))
        filter.update(gyro: SIMD3(0, rate, 0) + gyroBias,
                      accel: head.inverse.act(SIMD3(0, 1, 0)),
                      magnetometer: head.inverse.act(field) + hardIron,
                      dt: dt)
        time += dt
    }
    return trueYaw
}

private func yawError(_ filter: OrientationFilter, trueYaw: Double) -> Double {
    let estimated = filter.orientation(predictAhead: 0).yawPitch.yaw
    return atan2(sin(estimated - trueYaw), cos(estimated - trueYaw))
}

@Test func withoutCompassCalibrationStillnessLearningRemovesBias() {
    let filter = OrientationFilter()
    var trueYaw = run(filter, seconds: 30, gyroBias: SIMD3(0, 0.25 * degree, 0))
    let settled = yawError(filter, trueYaw: trueYaw)
    trueYaw += run(filter, seconds: 60, gyroBias: SIMD3(0, 0.25 * degree, 0), initialYaw: trueYaw)
    #expect(abs(yawError(filter, trueYaw: trueYaw) - settled) / degree < 0.5)
    #expect(abs(filter.gyroBias.y / degree - 0.25) < 0.02)
}

@Test func compassRemovesVerticalGyroBias() {
    let filter = OrientationFilter()
    filter.magnetometerCalibration = calibration
    var trueYaw = run(filter, seconds: 300, gyroBias: SIMD3(0, 0.25 * degree, 0))
    let errorBefore = yawError(filter, trueYaw: trueYaw)
    trueYaw += run(filter, seconds: 60, gyroBias: SIMD3(0, 0.25 * degree, 0))
    let errorAfter = yawError(filter, trueYaw: trueYaw)

    #expect(abs(errorAfter - errorBefore) / degree < 1)
    #expect(abs(errorAfter) / degree < 3)
    #expect(abs((filter.gyroBias.y + filter.verticalBias) / degree - 0.25) < 0.03)
}

@Test func compassWorksWhileHeadTurns() {
    let filter = OrientationFilter()
    filter.magnetometerCalibration = calibration
    let turning: (Double) -> Double = { 60 * degree * sin(2 * .pi * $0 / 7) }
    let trueYaw = run(filter, seconds: 360, gyroBias: SIMD3(0, -0.2 * degree, 0), headYawRate: turning)
    #expect(abs(yawError(filter, trueYaw: trueYaw)) / degree < 3)
}

@Test func distortedFieldFreezesTheEstimate() {
    let filter = OrientationFilter()
    filter.magnetometerCalibration = calibration
    _ = run(filter, seconds: 300, gyroBias: SIMD3(0, 0.25 * degree, 0))
    let learned = filter.verticalBias
    let rotatedField = simd_quatd(angle: 40 * degree, axis: SIMD3(0, 1, 0)).act(earthField) * 1.15
    _ = run(filter, seconds: 60, gyroBias: SIMD3(0, 0.25 * degree, 0), field: rotatedField)
    #expect(abs(filter.verticalBias - learned) / degree < 0.01)
}

@Test func recenterDoesNotMakeTheCompassPullBack() {
    let filter = OrientationFilter()
    filter.magnetometerCalibration = calibration
    let turned = run(filter, seconds: 300, gyroBias: .zero, headYawRate: { $0 < 1 ? 30 * degree : 0 })
    filter.alignYawToZero()
    _ = run(filter, seconds: 30, gyroBias: .zero, start: 300, initialYaw: turned)
    #expect(abs(filter.orientation(predictAhead: 0).yawPitch.yaw) / degree < 0.5)
}

@Test func recordedWearStaysPutWithStillnessLearningAndRecenter() throws {
    let rows = try Fixture.rows("carousel.csv.lzfse")
    let fitted = try TrackingReplay.compassCalibration(rows)

    func headings(compass: Bool, recenterAt: Double?) -> [(Double, Double)] {
        let filter = OrientationFilter()
        if compass { filter.magnetometerCalibration = fitted }
        var previousTick = rows[0][0]
        var time = 0.0
        var pressed = false
        var result: [(Double, Double)] = []
        for row in rows.dropFirst() {
            let dt = (row[0] - previousTick) / 10_000
            previousTick = row[0]
            guard dt > 0, dt < 0.05 else { continue }
            time += dt
            if let recenterAt, !pressed, time >= recenterAt {
                filter.trustNextStillness()
                pressed = true
            }
            let magnetometer = SIMD3(row[9], -row[8], row[10])
            filter.update(gyro: SIMD3(row[4], row[5], row[6]) * degree, accel: SIMD3(row[1], row[2], row[3]) / 9.80665, magnetometer: magnetometer, dt: dt)
            let world = filter.orientation(predictAhead: 0).act(magnetometer - fitted.center)
            result.append((time, atan2(world.x, world.z)))
        }
        return result
    }
    func drift(_ series: [(Double, Double)], from early: Range<Double>, to late: Range<Double>) -> Double {
        let mean = { (values: [Double]) in atan2(values.map(sin).reduce(0, +), values.map(cos).reduce(0, +)) }
        let difference = mean(series.filter { late.contains($0.0) }.map(\.1)) - mean(series.filter { early.contains($0.0) }.map(\.1))
        return abs(atan2(sin(difference), cos(difference))) / degree
    }

    let learnerOnly = headings(compass: false, recenterAt: 290)
    #expect(drift(learnerOnly, from: 100..<130, to: 200..<230) < 3)
    #expect(drift(learnerOnly, from: 300..<310, to: 320..<330) < 2)
    #expect(drift(headings(compass: true, recenterAt: nil), from: 100..<130, to: 300..<330) < 3)
}

@Test func orientationDependentCompassErrorDoesNotRockTheWorld() {
    let filter = OrientationFilter()
    filter.magnetometerCalibration = calibration
    let dt = 0.002
    var trueYaw = 0.0
    var worstBias = 0.0
    for step in 0..<Int(240 / dt) {
        let time = Double(step) * dt
        let phase = time.truncatingRemainder(dividingBy: 20)
        let rate = phase < 1.5 ? 55 * degree : (phase >= 10 && phase < 11.5 ? -55 * degree : 0)
        trueYaw += rate * dt
        let head = simd_quatd(angle: trueYaw, axis: SIMD3(0, 1, 0))
        let distortion = simd_quatd(angle: 6 * degree * sin(2 * trueYaw), axis: SIMD3(0, 1, 0))
        filter.update(gyro: SIMD3(0, rate, 0), accel: head.inverse.act(SIMD3(0, 1, 0)),
                      magnetometer: head.inverse.act(distortion.act(earthField)) + hardIron, dt: dt)
        if time > 20 { worstBias = max(worstBias, abs(filter.verticalBias)) }
    }
    #expect(worstBias / degree < 0.1)
    #expect(abs(yawError(filter, trueYaw: trueYaw)) / degree < 4)
}

@Test func compassAdaptsWhenSittingSomewhereElse() {
    let filter = OrientationFilter()
    filter.magnetometerCalibration = calibration
    let tilted = simd_quatd(angle: 8 * degree, axis: SIMD3(1, 0, 0)).act(earthField) * 0.93
    var trueYaw = run(filter, seconds: 240, gyroBias: SIMD3(0, 0.25 * degree, 0), field: tilted)
    let settledError = yawError(filter, trueYaw: trueYaw)
    trueYaw += run(filter, seconds: 120, gyroBias: SIMD3(0, 0.25 * degree, 0), field: tilted, initialYaw: trueYaw)
    #expect(abs(yawError(filter, trueYaw: trueYaw) - settledError) / degree < 1)
    #expect(abs((filter.gyroBias.y + filter.verticalBias) / degree - 0.25) < 0.05)
}
