import Foundation
import simd
@testable import RayDeskCore

struct TrackingMetrics {
    var jitterDegrees: Double
    var lagMilliseconds: Double
    var headingDriftDegrees: Double?
}

enum TrackingReplay {
    static let frameRate = 120.0
    private static let degree = Double.pi / 180

    static func measure(_ rows: [[Double]], pipeline: HeadPipeline, compass: MagnetometerCalibration? = nil) -> TrackingMetrics {
        let filter = pipeline.filter
        filter.magnetometerCalibration = compass
        var reference = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        var sampleTimes: [Double] = []
        var references: [simd_quatd] = []
        var rates: [Double] = []
        var frames: [(time: Double, rendered: simd_quatd, rate: SIMD3<Double>)] = []
        var worldRates: [SIMD3<Double>] = []
        var headings: [(Double, Double)] = []
        var previousTick = rows[0][0]
        var time = 0.0
        var nextFrame = 0.0
        var lastGyro = SIMD3<Double>(repeating: 0)

        for row in rows.dropFirst() {
            let dt = (row[0] - previousTick) / 10_000
            previousTick = row[0]
            guard dt > 0, dt < 0.05 else { continue }
            time += dt
            let gyro = SIMD3(row[4], row[5], row[6]) * degree
            lastGyro = gyro
            let magnetometer = row.count >= 11 ? SIMD3(row[9], -row[8], row[10]) : nil
            filter.update(gyro: gyro, accel: SIMD3(row[1], row[2], row[3]) / 9.80665, magnetometer: magnetometer, dt: dt)
            let angle = length(gyro) * dt
            if angle > 1e-12 {
                reference = simd_normalize(reference * simd_quatd(angle: angle, axis: normalize(gyro)))
            }
            sampleTimes.append(time)
            references.append(reference)
            rates.append(length(gyro))
            while time >= nextFrame {
                let rendered = pipeline.renderedOrientation(frameInterval: 1 / frameRate)
                frames.append((nextFrame, rendered, lastGyro))
                if let compass, let magnetometer {
                    let world = rendered.act(magnetometer - compass.center)
                    headings.append((nextFrame, atan2(world.x, world.z)))
                }
                nextFrame += 1 / frameRate
            }
        }

        var errors: [SIMD3<Double>] = []
        var index = 0
        for frame in frames {
            let target = frame.time + pipeline.predictionSeconds
            while index + 1 < sampleTimes.count, sampleTimes[index + 1] <= target { index += 1 }
            var difference = frame.rendered * references[index].inverse
            if difference.real < 0 { difference = simd_quatd(vector: -difference.vector) }
            errors.append(difference.angle > 1e-12 ? difference.axis * difference.angle : .zero)
            worldRates.append(references[index].act(frame.rate))
        }

        func movingAverage(_ values: [SIMD3<Double>], seconds: Double) -> [SIMD3<Double>] {
            let half = Int(seconds * frameRate / 2)
            var prefix = [SIMD3<Double>(repeating: 0)]
            for value in values { prefix.append(prefix.last! + value) }
            return values.indices.map { i in
                let lo = max(0, i - half), hi = min(values.count, i + half + 1)
                return (prefix[hi] - prefix[lo]) / Double(hi - lo)
            }
        }
        let smoothedRate: [Double] = {
            var result: [Double] = []
            var sampleIndex = 0
            var window: [Double] = []
            for frame in frames {
                while sampleIndex < sampleTimes.count, sampleTimes[sampleIndex] <= frame.time {
                    window.append(rates[sampleIndex])
                    if window.count > 250 { window.removeFirst() }
                    sampleIndex += 1
                }
                result.append(window.isEmpty ? 0 : window.reduce(0, +) / Double(window.count))
            }
            return result
        }()

        let jitterBand = zip(errors, movingAverage(errors, seconds: 1)).map { $0 - $1 }
        let quiet = frames.indices.filter { smoothedRate[$0] < 5 * degree && frames[$0].time > 5 }
        let jitter = (quiet.map { simd_length_squared(jitterBand[$0]) }.reduce(0, +) / Double(max(quiet.count, 1))).squareRoot() / degree

        let lagBand = zip(errors, movingAverage(errors, seconds: 2)).map { $0 - $1 }
        let moving = frames.indices.filter { smoothedRate[$0] > 20 * degree && frames[$0].time > 5 }
        let numerator = moving.map { simd_dot(lagBand[$0], worldRates[$0]) }.reduce(0, +)
        let denominator = moving.map { simd_length_squared(worldRates[$0]) }.reduce(0, +)
        let lag = denominator > 0 ? -numerator / denominator * 1000 : 0

        var drift: Double?
        if !headings.isEmpty {
            let mean = { (values: [Double]) in atan2(values.map(sin).reduce(0, +), values.map(cos).reduce(0, +)) }
            let early = headings.filter { (100..<130).contains($0.0) }.map(\.1)
            let late = headings.filter { (300..<330).contains($0.0) }.map(\.1)
            if !early.isEmpty, !late.isEmpty {
                let difference = mean(late) - mean(early)
                drift = abs(atan2(sin(difference), cos(difference))) / degree
            }
        }
        return TrackingMetrics(jitterDegrees: jitter, lagMilliseconds: lag, headingDriftDegrees: drift)
    }

    static func compassCalibration(_ rows: [[Double]]) throws -> MagnetometerCalibration {
        var fitter = HardIronFitter()
        for row in rows { fitter.add(magnetometer: SIMD3(row[9], -row[8], row[10]), up: simd_normalize(SIMD3(row[1], row[2], row[3]))) }
        return try fitter.result()
    }
}
