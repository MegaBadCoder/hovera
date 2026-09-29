import Foundation
import simd

/// Отменяет самокалибровку нуля гироскопа, которую делает прошивка очков RayNeo.
///
/// Прошивка отдаёт угловую скорость как целое число шагов по 0,035 °/с плюс своё смещение нуля.
/// Когда ей кажется, что очки лежат неподвижно, она вычитает из смещения среднее своих же
/// показаний за последние 1000 отсчётов (2 с) — и это делается и при медленном повороте головы:
/// тогда поворот объявляется нулём, и мир начинает плыть со скоростью до 2–3 °/с, пока прошивка
/// не пересчитает ноль снова. Такое обновление видно по тому, что дробная часть показаний
/// в шагах решётки сменилась сразу у всех осей, а скачок совпадает с минус средним за окно.
/// Восстановитель добавляет скачок обратно, так что на выходе ноль гироскопа постоянный
/// (какой прошивка выставила до подключения); его доучивает `StillnessBiasLearner`.
///
/// На данных без решётки (синтетические, другие очки) ничего не меняет: решётка сначала
/// должна продержаться `lockSamples` отсчётов подряд.
public struct FirmwareZeroRestorer: Sendable {
    /// Шаг решётки показаний гироскопа, рад/с.
    public static let step = 0.035 * Double.pi / 180
    /// Сколько последних отсчётов прошивка усредняет, пересчитывая ноль.
    public static let window = 1000
    /// Сколько отсчётов подряд дробная часть должна стоять, чтобы решётка считалась найденной.
    public static let lockSamples = 20
    /// Смена дробной части, которая считается сменой смещения, в долях шага.
    static let phaseTolerance = 0.02
    /// Сколько осей должны сменить дробную часть одновременно: прошивка сдвигает ноль всех трёх
    /// осей сразу, а у одной оси дробная часть может случайно почти совпасть.
    static let minChangedAxes = 2
    /// Насколько дробная часть скачка может отличаться от минус среднего за окно, в долях шага.
    static let matchTolerance = 0.1

    /// Сколько раз прошивка пересчитала ноль и это было отменено.
    public private(set) var restoredUpdates = 0
    /// Суммарная поправка к показаниям прошивки, рад/с по осям тела: выход = вход − `shift`.
    public private(set) var shift = SIMD3<Double>(repeating: 0)

    private var ring = [SIMD3<Double>](repeating: .zero, count: FirmwareZeroRestorer.window)
    private var ringNext = 0
    private var ringCount = 0
    private var ringSum = SIMD3<Double>(repeating: 0)
    private var lastPhase: SIMD3<Double>?
    private var steadySamples = 0

    public init() {}

    /// Принимает показание гироскопа прошивки и возвращает его с постоянным нулём.
    ///
    /// - Parameter gyro: угловая скорость по осям очков, как её отдала прошивка, рад/с.
    /// - Returns: угловая скорость без пересчётов нуля прошивкой, рад/с.
    public mutating func restore(_ gyro: SIMD3<Double>) -> SIMD3<Double> {
        let phase = Self.phase(of: gyro)
        defer { lastPhase = phase }
        var output = gyro - shift
        push(output)
        guard let lastPhase else { return output }
        let change = Self.wrapped(phase - lastPhase)
        let changedAxes = (0..<3).filter { abs(change[$0]) > Self.phaseTolerance }.count
        guard changedAxes > 0 else {
            steadySamples += 1
            return output
        }
        let locked = steadySamples >= Self.lockSamples
        steadySamples = 0
        guard locked, changedAxes >= Self.minChangedAxes, ringCount == Self.window else { return output }
        let jump = -(ringSum / Double(ringCount) + shift)
        let mismatch = Self.wrapped(jump / Self.step - change)
        guard abs(mismatch).max() < Self.matchTolerance else { return output }
        let snapped = (change + (jump / Self.step - change).rounded(.toNearestOrEven)) * Self.step
        shift += snapped
        output = gyro - shift
        replaceNewest(output)
        restoredUpdates += 1
        return output
    }

    private static func phase(of gyro: SIMD3<Double>) -> SIMD3<Double> {
        wrapped(gyro / step)
    }

    private static func wrapped(_ value: SIMD3<Double>) -> SIMD3<Double> {
        value - value.rounded(.toNearestOrEven)
    }

    private mutating func push(_ value: SIMD3<Double>) {
        if ringCount == Self.window {
            ringSum -= ring[ringNext]
        } else {
            ringCount += 1
        }
        ring[ringNext] = value
        ringSum += value
        ringNext = (ringNext + 1) % Self.window
    }

    private mutating func replaceNewest(_ value: SIMD3<Double>) {
        let newest = (ringNext + Self.window - 1) % Self.window
        ringSum += value - ring[newest]
        ring[newest] = value
    }
}
