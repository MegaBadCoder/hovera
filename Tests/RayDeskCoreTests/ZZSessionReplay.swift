import Foundation
import Testing
import simd
@testable import RayDeskCore

@Test func zzSessionReplay() throws {
    guard let path = ProcessInfo.processInfo.environment["REPLAY_CSV"] else { return }
    let text = try String(contentsOfFile: path, encoding: .utf8)
    let recenters = (ProcessInfo.processInfo.environment["REPLAY_RECENTERS"] ?? "").split(separator: ",").compactMap { Double($0) }
    let noCompass = ProcessInfo.processInfo.environment["REPLAY_NOCOMPASS"] != nil
    let filter = OrientationFilter()
    if ProcessInfo.processInfo.environment["REPLAY_SEED"] != nil {
        filter.seedGyroBias(SIMD3(-0.0006468984742502956, -0.001065970075083505, -0.001910513790240441))
    }
    filter.gyroScale = SIMD3(1, 1.0345582874373933, 1)
    if !noCompass {
        let c = (ProcessInfo.processInfo.environment["REPLAY_CAL"] ?? "24.011977443458576,82.71605516440869,-30.64628335146423,53.300149128282186,0.30771340177522993").split(separator: ",").map { Double($0)! }
        filter.magnetometerCalibration = MagnetometerCalibration(center: SIMD3(c[0], c[1], c[2]), radius: c[3], dip: c[4])
    }
    let degree = 180 / Double.pi
    var gyroOnly = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    var nextRecenter = 0
    var nextPrint = 0.0
    var start: Double?
    var errSum = 0.0, errCount = 0.0, errMax = 0.0
    var dump = "t,qw,qx,qy,qz,mx,my,mz,speed\n"
    var nextDump = 0.0
    var firstHeading: [SIMD2<Int>: Double] = [:]
    var headings: [SIMD2<Int>: [Double]] = [:]
    var stillHeadings: [(Double, Double)] = []
    var out = "t,yaw,pitch,gyroyaw,diff,cerr,cerrmax,sectors\n"
    let lag = Int(ProcessInfo.processInfo.environment["REPLAY_MAGLAG"] ?? "0")!
    let lines = Array(text.split(separator: "\n").dropFirst())
    for (index, line) in lines.enumerated() {
        var f = line.split(separator: ",", omittingEmptySubsequences: false).map { Double($0) }
        let shifted = min(max(index + lag, 0), lines.count - 1)
        if lag != 0 {
            let g = lines[shifted].split(separator: ",", omittingEmptySubsequences: false).map { Double($0) }
            if g.count >= 12, f.count >= 12 { f[9] = g[9]; f[10] = g[10]; f[11] = g[11] }
        }
        guard f.count >= 12, let time = f[0], let dt = f[1], let ax = f[2], let ay = f[3], let az = f[4],
              let gx = f[5], let gy = f[6], let gz = f[7] else { continue }
        if start == nil { start = time }
        let t = time - start!
        let mag: SIMD3<Double>? = (f[9] != nil && f[10] != nil && f[11] != nil) ? SIMD3(f[9]!, f[10]!, f[11]!) : nil
        let gyro = SIMD3(gx, gy, gz) / degree
        while nextRecenter < recenters.count, time - recenters[nextRecenter] > 0.05 { nextRecenter += 1 }
        while nextRecenter < recenters.count, time >= recenters[nextRecenter] {
            let rendered = ViewCalibration(yaw: 0, pitch: 17.5 * .pi / 180, roll: -1 * .pi / 180).apply(to: filter.orientation(predictAhead: 0.018))
            print(String(format: "RECENTER at %.4f replay rendered yaw %.1f", recenters[nextRecenter], -rendered.yawPitch.yaw * degree))
            filter.alignYawToZero()
            let yp = gyroOnly.yawPitch
            gyroOnly = simd_quatd(angle: -yp.yaw, axis: SIMD3(0, 1, 0)) * gyroOnly
            nextRecenter += 1
        }
        filter.update(gyro: gyro, accel: SIMD3(ax, ay, az), magnetometer: mag, dt: dt)
        let g = gyro * SIMD3(1, 1.0345582874373933, 1)
        if dt > 0, dt < 0.1, length(g) * dt > 1e-12 {
            gyroOnly = simd_normalize(gyroOnly * simd_quatd(angle: length(g) * dt, axis: normalize(g)))
        }
        if let mag, t > 5, t >= nextDump {
            let q = filter.orientation(predictAhead: 0)
            dump += String(format: "%.2f,%.6f,%.6f,%.6f,%.6f,%.2f,%.2f,%.2f,%.4f,%.3f,%.5f,%.5f,%.5f\n", t, q.real, q.imag.x, q.imag.y, q.imag.z, mag.x, mag.y, mag.z, filter.angularSpeed, filter.compassError * degree, ax, ay, az)
            nextDump += 0.1
        }
        if let mag, t > 5 {
            let q = filter.orientation(predictAhead: 0)
            let world = q.act(mag - (filter.magnetometerCalibration?.center ?? .zero))
            let heading = atan2(world.x, world.z) * degree
            let look = q.yawPitch
            let sector = SIMD2(Int((look.yaw / (15 / degree)).rounded()), Int((look.pitch / (15 / degree)).rounded()))
            if firstHeading[sector] == nil { firstHeading[sector] = heading }
            headings[sector, default: []].append(heading)
            if filter.angularSpeed < 3 / degree { stillHeadings.append((t, heading)) }
        }
        let e = filter.compassError * degree
        errSum += e; errCount += 1; errMax = abs(e) > abs(errMax) ? e : errMax
        if t >= nextPrint {
            let q = filter.orientation(predictAhead: 0)
            let yaw = q.yawPitch.yaw * degree
            let gyaw = gyroOnly.yawPitch.yaw * degree
            out += String(format: "%.0f,%.1f,%.1f,%.1f,%.1f,%.2f,%.1f\n", t, yaw, q.yawPitch.pitch * degree, gyaw,
                          remainder(yaw - gyaw, 360), errSum / max(errCount, 1), errMax)
            errSum = 0; errCount = 0; errMax = 0
            nextPrint += 1
        }
    }
    var report = "sector,first,mean,count\n"
    for (sector, list) in headings where list.count > 500 {
        let mean = list.reduce(0, +) / Double(list.count)
        report += "\(sector.x * 15)/\(sector.y * 15),\(String(format: "%.1f,%.1f,%d", firstHeading[sector]!, mean, list.count))\n"
    }
    var diffs: [Double] = []
    for i in 1..<stillHeadings.count where stillHeadings[i].0 - stillHeadings[i - 1].0 < 0.05 {
        diffs.append(remainder(stillHeadings[i].1 - stillHeadings[i - 1].1, 360))
    }
    let sd = (diffs.map { $0 * $0 }.reduce(0, +) / Double(diffs.count) / 2).squareRoot()
    report += String(format: "per-sample heading noise (still): %.2f° from %d pairs\n", sd, diffs.count)
    try report.write(toFile: ProcessInfo.processInfo.environment["REPLAY_OUT"]! + ".sectors", atomically: true, encoding: .utf8)
    try dump.write(toFile: ProcessInfo.processInfo.environment["REPLAY_OUT"]! + ".dump", atomically: true, encoding: .utf8)
    try out.write(toFile: ProcessInfo.processInfo.environment["REPLAY_OUT"]!, atomically: true, encoding: .utf8)
}
