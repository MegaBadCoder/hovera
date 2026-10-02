import simd
import Foundation

/// Checks rigid marker motion against time-aligned IMU motion. Does not resolve the initial pose ambiguity.
public struct AprilTagMotionGate: Sendable {
    private var reference: (tag: simd_quatd, head: simd_quatd, time: Double)?
    private let tagFromHead = simd_quatd(angle: .pi, axis: SIMD3(0,0,1))
    public private(set) var residualDegrees: Double? = nil
    private var lastTime: Double?
    public init() {}
    public mutating func accept(tag: simd_quatd, head: simd_quatd, time: Double) -> Bool {
        residualDegrees = nil
        guard time.isFinite, lastTime.map({ time > $0 }) ?? true else { return false }
        lastTime = time
        for rotation in [tag, head] {
            let q = rotation.vector
            guard q.x.isFinite, q.y.isFinite, q.z.isFinite, q.w.isFinite,
                  abs(simd_length(q)-1) < 0.01 else { return false }
        }
        if let reference {
            let headMotion = reference.head.inverse * head
            let expected = simd_normalize(reference.tag * tagFromHead * headMotion * tagFromHead.inverse)
            let dot = abs(simd_dot(expected.vector, simd_normalize(tag).vector))
            let residual = 2 * acos(min(1,dot)) * 180 / .pi
            residualDegrees = residual
            guard residual <= 5 else { return false }
        }
        // Rejected samples and visibility gaps never replace the trusted reference.
        reference = (tag,head,time)
        return true
    }
    public mutating func rotateWorld(by angle: Double) {
        guard angle.isFinite, let reference else { return }
        let rotation = simd_quatd(angle:angle,axis:SIMD3(0,1,0))
        self.reference = (reference.tag,rotation * reference.head,reference.time)
    }
}
