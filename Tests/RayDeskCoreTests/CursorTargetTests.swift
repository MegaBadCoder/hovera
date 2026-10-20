import Testing
import simd
@testable import RayDeskCore

private let degree = Double.pi / 180
private let panel = ScreenPose(yaw: 0, pitch: 0, distance: 1.5, width: 1.0, aspect: 16.0 / 9.0)
private let lookingDown = yawPitchQuat(yaw: 0, pitch: -35 * degree)

@Test func gazeOnPanelTargetsPanel() throws {
    let hit = try #require(cursorHit(head: yawPitchQuat(yaw: 0, pitch: 10 * degree), screens: [panel]))
    #expect(hit.target == .virtual(0))
}

@Test func gazeOnTheLowerPartOfAPanelStillTargetsThePanel() throws {
    let hit = try #require(cursorHit(head: yawPitchQuat(yaw: 0, pitch: -9 * degree), screens: [panel]))
    #expect(hit.target == .virtual(0))
}

@Test func lookingFarDownOffThePanelsMeansMac() throws {
    let hit = try #require(cursorHit(head: lookingDown, screens: [panel]))
    #expect(hit.target == .mac)
    #expect(hit.uv == SIMD2(0.5, 0.5))
}

@Test func lookingDownAtAPanelDoesNotLeaveIt() {
    let low = ScreenPose(yaw: 0, pitch: -35 * degree, distance: 1.5, width: 1.0, aspect: 16.0 / 9.0)
    let hit = cursorHit(head: lookingDown, screens: [low])
    #expect(hit?.target == .virtual(0))
}

@Test func lookingSidewaysHitsNothing() {
    #expect(cursorHit(head: yawPitchQuat(yaw: 90 * degree, pitch: 0), screens: [panel]) == nil)
}

@Test func nearestPanelWinsWhenTheyOverlap() throws {
    let near = ScreenPose(yaw: 0, pitch: 0, distance: 1.0, width: 2.0, aspect: 16.0 / 9.0)
    let far = ScreenPose(yaw: 0, pitch: 0, distance: 2.0, width: 2.0, aspect: 16.0 / 9.0)
    let hit = try #require(cursorHit(head: yawPitchQuat(yaw: 0, pitch: 0), screens: [far, near]))
    #expect(hit.target == .virtual(1))
}
