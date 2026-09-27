import Foundation
import Testing
@testable import RayDeskCore

private func measure(_ fixture: String, level: StabilizationLevel = .off, withCompass: Bool = false) throws -> TrackingMetrics {
    let rows = try Fixture.rows(fixture)
    let pipeline = HeadPipeline(filter: OrientationFilter())
    pipeline.stabilizer.level = level
    return TrackingReplay.measure(rows, pipeline: pipeline, compass: withCompass ? try TrackingReplay.compassCalibration(rows) : nil)
}

@Test func trackingAddsAlmostNoJitterOrLagOnRecordedHeadTurns() throws {
    let metrics = try measure("head-turns.csv")
    #expect(metrics.jitterDegrees < 0.03)
    #expect(abs(metrics.lagMilliseconds) < 5)
}

@Test func trackingWithCompassStaysSteadyOnRecordedWear() throws {
    let metrics = try measure("carousel.csv.lzfse", withCompass: true)
    #expect(metrics.jitterDegrees < 0.04)
    #expect(abs(metrics.lagMilliseconds) < 5)
    #expect(try #require(metrics.headingDriftDegrees) < 3)
}

@Test func oneEuroStabilizationCostsLagThatWeCanMeasure() throws {
    let off = try measure("head-turns.csv")
    let medium = try measure("head-turns.csv", level: .medium)
    #expect(medium.lagMilliseconds > off.lagMilliseconds + 10)
}
