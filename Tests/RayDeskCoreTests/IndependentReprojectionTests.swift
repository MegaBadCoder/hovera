import MetalKit
import Testing
import RayDeskCore
@testable import RayDesk

@Test func independentWarpKeepsUpdatingPixelsWhileSceneGPUWaits() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let producer = try #require(device.makeCommandQueue())
    let display = try #require(device.makeCommandQueue())
    let gate = try #require(device.makeSharedEvent())
    let compositor = try RotationalCompositor(device: device, pixelFormat: .rgba8Unorm,
                                             depthFormat: .depth32Float, sampleCount: 4)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 80, height: 80, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = [.shaderRead, .renderTarget]
    let textures = try (0..<3).map { _ in try #require(device.makeTexture(descriptor: descriptor)) }
    var gradient = [UInt8](repeating: 255, count: 80 * 80 * 4)
    for y in 0..<80 {
        for x in 0..<80 { gradient[(y * 80 + x) * 4] = UInt8(x * 255 / 79) }
    }
    textures[0].replace(region: MTLRegionMake2D(0, 0, 80, 80), mipmapLevel: 0, withBytes: &gradient, bytesPerRow: 320)
    let pool = CompletedFramePool<MTLTexture, Int>(resources: textures)
    let ready = try #require(pool.reserve())
    pool.complete(ready, metadata: 1)
    let pending = try #require(pool.reserve())
    let delayedScene = try #require(producer.makeCommandBuffer())
    delayedScene.encodeWaitForEvent(gate, value: 1)
    let completion = DispatchSemaphore(value: 0)
    delayedScene.addCompletedHandler { command in
        pool.complete(pending, metadata: command.status == .completed ? 2 : nil)
        completion.signal()
    }
    delayedScene.commit()
    defer {
        gate.signaledValue = 1
        #expect(completion.wait(timeout: .now() + 3) == .success)
    }
    descriptor.width = 64
    descriptor.height = 64
    let destination = try #require(device.makeTexture(descriptor: descriptor))
    let filter = OrientationFilter()
    let source = ReprojectionPoseSource.rayNeo(filter, bias: 0, limit: 0.045, fallback: 0)
    var centerPixels: [UInt8] = []
    for index in 0..<12 {
        filter.alignYaw(to: Double(index) * 0.004)
        let pose = try #require(source.sample(CACurrentMediaTime() + 0.01))
        let read = try #require(pool.acquire())
        #expect(read.metadata == 1)
        let warp = RotationalReprojection(scene: yawPitchQuat(yaw: 0, pitch: 0), display: pose.orientation,
                                         verticalFOV: 0.5, aspect: 1, overscan: SIMD2(1.25, 1.25))
        let command = try #require(display.makeCommandBuffer())
        try compositor.encode(warp, source: read.resource, destination: destination, commandBuffer: command)
        let displayed = DispatchSemaphore(value: 0)
        command.addCompletedHandler { _ in
            pool.release(read)
            displayed.signal()
        }
        command.commit()
        let result = displayed.wait(timeout: .now() + 2)
        #expect(result == .success)
        guard result == .success else { return }
        #expect(command.status == .completed)
        #expect(delayedScene.status != .completed)
        var pixel = [UInt8](repeating: 0, count: 4)
        destination.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(32, 32, 1, 1), mipmapLevel: 0)
        let uv = try #require(warp.textureCoordinate(at: SIMD2(32.5 / 64, 32.5 / 64)))
        #expect(abs(Float(pixel[0]) / 255 - (uv.x * 80 - 0.5) / 79) < 0.008)
        centerPixels.append(pixel[0])
    }
    #expect(Set(centerPixels).count >= 10)
}

@Test func independentRayNeoPoseReadsFreshSamplesAndBoundsPredictionForOldScenes() throws {
    let filter = OrientationFilter()
    let source = ReprojectionPoseSource.rayNeo(filter, bias: 0, limit: 0.045, fallback: 0.018)
    for index in 0..<30 {
        filter.alignYaw(to: Double(index) * 0.01)
        let pose = try #require(source.sample(CACurrentMediaTime() + 10))
        #expect(abs(pose.orientation.yawPitch.yaw - Double(index) * 0.01) < 1e-8)
        #expect(pose.horizon <= 0.045)
    }
}

@Test func independentSubmissionRejectsSceneInvalidatedDuringPoseSampling() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let compositor = try RotationalCompositor(device: device, pixelFormat: .rgba8Unorm,
                                             depthFormat: .depth32Float, sampleCount: 4)
    let target = try compositor.makeTarget(displaySize: SIMD2(16, 16))
    let pool = ReprojectionFramePool(resources: [target])
    let presenter = try AsyncReprojection(device: device, pixelFormat: .rgba8Unorm)
    presenter.use(pool)
    var submitted = false
    #expect(presenter.submit(using: pool) { submitted = true })
    #expect(submitted)
    let stateRead = DispatchSemaphore(value: 0)
    let callback = Thread {
        _ = presenter.snapshot
        stateRead.signal()
    }
    let callbackSubmission = presenter.submit(using: pool) {
        callback.start()
        #expect(stateRead.wait(timeout: .now() + 1) == .success)
    }
    #expect(callbackSubmission)
    let captured = DispatchSemaphore(value: 0)
    let invalidated = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let worker = Thread {
        captured.signal()
        guard invalidated.wait(timeout: .now() + 2) == .success else { return }
        let accepted = presenter.submit(using: pool) { Issue.record("Invalidated scene reached GPU submission") }
        #expect(!accepted)
        finished.signal()
    }
    worker.start()
    #expect(captured.wait(timeout: .now() + 2) == .success)
    presenter.use(nil)
    invalidated.signal()
    #expect(finished.wait(timeout: .now() + 2) == .success)
}

private final class AdaptiveTestMotion: @unchecked Sendable {
    private let lock = NSLock()
    private var turnTime: Double?

    func startTurn() {
        lock.lock()
        turnTime = CACurrentMediaTime()
        lock.unlock()
    }

    func sample(at time: Double) -> ReprojectionPose {
        expectedPose(at: time)
    }

    func expectedPose(at time: Double) -> ReprojectionPose {
        lock.lock()
        let turnTime = self.turnTime
        lock.unlock()
        let angle: Double
        if let turnTime {
            angle = 0.05 * .pi / 180 * sin(2 * .pi * 1.5 * turnTime) + 20 * .pi / 180 * (time - turnTime)
        } else {
            angle = 0.05 * .pi / 180 * sin(2 * .pi * 1.5 * time)
        }
        return ReprojectionPose(orientation: yawPitchQuat(yaw: angle, pitch: 0), horizon: 0, isStable: true)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["HOVERA_TEST_LIVE_DISPLAY"] == "1",
               "Требуется активный физический дисплей и кратковременно видимое тестовое окно"))
@MainActor func independentDisplayLinkPresentsWhileMainThreadIsBlocked() throws {
    _ = NSApplication.shared
    let screen = try #require(NSScreen.screens.first { screen in
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return CGDisplayVendorNumber(id.uint32Value) != VirtualScreen.vendorID
            && CGDisplayIsActive(id.uint32Value) != 0 && CGDisplayIsAsleep(id.uint32Value) == 0
    })
    let device = try #require(MTLCreateSystemDefaultDevice())
    let rect = CGRect(x: screen.frame.midX, y: screen.frame.midY, width: 64, height: 64)
    let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
    window.isReleasedWhenClosed = false
    let view = MTKView(frame: CGRect(origin: .zero, size: rect.size), device: device)
    view.colorPixelFormat = .bgra8Unorm_srgb
    view.isPaused = true
    view.enableSetNeedsDisplay = false
    view.autoResizeDrawable = false
    view.drawableSize = CGSize(width: 64, height: 64)
    window.contentView = view
    window.orderFrontRegardless()
    CATransaction.flush()
    let layer = try #require(view.layer as? CAMetalLayer)
    let compositor = try RotationalCompositor(device: device, pixelFormat: view.colorPixelFormat,
                                             depthFormat: .depth32Float, sampleCount: 4)
    let target = try compositor.makeTarget(displaySize: SIMD2(64, 64))
    let queue = try #require(device.makeCommandQueue())
    let ready = try #require(queue.makeCommandBuffer())
    let pass = target.pass
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
    let encoder = try #require(ready.makeRenderCommandEncoder(descriptor: pass))
    encoder.endEncoding()
    ready.commit()
    ready.waitUntilCompleted()
    #expect(ready.status == .completed)
    let pool = ReprojectionFramePool(resources: [target])
    let ticket = try #require(pool.reserve())
    let motion = AdaptiveTestMotion()
    let sample: @Sendable (Double) -> ReprojectionPose? = { time in motion.sample(at: time) }
    pool.complete(ticket, metadata: ReprojectionFrame(orientation: yawPitchQuat(yaw: 0, pitch: 0), position: .zero,
                  verticalFOV: 0.5, calibration: ViewCalibration(),
                  source: ReprojectionPoseSource(external: true, sample: sample),
                  worldLocked: true, smoothing: true, adaptiveVSync: true, restSmoothing: true, restTolerance: 5, restStrength: .strong,
                  indicatorYaw: 0, epoch: 1, created: CACurrentMediaTime()))
    let presenter = try AsyncReprojection(device: device, pixelFormat: view.colorPixelFormat)
    presenter.use(pool)
    presenter.start(layer: layer, framesPerSecond: screen.maximumFramesPerSecond)
    defer {
        presenter.stop()
        window.close()
    }
    let deadline = Date(timeIntervalSinceNow: 3)
    while presenter.snapshot.presented < 3 && Date() < deadline {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
    }
    #expect(presenter.snapshot.presented >= 3)
    for _ in 0..<5 {
        let before = presenter.snapshot
        Thread.sleep(forTimeInterval: 0.2)
        let after = presenter.snapshot
        #expect(after.presented - before.presented >= 3)
        #expect(after.reused - before.reused >= 3)
        #expect(after.failed == 0)
        let expected = motion.expectedPose(at: after.poseTargetTime).orientation
        let displayed = try #require(after.orientation)
        #expect(abs(simd_dot(expected.vector, displayed.vector)) > 1 - 1e-12)
        #expect(after.restCorrection == 0)
        #expect(!after.restStabilizing)
        print("ATW live test: blocked main 200ms, presented=\(after.presented - before.presented), reused=\(after.reused - before.reused), vsync=\(after.displaySyncEnabled), updates=\(after.receivedUpdates - before.receivedUpdates), blocked=\(after.blockedUpdates - before.blockedUpdates), inFlight=\(after.outstandingGPUCommands), skips=\(after.pacing?.skipped ?? 0), visible=\(window.occlusionState.contains(.visible)), activeSpace=\(window.isOnActiveSpace)")
    }
    let restDeadline = Date(timeIntervalSinceNow: 3)
    while (presenter.snapshot.displaySyncEnabled || presenter.snapshot.restPhase != .resting) && Date() < restDeadline {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    let settled = presenter.snapshot
    #expect(settled.adaptiveVSync)
    #expect(settled.restPhase == .resting)
    #expect(!settled.displaySyncEnabled)
    #expect(!layer.displaySyncEnabled)
    #expect(settled.poseTargetTime > settled.sampleTime)
    #expect(abs(settled.lastPresentedTime - settled.poseTargetTime) < 0.012)
    motion.startTurn()
    let turnDeadline = Date(timeIntervalSinceNow: 0.3)
    while !presenter.snapshot.displaySyncEnabled && Date() < turnDeadline {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.002))
    }
    #expect(presenter.snapshot.displaySyncEnabled)
    #expect(layer.displaySyncEnabled)
    #expect(presenter.snapshot.syncSwitches >= 2)
    presenter.stop()
    #expect(layer.displaySyncEnabled)
}
