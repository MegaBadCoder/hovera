import Foundation
import simd

/// Управляет одиночными пропусками отправки по задержке представления и свежему движению головы.
public final class PresentationFramePacer: @unchecked Sendable {
    /// Диагностика текущего поколения вывода, без изменения ориентации.
    public struct Snapshot: Sendable {
        /// Число поглощённых запросов пропуска.
        public fileprivate(set) var skipped = 0
        /// Последняя задержка представления в периодах обновления; `nil` до измерений.
        public fileprivate(set) var latencyPeriods: Double?
        /// Текущая серия превышений, ограниченная порогом запроса.
        public fileprivate(set) var overStreak = 0
        /// Ожидается ли одиночный пропуск следующей подходящей отправки.
        public fileprivate(set) var drainRequested = false
        /// Разрешает ли последняя оценка движения пропуск.
        public fileprivate(set) var motionEligible = false
    }

    private let refreshPeriod: Double
    private let lock = NSLock()
    private var state = Snapshot()
    private var lastOrientation: simd_quatd?
    private var lastMotionTime: Double?
    private var lastRenderStart: Double?
    private var lastDrainTime: Double?
    private var smoothedSpeed = 0.0
    private static let latencyThresholdPeriods = 2.2
    private static let sustainFrames = 30
    private static let cooldownSeconds = 3.0
    private static let maximumMotionAge = 0.1
    private static let maximumSpeed = 0.35
    private static let maximumSpeedGrowth = 1.05
    private static let speedSmoothing = 0.2

    /// Создаёт политику для положительного конечного периода обновления в секундах.
    public init(refreshPeriod: Double) {
        precondition(refreshPeriod.isFinite && refreshPeriod > 0)
        self.refreshPeriod = refreshPeriod
    }

    /// Возвращает согласованный снимок счётчиков текущего поколения.
    public var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    /// Обновляет разрешение пропуска по исходной ориентации и монотонному времени в секундах.
    /// При недостоверном трекинге отменяет запрос; прогнозная ориентация не изменяется.
    public func updateMotion(_ orientation: simd_quatd, at time: Double, stable: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let norm = simd_length(orientation.vector)
        guard stable, time.isFinite, norm.isFinite, norm > 1e-9 else {
            invalidateMotion()
            return
        }
        let current = simd_quatd(vector: orientation.vector / norm)
        defer {
            lastOrientation = current
            lastMotionTime = time
        }
        guard let previous = lastOrientation, let previousTime = lastMotionTime else { return }
        let dt = time - previousTime
        guard dt > 0.0005, dt < Self.maximumMotionAge else {
            invalidateMotion()
            return
        }
        let delta = current * previous.inverse
        let measured = 2 * atan2(simd_length(delta.imag), abs(delta.real)) / dt
        let prior = smoothedSpeed
        smoothedSpeed += (measured - smoothedSpeed) * Self.speedSmoothing
        state.motionEligible = smoothedSpeed <= prior * Self.maximumSpeedGrowth && smoothedSpeed < Self.maximumSpeed
        if !state.motionEligible { state.drainRequested = false }
    }

    /// Добавляет фактическое представление кадра; все времена заданы в монотонных секундах.
    /// Нулевые, нечисловые и запоздавшие измерения не учитываются.
    public func observe(renderStart: Double, presented: Double, now: Double) {
        guard renderStart.isFinite, presented.isFinite, now.isFinite,
              renderStart >= 0, presented > 0, presented >= renderStart, now >= presented else { return }
        lock.lock()
        defer { lock.unlock() }
        guard lastRenderStart.map({ renderStart > $0 }) ?? true else { return }
        lastRenderStart = renderStart
        let periods = (presented - renderStart) / refreshPeriod
        state.latencyPeriods = periods
        guard periods > Self.latencyThresholdPeriods else {
            clearRequest()
            return
        }
        state.overStreak = min(Self.sustainFrames, state.overStreak + 1)
        guard state.overStreak >= Self.sustainFrames, motionIsCurrent(at: now),
              lastDrainTime.map({ now - $0 > Self.cooldownSeconds }) ?? true else { return }
        state.drainRequested = true
    }

    /// Поглощает не более одного запроса пропуска при свежем разрешённом движении.
    /// Возвращает `true`, если отправку текущего кадра следует пропустить; `time` — монотонные секунды.
    public func consumeDrain(at time: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard motionIsRecent(at: time) else {
            clearRequest()
            return false
        }
        guard state.motionEligible else {
            state.drainRequested = false
            return false
        }
        guard state.drainRequested else { return false }
        clearRequest()
        lastDrainTime = time
        state.skipped += 1
        return true
    }

    private func motionIsCurrent(at time: Double) -> Bool {
        state.motionEligible && motionIsRecent(at: time)
    }

    private func motionIsRecent(at time: Double) -> Bool {
        guard time.isFinite, let lastMotionTime else { return false }
        return time >= lastMotionTime && time - lastMotionTime < Self.maximumMotionAge
    }

    private func clearRequest() {
        state.overStreak = 0
        state.drainRequested = false
    }

    private func invalidateMotion() {
        lastOrientation = nil
        lastMotionTime = nil
        smoothedSpeed = 0
        state.motionEligible = false
        clearRequest()
    }
}
