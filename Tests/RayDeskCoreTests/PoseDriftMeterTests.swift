import Foundation
import Testing
@testable import VitureSDK

@Test func driftIsMeasuredWhileTheHeadIsStill() {
    var meter = PoseDriftMeter()
    var yaw = 0.0
    for step in 0...120 {
        let time = Double(step) / 4
        yaw = 12 * time / 60
        meter.add(time: time, yaw: yaw, pitch: 0, roll: 0, angularSpeed: 0.001)
    }
    let drift = try? #require(meter.driftPerMinute)
    #expect(abs((drift?.yaw ?? 0) - 12) < 0.5)
}

@Test func motionResetsTheMeasurement() {
    var meter = PoseDriftMeter()
    for step in 0...40 {
        meter.add(time: Double(step), yaw: Double(step), pitch: 0, roll: 0, angularSpeed: 0.001)
    }
    meter.add(time: 41, yaw: 200, pitch: 0, roll: 0, angularSpeed: 1.0)
    #expect(meter.driftPerMinute == nil)
    #expect(meter.measuredSpan == 0)
}

@Test func shortStillWindowIsNotEnough() {
    var meter = PoseDriftMeter()
    for step in 0...10 {
        meter.add(time: Double(step) / 4, yaw: Double(step) / 4, pitch: 0, roll: 0, angularSpeed: 0.001)
    }
    #expect(meter.driftPerMinute == nil)
}
