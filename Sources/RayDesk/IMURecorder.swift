import Foundation
import RayDeskCore

final class IMURecorder {
    private let queue = DispatchQueue(label: "raydesk.imu-recorder", qos: .utility)
    private let lock = NSLock()
    private var buffer: [String] = []
    private var handle: FileHandle?
    private var fileStarted = Date()
    private let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RayDesk-imu")
    private static let fileSeconds = 1800.0
    private static let keptFiles = 4

    func record(_ sample: IMUSample) {
        let degree = 180 / Double.pi
        let field = sample.magnetometer.map { String(format: "%.2f,%.2f,%.2f", $0.x, $0.y, $0.z) } ?? ",,"
        let line = String(format: "%.4f,%.5f,%.5f,%.5f,%.5f,%.4f,%.4f,%.4f,%.2f,", Date().timeIntervalSinceReferenceDate, sample.dt,
                          sample.accel.x, sample.accel.y, sample.accel.z,
                          sample.gyro.x * degree, sample.gyro.y * degree, sample.gyro.z * degree, sample.temperature) + field
        lock.lock()
        buffer.append(line)
        let ready = buffer.count >= 500
        let lines = ready ? buffer : []
        if ready { buffer.removeAll(keepingCapacity: true) }
        lock.unlock()
        if ready { queue.async { self.write(lines) } }
    }

    private func write(_ lines: [String]) {
        if handle == nil || Date().timeIntervalSince(fileStarted) > IMURecorder.fileSeconds {
            startFile()
        }
        handle?.write((lines.joined(separator: "\n") + "\n").data(using: .utf8)!)
    }

    private func startFile() {
        try? handle?.close()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("imu-\(Int(Date().timeIntervalSinceReferenceDate)).csv")
            FileManager.default.createFile(atPath: url.path, contents: "time,dt,ax,ay,az,gx,gy,gz,temp,mx,my,mz\n".data(using: .utf8))
            handle = try FileHandle(forWritingTo: url)
            handle?.seekToEndOfFile()
            fileStarted = Date()
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("imu-") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for old in files.dropLast(IMURecorder.keptFiles) {
                try FileManager.default.removeItem(at: old)
            }
            log("imu recording: \(url.lastPathComponent)")
        } catch {
            handle = nil
            log("imu recording failed: \(error)")
        }
    }
}
