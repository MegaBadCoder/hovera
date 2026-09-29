import Foundation
import Testing
import simd
@testable import RayDeskCore

@Test func zzMagDump() throws {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["MAGDUMP_CSV"], let outPath = env["MAGDUMP_OUT"] else { return }
    let text = try String(contentsOfFile: path, encoding: .utf8)
    let recenters = (env["REPLAY_RECENTERS"] ?? "").split(separator: ",").compactMap { Double($0) }
    let c = (env["REPLAY_CAL"] ?? "22.980775323714415,82.39386138665067,-27.546536925009608,52.59850485625357,0.29489587768107667").split(separator: ",").map { Double($0)! }
    let fused = OrientationFilter()
    fused.gyroScale = SIMD3(1, 1.0345582874373933, 1)
    fused.magnetometerCalibration = MagnetometerCalibration(center: SIMD3(c[0], c[1], c[2]), radius: c[3], dip: c[4])
    let gyroOnly = OrientationFilter()
    gyroOnly.gyroScale = SIMD3(1, 1.0345582874373933, 1)
    gyroOnly.seedGyroBias(SIMD3(-0.0006468984742502956, -0.001065970075083505, -0.001910513790240441))
    let every = Int(env["MAGDUMP_EVERY"] ?? "5")!
    var out = "t,fw,fx,fy,fz,gw,gx,gy,gz,mx,my,mz,ax,ay,az,wx,wy,wz,temp,cerr,speed\n"
    var nextRecenter = 0
    var index = 0
    for line in text.split(separator: "\n").dropFirst() {
        let f = line.split(separator: ",", omittingEmptySubsequences: false).map { Double($0) }
        guard f.count >= 12, let time = f[0], let dt = f[1], let ax = f[2], let ay = f[3], let az = f[4],
              let gx = f[5], let gy = f[6], let gz = f[7] else { continue }
        let mag: SIMD3<Double>? = (f[9] != nil && f[10] != nil && f[11] != nil) ? SIMD3(f[9]!, f[10]!, f[11]!) : nil
        while nextRecenter < recenters.count, time - recenters[nextRecenter] > 0.05 { nextRecenter += 1 }
        while nextRecenter < recenters.count, time >= recenters[nextRecenter] {
            fused.alignYawToZero()
            nextRecenter += 1
        }
        let gyro = SIMD3(gx, gy, gz) * .pi / 180
        fused.update(gyro: gyro, accel: SIMD3(ax, ay, az), magnetometer: mag, dt: dt)
        gyroOnly.update(gyro: gyro, accel: SIMD3(ax, ay, az), magnetometer: mag, dt: dt)
        index += 1
        if index % every == 0, let mag {
            let q = fused.orientation(predictAhead: 0)
            let g = gyroOnly.orientation(predictAhead: 0)
            out += String(format: "%.4f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.2f,%.2f,%.2f,%.4f,%.4f,%.4f,%.3f,%.3f,%.3f,%.2f,%.3f,%.4f\n",
                          time, q.real, q.imag.x, q.imag.y, q.imag.z, g.real, g.imag.x, g.imag.y, g.imag.z,
                          mag.x, mag.y, mag.z, ax, ay, az, gx, gy, gz, f[8] ?? 0, fused.compassError * 180 / .pi, fused.angularSpeed)
        }
    }
    try out.write(toFile: outPath, atomically: true, encoding: .utf8)
}
