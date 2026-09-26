import Testing
import simd
@testable import RayDeskCore

private let degree = Double.pi / 180

@Test func gazeHitPicksClosestScreenAlongRay() {
    let near = ScreenPose(yaw: 0, pitch: 0, distance: 1.0, width: 1.0, aspect: 1.0)
    let far = ScreenPose(yaw: 0, pitch: 0, distance: 2.0, width: 3.0, aspect: 1.0)
    let head = yawPitchQuat(yaw: 0, pitch: 0)
    let hit = gazeHit(head: head, screens: [far, near])
    #expect(hit?.screen == 1)
    #expect(hit != nil)
    if let uv = hit?.uv {
        #expect(abs(uv.x - 0.5) < 1e-6)
        #expect(abs(uv.y - 0.5) < 1e-6)
    }
}

@Test func gazeHitReturnsNilWhenNoScreenIntersects() {
    let pose = ScreenPose(yaw: 90 * degree, pitch: 0, distance: 1.5, width: 0.2, aspect: 1.0)
    let head = yawPitchQuat(yaw: 0, pitch: 0)
    #expect(gazeHit(head: head, screens: [pose]) == nil)
}

@Test func gazeHitReturnsNilForEmptyScreens() {
    let head = yawPitchQuat(yaw: 0, pitch: 0)
    #expect(gazeHit(head: head, screens: []) == nil)
}
