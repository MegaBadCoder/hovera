import Foundation
import simd

/// Связь осей мира гироскопа с осями кадра камеры (x вправо, y вниз, z от камеры): поворот `W`,
/// при котором поворот головы, видимый камерой, равен `W · (поворот по гироскопу) · Wᵀ`.
///
/// Учится на ходу по парам «поворот головы по модели лица — поворот по гироскопу» между кадрами,
/// пока лицо видно. Нужны повороты хотя бы вокруг двух разных осей, например влево-вправо и вверх-вниз.
public struct CameraAlignment: Sendable {
    /// Поворот из осей мира в оси камеры; `nil`, пока пар мало или они не сходятся.
    public private(set) var rotation: simd_double3x3?
    /// Среднеквадратичное расхождение пар с найденным поворотом: угол поворота, радианы.
    public private(set) var residual = Double.nan
    /// Сколько пар накоплено.
    public var pairCount: Int { pairs.count }
    private var anchor: (face: simd_quatd, imu: simd_quatd)?
    private var pairs: [(camera: SIMD3<Double>, world: SIMD3<Double>)] = []
    static let minStep = 15 * Double.pi / 180
    static let maxPairs = 150
    static let minPairs = 6
    static let maxResidual = 8 * Double.pi / 180
    static let maxMismatch = 8 * Double.pi / 180

    public init() {}

    /// Добавляет кадр, где видно лицо.
    ///
    /// - Parameters:
    ///   - face: поворот головы по модели лица в осях камеры (относительно любой постоянной опоры).
    ///   - imu: ориентация очков по гироскопу в мире в момент съёмки кадра.
    public mutating func add(face: simd_double3x3, imu: simd_quatd) {
        let faceQuaternion = simd_quatd(face)
        guard let anchor else {
            self.anchor = (faceQuaternion, imu)
            return
        }
        let camera = Self.rotationVector(faceQuaternion * anchor.face.inverse)
        let world = Self.rotationVector(imu * anchor.imu.inverse)
        let angle = max(simd_length(camera), simd_length(world))
        guard angle >= Self.minStep else { return }
        self.anchor = (faceQuaternion, imu)
        guard abs(simd_length(camera) - simd_length(world)) <= Self.maxMismatch else { return }
        pairs.append((camera, world))
        if pairs.count > Self.maxPairs { pairs.removeFirst(pairs.count - Self.maxPairs) }
        solve()
    }

    /// Мир повернули на `angle` радиан вокруг вертикали (⌃⌥R или поправка курса): связь поворачивается следом.
    public mutating func worldYawChanged(by angle: Double) {
        let turn = simd_quatd(angle: angle, axis: SIMD3(0, 1, 0))
        pairs = pairs.map { ($0.camera, turn.act($0.world)) }
        anchor = anchor.map { ($0.face, turn * $0.imu) }
        rotation = rotation.map { $0 * simd_double3x3(turn.inverse) }
    }

    /// Поворот головы в осях камеры сейчас, если в момент `anchorIMU` он был `anchorFace`.
    ///
    /// - Returns: `nil`, пока связь не выучена.
    public func predict(anchorFace: simd_double3x3, anchorIMU: simd_quatd, imu: simd_quatd) -> simd_double3x3? {
        guard let rotation else { return nil }
        return rotation * simd_double3x3(imu * anchorIMU.inverse) * rotation.transpose * anchorFace
    }

    private mutating func solve() {
        guard pairs.count >= Self.minPairs, Self.spansTwoAxes(pairs.map(\.world)) else { return }
        let found = bestRotation(from: pairs.map(\.world), to: pairs.map(\.camera))
        let errors = pairs.map { simd_length_squared(found * $0.world - $0.camera) }
        residual = sqrt(errors.reduce(0, +) / Double(errors.count))
        rotation = residual <= Self.maxResidual ? found : nil
    }

    private static func spansTwoAxes(_ vectors: [SIMD3<Double>]) -> Bool {
        let axes = vectors.map { simd_normalize($0) }
        for i in axes.indices {
            for j in axes.indices where j > i && simd_length(simd_cross(axes[i], axes[j])) > 0.5 {
                return true
            }
        }
        return false
    }

    static func rotationVector(_ q: simd_quatd) -> SIMD3<Double> {
        let q = q.real < 0 ? simd_quatd(real: -q.real, imag: -q.imag) : q
        let sine = simd_length(q.imag)
        guard sine > 1e-12 else { return .zero }
        return q.imag / sine * 2 * atan2(sine, q.real)
    }
}

/// Поворот, лучше всего переводящий векторы `from` в `to` (без сдвига и масштаба), метод Хорна.
public func bestRotation(from: [SIMD3<Double>], to: [SIMD3<Double>]) -> simd_double3x3 {
    var s = simd_double3x3()
    for (a, b) in zip(from, to) {
        s += simd_double3x3(columns: (a * b.x, a * b.y, a * b.z))
    }
    return hornRotation(s, previous: nil).matrix
}

func hornRotation(_ s: simd_double3x3, previous: SIMD4<Double>?) -> (matrix: simd_double3x3, quaternion: SIMD4<Double>) {
    func m(_ r: Int, _ c: Int) -> Double { s[c][r] }
    let (xx, xy, xz) = (m(0, 0), m(0, 1), m(0, 2))
    let (yx, yy, yz) = (m(1, 0), m(1, 1), m(1, 2))
    let (zx, zy, zz) = (m(2, 0), m(2, 1), m(2, 2))
    let matrix = simd_double4x4(rows: [
        SIMD4(xx + yy + zz, yz - zy, zx - xz, xy - yx),
        SIMD4(yz - zy, xx - yy - zz, xy + yx, zx + xz),
        SIMD4(zx - xz, xy + yx, -xx + yy - zz, yz + zy),
        SIMD4(xy - yx, zx + xz, yz + zy, -xx - yy + zz),
    ])
    var shift = 0.0
    for c in 0..<4 { shift += simd_length_squared(matrix[c]) }
    shift = sqrt(shift)
    var v = previous ?? SIMD4(1, 0, 0, 0)
    for _ in 0..<60 {
        v = simd_normalize(matrix * v + shift * v)
    }
    let (w, x, y, z) = (v.x, v.y, v.z, v.w)
    let rotation = simd_double3x3(rows: [
        SIMD3(1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)),
        SIMD3(2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)),
        SIMD3(2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)),
    ])
    return (rotation, v)
}

/// Поворот головы относительно направления на камеру по повороту в осях кадра камеры.
///
/// - Parameter rotation: поворот головы от положения «лицом к камере» в осях кадра (x вправо, y вниз, z от камеры).
/// - Returns: радианы; yaw плюс — влево от пользователя, pitch плюс — вверх.
public func headTurn(fromCameraRotation rotation: simd_double3x3) -> SIMD2<Double> {
    let forward = rotation * SIMD3(0, 0, -1)
    return SIMD2(atan2(forward.x, -forward.z), atan2(-forward.y, hypot(forward.x, forward.z)))
}

/// Поправка уплывания курса по камере: камера стоит на месте и видит настоящий поворот головы, поэтому
/// «направление на камеру + поворот головы по камере» — это курс, каким он должен быть по гироскопу.
/// Мир доворачивается к нему плавно, не быстрее `maxRate`.
public struct CameraYawCorrector: Sendable {
    /// Во сколько раз в секунду сокращается расхождение.
    public var gain = 2.0
    /// Наибольшая скорость доворота в покое, рад/с.
    public var maxRate = 1 * Double.pi / 180
    /// Какую долю скорости поворота головы можно добавить к довороту: пока голова движется, поворот мира не заметен.
    public var motionShare = 0.15
    /// Дальше этого поворота головы от камеры модель лица менее точна, поправки нет, радианы.
    public var maxTurn = 25 * Double.pi / 180
    /// Доля нового кадра в сглаженном расхождении.
    public var smoothing = 0.1
    /// Как быстро учится постоянная скорость уплывания, доля расхождения в секунду за секунду.
    public var rateGain = 0.03
    /// Скорость уплывания учится только на расхождениях меньше этого, радианы: крупные — это переходы после поворотов.
    public var rateLearningBelow = 3 * Double.pi / 180
    /// Предел выученной скорости уплывания, рад/с.
    public var maxDriftRate = 1.5 * Double.pi / 180
    /// Сглаженное расхождение курса по гироскопу с курсом по камере, радианы; `nil` до первого кадра.
    public private(set) var drift: Double?
    /// Выученная постоянная скорость уплывания курса по гироскопу, рад/с, плюс — влево.
    public private(set) var driftRate = 0.0

    public init() {}

    /// Забывает накопленное расхождение; выученная скорость уплывания остаётся.
    public mutating func reset() {
        drift = nil
    }

    /// Кадр без лица: мир доворачивается только на выученную скорость уплывания.
    ///
    /// - Parameter dt: время с прошлого кадра, секунды.
    /// - Returns: на сколько довернуть мир вокруг вертикали, радианы.
    public mutating func coast(dt: Double) -> Double {
        guard dt > 0 else { return 0 }
        drift = drift.map { $0 - driftRate * dt }
        return -driftRate * dt
    }

    /// Один кадр камеры.
    ///
    /// - Parameters:
    ///   - headYaw: курс головы по гироскопу в момент кадра, радианы, плюс — влево.
    ///   - cameraYaw: где камера в мире, радианы.
    ///   - faceTurn: поворот головы от камеры по модели лица, радианы: x — влево, y — вверх.
    ///   - dt: время с прошлого кадра, секунды.
    ///   - headSpeed: скорость поворота головы, рад/с.
    /// - Returns: на сколько довернуть мир вокруг вертикали, радианы (плюс — влево); ноль, если голова
    ///   отвёрнута от камеры сильнее `maxTurn`.
    public mutating func step(headYaw: Double, cameraYaw: Double, faceTurn: SIMD2<Double>, dt: Double,
                              headSpeed: Double = 0) -> Double {
        guard abs(faceTurn.x) < maxTurn, abs(faceTurn.y) < maxTurn, dt > 0 else { return 0 }
        let measured = remainder(headYaw - (cameraYaw + faceTurn.x), 2 * .pi)
        let smoothed = drift.map { $0 + remainder(measured - $0, 2 * .pi) * smoothing } ?? measured
        if abs(smoothed) < rateLearningBelow {
            driftRate = max(-maxDriftRate, min(maxDriftRate, driftRate + rateGain * smoothed * dt))
        }
        let limit = maxRate + motionShare * abs(headSpeed)
        let rotation = -(driftRate + max(-limit, min(limit, gain * smoothed))) * dt
        drift = smoothed + rotation
        return rotation
    }
}
