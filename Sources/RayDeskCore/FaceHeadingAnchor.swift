import Foundation
import simd

/// A camera face reference for small yaw corrections; large errors require explicit recentering.
public struct FaceHeadingAnchor: Sendable {
    public enum State: String, Sendable { case waiting, learning, holding, missing, moving, turned, stale, recenter }
    public private(set) var state: State = .waiting
    public private(set) var ready = false
    public private(set) var error: Double? = nil
    private var cameraYaw = 0.0
    private var referenceFace = SIMD2<Double>.zero
    private var lastTime: Double?
    private var lastHead: Double?
    private var calibration: [(time: Double, face: SIMD2<Double>, head: Double)] = []
    private var probe: (time: Double, error: Double, count: Int)?
    private static let degree = Double.pi / 180
    public init() {}
    public mutating func reset() { self = Self() }

    private mutating func suspend(_ state: State) -> Double {
        self.state = state
        calibration.removeAll()
        probe = nil
        error = nil
        return 0
    }

    public mutating func update(face: SIMD2<Double>?, headYaw: Double, speed: Double,
                                time: Double, arrival: Double) -> Double {
        let degree = Self.degree
        guard time.isFinite, arrival.isFinite, time > (lastTime ?? -.infinity),
              arrival-time >= 0, arrival-time < 0.2, headYaw.isFinite, speed.isFinite else {
            return suspend(.stale)
        }
        let dt = lastTime.map { time-$0 } ?? 1.0/30
        let headSpeed = lastHead.map { abs(remainder(headYaw-$0,2 * .pi))/dt } ?? 0
        lastTime = time
        lastHead = headYaw
        if dt>0.2 { _ = suspend(.learning) }
        guard let face, face.x.isFinite, face.y.isFinite else { return suspend(.missing) }
        guard abs(face.x)<40 * degree, abs(face.y)<60 * degree else { return suspend(.turned) }
        guard max(abs(speed),headSpeed)<(ready ? 15 : 5) * degree else { return suspend(.moving) }
        if !ready {
            if let first = calibration.first,
               abs(remainder(face.x-first.face.x,2 * .pi))>3 * degree ||
                abs(face.y-first.face.y)>3 * degree || abs(remainder(headYaw-first.head,2 * .pi))>3 * degree {
                calibration.removeAll()
            }
            calibration.append((time,face,headYaw))
            state = .learning
            guard let first = calibration.first, time-first.time>=1, calibration.count>=20 else { return 0 }
            let base = first.head-first.face.x
            cameraYaw = base + calibration.reduce(0) { $0 + remainder($1.head-$1.face.x-base,2 * .pi) } / Double(calibration.count)
            referenceFace = calibration.reduce(SIMD2<Double>.zero) { $0+$1.face } / Double(calibration.count)
            ready = true
            calibration.removeAll()
            state = .holding
            return 0
        }
        guard abs(remainder(face.x-referenceFace.x,2 * .pi))<20 * degree,
              abs(face.y-referenceFace.y)<15 * degree else { return suspend(.turned) }
        let measured = remainder(headYaw-cameraYaw-face.x,2 * .pi)
        guard abs(measured)<=8 * degree else { return suspend(.recenter) }
        if let old = probe, abs(remainder(measured-old.error,2 * .pi))<2 * degree {
            probe = (old.time,old.error,old.count+1)
        } else {
            probe = (time,measured,1)
            error = nil
        }
        guard let probe, time-probe.time>=0.35, probe.count>=8 else { state = .learning; return 0 }
        state = .holding
        let smoothed = error.map { $0 + (measured-$0)*(1-exp(-min(dt,0.1)/0.6)) } ?? measured
        let outside = max(0,abs(smoothed)-degree)
        let rate = min(degree,0.7*outside)
        let step = -(smoothed<0 ? -1.0 : 1.0)*rate*min(dt,0.1)
        error = smoothed+step
        return step
    }
}
