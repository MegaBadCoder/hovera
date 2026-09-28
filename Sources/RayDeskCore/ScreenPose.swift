import simd

/// Поза виртуального экрана в пространстве вокруг головы.
///
/// `yaw`/`pitch` — направление на экран относительно взгляда прямо вперёд
/// (радианы, yaw положителен влево, pitch положителен вверх), `distance` —
/// расстояние до экрана (метры), `width` — физическая ширина экрана (метры),
/// `aspect` — отношение ширины к высоте, `tilt` — наклон экрана вокруг его
/// горизонтальной оси через центр (радианы, плюс — верх уходит от зрителя).
public struct ScreenPose: Codable, Equatable, Sendable {
    public var yaw: Double
    public var pitch: Double
    public var distance: Double
    public var width: Double
    public var aspect: Double
    public var tilt: Double

    public init(yaw: Double, pitch: Double, distance: Double, width: Double, aspect: Double, tilt: Double = 0) {
        self.yaw = yaw
        self.pitch = pitch
        self.distance = distance
        self.width = width
        self.aspect = aspect
        self.tilt = tilt
    }

    private enum CodingKeys: String, CodingKey {
        case yaw, pitch, distance, width, aspect, tilt
    }

    /// Читает позу; у раскладок, сохранённых до появления наклона, `tilt` равен 0.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        yaw = try container.decode(Double.self, forKey: .yaw)
        pitch = try container.decode(Double.self, forKey: .pitch)
        distance = try container.decode(Double.self, forKey: .distance)
        width = try container.decode(Double.self, forKey: .width)
        aspect = try container.decode(Double.self, forKey: .aspect)
        tilt = try container.decodeIfPresent(Double.self, forKey: .tilt) ?? 0
    }

    /// Направление на центр экрана относительно головы.
    public var rotation: simd_quatd {
        yawPitchQuat(yaw: yaw, pitch: pitch)
    }

    private var tiltRotation: simd_quatd {
        simd_quatd(angle: -tilt, axis: SIMD3(1, 0, 0))
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
        .rotation(Self.float(rotation)) * .translation(SIMD3(0, 0, Float(-distance)))
            * .rotation(Self.float(tiltRotation)) * .scale(SIMD3(Float(width / 2), Float(height / 2), 1))
    }

    private static func float(_ q: simd_quatd) -> simd_quatf {
        simd_quatf(ix: Float(q.imag.x), iy: Float(q.imag.y), iz: Float(q.imag.z), r: Float(q.real))
    }

    /// Пересечение луча из начала координат (головы) с плоскостью экрана.
    ///
    /// - Parameter rayDirection: направление луча в мировых координатах (не обязательно нормализовано).
    /// - Returns: расстояние вдоль луча и координаты попадания `uv` (u вправо, v вниз, [0,1]²), либо `nil`, если луч не попадает в экран.
    public func intersect(rayDirection: SIMD3<Double>) -> (t: Double, uv: SIMD2<Double>)? {
        let local = rotation.inverse.act(rayDirection)
        let center = SIMD3<Double>(0, 0, -distance)
        let normal = tiltRotation.act(SIMD3(0, 0, 1))
        let facing = dot(local, normal)
        guard facing < 0 else { return nil }
        let t = dot(center, normal) / facing
        guard t > 0 else { return nil }
        let p = tiltRotation.inverse.act(t * local - center)
        let x = p.x / (width / 2)
        let y = p.y / (height / 2)
        guard abs(x) <= 1, abs(y) <= 1 else { return nil }
        return (t, SIMD2((x + 1) / 2, (1 - y) / 2))
    }
}
