import Foundation
import CoreGraphics
import simd

/// Мастер не меняет рабочую опору до успешной проверки возврата.
public struct GuidedCameraCalibration {
    public enum Mode { case center, turns }
    private let mode: Mode
    public enum Stage: Int { case position, left, middle, right, returning, complete, failed }
    public struct Sample {
        public var time: Double
        public var face: CGRect?
        public var turn: SIMD2<Double>
        public var head: SIMD2<Double>
        public var neck: SIMD3<Double>
        public var speed: Double
        public var quality: Double
        public var latency: Double
        public init(time: Double, face: CGRect?, turn: SIMD2<Double>, head: SIMD2<Double>, neck: SIMD3<Double>, speed: Double, quality: Double, latency: Double) {
            self.time = time; self.face = face; self.turn = turn; self.head = head
            self.neck = neck; self.speed = speed; self.quality = quality; self.latency = latency
        }
    }
    public struct Result {
        public var cameraYaw: Double
        public var cameraPitch: Double
        public var neck: SIMD3<Double>
        public var yawScale: Double
        public var returnError: Double
        public var checkedTurns: Bool = true
    }
    public private(set) var stage = Stage.position
    public private(set) var progress = 0.0
    public private(set) var hint = "Расположите лицо внутри контура и посмотрите в камеру"
    public private(set) var result: Result?
    private var samples: [Sample] = []
    private var origin: Sample?
    private var left: Sample?
    private var scale = 1.0
    private var lastTime: Double?
    private var lastReliableTime: Double?
    private var legStarted: Double?
    private var leftScale = 1.0
    private var leftReturnError = 0.0

    /// Called even when detection produces no sample; never retain a stale side measurement.
    public mutating func checkTimeout(at time: Double) {
        if mode == .center, stage == .complete, let lastTime, time - lastTime > 0.5 {
            stage = .position; result = nil; samples.removeAll(); progress = 0
            hint = "Посмотрите в камеру — обновим положение перед применением"
        }
        guard time.isFinite, stage != .complete, stage != .failed else { return }
        let lost = lastReliableTime.map { time - $0 > 2 } ?? false
        let expired = legStarted.map { time - $0 > 12 } ?? false
        if origin != nil && (lost || expired) {
            origin = nil; left = nil; result = nil; leftScale = 1; leftReturnError = 0
            legStarted = nil; lastReliableTime = nil
            advance(.position)
            hint = "Опора устарела. Вернитесь в центр — заново запомним положение"
        }
    }
    private static let degree = Double.pi / 180
    public init(mode: Mode = .center) { self.mode = mode }

    public mutating func interrupt(_ message: String = "Кадры камеры не поступают. Проверьте камеру") {
        if mode == .center, stage == .complete { stage = .position; result = nil }
        guard stage != .complete, stage != .failed else { return }
        samples.removeAll(); progress = 0; hint = message
    }

    public mutating func invalidate(_ message: String) { result = nil; fail(message) }

    public mutating func update(_ sample: Sample) {
        if mode == .center, stage == .complete {
            stage = .position; result = nil
            samples.removeAll { sample.time - $0.time > 1.1 }
        }
        guard stage != .complete, stage != .failed else { return }
        checkTimeout(at: sample.time)
        defer { lastTime = sample.time }
        if let lastTime, sample.time <= lastTime || sample.time - lastTime > 0.2 { interrupt() }
        guard sample.time.isFinite, sample.turn.x.isFinite, sample.turn.y.isFinite,
              sample.head.x.isFinite, sample.head.y.isFinite,
              sample.neck.x.isFinite, sample.neck.y.isFinite, sample.neck.z.isFinite,
              sample.latency >= 0, sample.latency < 0.2,
              let face = sample.face, sample.quality >= 0.75 else {
            interrupt("Лицо не распознано уверенно. Посмотрите в камеру"); return
        }
        guard face.minX > 0.03, face.maxX < 0.97, face.minY > 0.03, face.maxY < 0.97 else {
            interrupt("Лицо обрезано. Расположитесь ближе к центру кадра"); return
        }
        guard face.width >= 0.12 else { interrupt("Приблизьтесь немного к камере"); return }
        guard abs(sample.turn.y) < 25 * Self.degree else { interrupt("Держите голову ровнее"); return }
        lastReliableTime = sample.time
        let relativeYaw = sample.turn.x - (origin?.turn.x ?? 0)
        switch stage {
        case .position:
            guard abs(sample.turn.x) < 10 * Self.degree,
                  abs(face.midX - 0.5) < 0.2, abs(face.midY - 0.5) < 0.25 else {
                interrupt("Посмотрите прямо в камеру и расположитесь по центру"); return
            }
        case .left:
            guard relativeYaw > 12 * Self.degree, relativeYaw < 24 * Self.degree else {
                interrupt("Медленно поверните голову влево примерно на 15°"); return
            }
        case .right:
            guard relativeYaw < -12 * Self.degree, relativeYaw > -24 * Self.degree else {
                interrupt("Теперь медленно поверните голову вправо примерно на 15°"); return
            }
        case .middle, .returning:
            guard abs(relativeYaw) < 2 * Self.degree,
                  abs(sample.turn.y - origin!.turn.y) < 3 * Self.degree,
                  simd_distance(sample.neck, origin!.neck) < 0.05 else {
                interrupt("Вернитесь в исходное положение и посмотрите в камеру"); return
            }
        default: return
        }
        guard sample.speed.isFinite, sample.speed < 5 * Self.degree else {
            interrupt("Замрите на секунду"); return
        }
        if let first = samples.first,
           abs(remainder(sample.head.x - first.head.x, 2 * .pi)) > 2 * Self.degree ||
           abs(sample.turn.x - first.turn.x) > 2 * Self.degree ||
           abs(sample.turn.y - first.turn.y) > 2 * Self.degree ||
           simd_distance(sample.neck, first.neck) > 0.02 { samples.removeAll() }
        samples.append(sample)
        let duration = stage == .position || stage == .middle || stage == .returning ? 1.0 : 0.5
        progress = min(1, (sample.time - samples[0].time) / duration)
        hint = stage == .position ? "Хорошо. Не двигайтесь — запоминаю положение" : "Хорошо. Удерживайте положение"
        guard progress >= 1, samples.count >= 12 else { return }
        let mean = average()
        switch stage {
        case .position:
            if mode == .center {
                result = Result(cameraYaw: remainder(mean.head.x - mean.turn.x, 2 * .pi),
                                cameraPitch: mean.head.y - mean.turn.y, neck: mean.neck,
                                yawScale: 1, returnError: 0, checkedTurns: false)
                stage = .complete; progress = 1
                hint = "Центр запомнен. Нажмите «Применить» — поворачивать голову не нужно"
                return
            }
            origin = mean; legStarted = sample.time; advance(.left)
        case .left:
            left = mean; advance(.middle)
        case .middle:
            let origin = origin!, left = left!
            let gyro = remainder(left.head.x - origin.head.x, 2 * .pi)
            guard gyro > 8 * Self.degree else {
                fail("Камера и датчик не согласовали поворот. Повторите калибровку"); return
            }
            leftScale = (left.turn.x - origin.turn.x) / gyro
            guard (0.8...1.4).contains(leftScale) else {
                fail("Камера и датчик не согласовали поворот. Повторите калибровку"); return
            }
            let expected = origin.head.x + (mean.turn.x - origin.turn.x) / leftScale
            leftReturnError = abs(remainder(mean.head.x - expected, 2 * .pi))
            guard leftReturnError < 2 * Self.degree else {
                self.origin = nil; self.left = nil; legStarted = nil
                advance(.position)
                hint = "При возврате обнаружено смещение. Снова посмотрите в центр"; return
            }
            // Right turn uses a fresh central IMU measurement, not the start of the left leg.
            self.origin = mean; legStarted = sample.time; advance(.right)
        case .right:
            let origin = origin!
            let gyro = remainder(mean.head.x - origin.head.x, 2 * .pi)
            guard gyro < -8 * Self.degree else {
                fail("Камера и датчик не согласовали поворот. Повторите калибровку"); return
            }
            let rightScale = (mean.turn.x - origin.turn.x) / gyro
            guard (0.8...1.4).contains(rightScale), abs(leftScale - rightScale) < 0.12 else {
                fail("Оценки камеры и датчика разошлись. Повторите калибровку"); return
            }
            scale = (leftScale + rightScale) / 2
            advance(.returning)
        case .returning:
            let origin = origin!
            let expected = origin.head.x + (mean.turn.x - origin.turn.x) / scale
            let error = abs(remainder(mean.head.x - expected, 2 * .pi))
            guard error < 2 * Self.degree else {
                fail("Направление после возврата не совпало. Повторите калибровку"); return
            }
            result = Result(cameraYaw: remainder(mean.head.x - mean.turn.x / scale, 2 * .pi),
                            cameraPitch: mean.head.y - mean.turn.y, neck: mean.neck,
                            yawScale: scale, returnError: max(error, leftReturnError))
            stage = .complete; progress = 1; hint = "Направление после поворотов совпало. Можно применить калибровку"
        default: break
        }
    }
    private mutating func advance(_ next: Stage) {
        stage = next; samples.removeAll(); progress = 0
        hint = next == .left ? "Медленно поверните голову влево примерно на 15°" :
            next == .right ? "Теперь медленно поверните голову вправо примерно на 15°" :
            "Вернитесь в исходное положение и посмотрите в камеру"
    }
    private mutating func fail(_ message: String) { stage = .failed; hint = message; progress = 0; samples.removeAll() }
    private func average() -> Sample {
        var value = samples[0]
        let count = Double(samples.count)
        value.turn = samples.reduce(.zero) { $0 + $1.turn } / count
        value.neck = samples.reduce(.zero) { $0 + $1.neck } / count
        value.head.x += samples.reduce(0) { $0 + remainder($1.head.x - samples[0].head.x, 2 * .pi) } / count
        value.head.y = samples.reduce(0) { $0 + $1.head.y } / count
        return value
    }
}
