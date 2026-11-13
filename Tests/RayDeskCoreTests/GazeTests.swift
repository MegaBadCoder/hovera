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

@Test func translatedHeadSelectsThePanelActuallyInFrontOfIt() throws {
    let head = yawPitchQuat(yaw: 0, pitch: 0)
    let front = ScreenPose(yaw: 0, pitch: 0, distance: 2, width: 0.6, aspect: 1)
    let side = ScreenPose(center: SIMD3(1, 0, -2), right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0), width: 0.6, aspect: 1)
    let hit = try #require(gazeHit(head: head, screens: [front, side], origin: SIMD3(1, 0, 0)))
    #expect(hit.screen == 1)
    #expect(length(hit.uv - SIMD2(0.5, 0.5)) < 1e-6)
}

@Test func headTranslationChangesHitCoordinatesAndCanLeavePanel() throws {
    let head = yawPitchQuat(yaw: 0, pitch: 0)
    let panel = ScreenPose(yaw: 0, pitch: 0, distance: 2, width: 1, aspect: 1)
    let hit = try #require(gazeHit(head: head, screens: [panel], origin: SIMD3(0.25, 0.2, 0.3)))
    #expect(length(hit.uv - SIMD2(0.75, 0.3)) < 1e-6)
    #expect(gazeHit(head: head, screens: [panel], origin: SIMD3(0.6, 0, 0)) == nil)
    #expect(gazeHit(head: head, screens: [panel], origin: SIMD3(0, 0, -3)) == nil)
}

@Test func translatedHeadSkipsPanelBehindItAndSelectsTheNextOne() throws {
    let head = yawPitchQuat(yaw: 0, pitch: 0)
    let near = ScreenPose(yaw: 0, pitch: 0, distance: 1, width: 1, aspect: 1)
    let far = ScreenPose(yaw: 0, pitch: 0, distance: 2, width: 1, aspect: 1)
    let hit = try #require(gazeHit(head: head, screens: [near, far], origin: SIMD3(0, 0, -1.5)))
    #expect(hit.screen == 1)
    #expect(length(hit.uv - SIMD2(0.5, 0.5)) < 1e-6)
}
