import MetalKit
import Testing
import RayDeskCore
@testable import RayDesk

@Test @MainActor func worldLockSoftensSmallFrameToFrameJitterForExternalTracker() throws {
    let view = MTKView(frame: CGRect(x: 0, y: 0, width: 16, height: 16))
    let filter = OrientationFilter()
    filter.update(gyro: .zero, accel: SIMD3(0, 1, 0), dt: 0.002)
    let renderer = try Renderer(view: view, scene: SpatialScene(screens: [ScreenPose(yaw: 0, pitch: 0, distance: 2, width: 1, aspect: 1)]), filter: filter)
    renderer.externalPose = { _ in (yawPitchQuat(yaw: 0, pitch: 0), .zero, 0) }
    renderer.draw(in: view, targetTime: CACurrentMediaTime() + 0.01)
    let jitter = 0.05 * Double.pi / 180
    renderer.externalPose = { _ in (yawPitchQuat(yaw: jitter, pitch: 0), .zero, 0) }
    renderer.draw(in: view, targetTime: CACurrentMediaTime() + 0.01)
    #expect(renderer.currentHead.yawPitch.yaw > 0)
    #expect(renderer.currentHead.yawPitch.yaw < jitter * 0.8)
}

@Test @MainActor func worldLockedVitureBoundsTheLagOfRealHeadRotation() throws {
    let view = MTKView(frame: CGRect(x: 0, y: 0, width: 16, height: 16))
    let renderer = try Renderer(view: view, scene: SpatialScene(screens: [ScreenPose(yaw: 0, pitch: 0, distance: 2, width: 1, aspect: 1)]), filter: OrientationFilter())
    renderer.stabilizer.level = .medium
    renderer.externalPose = { _ in (simd_quatd(angle: 0, axis: SIMD3(0, 1, 0)), .zero, 0) }
    renderer.draw(in: view, targetTime: CACurrentMediaTime() + 0.01)
    let turned = yawPitchQuat(yaw: 0.05, pitch: 0.02)
    renderer.externalPose = { _ in (turned, .zero, 0.02) }
    renderer.draw(in: view, targetTime: CACurrentMediaTime() + 0.01)
    let error = 2 * acos(min(1, abs(simd_dot(renderer.currentHead.vector, turned.vector))))
    #expect(error <= OrientationStabilizer.worldLockMaximumDeviation + 1e-8)
}

@Test @MainActor func worldLockedRayNeoPreservesCurrentPoseWithoutPrediction() throws {
    let view = MTKView(frame: CGRect(x: 0, y: 0, width: 16, height: 16))
    let filter = OrientationFilter()
    filter.update(gyro: .zero, accel: SIMD3(0, 1, 0), dt: 0.002)
    let renderer = try Renderer(view: view, scene: SpatialScene(screens: [ScreenPose(yaw: 0, pitch: 0, distance: 2, width: 1, aspect: 1)]), filter: filter)
    renderer.stabilizer.level = .medium
    renderer.headPipeline.predictionSeconds = 0
    renderer.headPipeline.maxPrediction = 0
    renderer.draw(in: view, targetTime: CACurrentMediaTime() + 0.01)
    filter.alignYaw(to: 0.05)
    renderer.draw(in: view, targetTime: CACurrentMediaTime() + 0.01)
    let expected = filter.orientation(predictAhead: 0)
    let error = 2 * acos(min(1, abs(simd_dot(renderer.currentHead.vector, expected.vector))))
    #expect(error < 1e-8)
}

@Test @MainActor func manualPredictionSurvivesFramesWithAutomaticTuningDisabled() throws {
    let view = MTKView(frame: CGRect(x: 0, y: 0, width: 16, height: 16))
    let renderer = try Renderer(view: view, scene: SpatialScene(screens: [ScreenPose(yaw: 0, pitch: 0, distance: 2, width: 1, aspect: 1)]), filter: OrientationFilter())
    renderer.headPipeline.predictionBias = 0.007
    renderer.adaptivePrediction = false
    renderer.draw(in: view, targetTime: CACurrentMediaTime() + 0.01)
    #expect(renderer.headPipeline.predictionBias == 0.007)
}

@Test @MainActor func worldLockedRendererUsesLateExternalRotationWithoutChangingScenePosition() throws {
    let view = MTKView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
    let screen = ScreenPose(yaw: 0, pitch: 0, distance: 2, width: 1, aspect: 1)
    let renderer = try Renderer(view: view, scene: SpatialScene(screens: [screen]), filter: OrientationFilter())
    let late = yawPitchQuat(yaw: 0.03, pitch: -0.02)
    var samples = 0
    var callbacks = 0
    var positionBeforeWarp: SIMD3<Double>?
    renderer.externalPose = { _ in
        samples += 1
        if samples == 2 { positionBeforeWarp = renderer.currentHeadOffset }
        return samples == 1 ? (yawPitchQuat(yaw: 0, pitch: 0), SIMD3(0.1, 0, 0), 0.02)
            : (late, SIMD3(1, 0, 0), 0.015)
    }
    renderer.onFrame = { orientation in
        callbacks += 1
        #expect(abs(simd_dot(orientation.vector, late.vector)) > 1 - 1e-10)
    }
    renderer.draw(in: view, targetTime: CACurrentMediaTime() + 0.01)
    #expect(samples == 2)
    #expect(callbacks == 1)
    #expect(renderer.lastReprojectionApplied)
    #expect(abs(renderer.lastPredictionHorizon - 0.015) < 1e-9)
    #expect(renderer.currentHeadOffset == (try #require(positionBeforeWarp)))
}

@Test @MainActor func worldLockedRendererKeepsItsPoseWhenExternalTrackingDisappearsDuringFrame() throws {
    let view = MTKView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
    let screen = ScreenPose(yaw: 0, pitch: 0, distance: 2, width: 1, aspect: 1)
    let filter = OrientationFilter()
    filter.alignYaw(to: 1)
    let renderer = try Renderer(view: view, scene: SpatialScene(screens: [screen]), filter: filter)
    let external = yawPitchQuat(yaw: 0.03, pitch: 0.01)
    var samples = 0
    renderer.externalPose = { _ in
        samples += 1
        return samples == 1 ? (external, .zero, 0.02) : nil
    }
    renderer.draw(in: view, targetTime: CACurrentMediaTime() + 0.01)
    #expect(samples == 2)
    #expect(renderer.usedExternalOrientation)
    #expect(abs(simd_dot(renderer.currentHead.vector, external.vector)) > 1 - 1e-10)
}

@Test @MainActor func disablingWorldLockRestoresOptionalSmoothing() throws {
    let view = MTKView(frame: CGRect(x: 0, y: 0, width: 16, height: 16))
    let screen = ScreenPose(yaw: 0, pitch: 0, distance: 2, width: 1, aspect: 1)
    let renderer = try Renderer(view: view, scene: SpatialScene(screens: [screen]), filter: OrientationFilter())
    renderer.worldLockedPresentation = false
    renderer.stabilizer.level = .medium
    renderer.externalPose = { _ in (yawPitchQuat(yaw: 0, pitch: 0), .zero, 0) }
    renderer.draw(in: view, targetTime: CACurrentMediaTime() + 0.01)
    let turned = yawPitchQuat(yaw: 0.05, pitch: 0)
    renderer.externalPose = { _ in (turned, .zero, 0) }
    renderer.draw(in: view, targetTime: CACurrentMediaTime() + 0.01)
    #expect(renderer.currentHead.yawPitch.yaw < 0.05)
    #expect(!renderer.lastReprojectionApplied)
}
