import Foundation
import Testing
@testable import RayDesk
@testable import VitureSDK

private final class CurrentPoseClock {
    var time = 100.0
}

extension VitureIntegrationTests {
    struct CurrentTimePrediction {
        @Test(arguments: [false, true])
        func currentTimePredictionIncludesCacheAgeWithoutChangingTheBasePose(useFusion: Bool) throws {
            let sdk = try TestVitureSDK()
            let clock = CurrentPoseClock()
            let device = try #require(sdk.library.createDevice(productID: 0x1104))
            let tracker = try VitureTracker.start(library: sdk.library, device: device, productID: 0x1104,
                                                productName: "diagnostic", automaticallyPoll: false,
                                                clock: { clock.time }, connectionCheck: { true })
            defer {
                let done = DispatchSemaphore(value: 0)
                tracker.stop { done.signal() }
                #expect(done.wait(timeout: .now() + 2) == .success)
            }
            tracker.usesFusion = useFusion
            tracker.usesExtrapolation = true
            sdk.symbol("test_emit_imu", as: (@convention(c) (Float, Double) -> Void).self)(1, clock.time)
            tracker.poll()
            let base = try #require(tracker.poseSample(predictTime: 0, extrapolate: false)).pose
            clock.time += 0.008
            let current = try #require(tracker.poseSample(predictTime: 0, extrapolate: false))
            let nearCurrent = try #require(tracker.poseSample(predictTime: 0.000001, extrapolate: false))
            print("Pose timing diagnostic: known cache age=8ms, ahead=0 horizon=\(current.predictionHorizon * 1000)ms, ahead=0.001ms horizon=\(nearCurrent.predictionHorizon * 1000)ms")
            #expect(abs(current.predictionHorizon - 0.008) < 1e-9)
            #expect(abs(nearCurrent.predictionHorizon - current.predictionHorizon - 0.000001) < 1e-9)
            #expect(current.pose == base)
            let source = ReprojectionPoseSource.viture(tracker, clock: { clock.time })
            let immediate = try #require(source.sample(clock.time))
            #expect(abs(immediate.horizon - 0.008) < 1e-9)
            tracker.usesExtrapolation = false
            #expect(tracker.poseSample(predictTime: 0, extrapolate: false)?.predictionHorizon == 0)
        }
    }
}
