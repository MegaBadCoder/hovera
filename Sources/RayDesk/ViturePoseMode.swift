import Foundation
import Darwin

enum ViturePoseMode: String {
    case polling
    case callback

    var configuration: String? {
        self == .callback ? "pose_format: matrix\npose_callback_frequency: 1000\n" : nil
    }
}

enum VitureNativeClock {
    static func hostTime(for timestamp: Double) -> Double {
        let before = ProcessInfo.processInfo.systemUptime
        var native = timespec()
        guard clock_gettime(CLOCK_MONOTONIC_RAW, &native) == 0 else { return .nan }
        let after = ProcessInfo.processInfo.systemUptime
        return timestamp - (Double(native.tv_sec) + Double(native.tv_nsec) * 1e-9) + (before + after) * 0.5
    }
}
