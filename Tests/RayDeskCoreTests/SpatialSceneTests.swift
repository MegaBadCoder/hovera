import Testing
import simd
import Foundation
@testable import RayDeskCore

private let degree = Double.pi / 180

@Test func defaultLayoutForSingleScreenIsCenteredAtZeroYaw() {
    let layout = SpatialScene.defaultLayout(count: 1, aspect: 1.0)
    #expect(layout.count == 1)
    #expect(abs(layout[0].yaw) < 1e-9)
    #expect(abs(layout[0].pitch) < 1e-9)
    #expect(abs(layout[0].distance - 1.5) < 1e-9)
    #expect(abs(layout[0].width - 1.0) < 1e-9)
}

@Test func defaultLayoutForTwoScreensLeavesTwoDegreeGap() {
    let layout = SpatialScene.defaultLayout(count: 2, aspect: 1.0)
    #expect(layout.count == 2)
    #expect(layout[0].yaw > layout[1].yaw)
    let rightEdgeOfLeft = layout[0].yaw - layout[0].angularWidth / 2
    let leftEdgeOfRight = layout[1].yaw + layout[1].angularWidth / 2
    #expect(abs((rightEdgeOfLeft - leftEdgeOfRight) - 2 * degree) < 1e-6)
}

@Test func spatialSceneRejectsEmptyOrOversizedInit() {
    let scene = SpatialScene(screens: SpatialScene.defaultLayout(count: 4, aspect: 1.0))
    #expect(scene.screens.count == 4)
}

@Test func addScreenAppendsAtGazeUntilMax() {
    let scene = SpatialScene(screens: [ScreenPose(yaw: 0, pitch: 0, distance: 2.0, width: 1.2, aspect: 1.5)])
    let head = yawPitchQuat(yaw: 10 * degree, pitch: 5 * degree)
    #expect(scene.addScreen(head: head) == true)
    #expect(scene.screens.count == 2)
    #expect(abs(scene.screens[1].yaw - 10 * degree) < 1e-9)
    #expect(abs(scene.screens[1].pitch - 5 * degree) < 1e-9)
    #expect(abs(scene.screens[1].distance - 2.0) < 1e-9)
    #expect(abs(scene.screens[1].width - 1.2) < 1e-9)
    #expect(abs(scene.screens[1].aspect - 1.5) < 1e-9)

    #expect(scene.addScreen(head: head) == true)
    #expect(scene.addScreen(head: head) == true)
    #expect(scene.screens.count == 4)
    #expect(scene.addScreen(head: head) == false)
    #expect(scene.screens.count == 4)
}

@Test func removeLastScreenFailsWhenOnlyOneRemains() {
    let scene = SpatialScene(screens: [ScreenPose(yaw: 0, pitch: 0, distance: 1.5, width: 1.0, aspect: 1.0)])
    #expect(scene.removeLastScreen() == false)
    #expect(scene.screens.count == 1)
}

@Test func removeLastScreenClearsGrabIfItPointedAtRemovedScreen() {
    let scene = SpatialScene(screens: SpatialScene.defaultLayout(count: 2, aspect: 1.0))
    let head = yawPitchQuat(yaw: scene.screens[1].yaw, pitch: scene.screens[1].pitch)
    scene.toggleGrab(1, head: head)
    #expect(scene.grabbed == 1)
    #expect(scene.removeLastScreen() == true)
    #expect(scene.screens.count == 1)
    #expect(scene.grabbed == nil)
}

@Test func placeSetsYawPitchToGaze() {
    let scene = SpatialScene(screens: [ScreenPose(yaw: 0, pitch: 0, distance: 1.5, width: 1.0, aspect: 1.0)])
    let head = yawPitchQuat(yaw: 20 * degree, pitch: -10 * degree)
    scene.place(0, head: head)
    #expect(abs(scene.screens[0].yaw - 20 * degree) < 1e-9)
    #expect(abs(scene.screens[0].pitch - (-10 * degree)) < 1e-9)
}

@Test func toggleGrabTracksOffsetAndTickFollowsGaze() {
    let scene = SpatialScene(screens: [ScreenPose(yaw: 30 * degree, pitch: 10 * degree, distance: 1.5, width: 1.0, aspect: 1.0)])
    let initialHead = yawPitchQuat(yaw: 0, pitch: 0)
    scene.toggleGrab(0, head: initialHead)
    #expect(scene.grabbed == 0)

    let movedHead = yawPitchQuat(yaw: 15 * degree, pitch: 5 * degree)
    scene.tick(head: movedHead)
    #expect(abs(scene.screens[0].yaw - 45 * degree) < 1e-6)
    #expect(abs(scene.screens[0].pitch - 15 * degree) < 1e-6)

    scene.toggleGrab(0, head: movedHead)
    #expect(scene.grabbed == nil)
}

@Test func tickClampsPitchDuringGrab() {
    let scene = SpatialScene(screens: [ScreenPose(yaw: 0, pitch: 0, distance: 1.5, width: 1.0, aspect: 1.0)])
    let head = yawPitchQuat(yaw: 0, pitch: 0)
    scene.toggleGrab(0, head: head)
    let extremeHead = yawPitchQuat(yaw: 0, pitch: 89 * degree)
    scene.tick(head: extremeHead)
    #expect(scene.screens[0].pitch <= 80 * degree + 1e-9)
}

@Test func adjustDistanceClampsToRange() {
    let scene = SpatialScene(screens: [ScreenPose(yaw: 0, pitch: 0, distance: 1.5, width: 1.0, aspect: 1.0)])
    scene.adjustDistance(0, by: 100)
    #expect(abs(scene.screens[0].distance - 6.0) < 1e-9)
    scene.adjustDistance(0, by: 0.001)
    #expect(abs(scene.screens[0].distance - 0.4) < 1e-9)
}

@Test func adjustWidthClampsToRange() {
    let scene = SpatialScene(screens: [ScreenPose(yaw: 0, pitch: 0, distance: 1.5, width: 1.0, aspect: 1.0)])
    scene.adjustWidth(0, by: 100)
    #expect(abs(scene.screens[0].width - 5.0) < 1e-9)
    scene.adjustWidth(0, by: 0.001)
    #expect(abs(scene.screens[0].width - 0.2) < 1e-9)
}

@Test func setPoseOverwritesScreenDirectly() {
    let scene = SpatialScene(screens: [ScreenPose(yaw: 0, pitch: 0, distance: 1.5, width: 1.0, aspect: 1.0)])
    let newPose = ScreenPose(yaw: 0.5, pitch: 0.1, distance: 2.0, width: 1.5, aspect: 1.7)
    scene.setPose(0, newPose)
    #expect(scene.screens[0] == newPose)
}

@Test func encodedRoundtripsThroughDecode() {
    let scene = SpatialScene(screens: SpatialScene.defaultLayout(count: 3, aspect: 1.6))
    let data = scene.encoded()
    let decoded = SpatialScene.decode(data, default: 2, aspect: 1.6)
    #expect(decoded == scene.screens)
}

@Test func decodeFallsBackToDefaultForNilData() {
    let decoded = SpatialScene.decode(nil, default: 2, aspect: 1.6)
    #expect(decoded == SpatialScene.defaultLayout(count: 2, aspect: 1.6))
}

@Test func decodeFallsBackToDefaultForGarbageData() {
    let garbage = "not json".data(using: .utf8)
    let decoded = SpatialScene.decode(garbage, default: 3, aspect: 1.6)
    #expect(decoded == SpatialScene.defaultLayout(count: 3, aspect: 1.6))
}

@Test func decodeFallsBackToDefaultForEmptyArray() {
    let empty = try! JSONEncoder().encode([ScreenPose]())
    let decoded = SpatialScene.decode(empty, default: 2, aspect: 1.6)
    #expect(decoded == SpatialScene.defaultLayout(count: 2, aspect: 1.6))
}

@Test func decodeTruncatesToFirstFourScreens() {
    let five = (0..<5).map { ScreenPose(yaw: Double($0) * 0.1, pitch: 0, distance: 1.5, width: 1.0, aspect: 1.6) }
    let data = try! JSONEncoder().encode(five)
    let decoded = SpatialScene.decode(data, default: 2, aspect: 1.6)
    #expect(decoded.count == 4)
    #expect(decoded == Array(five.prefix(4)))
}

@Test func gatherInFrontCentersScreensOnGazeAndKeepsCount() {
    let scene = SpatialScene(screens: [
        ScreenPose(yaw: 70 * .pi / 180, pitch: 0.3, distance: 2, width: 1.2, aspect: 16.0 / 9.0),
        ScreenPose(yaw: -0.3, pitch: 0.28, distance: 1.5, width: 0.9, aspect: 16.0 / 9.0),
    ])
    let head = yawPitchQuat(yaw: 30 * .pi / 180, pitch: -10 * .pi / 180)
    scene.gatherInFront(head: head)

    #expect(scene.screens.count == 2)
    let meanYaw = scene.screens.map(\.yaw).reduce(0, +) / 2
    #expect(abs(meanYaw - 30 * .pi / 180) < 1e-9)
    #expect(scene.screens.allSatisfy { abs($0.pitch - (-10 * .pi / 180)) < 1e-9 })
    #expect(scene.screens[0].yaw > scene.screens[1].yaw)
    #expect(scene.grabbed == nil)
}
