import MetalKit
import Testing
import RayDeskCore
@testable import RayDesk

@Suite @MainActor struct RendererMetadataEpochTests {
    @Test func restControlsKeepCompatibleSceneResources() throws {
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 16, height: 16))
        let scene = SpatialScene(screens: [ScreenPose(yaw: 0, pitch: 0, distance: 2, width: 1, aspect: 1)])
        let renderer = try Renderer(view: view, scene: scene, filter: OrientationFilter())
        let size = CGSize(width: 16, height: 16)
        let original = try renderer.prepareIndependentPool(size: size)
        renderer.restTolerance = 8
        #expect(try renderer.prepareIndependentPool(size: size) === original)
        renderer.restStrength = .strong
        #expect(try renderer.prepareIndependentPool(size: size) === original)
        renderer.showsRestIndicator = true
        #expect(try renderer.prepareIndependentPool(size: size) === original)
        renderer.adaptiveVSync = true
        #expect(try renderer.prepareIndependentPool(size: size) === original)
        renderer.verticalFOV = 30
        #expect(try renderer.prepareIndependentPool(size: size) !== original)
    }
}
