import simd

extension simd_float4x4 {
    /// Матрица перспективной проекции с нижним левым началом NDC по Z в [0, 1] (Metal).
    ///
    /// - Parameters:
    ///   - fovY: вертикальный угол обзора, радианы.
    ///   - aspect: отношение ширины к высоте.
    ///   - near: расстояние до ближней плоскости отсечения.
    ///   - far: расстояние до дальней плоскости отсечения.
    public static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
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

    /// Матрица переноса на вектор `t`.
    public static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t, 1)
        return m
    }

    /// Диагональная матрица масштаба по осям `s`.
    public static func scale(_ s: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(diagonal: SIMD4(s, 1))
    }

    /// Матрица поворота, соответствующая кватерниону `q`.
    public static func rotation(_ q: simd_quatf) -> simd_float4x4 {
        simd_float4x4(q)
    }
}

extension simd_quatd {
    /// Разложение ориентации на yaw и pitch относительно направления взгляда -Z.
    ///
    /// Yaw положителен при повороте влево, pitch положителен при взгляде вверх.
    public var yawPitch: (yaw: Double, pitch: Double) {
        let forward = act(SIMD3(0, 0, -1))
        return (atan2(-forward.x, -forward.z), asin(max(-1, min(1, forward.y))))
    }
}

/// Строит кватернион ориентации из yaw и pitch (в радианах): yaw вокруг
/// мировой оси Y (положительный — влево), затем pitch вокруг локальной оси X
/// (положительный — вверх).
public func yawPitchQuat(yaw: Double, pitch: Double) -> simd_quatd {
    simd_quatd(angle: yaw, axis: SIMD3(0, 1, 0)) * simd_quatd(angle: pitch, axis: SIMD3(1, 0, 0))
}
