import Foundation
import Testing
import simd
@testable import RayDeskCore

private let degree = Double.pi / 180
private let panel = ScreenPose(yaw: 0, pitch: 10 * degree, distance: 1.5, width: 1.0, aspect: 16.0 / 9.0)
private let lookingDown = yawPitchQuat(yaw: 0, pitch: -35 * degree)

@Test func anchorIsCapturedWhereTheHeadLooks() {
    let anchor = MacAnchor.captured(head: lookingDown, aspect: 1512.0 / 982.0)
    #expect(abs(anchor.pose.pitch - -35 * degree) < 1e-9)
    #expect(abs(anchor.pose.yaw) < 1e-9)
    #expect(anchor.pose.distance == 0.5)
}

@Test func gazeOnAnchorTargetsMacCenter() throws {
    let anchor = MacAnchor.captured(head: lookingDown, aspect: 1512.0 / 982.0)
    let hit = try #require(cursorHit(head: lookingDown, screens: [panel], mac: anchor))
    #expect(hit.target == .mac)
    #expect(abs(hit.uv.x - 0.5) < 1e-6 && abs(hit.uv.y - 0.5) < 1e-6)
}

@Test func gazeOnPanelTargetsPanel() throws {
    let anchor = MacAnchor.captured(head: lookingDown, aspect: 1512.0 / 982.0)
    let hit = try #require(cursorHit(head: yawPitchQuat(yaw: 0, pitch: 10 * degree), screens: [panel], mac: anchor))
    #expect(hit.target == .virtual(0))
}

@Test func nearerSurfaceWinsWhenTheyOverlap() throws {
    let far = ScreenPose(yaw: 0, pitch: -35 * degree, distance: 1.5, width: 1.0, aspect: 16.0 / 9.0)
    let anchor = MacAnchor.captured(head: lookingDown, aspect: 1512.0 / 982.0)
    let hit = try #require(cursorHit(head: lookingDown, screens: [far], mac: anchor))
    #expect(hit.target == .mac)
}

@Test func withoutAnchorLookingFarDownMeansMac() throws {
    let hit = try #require(cursorHit(head: lookingDown, screens: [panel], mac: nil))
    #expect(hit.target == .mac)
    #expect(hit.uv == SIMD2(0.5, 0.5))
}

@Test func withoutAnchorLookingSidewaysHitsNothing() {
    #expect(cursorHit(head: yawPitchQuat(yaw: 90 * degree, pitch: 0), screens: [panel], mac: nil) == nil)
}

@Test func anchorRoundTripsThroughCodable() throws {
    let anchor = MacAnchor.captured(head: lookingDown, aspect: 1.54)
    #expect(try JSONDecoder().decode(MacAnchor.self, from: JSONEncoder().encode(anchor)) == anchor)
}
