import Foundation
import simd
import CAprilTag

public struct TagIntrinsics: Sendable {
    public var fx: Double, fy: Double, cx: Double, cy: Double
    public init(fx: Double, fy: Double, cx: Double, cy: Double) { self.fx=fx;self.fy=fy;self.cx=cx;self.cy=cy }
}
/// Use on one capture queue; the native detector retains its work buffers.
public final class AprilTagDetector {
    private let native: OpaquePointer
    public init?() { guard let d = rd_tag_create() else { return nil }; native=d }
    deinit { rd_tag_destroy(native) }
    public func detect(gray: [UInt8], width: Int, height: Int, intrinsics k: TagIntrinsics, size: Double) -> [TagObservation] {
        guard width>0, height>0, width<=4096, height<=4096, gray.count==width*height,
              [k.fx,k.fy,k.cx,k.cy,size].allSatisfy(\.isFinite), size>0 else { return [] }
        let count=gray.withUnsafeBufferPointer { rd_tag_detect(native,$0.baseAddress,Int32(width),Int32(height),size,k.fx,k.fy,k.cx,k.cy) }
        return (0..<count).map { i in
            func v(_ f: Int32) -> Double { rd_tag_value(native,i,f) }
            let rotation=simd_double3x3(rows:[SIMD3(v(4),v(5),v(6)),SIMD3(v(7),v(8),v(9)),SIMD3(v(10),v(11),v(12))])
            let pose=TagPose(rotation: simd_quatd(rotation),position: SIMD3(v(13),v(14),v(15)))
            return TagObservation(id:Int(v(0)),pose:pose,corners:(0..<4).map { SIMD2(v(16+$0*2),v(17+$0*2)) })
        }
    }
}
