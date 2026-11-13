import Testing
import simd
@testable import RayDeskCore

@Test func gatheringAroundSelectedMonitorPreservesItsEntirePose() {
    let anchor = ScreenPose(yaw: 0.4, pitch: -0.2, distance: 2.3, width: 1.1, aspect: 1.6,
                            tilt: 0.25, roll: 0.15, pan: -0.2)
    let other = ScreenPose(yaw: -0.5, pitch: 0.3, distance: 1, width: 0.7, aspect: 1.2)
    for join in ScreenJoin.allCases {
        let scene = SpatialScene(screens: [anchor, other, other])
        scene.toggleGrab(0, head: anchor.rotation)
        scene.arrangeInArc(around: 0, join: join)
        #expect(scene.screens[0] == anchor)
        #expect(scene.grabbed == nil)
        #expect(scene.screens[1].width == other.width)
        #expect(scene.screens[2].aspect == other.aspect)
    }
}

@Test func anchoredHingeLayoutTouchesBothSidesOfRotatedMonitor() {
    let anchor = ScreenPose(yaw: 0.4, pitch: -0.2, distance: 2.3, width: 1.1, aspect: 1.6,
                            tilt: 0.25, roll: 0.35, pan: -0.2)
    let left = ScreenPose(yaw: 0.8, pitch: 0, distance: 1.5, width: 1.1, aspect: 1.6)
    let right = ScreenPose(yaw: -0.8, pitch: 0, distance: 1.5, width: 1.1, aspect: 1.6)
    let scene = SpatialScene(screens: [anchor, left, right])
    scene.arrangeInArc(around: 0, join: .hinge)
    for height in [-0.5, 0.5] {
        let anchorLeft = edgeMidpoint(anchor, .left) + anchor.up * (height * anchor.height)
        let anchorRight = edgeMidpoint(anchor, .right) + anchor.up * (height * anchor.height)
        let leftEdge = edgeMidpoint(scene.screens[1], .right) + scene.screens[1].up * (height * scene.screens[1].height)
        let rightEdge = edgeMidpoint(scene.screens[2], .left) + scene.screens[2].up * (height * scene.screens[2].height)
        #expect(length(leftEdge - anchorLeft) < 1e-9)
        #expect(length(rightEdge - anchorRight) < 1e-9)
    }
}

@Test func inPlaneRotationPreservesCenterAndNormalForTiltedScreens() {
    let original = ScreenPose(yaw: 0.4, pitch: -0.2, distance: 2.3, width: 1.1, aspect: 1.6,
                              tilt: 0.25, roll: 0.35, pan: -0.2)
    let scene = SpatialScene(screens: [original])
    scene.rotateInPlane(0, by: .pi / 2)
    let rotated = scene.screens[0]
    #expect(rotated.center == original.center)
    #expect(length(rotated.normal - original.normal) < 1e-9)
    #expect(length(rotated.right - original.up) < 1e-9)
    #expect(length(rotated.up + original.right) < 1e-9)
    #expect(rotated.width == original.width && rotated.aspect == original.aspect)
    scene.rotateInPlane(0, by: -.pi / 2)
    #expect(length(scene.screens[0].right - original.right) < 1e-9)
    #expect(length(scene.screens[0].up - original.up) < 1e-9)
}

@Test func anchoredLayoutHandlesEveryScreenCountAndAnchor() {
    for count in 1...4 {
        for anchor in 0..<count {
            let original = SpatialScene.defaultLayout(count: count, aspect: 1.6)
            let scene = SpatialScene(screens: original)
            scene.beginFocus(anchor, uv: SIMD2(0.5, 0.5), head: original[anchor].rotation, origin: .zero)
            scene.arrangeInArc(around: anchor, join: .hinge)
            #expect(scene.screens[anchor] == original[anchor])
            #expect(scene.focus == nil)
            #expect(scene.screens.count == count)
            #expect(scene.screens.allSatisfy { $0.center.x.isFinite && $0.normal.z.isFinite })
        }
    }
}

@Test func invalidLayoutTargetsAndRotationAnglesLeaveSceneUnchanged() {
    let original = SpatialScene.defaultLayout(count: 2, aspect: 1.6)
    let scene = SpatialScene(screens: original)
    scene.arrangeInArc(around: -1, join: .hinge)
    scene.arrangeInArc(around: 2, join: .hinge)
    scene.rotateInPlane(2, by: 1)
    scene.rotateInPlane(0, by: .nan)
    scene.rotateInPlane(0, by: .infinity)
    #expect(scene.screens == original)
}
