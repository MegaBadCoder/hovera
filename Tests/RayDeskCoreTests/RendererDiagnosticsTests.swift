import MetalKit
import Testing
import RayDeskCore
@testable import RayDesk

@Test @MainActor func rendererReportsTheHorizonOfItsCurrentTrackingSource() throws {
    let view = MTKView(frame: CGRect(x: 0, y: 0, width: 16, height: 16))
    let screen = ScreenPose(yaw: 0, pitch: 0, distance: 2, width: 1, aspect: 1)
    let renderer = try Renderer(view: view, scene: SpatialScene(screens: [screen]), filter: OrientationFilter())
    let orientation = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    renderer.externalPose = { _ in (orientation, .zero, 0.032) }
    renderer.draw(in: view, targetTime: CACurrentMediaTime() + 0.01)
    #expect(renderer.usedExternalOrientation)
    #expect(abs(renderer.lastPredictionHorizon - 0.032) < 1e-9)
    renderer.externalPose = { _ in (orientation, .zero, 0) }
    renderer.draw(in: view, targetTime: CACurrentMediaTime() + 0.01)
    #expect(renderer.lastPredictionHorizon == 0)
    renderer.externalPose = nil
    renderer.headPipeline.predictionSeconds = 0.017
    renderer.draw(in: view, targetTime: CACurrentMediaTime() + 0.01)
    #expect(!renderer.usedExternalOrientation)
    #expect(abs(renderer.lastPredictionHorizon - 0.017) < 1e-9)
}
