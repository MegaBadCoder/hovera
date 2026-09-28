import Foundation
import simd

private let maxPitch = 80 * Double.pi / 180
private let minDistance = 0.4
private let maxDistance = 6.0
private let minWidth = 0.2
private let maxWidth = 5.0
private let defaultGap = 2 * Double.pi / 180

private func wrap(_ angle: Double) -> Double {
    atan2(sin(angle), cos(angle))
}

/// Пространственная сцена: позы виртуальных экранов вокруг головы, не более `maxScreens`.
public final class SpatialScene {
    public let maxScreens = 4
    public private(set) var screens: [ScreenPose]
    public private(set) var grabbed: Int?
    private var grabOffset = (yaw: 0.0, pitch: 0.0)

    public init(screens: [ScreenPose]) {
        precondition((1...4).contains(screens.count), "количество экранов должно быть от 1 до 4")
        self.screens = screens
    }

    /// Раскладка по умолчанию: `count` экранов дистанцией 1.5 м и шириной 1 м,
    /// расположенных в ряд по центру взгляда с зазором 2° между угловыми краями.
    public static func defaultLayout(count: Int, aspect: Double) -> [ScreenPose] {
        let distance = 1.5
        let width = 1.0
        let angularWidth = 2 * atan(width / 2 / distance)
        let leftEdge = (Double(count) * angularWidth + Double(count - 1) * defaultGap) / 2
        return (0..<count).map { index in
            let yaw = leftEdge - angularWidth / 2 - Double(index) * (angularWidth + defaultGap)
            return ScreenPose(yaw: yaw, pitch: 0, distance: distance, width: width, aspect: aspect)
        }
    }

    /// Добавляет экран в направлении взгляда, копируя дистанцию/ширину/aspect последнего экрана.
    ///
    /// - Returns: `false`, если уже достигнут `maxScreens`.
    @discardableResult
    public func addScreen(head: simd_quatd) -> Bool {
        guard screens.count < maxScreens else { return false }
        let gaze = head.yawPitch
        let last = screens[screens.count - 1]
        screens.append(ScreenPose(yaw: gaze.yaw, pitch: gaze.pitch, distance: last.distance, width: last.width, aspect: last.aspect))
        return true
    }

    /// Удаляет последний экран.
    ///
    /// - Returns: `false`, если остался только один экран.
    @discardableResult
    public func removeLastScreen() -> Bool {
        guard screens.count > 1 else { return false }
        let removedIndex = screens.count - 1
        screens.removeLast()
        if grabbed == removedIndex {
            grabbed = nil
        }
        return true
    }

    /// Ставит экран `index` в направлении взгляда.
    public func place(_ index: Int, head: simd_quatd) {
        let gaze = head.yawPitch
        screens[index].yaw = gaze.yaw
        screens[index].pitch = gaze.pitch
    }

    /// Захватывает или отпускает экран `index` под текущим взглядом.
    public func toggleGrab(_ index: Int, head: simd_quatd) {
        if grabbed == index {
            grabbed = nil
            return
        }
        let gaze = head.yawPitch
        grabOffset = (wrap(screens[index].yaw - gaze.yaw), screens[index].pitch - gaze.pitch)
        grabbed = index
    }

    /// Обновляет позу захваченного экрана по текущему взгляду.
    public func tick(head: simd_quatd) {
        guard let grabbed else { return }
        let gaze = head.yawPitch
        screens[grabbed].yaw = gaze.yaw + grabOffset.yaw
        screens[grabbed].pitch = min(maxPitch, max(-maxPitch, gaze.pitch + grabOffset.pitch))
    }

    /// Выстраивает все экраны в ряд по центру взгляда, как в `defaultLayout`, сохраняя
    /// их количество, дистанцию, ширину и соотношение сторон. Отпускает захваченный экран.
    public func gatherInFront(head: simd_quatd) {
        let gaze = head.yawPitch
        let layout = SpatialScene.defaultLayout(count: screens.count, aspect: screens[0].aspect)
        for index in screens.indices {
            screens[index].yaw = gaze.yaw + layout[index].yaw
            screens[index].pitch = gaze.pitch
            screens[index].distance = layout[index].distance
            screens[index].width = layout[index].width
        }
        grabbed = nil
    }

    /// Ставит все экраны дугой вплотную друг к другу вокруг направления взгляда, сохраняя их
    /// порядок слева направо и ширину. Расстояние у всех — медиана текущих, высота — как у
    /// взгляда, наклон снимается. Отпускает захваченный экран.
    public func arrangeInArc(head: simd_quatd) {
        let gaze = head.yawPitch
        let distances = screens.map(\.distance).sorted()
        let distance = distances[distances.count / 2]
        let order = screens.indices.sorted { wrap(screens[$0].yaw - gaze.yaw) > wrap(screens[$1].yaw - gaze.yaw) }
        for index in screens.indices {
            screens[index].distance = distance
            screens[index].pitch = gaze.pitch
            screens[index].tilt = 0
        }
        let halves = order.map { horizontalHalfAngle(screens[$0]) }
        var edge = gaze.yaw + halves.reduce(0, +)
        for (position, index) in order.enumerated() {
            screens[index].yaw = edge - halves[position]
            edge -= 2 * halves[position]
        }
        grabbed = nil
    }

    /// Изменяет дистанцию экрана `index`, умножая на `factor`, в пределах 0.4…6 м.
    public func adjustDistance(_ index: Int, by factor: Double) {
        screens[index].distance = min(maxDistance, max(minDistance, screens[index].distance * factor))
    }

    /// Изменяет ширину экрана `index`, умножая на `factor`, в пределах 0.2…5 м.
    public func adjustWidth(_ index: Int, by factor: Double) {
        screens[index].width = min(maxWidth, max(minWidth, screens[index].width * factor))
    }

    /// Напрямую заменяет позу экрана `index` (используется при перетаскивании мышью в приложении).
    public func setPose(_ index: Int, _ pose: ScreenPose) {
        screens[index] = pose
    }

    /// Кодирует позы экранов в JSON.
    public func encoded() -> Data {
        try! JSONEncoder().encode(screens)
    }

    /// Декодирует позы экранов из JSON.
    ///
    /// - Returns: декодированные позы (не более `maxScreens`, лишние отбрасываются), либо
    ///   `defaultLayout(count:aspect:)`, если `data` отсутствует, не декодируется или пуст.
    public static func decode(_ data: Data?, default count: Int, aspect: Double) -> [ScreenPose] {
        guard let data, let decoded = try? JSONDecoder().decode([ScreenPose].self, from: data), !decoded.isEmpty else {
            return defaultLayout(count: count, aspect: aspect)
        }
        return Array(decoded.prefix(4))
    }
}
