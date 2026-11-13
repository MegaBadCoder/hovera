import Foundation
import Testing
@testable import RayDeskCore
@testable import RayDesk
@testable import VitureSDK

@Test func rayNeoCarriesItsPredictionLimitToRowCompensation() throws {
    let filter = OrientationFilter()
    filter.clock = { 100 }
    filter.update(gyro: .zero, accel: SIMD3(0, 1, 0), dt: 0.002)
    filter.update(gyro: SIMD3(0, 1, 0), accel: SIMD3(0, 1, 0), dt: 0.002)
    let source = ReprojectionPoseSource.rayNeo(filter, bias: 0, limit: 0.045, fallback: 0)
    let pose = try #require(source.sample(100.04))
    #expect(pose.maximumPredictionHorizon == 0.045)
    #expect(abs(pose.maximumPredictionHorizon - pose.horizon - 0.005) < 1e-10)
}

extension VitureIntegrationTests {
    struct ScanoutBudget {
        @Test func vitureReportsRemainingBudgetAndHonorsDisabledExtrapolation() throws {
            let sdk = try TestVitureSDK()
            let device = try #require(sdk.library.createDevice(productID: 0x1104))
            let tracker = try VitureTracker.start(library: sdk.library, device: device, productID: 0x1104,
                                                productName: "test", automaticallyPoll: false, clock: { 100 }, connectionCheck: { true })
            defer {
                let done = DispatchSemaphore(value: 0)
                tracker.stop { done.signal() }
                #expect(done.wait(timeout: .now() + 2) == .success)
            }
            tracker.usesFusion = false
            tracker.usesExtrapolation = true
            tracker.poll()
            sdk.symbol("test_emit_imu", as: (@convention(c) (Float, Double) -> Void).self)(1, 100)
            let source = ReprojectionPoseSource.viture(tracker, clock: { 100 })
            let pose = try #require(source.sample(100.049))
            #expect(pose.maximumPredictionHorizon == 0.05)
            #expect(abs(pose.maximumPredictionHorizon - pose.horizon - 0.001) < 1e-10)
            tracker.usesExtrapolation = false
            #expect(try #require(source.sample(100.02)).maximumPredictionHorizon == 0)
        }
    }
}
