import Foundation
import simd

extension ViturePose {
    init?(nativeGL values: [Float], timestamp: Double) {
        guard values.count >= 32, values.prefix(16).allSatisfy(\.isFinite), values[30].isFinite else { return nil }
        let rotation = simd_double3x3(columns: (
            SIMD3(Double(values[0]), Double(values[1]), Double(values[2])),
            SIMD3(Double(values[4]), Double(values[5]), Double(values[6])),
            SIMD3(Double(values[8]), Double(values[9]), Double(values[10]))))
        guard abs(simd_determinant(rotation) - 1) < 0.02,
              abs(length(rotation.columns.0) - 1) < 0.02,
              abs(length(rotation.columns.1) - 1) < 0.02,
              abs(length(rotation.columns.2) - 1) < 0.02,
              abs(dot(rotation.columns.0, rotation.columns.1)) < 0.02,
              abs(dot(rotation.columns.0, rotation.columns.2)) < 0.02,
              abs(dot(rotation.columns.1, rotation.columns.2)) < 0.02 else { return nil }
        let quaternion = simd_quatd(rotation)
        guard quaternion.vector.x.isFinite, quaternion.vector.y.isFinite,
              quaternion.vector.z.isFinite, quaternion.vector.w.isFinite else { return nil }
        self.init(position: SIMD3(Double(values[12]), Double(values[13]), Double(values[14])),
                  orientation: quaternion, timestamp: timestamp, isStable: values[30] == 2)
    }
}
