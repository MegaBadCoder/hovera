import Foundation
import simd

/// Куда может попасть курсор: виртуальная панель по индексу или встроенный экран Mac.
public enum CursorTarget: Hashable, Codable, Sendable {
    case virtual(Int)
    case mac
}

/// Цель курсора под взглядом и точка на ней (u вправо, v вниз, [0,1]²).
public struct CursorHit: Equatable {
    public var target: CursorTarget
    public var uv: SIMD2<Double>

    public init(target: CursorTarget, uv: SIMD2<Double>) {
        self.target = target
        self.uv = uv
    }
}

/// Где в пространстве стоит экран MacBook, запомненный по взгляду пользователя.
public struct MacAnchor: Codable, Equatable, Sendable {
    public var pose: ScreenPose

    public init(pose: ScreenPose) {
        self.pose = pose
    }

    /// Якорь в направлении взгляда: экран ноутбука на расстоянии 0,5 м, шириной 0,3 м.
    ///
    /// - Parameters:
    ///   - head: ориентация головы в момент, когда пользователь смотрит на центр экрана Mac.
    ///   - aspect: соотношение ширины к высоте экрана Mac.
    public static func captured(head: simd_quatd, aspect: Double) -> MacAnchor {
        let gaze = head.yawPitch
        return MacAnchor(pose: ScreenPose(yaw: gaze.yaw, pitch: gaze.pitch, distance: 0.5, width: 0.3, aspect: aspect))
    }
}

/// Цель курсора под взглядом: ближайшая по лучу панель или якорь Mac.
///
/// Без якоря взгляд ниже `lookDownPitch`, не попавший ни в одну панель, считается
/// взглядом в центр экрана Mac.
///
/// - Parameters:
///   - head: ориентация головы голова→мир.
///   - screens: позы виртуальных панелей, индекс — номер панели.
///   - mac: якорь экрана Mac или `nil`, если он не задан.
///   - lookDownPitch: порог наклона взгляда вниз для случая без якоря, радианы.
public func cursorHit(head: simd_quatd, screens: [ScreenPose], mac: MacAnchor?, lookDownPitch: Double = -30 * .pi / 180) -> CursorHit? {
    let direction = head.act(SIMD3(0, 0, -1))
    var best: (t: Double, hit: CursorHit)?
    for (index, pose) in screens.enumerated() {
        if let hit = pose.intersect(rayDirection: direction), hit.t < best?.t ?? .infinity {
            best = (hit.t, CursorHit(target: .virtual(index), uv: hit.uv))
        }
    }
    if let mac, let hit = mac.pose.intersect(rayDirection: direction), hit.t < best?.t ?? .infinity {
        best = (hit.t, CursorHit(target: .mac, uv: hit.uv))
    }
    if let best { return best.hit }
    if mac == nil, head.yawPitch.pitch < lookDownPitch {
        return CursorHit(target: .mac, uv: SIMD2(0.5, 0.5))
    }
    return nil
}
