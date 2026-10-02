import simd

/// Положение головы для отрисовки из шумной и запаздывающей оценки камеры.
///
/// Пока голова поворачивается или кивает, положение стоит на месте: сдвиг глаз от поворота
/// даёт гироскоп, а камера в движении ошибается. Когда голова успокоилась на `settleTime`,
/// положение сравнивается со средним за это время; если оно ушло дальше `band` хотя бы по
/// одной оси и замеры согласны между собой, положение плавно переезжает туда с постоянной времени `glideTime` и снова
/// замирает, подойдя ближе `settledShare` от `band`. Шум глубины меньше `band` до экранов не доходит.
public struct SettledPosition: Sendable {
    /// Насколько по осям должно сместиться положение, чтобы экраны за ним поехали, метры.
    public var band = SIMD3<Double>(0.01, 0.01, 0.03)
    /// Угловая скорость головы, выше которой положение не трогается, рад/с.
    public var stillSpeed = 20 * Double.pi / 180
    /// Сколько голова должна быть спокойна, прежде чем положению верят, секунды.
    public var settleTime = 0.35
    /// Постоянная времени переезда к новому положению, секунды.
    public var glideTime = 0.4
    /// Доля `band`, подойдя ближе которой переезд заканчивается.
    public var settledShare = 0.15
    /// Насколько, в долях `band`, замеры за время покоя могут расходиться со своим средним;
    /// при большем разбросе голова на самом деле не стоит, и положение не трогается.
    public static let maxSpread = 0.6

    /// Текущее положение для отрисовки; `nil` до первого замера.
    public private(set) var value: SIMD3<Double>?
    private var gliding = false
    private var stillSince: Double?
    private var samples: [(time: Double, position: SIMD3<Double>)] = []
    private var lastTime: Double?

    public init() {}

    /// Добавляет замер камеры и возвращает положение для отрисовки.
    ///
    /// - Parameters:
    ///   - position: положение по камере, метры.
    ///   - time: время кадра, секунды.
    ///   - headSpeed: угловая скорость головы по гироскопу в момент кадра, рад/с.
    public mutating func add(_ position: SIMD3<Double>, time: Double, headSpeed: Double) -> SIMD3<Double> {
        defer { lastTime = time }
        guard var current = value else {
            value = position
            return position
        }
        guard headSpeed < stillSpeed else {
            interrupt()
            return current
        }
        stillSince = stillSince ?? time
        samples.append((time, position))
        samples.removeAll { $0.time < time - settleTime }
        guard let stillSince, time - stillSince >= settleTime else { return current }
        let target = samples.map(\.position).reduce(.zero, +) / Double(samples.count)
        let spread = samples.map { (abs($0.position - target) / band).max() }.max() ?? 0
        guard spread < Self.maxSpread else { return current }
        let excess = (abs(target - current) / band).max()
        if excess > 1 { gliding = true }
        if gliding {
            let dt = min(max(time - (lastTime ?? time), 0), 0.1)
            current += (target - current) * (1 - exp(-dt / glideTime))
            value = current
            if excess < settledShare { gliding = false }
        }
        return current
    }

    /// Замеры прервались, например голова отвернулась от камеры: покой начнётся заново.
    public mutating func interrupt() {
        stillSince = nil
        samples.removeAll()
    }

    /// Ставит положение в `position` без переезда, например на новую опору; `nil` — забыть совсем.
    public mutating func reset(to position: SIMD3<Double>? = nil) {
        value = position
        gliding = false
        interrupt()
    }
}
