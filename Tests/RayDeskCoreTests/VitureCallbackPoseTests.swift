import Foundation
import Testing
import simd
@testable import RayDesk
@testable import VitureSDK

extension VitureIntegrationTests {
    struct CallbackPose {
        @Test func aBlockedUSBRegistryCheckDoesNotBlockNativePoseDelivery() throws {
            let sdk = try TestVitureSDK()
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let device = try #require(sdk.library.createDevice(productID: 0x1104))
            let tracker = try VitureTracker.start(library: sdk.library, device: device, productID: 0x1104,
                                                productName: "test", automaticallyPoll: true, clock: { 100 },
                                                connectionCheck: {
                                                    entered.signal()
                                                    _ = release.wait(timeout: .now() + 3)
                                                    return true
                                                }, poseMode: .callback, nativeToHost: { $0 - 1000 })
            defer {
                release.signal()
                let stopped = DispatchSemaphore(value: 0)
                tracker.stop { stopped.signal() }
                #expect(stopped.wait(timeout: .now() + 2) == .success)
            }
            #expect(entered.wait(timeout: .now() + 2) == .success)
            sdk.symbol("test_emit_pose", as: (@convention(c) (Double) -> Void).self)(1100)
            let deadline = Date(timeIntervalSinceNow: 0.3)
            while tracker.pose() == nil && Date() < deadline {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
            }
            #expect(tracker.pose() != nil)
        }

        @Test func callbackDuringFailedStartCannotRaceDeviceCleanup() throws {
            let sdk = try TestVitureSDK()
            sdk.fail(at: 7)
            sdk.symbol("test_block_next_pose", as: (@convention(c) () -> Void).self)()
            defer { sdk.symbol("test_release_pose", as: (@convention(c) () -> Void).self)() }
            let device = try #require(sdk.library.createDevice(productID: 0x1104))
            do {
                _ = try VitureTracker.start(library: sdk.library, device: device, productID: 0x1104,
                                           productName: "test", automaticallyPoll: false, clock: { 100 },
                                           connectionCheck: { true }, poseMode: .callback,
                                           nativeToHost: { $0 - 1000 })
                Issue.record("SDK start unexpectedly succeeded")
            } catch VitureTracker.StartError.startupFailed { }
            #expect(sdk.symbol("test_native_calls", as: (@convention(c) () -> Int32).self)() == 0)
            #expect(sdk.symbol("test_overlapping_control", as: (@convention(c) () -> Int32).self)() == 0)
            #expect(sdk.trace == 123456)
        }

        @Test func missingNativeAPIRejectsCallbackModeAndClosesDevice() throws {
            let sdk = try TestVitureSDK(includesNativePose: false)
            let device = try #require(sdk.library.createDevice(productID: 0x1104))
            do {
                _ = try VitureTracker.start(library: sdk.library, device: device, productID: 0x1104,
                                           productName: "test", automaticallyPoll: false,
                                           connectionCheck: { true }, poseMode: .callback)
                Issue.record("Callback mode accepted missing native API")
            } catch VitureTracker.StartError.sdkUnavailable { }
            #expect(sdk.trace == 12456)
        }

        @Test func nativeMatrixRejectsShearInsteadOfInventingARotation() {
            var values = [Float](repeating: 0, count: 32)
            for index in [0, 5, 10, 15] { values[index] = 1 }
            values[30] = 2
            values[4] = 1
            #expect(ViturePose(nativeGL: values, timestamp: 100) == nil)
        }

        @Test func callbackCoalescesWhileSDKIsBlocked() throws {
            let sdk = try TestVitureSDK()
            let device = try #require(sdk.library.createDevice(productID: 0x1104))
            let tracker = try VitureTracker.start(library: sdk.library, device: device, productID: 0x1104,
                                                productName: "test", automaticallyPoll: false, clock: { 100 },
                                                connectionCheck: { true }, poseMode: .callback,
                                                nativeToHost: { $0 - 1000 })
            defer {
                let done = DispatchSemaphore(value: 0)
                tracker.stop { done.signal() }
                #expect(done.wait(timeout: .now() + 2) == .success)
            }
            sdk.symbol("test_block_next_pose", as: (@convention(c) () -> Void).self)()
            let emit = sdk.symbol("test_emit_pose", as: (@convention(c) (Double) -> Void).self)
            emit(1099.8)
            #expect(sdk.symbol("test_wait_for_pose", as: (@convention(c) () -> Int32).self)() == 0)
            for index in 0..<1000 { emit(1099.9 + Double(index) * 0.0001) }
            sdk.symbol("test_release_pose", as: (@convention(c) () -> Void).self)()
            tracker.poll()
            tracker.poll()
            #expect(sdk.symbol("test_native_calls", as: (@convention(c) () -> Int32).self)() == 2)
            #expect(abs(sdk.symbol("test_native_request", as: (@convention(c) () -> Double).self)() - 1099.9999) < 1e-8)
        }

        @Test func callbackStopWaitsForGetterAndDropsPendingRequests() throws {
            let sdk = try TestVitureSDK()
            let device = try #require(sdk.library.createDevice(productID: 0x1104))
            let tracker = try VitureTracker.start(library: sdk.library, device: device, productID: 0x1104,
                                                productName: "test", automaticallyPoll: false, clock: { 100 },
                                                connectionCheck: { true }, poseMode: .callback,
                                                nativeToHost: { $0 - 1000 })
            sdk.symbol("test_block_next_pose", as: (@convention(c) () -> Void).self)()
            let emit = sdk.symbol("test_emit_pose", as: (@convention(c) (Double) -> Void).self)
            emit(1099.9)
            #expect(sdk.symbol("test_wait_for_pose", as: (@convention(c) () -> Int32).self)() == 0)
            emit(1100)
            let done = DispatchSemaphore(value: 0)
            tracker.stop { done.signal() }
            sdk.symbol("test_release_pose", as: (@convention(c) () -> Void).self)()
            #expect(done.wait(timeout: .now() + 2) == .success)
            #expect(sdk.symbol("test_native_calls", as: (@convention(c) () -> Int32).self)() == 1)
            #expect(sdk.symbol("test_overlapping_control", as: (@convention(c) () -> Int32).self)() == 0)
        }

        @Test func nativeMatrixKeepsOpenGLAxesAndTrackingStatus() throws {
            let sdk = try TestVitureSDK()
            let device = try #require(sdk.library.createDevice(productID: 0x1104))
            defer { device.close() }
            #expect(device.initialize())
            sdk.symbol("test_native_angle", as: (@convention(c) (Float) -> Void).self)(0.4)
            sdk.symbol("test_pose_position", as: (@convention(c) (Float, Float, Float) -> Void).self)(1, 2, 3)
            let pose = try #require(device.nativePose(at: 1234))
            #expect(pose.timestamp == 1234)
            #expect(pose.position == SIMD3(1, 2, 3))
            #expect(abs(pose.orientation.yawPitch.yaw - 0.4) < 1e-6)
            #expect(pose.isStable)
            sdk.symbol("test_native_status", as: (@convention(c) (Int32) -> Void).self)(4)
            #expect(try #require(device.nativePose(at: 1234)).isStable == false)
            sdk.fail(at: 6)
            #expect(device.nativePose(at: 1234) == nil)
        }

        @Test func callbackUsesNativeTimestampAndDoesNotPollForPoses() throws {
            let sdk = try TestVitureSDK()
            let device = try #require(sdk.library.createDevice(productID: 0x1104))
            let tracker = try VitureTracker.start(library: sdk.library, device: device, productID: 0x1104,
                                                productName: "test", automaticallyPoll: false, clock: { 100 },
                                                connectionCheck: { true }, poseMode: .callback,
                                                nativeToHost: { $0 - 1000 })
            defer {
                let stopped = DispatchSemaphore(value: 0)
                tracker.stop { stopped.signal() }
                #expect(stopped.wait(timeout: .now() + 2) == .success)
            }
            tracker.usesFusion = false
            tracker.usesExtrapolation = false
            tracker.poll()
            #expect(tracker.pose() == nil)
            let config = String(cString: sdk.symbol("test_custom_config", as: (@convention(c) () -> UnsafePointer<CChar>).self)())
            #expect(config.contains("pose_callback_frequency: 1000"))
            #expect(config.contains("pose_format: matrix"))
            sdk.symbol("test_emit_pose", as: (@convention(c) (Double) -> Void).self)(1099.99)
            tracker.poll()
            #expect(tracker.pose() != nil)
            #expect(sdk.symbol("test_native_request", as: (@convention(c) () -> Double).self)() == 1099.99)
            #expect(abs((tracker.poseAge ?? 0) - 0.01) < 1e-8)
            let count = sdk.symbol("test_native_calls", as: (@convention(c) () -> Int32).self)()
            tracker.poll()
            #expect(sdk.symbol("test_native_calls", as: (@convention(c) () -> Int32).self)() == count)
        }

        @Test func callbackRejectsWrongClockAndStopsAcceptingAfterClose() throws {
            let sdk = try TestVitureSDK()
            let device = try #require(sdk.library.createDevice(productID: 0x1104))
            let tracker = try VitureTracker.start(library: sdk.library, device: device, productID: 0x1104,
                                                productName: "test", automaticallyPoll: false, clock: { 100 },
                                                connectionCheck: { true }, poseMode: .callback,
                                                nativeToHost: { $0 - 1000 })
            let emit = sdk.symbol("test_emit_pose", as: (@convention(c) (Double) -> Void).self)
            emit(10)
            emit(.nan)
            emit(1101)
            tracker.poll()
            #expect(tracker.pose() == nil)
            let done = DispatchSemaphore(value: 0)
            tracker.stop { done.signal() }
            #expect(done.wait(timeout: .now() + 2) == .success)
            emit(1100)
            #expect(sdk.symbol("test_native_calls", as: (@convention(c) () -> Int32).self)() == 0)
        }
    }
}
