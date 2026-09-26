import Foundation
import simd

final class OrientationFilter {
    private let lock = NSLock()
    private var q = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    private var omega = SIMD3<Double>(repeating: 0)
    private var bias = SIMD3<Double>(repeating: 0)
    private var integral = SIMD3<Double>(repeating: 0)
    private var initialized = false
    private var stillTime = 0.0
    private var calibrationSum = SIMD3<Double>(repeating: 0)
    private var calibrationCount = 0
    private(set) var sampleCount = 0

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return initialized && sampleCount > 200
    }

    var kp = 0.5
    var ki = 0.002

    func reset() {
        lock.lock()
        initialized = false
        integral = .zero
        calibrationSum = .zero
        calibrationCount = 0
        lock.unlock()
    }

    func update(gyro: SIMD3<Double>, accel: SIMD3<Double>, dt: Double) {
        guard dt > 0, dt < 0.1 else { return }
        lock.lock()
        defer { lock.unlock() }
        sampleCount &+= 1

        let accelNorm = length(accel)
        if !initialized {
            guard accelNorm > 0.1 else { return }
            q = simd_quatd(from: normalize(accel), to: SIMD3(0, 1, 0))
            let yp = q.yawPitch
            q = simd_quatd(angle: -yp.yaw, axis: SIMD3(0, 1, 0)) * q
            initialized = true
            return
        }

        trackBias(gyro: gyro, accel: accel, accelNorm: accelNorm, dt: dt)

        var w = gyro - bias
        omega = w
        if accelNorm > 0.7, accelNorm < 1.3 {
            let measuredUp = accel / accelNorm
            let estimatedUp = q.inverse.act(SIMD3(0, 1, 0))
            let error = cross(measuredUp, estimatedUp)
            integral += ki * error * dt
            w += kp * error + integral
        }
        let angle = length(w) * dt
        if angle > 1e-9 {
            q = simd_normalize(q * simd_quatd(angle: angle, axis: normalize(w)))
        }
    }

    private func trackBias(gyro: SIMD3<Double>, accel: SIMD3<Double>, accelNorm: Double, dt: Double) {
        let still = length(gyro - bias) < 0.03 && abs(accelNorm - 1) < 0.05
        stillTime = still ? stillTime + dt : 0
        guard stillTime > 0.4 else { return }
        if calibrationCount < 400 {
            calibrationSum += gyro
            calibrationCount += 1
            bias = calibrationSum / Double(calibrationCount)
        } else {
            bias += (gyro - bias) * min(1, dt * 0.5)
        }
    }

    func orientation(predictAhead seconds: Double) -> simd_quatd {
        lock.lock()
        defer { lock.unlock() }
        let angle = length(omega) * seconds
        guard angle > 1e-9 else { return q }
        return simd_normalize(q * simd_quatd(angle: angle, axis: normalize(omega)))
    }

    func alignYawToZero() {
        lock.lock()
        let yp = q.yawPitch
        q = simd_quatd(angle: -yp.yaw, axis: SIMD3(0, 1, 0)) * q
        lock.unlock()
    }
}
