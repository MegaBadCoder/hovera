import Foundation
import simd
import RayDeskCore

public struct TagPose: Sendable {
    public var rotation: simd_quatd
    public var position: SIMD3<Double>
    public init(rotation: simd_quatd, position: SIMD3<Double>) { self.rotation = rotation; self.position = position }
    public func composed(with other: TagPose) -> TagPose {
        TagPose(rotation: simd_normalize(rotation * other.rotation), position: position + rotation.act(other.position))
    }
    public var inverse: TagPose { TagPose(rotation: rotation.inverse, position: rotation.inverse.act(-position)) }
    public func distance(to other: TagPose) -> (meters: Double, radians: Double) {
        let dot = abs(simd_dot(rotation.vector, other.rotation.vector))
        return (simd_distance(position, other.position), 2 * acos(min(1, dot)))
    }
}
public struct TagObservation: Sendable {
    public var id: Int
    public var pose: TagPose
    public var corners: [SIMD2<Double>]
    public init(id: Int, pose: TagPose, corners: [SIMD2<Double>] = []) { self.id = id; self.pose = pose; self.corners = corners }
}
public struct AprilTagRig: Sendable {
    public struct Reading: Sendable {
        public var pose: TagPose
        public var id: Int
    }
    public private(set) var knownIDs: Set<Int> = [0]
    private var transforms: [Int: TagPose] = [0: TagPose(rotation: simd_quatd(angle: 0, axis: SIMD3(0,1,0)), position: .zero)]
    private var pending: [Int: (pose: TagPose, start: Double, last: Double, count: Int)] = [:]
    private var lastTime: Double?
    public init() {}
    public mutating func reset() { self = Self() }
    public mutating func update(_ observations: [TagObservation], time: Double) -> Reading? {
        guard time.isFinite else { return nil }
        defer { lastTime = time }
        if let lastTime, time <= lastTime { pending.removeAll(); return nil }
        let valid = observations.filter { (0...2).contains($0.id) &&
            $0.pose.position.x.isFinite && $0.pose.position.y.isFinite && $0.pose.position.z.isFinite &&
            $0.pose.rotation.vector.x.isFinite && $0.pose.rotation.vector.y.isFinite &&
            $0.pose.rotation.vector.z.isFinite && $0.pose.rotation.vector.w.isFinite &&
            abs(simd_length($0.pose.rotation.vector) - 1) < 0.01 }
        guard Set(valid.map(\.id)).count == valid.count else { pending.removeAll(); return nil }
        let candidates = valid.sorted { $0.id < $1.id }.compactMap { tag -> Reading? in
            guard let rootFromTag = transforms[tag.id] else { return nil }
            return Reading(pose: tag.pose.composed(with: rootFromTag.inverse), id: tag.id)
        }
        guard let root = candidates.first else { pending.removeAll(); return nil }
        for candidate in candidates.dropFirst() {
            let delta = candidate.pose.distance(to: root.pose)
            guard delta.meters < 0.025, delta.radians < 6 * .pi / 180 else { pending.removeAll(); return nil }
        }
        let visible = Set(valid.map(\.id))
        pending = pending.filter { visible.contains($0.key) }
        for tag in valid where transforms[tag.id] == nil {
            let relative = root.pose.inverse.composed(with: tag.pose)
            guard simd_length(relative.position) < 0.3 else { pending[tag.id] = nil; continue }
            if var probe = pending[tag.id] {
                let delta = probe.pose.distance(to: relative)
                if time - probe.last <= 0.15, delta.meters < 0.005, delta.radians < 3 * .pi / 180 {
                    probe.count += 1; probe.last = time
                    let alpha = 1 / Double(probe.count)
                    probe.pose.position += (relative.position - probe.pose.position) * alpha
                    probe.pose.rotation = simd_slerp(probe.pose.rotation, relative.rotation, alpha)
                    pending[tag.id] = probe
                    if time - probe.start >= 0.6 && probe.count >= 15 {
                        transforms[tag.id] = probe.pose; knownIDs.insert(tag.id); pending[tag.id] = nil
                    }
                    continue
                }
            }
            pending[tag.id] = (relative, time, time, 1)
        }
        return root
    }
}
