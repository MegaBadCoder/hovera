import Foundation
import Testing
import simd
@testable import RayDeskCore

@Test func zzGyroDump() throws {
    guard let path = ProcessInfo.processInfo.environment["GYRODUMP_CSV"],
          let outPath = ProcessInfo.processInfo.environment["GYRODUMP_OUT"] else { return }
    let text = try String(contentsOfFile: path, encoding: .utf8)
    let filter = OrientationFilter()
    filter.configureBiasLearner { $0.uncheckedGate = 0; $0.usesField = false }
    filter.gyroScale = SIMD3(1, 1.0345582874373933, 1)
    let degree = 180 / Double.pi
    var out = "t,qw,qx,qy,qz,gx,gy,gz,ax,ay,az,mx,my,mz,temp\n"
    var n = 0
    var gs = SIMD3<Double>(repeating: 0), acs = SIMD3<Double>(repeating: 0), ms = SIMD3<Double>(repeating: 0)
    for line in text.split(separator: "\n").dropFirst() {
        let f = line.split(separator: ",", omittingEmptySubsequences: false).map { Double($0) }
        guard f.count >= 12, let time = f[0], let dt = f[1], let ax = f[2], let ay = f[3], let az = f[4],
              let gx = f[5], let gy = f[6], let gz = f[7], let temp = f[8], let mx = f[9], let my = f[10], let mz = f[11] else { continue }
        filter.update(gyro: SIMD3(gx, gy, gz) / degree, accel: SIMD3(ax, ay, az), magnetometer: nil, dt: dt)
        gs += SIMD3(gx, gy, gz); acs += SIMD3(ax, ay, az); ms += SIMD3(mx, my, mz); n += 1
        if n == 5 {
            let q = filter.orientation(predictAhead: 0)
            let g = gs / 5, a = acs / 5, m = ms / 5
            out += String(format: "%.4f,%.7f,%.7f,%.7f,%.7f,%.4f,%.4f,%.4f,%.5f,%.5f,%.5f,%.3f,%.3f,%.3f,%.2f\n",
                          time, q.real, q.imag.x, q.imag.y, q.imag.z, g.x, g.y, g.z, a.x, a.y, a.z, m.x, m.y, m.z, temp)
            n = 0; gs = .zero; acs = .zero; ms = .zero
        }
    }
    try out.write(toFile: outPath, atomically: true, encoding: .utf8)
}
