import simd

/// Поза виртуального экрана в пространстве вокруг головы.
///
/// `yaw`/`pitch` — направление на экран относительно взгляда прямо вперёд
/// (радианы, yaw положителен влево, pitch положителен вверх), `distance` —
/// расстояние до экрана (метры), `width` — физическая ширина экрана (метры),
/// `aspect` — отношение ширины к высоте.
public struct ScreenPose: Codable, Equatable {
    public var yaw: Double
    public var pitch: Double
    public var distance: Double
    public var width: Double
    public var aspect: Double

    public init(yaw: Double, pitch: Double, distance: Double, width: Double, aspect: Double) {
        self.yaw = yaw
        self.pitch = pitch
        self.distance = distance
        self.width = width
        self.aspect = aspect
    }

    /// Ориентация экрана относительно головы.
    public var rotation: simd_quatd {
        yawPitchQuat(yaw: yaw, pitch: pitch)
    }

    /// Физическая высота экрана в метрах.
    public var height: Double {
        width / aspect
    }

    /// Угловая ширина экрана, видимая из начала координат, в радианах.
    public var angularWidth: Double {
        2 * atan(width / 2 / distance)
    }

    /// Матрица модели, переводящая единичный квад (x,y ∈ [-1,1], z=0) в мировые координаты экрана.
    public var modelMatrix: simd_float4x4 {
        let q = rotation
        let rotationF = simd_quatf(ix: Float(q.imag.x), iy: Float(q.imag.y), iz: Float(q.imag.z), r: Float(q.real))
        return .rotation(rotationF) * .translation(SIMD3(0, 0, Float(-distance))) * .scale(SIMD3(Float(width / 2), Float(height / 2), 1))
    }

    /// Пересечение луча из начала координат (головы) с плоскостью экрана.
    ///
    /// - Parameter rayDirection: направление луча в мировых координатах (не обязательно нормализовано).
    /// - Returns: расстояние вдоль луча и координаты попадания `uv` (u вправо, v вниз, [0,1]²), либо `nil`, если луч не попадает в экран.
    public func intersect(rayDirection: SIMD3<Double>) -> (t: Double, uv: SIMD2<Double>)? {
        let local = rotation.inverse.act(rayDirection)
        guard local.z < 0 else { return nil }
        let t = -distance / local.z
        guard t > 0 else { return nil }
        let p = t * local
        let x = p.x / (width / 2)
        let y = p.y / (height / 2)
        guard abs(x) <= 1, abs(y) <= 1 else { return nil }
        return (t, SIMD2((x + 1) / 2, (1 - y) / 2))
    }
}
