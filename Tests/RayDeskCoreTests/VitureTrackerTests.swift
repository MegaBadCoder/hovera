import Foundation
import Testing
import simd
@testable import RayDesk
@testable import VitureSDK

private final class SharedTracker: @unchecked Sendable {
    let value: VitureTracker
    init(_ value: VitureTracker) { self.value = value }
}

private final class TrackerClock {
    var time = 100.0
}

extension VitureIntegrationTests {
    struct Tracker {
        private func start(_ sdk: TestVitureSDK, _ clock: TrackerClock, connected: @escaping () -> Bool = { true }) throws -> VitureTracker {
            let device = try #require(sdk.library.createDevice(productID: 0x1104))
            return try VitureTracker.start(library: sdk.library, device: device, productID: 0x1104, productName: "test", automaticallyPoll: false, clock: { clock.time }, connectionCheck: connected)
        }

        private func stop(_ tracker: VitureTracker) {
            let done = DispatchSemaphore(value: 0)
            tracker.stop { done.signal() }
            #expect(done.wait(timeout: .now() + 2) == .success)
        }

        @Test func stableSDKTeleportDoesNotReachRenderedPosition() throws {
            let sdk = try TestVitureSDK()
            let clock = TrackerClock()
            let tracker = try start(sdk, clock)
            defer { stop(tracker) }
            tracker.usesFusion = false
            tracker.usesExtrapolation = false
            for _ in 0..<120 {
                clock.time += 1.0 / 120
                tracker.poll()
            }
            let setPosition = sdk.symbol("test_pose_position", as: (@convention(c) (Float, Float, Float) -> Void).self)
            setPosition(-2.34, -5.36, -6.76)
            clock.time += 1.0 / 120
            tracker.poll()
            let rejected = try #require(tracker.pose())
            #expect(rejected.position == .zero)
            #expect(rejected.isStable)
            for _ in 0..<120 {
                clock.time += 1.0 / 120
                tracker.poll()
                #expect(length(try #require(tracker.pose()).position) < 1e-9)
            }
            setPosition(-2.33, -5.36, -6.76)
            clock.time += 1.0 / 120
            tracker.poll()
            #expect(abs(try #require(tracker.pose()).position.x - 0.01) < 1e-5)
            let reset = DispatchSemaphore(value: 0)
            tracker.resetOrigin(to: try #require(tracker.pose())) { success in
                #expect(success)
                reset.signal()
            }
            #expect(reset.wait(timeout: .now() + 2) == .success)
            #expect(abs(sdk.symbol("test_reset_position_x", as: (@convention(c) () -> Float).self)() + 2.33) < 1e-5)
        }

        @Test func independentViturePoseReadsFreshCacheWithoutRenderingScene() throws {
            let sdk = try TestVitureSDK()
            let clock = TrackerClock()
            let tracker = try start(sdk, clock)
            defer { stop(tracker) }
            tracker.usesFusion = true
            tracker.usesExtrapolation = false
            tracker.poll()
            let source = ReprojectionPoseSource.viture(tracker, clock: { clock.time })
            let first = try #require(source.sample(clock.time))
            sdk.symbol("test_pose_mode", as: (@convention(c) (Int32) -> Void).self)(1)
            for _ in 0..<24 {
                clock.time += 1.0 / 120
                sdk.symbol("test_emit_imu", as: (@convention(c) (Float, Double) -> Void).self)(1, clock.time)
                tracker.poll()
            }
            let latest = try #require(source.sample(clock.time + 10))
            #expect(latest.orientation.yawPitch.yaw - first.orientation.yawPitch.yaw > 0.15)
            #expect(latest.horizon <= 0.05)
        }

        @Test func adaptiveVSyncRejectsStaleVitureTrackingEvenWhenCachedPoseRemainsStable() throws {
            let sdk = try TestVitureSDK()
            let clock = TrackerClock()
            let tracker = try start(sdk, clock)
            defer { stop(tracker) }
            tracker.usesFusion = false
            tracker.poll()
            let source = ReprojectionPoseSource.viture(tracker, clock: { clock.time })
            #expect(try #require(source.sample(clock.time)).isStable)
            clock.time += 0.2
            #expect(try #require(source.sample(clock.time)).isStable == false)
            tracker.poll()
            #expect(try #require(source.sample(clock.time)).isStable)
            clock.time -= 0.1
            #expect(try #require(source.sample(clock.time)).isStable == false)
        }

        @Test func firstPoseHasAWaitingDeadline() throws {
            let sdk = try TestVitureSDK()
            let clock = TrackerClock()
            let tracker = try start(sdk, clock)
            defer { stop(tracker) }
            clock.time += 12
            #expect((tracker.poseAge ?? 0) >= 12)
        }

        @Test func independentViturePredictionStartsFromCurrentSDKPose() throws {
            let sdk = try TestVitureSDK()
            let clock = TrackerClock()
            let tracker = try start(sdk, clock)
            defer { stop(tracker) }
            tracker.usesFusion = false
            tracker.usesExtrapolation = true
            tracker.poll()
            sdk.symbol("test_emit_imu", as: (@convention(c) (Float, Double) -> Void).self)(1, clock.time)
            let current = try #require(tracker.pose(predictTime: 0))
            let source = ReprojectionPoseSource.viture(tracker, clock: { clock.time })
            let sample = try #require(source.sample(clock.time + 0.02))
            let error = 2 * acos(min(1, abs(simd_dot(current.orientation.vector, sample.orientation.vector))))
            #expect(error < 1e-8)
            #expect(abs(sample.horizon - 0.02) < 1e-10)
        }

        @Test func connectionIsCheckedEvenWithoutAPose() throws {
            let sdk = try TestVitureSDK()
            sdk.symbol("test_pose_mode", as: (@convention(c) (Int32) -> Void).self)(1)
            let tracker = try start(sdk, TrackerClock(), connected: { false })
            defer { stop(tracker) }
            tracker.poll()
            #expect(!tracker.isConnected)
        }

        @Test func missingPoseStillIntegratesFreshGyro() throws {
            let sdk = try TestVitureSDK()
            let clock = TrackerClock()
            let tracker = try start(sdk, clock)
            defer { stop(tracker) }
            tracker.usesFusion = true
            tracker.usesExtrapolation = false
            tracker.poll()
            sdk.symbol("test_pose_mode", as: (@convention(c) (Int32) -> Void).self)(1)
            for _ in 0..<12 {
                clock.time += 1.0 / 120
                sdk.symbol("test_emit_imu", as: (@convention(c) (Float, Double) -> Void).self)(1, clock.time)
                tracker.poll()
            }
            let pose = try #require(tracker.pose())
            #expect(pose.orientation.yawPitch.yaw > 0.08)
            #expect(!pose.isStable)
            #expect((tracker.poseAge ?? 0) > 0.09)
        }

        @Test func predictionIncludesAgeOfCachedPose() throws {
            let sdk = try TestVitureSDK()
            let clock = TrackerClock()
            let tracker = try start(sdk, clock)
            defer { stop(tracker) }
            tracker.usesFusion = false
            tracker.usesExtrapolation = true
            tracker.poll()
            sdk.symbol("test_emit_imu", as: (@convention(c) (Float, Double) -> Void).self)(1, clock.time)
            clock.time += 0.01
            let pose = try #require(tracker.pose(predictTime: 0.01))
            #expect(abs(pose.orientation.yawPitch.yaw - 0.02) < 0.001)
        }

        @Test func reportedHorizonMatchesThePredictedPoseIncludingItsAge() throws {
            let sdk = try TestVitureSDK()
            let clock = TrackerClock()
            let tracker = try start(sdk, clock)
            defer { stop(tracker) }
            tracker.usesFusion = false
            tracker.usesExtrapolation = true
            tracker.poll()
            sdk.symbol("test_emit_imu", as: (@convention(c) (Float, Double) -> Void).self)(1, clock.time)
            clock.time += 0.01
            let sample = try #require(tracker.poseSample(predictTime: 0.02))
            #expect(abs(sample.predictionHorizon - 0.03) < 1e-6)
            #expect(abs(sample.pose.orientation.yawPitch.yaw - sample.predictionHorizon) < 1e-6)
        }

        @Test func reportedHorizonRespectsCapAndDisabledOrStalePrediction() throws {
            let sdk = try TestVitureSDK()
            let clock = TrackerClock()
            let tracker = try start(sdk, clock)
            defer { stop(tracker) }
            tracker.usesFusion = false
            tracker.usesExtrapolation = true
            tracker.poll()
            #expect(tracker.poseSample(predictTime: 0.2)?.predictionHorizon == 0)
            sdk.symbol("test_emit_imu", as: (@convention(c) (Float, Double) -> Void).self)(1, clock.time)
            #expect(tracker.poseSample(predictTime: 0.2)?.predictionHorizon == 0.05)
            #expect(tracker.poseSample(predictTime: 0)?.predictionHorizon == 0)
            tracker.usesExtrapolation = false
            #expect(tracker.poseSample(predictTime: 0.2)?.predictionHorizon == 0)
            tracker.usesExtrapolation = true
            clock.time += 0.2
            #expect(tracker.poseSample(predictTime: 0.2)?.predictionHorizon == 0)
        }

        @Test func fusionDoesNotOverrideAStableSDKPose() throws {
            let sdk = try TestVitureSDK()
            let clock = TrackerClock()
            let tracker = try start(sdk, clock)
            defer { stop(tracker) }
            tracker.usesFusion = true
            tracker.usesExtrapolation = false
            tracker.poll()
            for _ in 0..<120 {
                clock.time += 1.0 / 120
                sdk.symbol("test_emit_imu", as: (@convention(c) (Float, Double) -> Void).self)(0.02, clock.time)
                tracker.poll()
            }
            let pose = try #require(tracker.pose())
            #expect(abs(pose.orientation.yawPitch.yaw) < 1e-6)
            #expect(pose.isStable)
        }

        @Test func predictionCannotExtendFusionPastTrackingLossWindow() throws {
            let sdk = try TestVitureSDK()
            let clock = TrackerClock()
            let tracker = try start(sdk, clock)
            defer { stop(tracker) }
            tracker.usesFusion = true
            tracker.usesExtrapolation = true
            tracker.poll()
            sdk.symbol("test_pose_mode", as: (@convention(c) (Int32) -> Void).self)(1)
            for step in 1...120 {
                clock.time += 1.0 / 120
                sdk.symbol("test_emit_imu", as: (@convention(c) (Float, Double) -> Void).self)(1, clock.time)
                tracker.poll()
                if step == 29 {
                    let predicted = try #require(tracker.poseSample(predictTime: 0.05))
                    #expect(abs(predicted.pose.orientation.yawPitch.yaw - 0.25) < 1e-6)
                    #expect(abs(predicted.predictionHorizon - 1.0 / 120) < 1e-6)
                }
            }
            let frozen = try #require(tracker.poseSample(predictTime: 0.05))
            #expect(abs(frozen.pose.orientation.yawPitch.yaw - 0.25) < 1e-6)
            #expect(!frozen.pose.isStable)
            #expect(frozen.predictionHorizon == 0)
            sdk.symbol("test_pose_mode", as: (@convention(c) (Int32) -> Void).self)(0)
            clock.time += 1.0 / 120
            tracker.poll()
            let recovered = try #require(tracker.pose())
            #expect(abs(recovered.orientation.yawPitch.yaw) < 1e-6)
            #expect(recovered.isStable)
        }

        @Test func oldIMUDoesNotPredictMotion() throws {
            let sdk = try TestVitureSDK()
            let clock = TrackerClock()
            let tracker = try start(sdk, clock)
            defer { stop(tracker) }
            tracker.usesFusion = false
            tracker.usesExtrapolation = true
            tracker.poll()
            sdk.symbol("test_emit_imu", as: (@convention(c) (Float, Double) -> Void).self)(1, clock.time)
            clock.time += 0.5
            tracker.poll()
            let pose = try #require(tracker.pose(predictTime: 0.02))
            #expect(abs(pose.orientation.yawPitch.yaw) < 0.001)
        }
        @Test func tintIsRestoredOnDisableAndShutdown() throws {
            let sdk = try TestVitureSDK()
            let tracker = try start(sdk, TrackerClock())
            let film = sdk.symbol("test_film", as: (@convention(c) () -> Float).self)
            let writes = sdk.symbol("test_film_writes", as: (@convention(c) () -> Int32).self)
            tracker.setLensTint(false)
            tracker.poll()
            #expect(film() == 0)
            tracker.setLensTint(false)
            tracker.poll()
            #expect(writes() == 1)
            tracker.setLensTint(true)
            tracker.poll()
            #expect(film() == 1)
            tracker.setLensTint(nil)
            tracker.poll()
            #expect(film() == 0.75)
            tracker.setLensTint(false)
            tracker.poll()
            stop(tracker)
            #expect(film() == 0.75)
            #expect(sdk.trace == 123456)
        }

        @Test func unsupportedFilmControlDoesNotStopTracking() throws {
            let sdk = try TestVitureSDK()
            let tracker = try start(sdk, TrackerClock())
            defer { stop(tracker) }
            sdk.fail(at: 5)
            tracker.setLensTint(false)
            tracker.poll()
            #expect(!tracker.supportsFilmControl)
            #expect(tracker.pose() != nil)
        }

        @Test func initialAndRunningPoseTimeoutsAreDifferent() throws {
            let sdk = try TestVitureSDK()
            let clock = TrackerClock()
            let tracker = try start(sdk, clock)
            defer { stop(tracker) }
            clock.time += 5
            #expect(!tracker.shouldRestart)
            clock.time += 6
            #expect(tracker.shouldRestart)
            tracker.poll()
            #expect(!tracker.shouldRestart)
            clock.time += 2.1
            #expect(tracker.shouldRestart)
        }

        @Test func callbackRegistrationFailureCleansUpDevice() throws {
            let sdk = try TestVitureSDK()
            sdk.fail(at: 4)
            #expect(throws: VitureTracker.StartError.self) { try start(sdk, TrackerClock()) }
            #expect(sdk.trace == 12456)
        }

        @Test func stoppedTrackerIsReleased() throws {
            let sdk = try TestVitureSDK()
            weak var released: VitureTracker?
            do {
                let tracker = try start(sdk, TrackerClock())
                released = tracker
                stop(tracker)
                tracker.poll()
            }
            #expect(released == nil)
        }

        @Test func stoppingWaitsForSDKCallWithoutBlockingCaller() throws {
            let sdk = try TestVitureSDK()
            let tracker = try start(sdk, TrackerClock())
            tracker.poll()
            let shared = SharedTracker(tracker)
            sdk.symbol("test_block_next_pose", as: (@convention(c) () -> Void).self)()
            DispatchQueue.global().async { shared.value.poll() }
            let entered = sdk.symbol("test_wait_for_pose", as: (@convention(c) () -> Int32).self)()
            #expect(entered == 0)
            let done = DispatchSemaphore(value: 0)
            tracker.stop { done.signal() }
            #expect(done.wait(timeout: .now()) == .timedOut)
            #expect(tracker.pose() == nil)
            sdk.symbol("test_release_pose", as: (@convention(c) () -> Void).self)()
            #expect(done.wait(timeout: .now() + 2) == .success)
            #expect(sdk.symbol("test_overlapping_control", as: (@convention(c) () -> Int32).self)() == 0)
            #expect(sdk.trace == 123456)
        }

        @Test func concurrentPoseReadsResetsAndSettingsStayConsistent() throws {
            let sdk = try TestVitureSDK()
            let tracker = try start(sdk, TrackerClock())
            defer { stop(tracker) }
            tracker.poll()
            let shared = SharedTracker(tracker)
            let group = DispatchGroup()
            for worker in 0..<3 {
                DispatchQueue.global().async(group: group) {
                    for index in 0..<200 {
                        switch worker {
                        case 0:
                            shared.value.poll()
                        case 1:
                            shared.value.usesFusion = index.isMultiple(of: 2)
                            _ = shared.value.pose(predictTime: 0.01)
                            _ = shared.value.gyroBias
                        default:
                            if let pose = shared.value.pose() { shared.value.resetOrigin(to: pose) }
                        }
                    }
                }
            }
            #expect(group.wait(timeout: .now() + 5) == .success)
            tracker.poll()
            let pose = try #require(tracker.pose())
            #expect(pose.orientation.vector.x.isFinite)
            #expect(abs(simd_length(pose.orientation.vector) - 1) < 1e-6)
        }

    }
}
