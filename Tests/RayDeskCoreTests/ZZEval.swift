import Foundation
import Testing
import simd
@testable import RayDeskCore

@Test func zzEval() throws {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["EVAL_CSV"] else { return }
    let degree = 180 / Double.pi
    let list = { (key: String) in (env[key] ?? "").split(separator: ",").compactMap { Double($0) } }
    let recenters = list("EVAL_RECENTERS")
    let marks = list("EVAL_MARKS")
    let filter = OrientationFilter()
    filter.gyroScale = SIMD3(1, 1.0345582874373933, 1)
    if env["EVAL_SEED"] != nil {
        filter.seedGyroBias(SIMD3(-0.0006468984742502956, -0.001065970075083505, -0.001910513790240441))
    }
    if env["EVAL_NOCOMPASS"] == nil {
        let c = env["REPLAY_CAL"]!.split(separator: ",").map { Double($0)! }
        filter.magnetometerCalibration = MagnetometerCalibration(center: SIMD3(c[0], c[1], c[2]), radius: c[3], dip: c[4])
    }
    var tuning = CompassTuning()
    if let v = env["T_GAIN"].flatMap(Double.init) { tuning.proportionalGain = v }
    if let v = env["T_RATE"].flatMap(Double.init) { tuning.maxCorrectionRate = v / degree }
    if let v = env["T_SECTOR"].flatMap(Double.init) { tuning.sectorSize = v / degree }
    if env["T_ABSORB"] != nil { tuning.absorbFastChanges = true }
    if let v = env["T_WIN"].flatMap(Double.init) { tuning.fastWindow = v }
    if let v = env["T_THR"].flatMap(Double.init) { tuning.fastThreshold = v / degree }
    if let v = env["T_THRROT"].flatMap(Double.init) { tuning.fastThresholdPerTravel = v }
    if let v = env["T_SMOOTH"].flatMap(Double.init) { tuning.smoothing = v }
    if let v = env["T_DECAY"].flatMap(Double.init) { tuning.offsetDecaySeconds = v }
    if let v = env["T_MAXTRAVEL"].flatMap(Double.init) { tuning.maxTravel = v / degree }
    if let v = env["T_SNAP"].flatMap(Double.init) { tuning.snapBack = v / degree }
    if let v = env["T_MAXOFF"].flatMap(Double.init) { tuning.maxOffset = v / degree }
    if let v = env["T_TILTGATE"].flatMap(Double.init) { tuning.tiltGate = v / degree }
    if env["T_LEVEL"] != nil { tuning.levelWithAccel = true }
    if let v = env["T_ACCSMOOTH"].flatMap(Double.init) { tuning.accelSmoothing = v }
    if let v = env["T_ACCGATE"].flatMap(Double.init) { tuning.accelGate = v }
    if let v = env["T_KI"].flatMap(Double.init) { tuning.tiltIntegralGain = v }
    if env["T_GATEINVALID"] != nil { tuning.gateInvalidAccel = true }
    if let v = env["T_HYST"].flatMap(Double.init) { tuning.sectorHysteresis = v / degree }
    if let v = env["T_KP"].flatMap(Double.init) { filter.kp = v }
    if let v = env["T_HGATE"].flatMap(Double.init) { tuning.headingTiltGate = v / degree }
    if let v = env["T_MGAIN"].flatMap(Double.init) { tuning.motionRateGain = v }
    if let v = env["T_STILL"].flatMap(Double.init) { tuning.stillCorrectionRate = v / degree }
    filter.compassTuning = tuning

    let view = ViewCalibration(yaw: 0, pitch: 17.5 / degree, roll: -1 / degree)
    var gyroOnly = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    var nextRecenter = 0, nextMark = 0
    var series: [(t: Double, diff: Double, segment: Int)] = []
    var segment = 0
    var nextSample = 0.0
    var report = ""
    var trace = "t,yaw,gyaw,pitch,cerr,offset,turn,speed\n"
    let text = try String(contentsOfFile: path, encoding: .utf8)
    for line in text.split(separator: "\n").dropFirst() {
        let f = line.split(separator: ",", omittingEmptySubsequences: false).map { Double($0) }
        guard f.count >= 12, let time = f[0], let dt = f[1], let ax = f[2], let ay = f[3], let az = f[4],
              let gx = f[5], let gy = f[6], let gz = f[7] else { continue }
        let mag: SIMD3<Double>? = (f[9] != nil && f[10] != nil && f[11] != nil) ? SIMD3(f[9]!, f[10]!, f[11]!) : nil
        while nextMark < marks.count, time >= marks[nextMark] {
            let rendered = view.apply(to: filter.orientation(predictAhead: 0.018))
            report += String(format: "MK %.4f %.2f\n", marks[nextMark], -rendered.yawPitch.yaw * degree)
            nextMark += 1
        }
        while nextRecenter < recenters.count, time - recenters[nextRecenter] > 0.05 { nextRecenter += 1 }
        while nextRecenter < recenters.count, time >= recenters[nextRecenter] {
            let rendered = view.apply(to: filter.orientation(predictAhead: 0.018))
            report += String(format: "RC %.4f %.2f\n", recenters[nextRecenter], -rendered.yawPitch.yaw * degree)
            filter.alignYawToZero()
            let yp = gyroOnly.yawPitch
            gyroOnly = simd_quatd(angle: -yp.yaw, axis: SIMD3(0, 1, 0)) * gyroOnly
            segment += 1
            nextRecenter += 1
        }
        let gyro = SIMD3(gx, gy, gz) / degree
        filter.update(gyro: gyro, accel: SIMD3(ax, ay, az), magnetometer: mag, dt: dt)
        let g = gyro * SIMD3(1, 1.0345582874373933, 1)
        if dt > 0, dt < 0.1, length(g) * dt > 1e-12 {
            gyroOnly = simd_normalize(gyroOnly * simd_quatd(angle: length(g) * dt, axis: normalize(g)))
        }
        if time >= nextSample {
            let q = filter.orientation(predictAhead: 0)
            let yaw = q.yawPitch.yaw * degree
            let gyaw = gyroOnly.yawPitch.yaw * degree
            series.append((time, filter.compassTurn * degree, 0))
            trace += String(format: "%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.1f\n", time, yaw, gyaw, q.yawPitch.pitch * degree, filter.compassError * degree, filter.magneticOffset * degree, filter.compassTurn * degree, filter.angularSpeed * degree)
            nextSample = time + 0.1
        }
    }
    var worst = 0.0, worstAt = 0.0
    var j = 0
    for i in series.indices {
        while j < series.count, series[j].t < series[i].t + 10 { j += 1 }
        for k in i..<min(j, series.count) where series[k].segment == series[i].segment {
            let swing = abs(remainder(series[k].diff - series[i].diff, 360))
            if swing > worst { worst = swing; worstAt = series[i].t }
        }
    }
    report += String(format: "SWING %.2f %.2f\n", worst, worstAt)
    var swings: [Double] = []
    var k = 0
    for i in series.indices {
        while k < series.count, series[k].t < series[i].t + 10 { k += 1 }
        if k < series.count { swings.append(abs(series[k].diff - series[i].diff)) }
    }
    swings.sort()
    if !swings.isEmpty {
        report += String(format: "P95 %.2f P99 %.2f TURN %.1f\n", swings[swings.count * 95 / 100], swings[swings.count * 99 / 100], series.last!.diff)
    }
    print(report)
    if let out = env["EVAL_OUT"] {
        try report.write(toFile: out, atomically: true, encoding: .utf8)
        try trace.write(toFile: out + ".trace", atomically: true, encoding: .utf8)
    }
}
