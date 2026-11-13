import Foundation

/// Хранит ограниченное окно времён CPU, GPU и представления с сопоставлением по идентификатору кадра.
public final class FrameTimeline: @unchecked Sendable {
    private struct Row {
        let id: Int
        let cpuStart: Double
        let committed: Double
        let sourceTime: Double?
        let synchronized: Bool?
        var gpuStart: Double?
        var gpuEnd: Double?
        var presented: Double?
    }

    private let lock = NSLock()
    private var rows: [Row?]
    private var sequence = 0
    /// Процентили 95 за сохранённое окно; отсутствующие измерения представлены `nil`.
    public struct Summary: Sendable {
        /// Число кадров, для которых получено время исполнения GPU.
        public var frames = 0
        /// Подготовка CPU до commit, мс.
        public var cpuMillisecondsP95: Double?
        /// Ожидание от commit до начала GPU, мс.
        public var gpuQueueMillisecondsP95: Double?
        /// Исполнение команды GPU, мс.
        public var gpuMillisecondsP95: Double?
        /// Ожидание от конца GPU до представления, мс.
        public var presentWaitMillisecondsP95: Double?
        /// Возраст исходной позы на входе CPU, мс.
        public var sourceAgeMillisecondsP95: Double?
    }

    /// Создаёт окно положительной ёмкости в кадрах; старые идентификаторы после вытеснения игнорируются.
    public init(capacity: Int) {
        precondition(capacity > 0)
        rows = Array(repeating: nil, count: capacity)
    }

    /// Регистрирует кадр и возвращает его идентификатор; все времена — монотонные секунды.
    public func begin(cpuStart: Double, committed: Double, sourceTime: Double?, synchronized: Bool?) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = sequence
        sequence += 1
        rows[id % rows.count] = Row(id: id, cpuStart: cpuStart, committed: committed,
                                    sourceTime: sourceTime, synchronized: synchronized)
        return id
    }

    /// Добавляет монотонные секунды начала и конца GPU для ранее зарегистрированного кадра.
    public func completed(_ frame: Int, gpuStart: Double, gpuEnd: Double) {
        guard frame >= 0, gpuStart.isFinite, gpuEnd.isFinite, gpuStart > 0, gpuEnd >= gpuStart else { return }
        lock.lock()
        defer { lock.unlock() }
        let index = frame % rows.count
        guard let row = rows[index], row.id == frame,
              row.cpuStart.isFinite, row.committed.isFinite,
              row.committed >= row.cpuStart, gpuStart >= row.committed else { return }
        rows[index]?.gpuStart = gpuStart
        rows[index]?.gpuEnd = gpuEnd
    }

    /// Добавляет фактическое представление; нулевое или нечисловое время не учитывается.
    public func presented(_ frame: Int, at time: Double) {
        guard frame >= 0, time.isFinite, time > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        let index = frame % rows.count
        guard rows[index]?.id == frame else { return }
        rows[index]?.presented = time
    }

    /// Возвращает сводку окна по выбранному VSync; `nil` объединяет режимы.
    public func summary(synchronized: Bool?) -> Summary {
        lock.lock()
        let snapshot = rows
        lock.unlock()
        let valid = snapshot.compactMap { $0 }.filter {
            $0.gpuStart != nil && $0.gpuEnd != nil && (synchronized == nil || $0.synchronized == synchronized)
        }
        var result = Summary()
        result.frames = valid.count
        result.cpuMillisecondsP95 = percentile(valid.map { $0.committed - $0.cpuStart })
        result.gpuQueueMillisecondsP95 = percentile(valid.compactMap { row in row.gpuStart.map { $0 - row.committed } })
        result.gpuMillisecondsP95 = percentile(valid.compactMap { row in
            guard let start = row.gpuStart, let end = row.gpuEnd else { return nil }
            return end - start
        })
        result.presentWaitMillisecondsP95 = percentile(valid.compactMap { row in
            guard let end = row.gpuEnd, let presented = row.presented, presented >= end else { return nil }
            return presented - end
        })
        result.sourceAgeMillisecondsP95 = percentile(valid.compactMap { row in
            guard let source = row.sourceTime, source.isFinite else { return nil }
            return row.cpuStart - source
        })
        return result
    }

    private func percentile(_ values: [Double]) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        return sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)] * 1000
    }
}
