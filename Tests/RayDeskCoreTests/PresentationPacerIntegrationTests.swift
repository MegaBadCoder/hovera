import MetalKit
import Testing
import RayDeskCore
@testable import RayDesk

@Suite struct PresentationPacerIntegrationTests {
    @Test(arguments: ["skip", "disabled", "moving", "unstable"])
    func drainingReleasesTheSceneOnlyWhenTheCurrentFrameMayBeSkipped(mode: String) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let compositor = try RotationalCompositor(device: device, pixelFormat: .rgba8Unorm,
                                                 depthFormat: .depth32Float, sampleCount: 4)
        let targets = try (0..<3).map { _ in try compositor.makeTarget(displaySize: SIMD2(16, 16)) }
        let pool = ReprojectionFramePool(resources: targets)
        let zero = simd_quatd(angle: 0, axis: SIMD3(0, 1, 0))
        let frame = ReprojectionFrame(orientation: zero, position: .zero, verticalFOV: 0.5,
                                     calibration: ViewCalibration(), source: ReprojectionPoseSource(external: true) { _ in
                                         ReprojectionPose(orientation: zero, horizon: 0)
                                     }, worldLocked: true, smoothing: true, adaptiveVSync: true,
                                     restSmoothing: true, restTolerance: 5, restStrength: .strong,
                                     indicatorYaw: nil, epoch: 1, created: 100)
        let first = try #require(pool.reserve())
        pool.complete(first, metadata: frame)
        let read = try #require(pool.acquire())
        let next = try #require(pool.reserve())
        pool.complete(next, metadata: frame)
        let writing = try #require(pool.reserve())
        #expect(pool.reserve() == nil)
        let presenter = try AsyncReprojection(device: device, pixelFormat: .rgba8Unorm)
        presenter.use(pool)
        for index in 0..<30 {
            let start = 100 + Double(index) / 120
            presenter.presentationPacer.updateMotion(zero, at: start, stable: true)
            presenter.presentationPacer.observe(renderStart: start, presented: start + 0.025, now: start + 0.025)
        }
        #expect(presenter.presentationPacer.snapshot.drainRequested)
        let motion = mode == "moving" ? simd_quatd(angle: 0.2, axis: SIMD3(0, 1, 0)) : zero
        let skipped = presenter.drainPresentationIfNeeded(read, from: pool, motion: motion, at: 100.275,
                                                         stable: mode != "unstable", enabled: mode != "disabled")
        #expect(skipped == (mode == "skip"))
        #expect(presenter.snapshot.submitted == 0)
        if skipped {
            let recycled = try #require(pool.reserve())
            #expect(recycled.index == first.index)
            #expect(presenter.snapshot.pacing?.skipped == 1)
            pool.complete(recycled, metadata: nil)
        } else {
            #expect(pool.reserve() == nil)
            #expect(!presenter.presentationPacer.snapshot.drainRequested)
            pool.release(read)
        }
        pool.complete(writing, metadata: nil)
    }

    @Test @MainActor func independentPresenterCapsDrawablesAndRestoresThePreviousLimit() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.maximumDrawableCount = 3
        let presenter = try AsyncReprojection(device: device, pixelFormat: layer.pixelFormat)
        presenter.start(layer: layer, framesPerSecond: 60)
        #expect(layer.maximumDrawableCount == 2)
        presenter.stop()
        #expect(layer.maximumDrawableCount == 3)
    }

    @Test @MainActor func fallbackRendererCapsDrawablesWithoutAVisibleWindow() throws {
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 16, height: 16))
        let screen = ScreenPose(yaw: 0, pitch: 0, distance: 2, width: 1, aspect: 1)
        let renderer = try Renderer(view: view, scene: SpatialScene(screens: [screen]), filter: OrientationFilter())
        let layer = try #require(view.layer as? CAMetalLayer)
        #expect(layer.maximumDrawableCount == 2)
        #expect(!renderer.adaptiveVSync)
    }
}
