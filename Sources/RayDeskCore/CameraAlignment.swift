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
    /// Среднеквадратичное расхождение пар с найденным поворотом, радианы. Модель лица завышает углы,
    /// поэтому повороты камеры сначала подгоняются общим множителем в пределах `scaleRange`.
    /// Связь включается при расхождении до `maxResidual` и выключается только выше `dropResidual`.
    public private(set) var residual = Double.nan
    /// Сколько пар накоплено.
    public var pairCount: Int { pairs.count }
    /// Связь взята из прошлого запуска и ещё не выучена заново по этому.
    public private(set) var usesPrior = false
    private var prior: simd_double3x3?
    private var priorYaw = 0.0
    private var anchor: (face: simd_quatd, imu: simd_quatd)?
    private var pairs: [(camera: SIMD3<Double>, world: SIMD3<Double>)] = []
    static let minStep = 15 * Double.pi / 180
    static let maxPairs = 150
    static let minPairs = 6
    static let maxResidual = 8 * Double.pi / 180
    static let dropResidual = 11 * Double.pi / 180
    static let scaleRange = 0.8...1.4
    static let maxMismatch = 8 * Double.pi / 180
    static let mismatchShare = 0.25

    public init() {}

    /// Начинает со связью из прошлого запуска.
    ///
    /// Между запусками мир отсчитывает курс от другого направления, поэтому сохранённая связь верна
    /// с точностью до поворота мира вокруг вертикали. На повороты головы влево-вправо это не влияет,
    /// и связь работает сразу; недостающий угол довыучивается по первому кивку. Если пары с ней
    /// не сходятся (ноутбук передвинули), она отбрасывается и связь учится заново.
    ///
    /// - Parameter prior: поворот из осей мира в оси камеры, сохранённый в прошлый раз.
    public init(prior: simd_double3x3) {
        self.prior = prior
        rotation = prior
        usesPrior = true
    }

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
        guard abs(simd_length(camera) - simd_length(world)) <= Self.maxMismatch + Self.mismatchShare * simd_length(world)
        else { return }
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
        prior = prior.map { $0 * simd_double3x3(turn.inverse) }
    }

    /// Поворот головы в осях камеры сейчас, если в момент `anchorIMU` он был `anchorFace`.
    ///
    /// - Returns: `nil`, пока связь не выучена.
    public func predict(anchorFace: simd_double3x3, anchorIMU: simd_quatd, imu: simd_quatd) -> simd_double3x3? {
        guard let rotation else { return nil }
        return rotation * simd_double3x3(imu * anchorIMU.inverse) * rotation.transpose * anchorFace
    }

    private mutating func solve() {
        guard pairs.count >= Self.minPairs, Self.spansTwoAxes(pairs.map(\.world)) else {
            solveWithPrior()
            return
        }
        let found = bestRotation(from: pairs.map(\.world), to: pairs.map(\.camera))
        residual = rms(found)
        rotation = residual <= (rotation == nil || usesPrior ? Self.maxResidual : Self.dropResidual) ? found : nil
        if rotation != nil {
            usesPrior = false
            prior = nil
        }
    }

    private mutating func solveWithPrior() {
        guard let prior else { return }
        var a = 0.0, b = 0.0, horizontal = 0.0
        for pair in pairs {
            let c = prior.transpose * pair.camera, w = pair.world
            a += c.x * w.x + c.z * w.z
            b += c.x * w.z - c.z * w.x
            horizontal += hypot(w.x, w.z) * hypot(c.x, c.z)
        }
        if horizontal > Self.minStep * Self.minStep { priorYaw = atan2(b, a) }
        let candidate = prior * simd_double3x3(simd_quatd(angle: priorYaw, axis: SIMD3(0, 1, 0)))
        residual = rms(candidate)
        if residual <= Self.maxResidual {
            rotation = candidate
        } else {
            self.prior = nil
            usesPrior = false
            rotation = nil
        }
    }

    private func rms(_ candidate: simd_double3x3) -> Double {
        let rotated = pairs.map { (seen: candidate * $0.world, camera: $0.camera) }
        let overlap = rotated.map { simd_dot($0.seen, $0.camera) }.reduce(0, +)
        let size = rotated.map { simd_length_squared($0.seen) }.reduce(0, +)
        let scale = size > 0 ? min(max(overlap / size, Self.scaleRange.lowerBound), Self.scaleRange.upperBound) : 1
        let errors = rotated.map { simd_length_squared($0.seen * scale - $0.camera) }
        return sqrt(errors.reduce(0, +) / Double(max(errors.count, 1)))
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
    /// Предел скорости доворота, пока голова движется, рад/с.
    public var maxMotionRate = 2 * Double.pi / 180
    /// Дальше этого поворота головы от камеры модель лица менее точна, расхождение не меряется, радианы.
    public var maxTurn = 15 * Double.pi / 180
    /// Быстрее этой скорости головы кадр запаздывает и модель лица ошибается в угле, расхождение
    /// не меряется, а только исправляется уже измеренное, рад/с.
    public var measureSpeed = 10 * Double.pi / 180
    /// Доля нового кадра в сглаженном расхождении.
    public var smoothing = 0.03
    /// Медленнее этой скорости голова считается неподвижной, рад/с: тогда доворот мира заметен глазом.
    public var stillSpeed = 5 * Double.pi / 180
    /// При неподвижной голове расхождение меньше этого считается шумом модели лица, радианы.
    public var stillDeadband = 1.5 * Double.pi / 180
    /// При неподвижной голове: во сколько раз в секунду сокращается расхождение сверх зоны и предел скорости, рад/с.
    public var stillGain = 0.4
    public var stillMaxRate = 0.5 * Double.pi / 180
    /// При неподвижной голове расхождение больше этого уже заметно глазом и исправляется быстрее, радианы.
    public var stillFastFrom = 3 * Double.pi / 180
    /// На сколько рад/с растёт предел скорости в покое на каждый радиан расхождения сверх `stillFastFrom`.
    public var stillFastShare = 0.3
    /// Как быстро учится постоянная скорость уплывания, доля расхождения в секунду за секунду.
    public var rateGain = 0.005
    /// Скорость уплывания учится только на расхождениях меньше этого, радианы: крупные — это переходы после поворотов.
    public var rateLearningBelow = 5 * Double.pi / 180
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
    /// - Returns: на сколько довернуть мир вокруг вертикали, радианы (плюс — влево). Кадры, где голова
    ///   отвёрнута сильнее `maxTurn` или движется быстрее `measureSpeed`, расхождение не меняют: по ним
    ///   мир доворачивается только на уже измеренное.
    public mutating func step(headYaw: Double, cameraYaw: Double, faceTurn: SIMD2<Double>, dt: Double,
                              headSpeed: Double = 0) -> Double {
        guard dt > 0 else { return 0 }
        let measurable = abs(faceTurn.x) < maxTurn && abs(faceTurn.y) < maxTurn && abs(headSpeed) < measureSpeed
        let measured = remainder(headYaw - (cameraYaw + faceTurn.x), 2 * .pi)
        guard let smoothed = measurable ? drift.map({ $0 + remainder(measured - $0, 2 * .pi) * smoothing }) ?? measured : drift
        else { return 0 }
        if measurable, abs(smoothed) < rateLearningBelow {
            driftRate = max(-maxDriftRate, min(maxDriftRate, driftRate + rateGain * smoothed * dt))
        }
        let still = abs(headSpeed) < stillSpeed
        let error = still ? (smoothed > 0 ? 1.0 : -1.0) * max(0, abs(smoothed) - stillDeadband) : smoothed
        let limit = still ? stillMaxRate + stillFastShare * max(0, abs(smoothed) - stillFastFrom)
            : min(maxRate + motionShare * abs(headSpeed), maxMotionRate)
        let correction = max(-limit, min(limit, (still ? stillGain : gain) * error))
        let rotation = -(abs(smoothed) > stillFastFrom ? correction : driftRate + correction) * dt
        drift = smoothed + rotation
        return rotation
    }
}

/// Во сколько раз курс по модели лица больше настоящего поворота головы. Настоящий поворот даёт гироскоп,
/// его масштаб откалиброван на столе. Модель лица обычно завышает курс на 10–20 %, и от сессии к сессии по-разному.
public struct FaceYawScale: Sendable {
    /// Медиана отношений; единица, пока их мало.
    public private(set) var scale = 1.0
    /// Сколько отношений накоплено.
    public var count: Int { ratios.count }
    private var history: [(time: Double, gyro: Double, face: Double)] = []
    private var ratios: [Double] = []
    static let step = 1.0
    static let minTurn = 8 * Double.pi / 180
    static let maxTurn = 40 * Double.pi / 180
    static let maxFaceTurn = 25 * Double.pi / 180
    static let maxRatios = 200
    static let minRatios = 30
    static let range = 0.8...1.4

    public init() {}

    /// Добавляет кадр, где видно лицо.
    ///
    /// - Parameters:
    ///   - time: время кадра, секунды.
    ///   - gyroYaw: курс головы по гироскопу, радианы.
    ///   - faceYaw: поворот головы от камеры по модели лица, радианы.
    public mutating func add(time: Double, gyroYaw: Double, faceYaw: Double) {
        guard abs(faceYaw) < Self.maxFaceTurn else { return }
        history.append((time, gyroYaw, faceYaw))
        while let first = history.first, time - first.time > Self.step {
            history.removeFirst()
            let gyro = remainder(gyroYaw - first.gyro, 2 * .pi), face = faceYaw - first.face
            guard abs(gyro) >= Self.minTurn, abs(gyro) <= Self.maxTurn else { continue }
            ratios.append(face / gyro)
            if ratios.count > Self.maxRatios { ratios.removeFirst() }
            if ratios.count >= Self.minRatios {
                let median = ratios.sorted()[ratios.count / 2]
                scale = min(Self.range.upperBound, max(Self.range.lowerBound, median))
            }
        }
    }
}
