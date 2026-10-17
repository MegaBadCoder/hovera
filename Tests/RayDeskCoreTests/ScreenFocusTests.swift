import Foundation
import Testing
import simd
@testable import RayDeskCore

@Test func focusCentersSelectedPointAndFacesEyes() throws {
    let source = ScreenPose(yaw: 0.7, pitch: -0.3, distance: 1.5, width: 1.2, aspect: 16.0 / 9, tilt: 0.4, roll: 0.2, pan: -0.3)
    for pitch in [0.0, -0.8, 1.4] {
        let head = yawPitchQuat(yaw: 0.5, pitch: pitch) * simd_quatd(angle: 0.3, axis: SIMD3(0, 0, 1))
        let origin = SIMD3<Double>(0.12, -0.08, 0.2)
        for uv in [SIMD2<Double>(0.5, 0.5), SIMD2(0.95, 0.95), SIMD2(0.05, 0.05)] {
            let focus = ScreenFocus(screen: 2, source: source, uv: uv, head: head, origin: origin)
            let selected = focus.pose.center + focus.pose.right * ((uv.x - 0.5) * focus.pose.width)
                + focus.pose.up * ((0.5 - uv.y) * focus.pose.height)
            let direction = normalize(selected - origin)
            #expect(length(direction - head.act(SIMD3(0, 0, -1))) < 1e-9)
            #expect(length(focus.pose.right - head.act(SIMD3(1, 0, 0))) < 1e-9)
            #expect(length(focus.pose.up - head.act(SIMD3(0, 1, 0))) < 1e-9)
            #expect(abs(focus.pose.width - 2 * source.width) < 1e-9)
            let hit = try #require(focus.hit(head: head, origin: origin))
            #expect(hit.screen == 2)
            #expect(length(hit.uv - uv) < 1e-9)
            #expect(focus.hit(head: head * simd_quatd(angle: .pi, axis: SIMD3(0, 1, 0)), origin: origin) == nil)
        }
    }
}

@Test func focusPreservesLayoutAndStopsGrab() {
    let layout = SpatialScene.defaultLayout(count: 2, aspect: 16.0 / 9)
    let scene = SpatialScene(screens: layout)
    let head = yawPitchQuat(yaw: 0, pitch: 0)
    scene.toggleGrab(1, head: head)
    scene.beginFocus(1, uv: SIMD2(0.9, 0.9), head: head, origin: .zero)
    #expect(scene.focus?.screen == 1)
    #expect(scene.grabbed == nil)
    scene.tick(head: yawPitchQuat(yaw: 1, pitch: 0.2))
    #expect(scene.screens == layout)
    #expect(SpatialScene.decode(scene.encoded(), default: 1, aspect: 1) == layout)
    scene.endFocus()
    #expect(scene.focus == nil)
    #expect(scene.screens == layout)
}

@Test func swapExchangesPlacesPreservesAspectsAndSurvivesReload() {
    var layout = SpatialScene.defaultLayout(count: 3, aspect: 16.0 / 9)
    layout[1].aspect = 1
    let scene = SpatialScene(screens: layout)
    let head = yawPitchQuat(yaw: 0, pitch: 0)
    scene.beginFocus(0, uv: SIMD2(0.8, 0.8), head: head, origin: .zero)
    #expect(scene.swapScreens(0, 1))
    var expected = [layout[1], layout[0], layout[2]]
    expected[0].aspect = layout[0].aspect
    expected[1].aspect = layout[1].aspect
    #expect(scene.screens == expected)
    #expect(scene.focus == nil)
    #expect(SpatialScene.decode(scene.encoded(), default: 1, aspect: 1) == expected)
    #expect(!scene.swapScreens(-1, 0))
    #expect(!scene.swapScreens(0, 3))
    #expect(!scene.swapScreens(0, 0))
    #expect(scene.screens == expected)
}

@Test func layoutEditExitsFocus() {
    let scene = SpatialScene(screens: SpatialScene.defaultLayout(count: 1, aspect: 1))
    scene.beginFocus(0, uv: SIMD2(0.5, 0.5), head: yawPitchQuat(yaw: 0, pitch: 0), origin: .zero)
    scene.adjustWidth(0, by: 1.1)
    #expect(scene.focus == nil)
}
