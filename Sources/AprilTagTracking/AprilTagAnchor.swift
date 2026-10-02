import Foundation
import simd
import RayDeskCore

/// ID0 is upright on the front of the glasses. Its centre approximates the eye position.
public struct AprilTagAnchor: Sendable {
    public struct Reading: Sendable {
        public var targetYaw: Double
        public var offset: SIMD3<Double>
    }
    public private(set) var ready = false
    public private(set) var offset = SIMD3<Double>.zero
    private let tagFromHead = simd_quatd(angle: .pi, axis: SIMD3(0,0,1))
    private var worldFromCamera = simd_quatd(angle: 0, axis: SIMD3(0,1,0))
    private var referencePosition = SIMD3<Double>.zero
    private var window: [(time: Double, pose: TagPose, head: simd_quatd)] = []
    private var last: (time: Double, pose: TagPose)?
    public init() {}
    public mutating func update(pose: TagPose?, time: Double, arrival: Double, head: simd_quatd, speed: Double) -> Reading? {
        guard time.isFinite, arrival.isFinite, speed.isFinite,
              arrival-time >= 0, arrival-time < 0.2, let pose,
              [pose.position.x,pose.position.y,pose.position.z].allSatisfy(\.isFinite),
              pose.rotation.vector.x.isFinite,pose.rotation.vector.y.isFinite,
              pose.rotation.vector.z.isFinite,pose.rotation.vector.w.isFinite,
              abs(simd_length(pose.rotation.vector)-1)<0.01,
              head.vector.x.isFinite,head.vector.y.isFinite,head.vector.z.isFinite,head.vector.w.isFinite else {
            window.removeAll(); last=nil; return nil
        }
        let dt = last.map { time-$0.time } ?? 1.0/30
        guard dt>0 else { return nil }
        if dt>0.2 { window.removeAll(); last=nil }
        if !ready {
            guard abs(speed)<5 * .pi/180 else { window.removeAll(); last=nil; return nil }
            if let first=window.first {
                let delta=first.pose.distance(to:pose)
                if delta.meters>0.01 || delta.radians>3 * .pi/180 ||
                    abs(remainder(head.yawPitch.yaw-first.head.yawPitch.yaw,2 * .pi))>3 * .pi/180 { window.removeAll() }
            }
            window.append((time,pose,head));last=(time,pose)
            guard let first=window.first, time-first.time>=1,window.count>=20 else { return nil }
            var mean=first.pose
            for (index,sample) in window.dropFirst().enumerated() {
                let alpha=1/Double(index+2)
                mean.position += (sample.pose.position-mean.position)*alpha
                mean.rotation=simd_slerp(mean.rotation,sample.pose.rotation,alpha)
            }
            // Pose axes: camera +x right, +y down, +z away; upright front tag +z into head.
            worldFromCamera=simd_normalize(head * tagFromHead.inverse * mean.rotation.inverse)
            referencePosition=mean.position;ready=true;window.removeAll();offset = .zero
        }
        if let last, dt<0.2 {
            let change=last.pose.distance(to:pose)
            guard change.meters<0.02+1.5*dt, change.radians<10 * .pi/180+abs(speed)*dt*2 else {
                self.last=nil;return nil
            }
        }
        last=(time,pose)
        let target=worldFromCamera.act(pose.position-referencePosition)
        guard simd_length(target)<0.5 else { return nil }
        offset += (target-offset)*(1-exp(-min(dt,0.05)/0.12))
        let estimatedHead=worldFromCamera * pose.rotation * tagFromHead
        return Reading(targetYaw:estimatedHead.yawPitch.yaw,offset:offset)
    }
    public mutating func rotateWorld(by angle: Double) {
        guard angle.isFinite else { return }
        let rotation=simd_quatd(angle:angle,axis:SIMD3(0,1,0))
        worldFromCamera=rotation * worldFromCamera;offset=rotation.act(offset)
    }
}
