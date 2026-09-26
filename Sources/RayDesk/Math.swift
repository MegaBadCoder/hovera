import simd

extension simd_float4x4 {
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY / 2)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4(x, 0, 0, 0),
            SIMD4(0, y, 0, 0),
            SIMD4(0, 0, z, -1),
            SIMD4(0, 0, z * near, 0)
        ))
    }

    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t, 1)
        return m
    }

    static func scale(_ s: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(diagonal: SIMD4(s, 1))
    }

    static func rotation(_ q: simd_quatf) -> simd_float4x4 {
        simd_float4x4(q)
    }
}

extension simd_quatd {
    var yawPitch: (yaw: Double, pitch: Double) {
        let forward = act(SIMD3(0, 0, -1))
        return (atan2(-forward.x, -forward.z), asin(max(-1, min(1, forward.y))))
    }
}

func yawPitchQuat(yaw: Double, pitch: Double) -> simd_quatd {
    simd_quatd(angle: yaw, axis: SIMD3(0, 1, 0)) * simd_quatd(angle: pitch, axis: SIMD3(1, 0, 0))
}
