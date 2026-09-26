import Foundation
import simd

final class ScreenPlacement {
    private let defaults = UserDefaults.standard

    var yaw: Double { didSet { save() } }
    var pitch: Double { didSet { save() } }
    var distance: Double { didSet { save() } }
    var width: Double { didSet { save() } }
    var verticalFOV: Double { didSet { save() } }
    var predictionMs: Double { didSet { save() } }
    var follow = false

    private(set) var isGrabbing = false
    private var grabOffset = (yaw: 0.0, pitch: 0.0)

    init() {
        defaults.register(defaults: [
            "yaw": 0.0, "pitch": 0.0, "distance": 1.5, "width": 1.0,
            "verticalFOV": 23.6, "predictionMs": 18.0,
        ])
        yaw = defaults.double(forKey: "yaw")
        pitch = defaults.double(forKey: "pitch")
        distance = defaults.double(forKey: "distance")
        width = defaults.double(forKey: "width")
        verticalFOV = defaults.double(forKey: "verticalFOV")
        predictionMs = defaults.double(forKey: "predictionMs")
    }

    private func save() {
        defaults.set(yaw, forKey: "yaw")
        defaults.set(pitch, forKey: "pitch")
        defaults.set(distance, forKey: "distance")
        defaults.set(width, forKey: "width")
        defaults.set(verticalFOV, forKey: "verticalFOV")
        defaults.set(predictionMs, forKey: "predictionMs")
    }

    func place(atGaze head: simd_quatd) {
        let gaze = head.yawPitch
        yaw = gaze.yaw
        pitch = gaze.pitch
    }

    func toggleGrab(head: simd_quatd) {
        if isGrabbing {
            isGrabbing = false
            return
        }
        let gaze = head.yawPitch
        grabOffset = (wrap(yaw - gaze.yaw), pitch - gaze.pitch)
        isGrabbing = true
    }

    func tick(head: simd_quatd, dt: Double) {
        let gaze = head.yawPitch
        if isGrabbing {
            yaw = gaze.yaw + grabOffset.yaw
            pitch = clampPitch(gaze.pitch + grabOffset.pitch)
        } else if follow {
            let deadZone = 12.0 * .pi / 180
            let dy = wrap(gaze.yaw - yaw)
            let dp = gaze.pitch - pitch
            let k = min(1, dt * 3)
            if abs(dy) > deadZone { yaw += (dy - deadZone * sign(dy)) * k }
            if abs(dp) > deadZone { pitch += (dp - deadZone * sign(dp)) * k }
        }
    }

    func adjustDistance(by factor: Double) {
        distance = min(6, max(0.4, distance * factor))
    }

    func adjustWidth(by factor: Double) {
        width = min(5, max(0.2, width * factor))
    }

    var rotation: simd_quatd { yawPitchQuat(yaw: yaw, pitch: pitch) }

    private func wrap(_ a: Double) -> Double { atan2(sin(a), cos(a)) }
    private func clampPitch(_ p: Double) -> Double { min(1.4, max(-1.4, p)) }
}
