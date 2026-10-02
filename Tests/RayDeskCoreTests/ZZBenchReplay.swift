import Foundation
import Testing
import simd
@testable import RayDeskCore

/// Прогон записи IMU через фильтр текущей сборки для стенда `tmp/bench`.
///
/// Работает только при заданной `BENCH_CSV`, иначе ничего не делает.
/// Переменные окружения:
/// - `BENCH_CSV` — запись `time,dt,ax,ay,az,gx,gy,gz,temp,mx,my,mz`;
/// - `BENCH_OUT` — куда писать трассу 100 Гц;
/// - `BENCH_RESETS` — моменты ⌃R через запятую, секунды от 2001-01-01;
/// - `BENCH_CAL` — калибровка компаса `cx,cy,cz,radius,dip`.
@Test func zzBenchReplay() throws {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["BENCH_CSV"], let outPath = env["BENCH_OUT"] else { return }
    let resets = (env["BENCH_RESETS"] ?? "").split(separator: ",").compactMap { Double($0) }.sorted()
    let seed = SIMD3(-0.0006468984742502956, -0.001065970075083505, -0.001910513790240441)
    let scale = SIMD3(1, 1.0345582874373933, 1)
    let mount = ViewCalibration(yaw: 0, pitch: 17.5 * .pi / 180, roll: -1 * .pi / 180)
    let c = (env["BENCH_CAL"] ?? "").split(separator: ",").compactMap { Double($0) }
    let calibration = MagnetometerCalibration(center: SIMD3(c[0], c[1], c[2]), radius: c[3], dip: c[4])

    let fused = OrientationFilter()
    fused.seedGyroBias(seed)
    fused.gyroScale = scale
    fused.magnetometerCalibration = calibration
    let gyroOnly = OrientationFilter()
    gyroOnly.seedGyroBias(seed)
    gyroOnly.gyroScale = scale
    let frozen = OrientationFilter()
    frozen.seedGyroBias(seed)
    frozen.gyroScale = scale
    frozen.configureBiasLearner { $0.usesField = false; $0.uncheckedGate = 0 }

    let degree = 180 / Double.pi
    func renderedYawPitch(_ filter: OrientationFilter) -> (Double, Double) {
        let yp = mount.apply(to: filter.orientation(predictAhead: 0.018)).yawPitch
        return (yp.yaw * degree, yp.pitch * degree)
    }

    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    var out = "t,yaw,pitch,gyaw,fyaw,speed,cerr,temp,heading,bx,by,bz,uyaw,ugyaw,ufyaw\n"
    var nextReset = 0
    let filters = [fused, gyroOnly, frozen]
    var offsets = [0.0, 0.0, 0.0]
    var nextOut = -Double.infinity
    var speedAverage = 0.0
    var lastMag: SIMD3<Double>?
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let bytes = raw.bindMemory(to: UInt8.self)
        var index = 0
        while index < bytes.count, bytes[index] != 10 { index += 1 }
        index += 1
        var fields = [Double](repeating: .nan, count: 12)
        while index < bytes.count {
            var field = 0
            var start = index
            while index < bytes.count, bytes[index] != 10 {
                if bytes[index] == 44 {
                    if field < 12 { fields[field] = parse(bytes, start, index) }
                    field += 1
                    start = index + 1
                }
                index += 1
            }
            if field < 12 { fields[field] = parse(bytes, start, index) }
            index += 1
            guard field >= 11 else { continue }
            let time = fields[0], dt = fields[1]
            let gyro = SIMD3(fields[5], fields[6], fields[7]) / degree
            let accel = SIMD3(fields[2], fields[3], fields[4])
            let mag: SIMD3<Double>? = fields[9].isNaN ? nil : SIMD3(fields[9], fields[10], fields[11])
            while nextReset < resets.count, time - resets[nextReset] > 0.05 { nextReset += 1 }
            while nextReset < resets.count, time >= resets[nextReset] {
                let before = filters.map { renderedYawPitch($0).0 }
                print(String(format: "BENCH RESET at %.4f fused %.2f gyro %.2f frozen %.2f", resets[nextReset], -before[0], -before[1], -before[2]))
                for (i, filter) in filters.enumerated() {
                    filter.alignYawToZero()
                    offsets[i] += before[i] - renderedYawPitch(filter).0
                }
                nextReset += 1
            }
            fused.update(gyro: gyro, accel: accel, magnetometer: mag, dt: dt)
            gyroOnly.update(gyro: gyro, accel: accel, magnetometer: mag, dt: dt)
            frozen.update(gyro: gyro, accel: accel, magnetometer: mag, dt: dt)
            if mag != nil { lastMag = mag }
            if dt > 0, dt < 0.1 {
                speedAverage += (length(gyro * scale) - speedAverage) * min(1, dt / 0.05)
            }
            if time >= nextOut {
                nextOut = max(nextOut + 0.01, time)
                let f = renderedYawPitch(fused), g = renderedYawPitch(gyroOnly), z = renderedYawPitch(frozen)
                let bias = gyroOnly.gyroBias * degree
                var heading = Double.nan
                if let lastMag {
                    let world = fused.orientation(predictAhead: 0).act(lastMag - calibration.center)
                    heading = atan2(world.x, world.z) * degree
                }
                out += String(format: "%.3f,%.3f,%.2f,%.3f,%.3f,%.2f,%.2f,%.2f,%.2f,%.4f,%.4f,%.4f,%.3f,%.3f,%.3f\n", time, f.0, f.1, g.0, z.0,
                              speedAverage * degree, fused.compassError * degree, fields[8], heading, bias.x, bias.y, bias.z,
                              f.0 + offsets[0], g.0 + offsets[1], z.0 + offsets[2])
            }
        }
    }
    try out.write(toFile: outPath, atomically: true, encoding: .utf8)
}

private func parse(_ bytes: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> Double {
    guard end > start else { return .nan }
    var buffer = [CChar](repeating: 0, count: end - start + 1)
    for i in start..<end { buffer[i - start] = CChar(bitPattern: bytes[i]) }
    return strtod(buffer, nil)
}
