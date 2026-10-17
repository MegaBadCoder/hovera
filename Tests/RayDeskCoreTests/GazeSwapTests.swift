import Testing
import simd
@testable import RayDeskCore

@Test func gazeSwapSelectsThenExchangesAndIgnoresMisses() {
    let layout = SpatialScene.defaultLayout(count: 3, aspect: 16.0 / 9)
    let scene = SpatialScene(screens: layout)
    #expect(!scene.selectSwapTarget(0))
    #expect(scene.swapSource == 0)
    #expect(scene.screens == layout)
    #expect(!scene.selectSwapTarget(nil))
    #expect(!scene.selectSwapTarget(4))
    #expect(scene.swapSource == 0)
    #expect(scene.selectSwapTarget(2))
    #expect(scene.screens == [layout[2], layout[1], layout[0]])
    #expect(scene.swapSource == nil)
}

@Test func gazeSwapCancelsOnSameScreenAndLayoutChanges() {
    let layout = SpatialScene.defaultLayout(count: 2, aspect: 1)
    let scene = SpatialScene(screens: layout)
    scene.selectSwapTarget(1)
    #expect(!scene.selectSwapTarget(1))
    #expect(scene.swapSource == nil)
    #expect(scene.screens == layout)
    scene.selectSwapTarget(1)
    scene.adjustWidth(0, by: 1.1)
    #expect(scene.swapSource == nil)
    scene.selectSwapTarget(1)
    scene.beginFocus(0, uv: SIMD2(0.5, 0.5), head: yawPitchQuat(yaw: 0, pitch: 0), origin: .zero)
    #expect(scene.swapSource == nil)
}
