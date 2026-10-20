import Foundation
import simd

/// Прямоугольная область уменьшенного кадра, пиксели; начало координат сверху слева.
public struct MotionRegion: Sendable, Equatable {
    public var minX: Int
    public var minY: Int
    public var maxX: Int
    public var maxY: Int

    public init(minX: Int, minY: Int, maxX: Int, maxY: Int) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }
}

/// Движение самой камеры по картинке: сравнивает уменьшенные кадры и ищет общий сдвиг фона.
///
/// Пока поворачивается голова, камера стоит на месте, и фон комнаты в кадре не меняется —
/// сдвиг нулевой. Когда едет ноутбук с камерой, сдвигается весь фон, и это видно по картинке,
/// а не только по лицу: модель лица в такой момент ошибается, потому что камера врёт про своё
/// положение. Сравнение идёт по яркости, поэтому автоподстройка экспозиции кадр не сдвигает;
/// область лица исключается — иначе поворот головы выглядел бы сдвигом.
///
/// Кадры — уменьшенная картинка `width × height` в оттенках серого, по строкам. Разрешение
/// выбрано так, чтобы одному градусу поворота камеры соответствовал примерно один пиксель.
public struct CameraMotionDetector {
    /// Ширина уменьшенного кадра, пиксели.
    public static let width = 160
    /// Высота уменьшенного кадра, пиксели.
    public static let height = 90
    /// Насколько далеко искать сдвиг между кадрами, пиксели уменьшенного кадра.
    public static let search = 6

    /// Наименьший сдвиг, который считается движением камеры, пиксели. Один пиксель — это около
    /// 0,6° поворота камеры, и поворот головы у края лица легко даёт такой же сдвиг фона.
    public var minimumShift = 2
    /// Наименьший выигрыш средней яркости по сравнению с нулевым сдвигом: без него шум,
    /// смена экспозиции и поворот головы давали бы случайный сдвиг.
    public var minimumImprovement = 2.5

    /// Последний найденный сдвиг фона, пиксели уменьшенного кадра: x вправо, y вниз.
    public private(set) var shift = SIMD2<Int>(repeating: 0)
    /// Насколько сдвиг объясняет картинку лучше, чем отсутствие сдвига, единицы яркости.
    public private(set) var improvement = 0.0
    /// Средняя разница кадров без сдвига, единицы яркости.
    public private(set) var stillDifference = 0.0

    private var previous: [UInt8]?
    private var previousExclusion: MotionRegion?

    public init() {}

    /// Принимает очередной уменьшенный кадр и сообщает, двигалась ли камера.
    ///
    /// - Parameters:
    ///   - luma: яркость кадра построчно, ровно `width × height` значений.
    ///   - excluding: область кадра, которую не сравнивать, обычно лицо. `nil` — сравнивать всё.
    /// - Returns: `true`, если найдённый сдвиг фона достаточно велик и объясняет разницу кадров.
    public mutating func update(luma: [UInt8], excluding: MotionRegion? = nil) -> Bool {
        precondition(luma.count == Self.width * Self.height)
        guard let oldFrame = previous else {
            previous = luma
            return false
        }
        defer { previous = luma }

        let width = Self.width, height = Self.height
        let margin = Self.search + 1
        // Маска лица между кадрами переезжает: если сравнить старый кадр с новой маской,
        // уехавшее лицо попадёт в выборку и будет выглядеть движением всего фона.
        let exclusions = [previousExclusion, excluding].compactMap { $0 }
        defer { previousExclusion = excluding }
        var indices: [Int] = []
        indices.reserveCapacity((width - 2 * margin) * (height - 2 * margin))
        for y in margin..<(height - margin) {
            for x in margin..<(width - margin) {
                if exclusions.contains(where: { x >= $0.minX && x < $0.maxX && y >= $0.minY && y < $0.maxY }) { continue }
                indices.append(y * width + x)
            }
        }
        guard indices.count > width * height / 4 else { return false }

        var bestError = Int.max
        var bestShift = SIMD2<Int>(repeating: 0)
        var zeroError = 0

        oldFrame.withUnsafeBufferPointer { old in
            luma.withUnsafeBufferPointer { new in
                indices.withUnsafeBufferPointer { pixels in
                    for dy in -Self.search...Self.search {
                        for dx in -Self.search...Self.search {
                            var sum = 0
                            let offset = dy * width + dx
                            for index in pixels {
                                sum += abs(Int(old[index + offset]) - Int(new[index]))
                            }
                            if dx == 0, dy == 0 { zeroError = sum }
                            if sum < bestError {
                                bestError = sum
                                bestShift = SIMD2(dx, dy)
                            }
                        }
                    }
                }
            }
        }

        let samples = Double(indices.count)
        let best = Double(bestError) / samples
        let still = Double(zeroError) / samples
        shift = bestShift
        improvement = still - best
        stillDifference = still
        let magnitude = max(abs(bestShift.x), abs(bestShift.y))
        return magnitude >= minimumShift && improvement >= minimumImprovement
    }

    /// Забывает предыдущий кадр: следующее сравнение будет с новым кадром.
    public mutating func reset() {
        previous = nil
        previousExclusion = nil
        shift = .zero
        improvement = 0
        stillDifference = 0
    }
}
