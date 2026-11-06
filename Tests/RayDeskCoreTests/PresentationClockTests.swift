import Foundation
import Testing
@testable import RayDeskCore

@Test func presentTimeEqualsTargetBeforeAnyMeasurement() {
    let clock = PresentationClock()
    #expect(clock.offset == nil)
    #expect(abs(clock.presentTime(target: 100) - 100) < 1e-12)
}

@Test func measuredOffsetMovesThePresentTimeForward() {
    let clock = PresentationClock()
    clock.observe(target: 10, presented: 10.004)
    #expect(abs((clock.offset ?? 0) - 0.004) < 1e-9)
    #expect(abs(clock.presentTime(target: 20) - 20.004) < 1e-9)
}

@Test func offsetIsClampedToTheAllowedRange() {
    let clock = PresentationClock(maxOffset: 0.030)
    clock.observe(target: 1, presented: 0.5)
    #expect(abs(clock.offset ?? -1) < 1e-12)
    for _ in 0..<100 {
        clock.observe(target: 1, presented: 5)
    }
    #expect(abs((clock.offset ?? 0) - 0.030) < 1e-6)
}

@Test func repeatedSamplesApproachTheMeasuredOffset() {
    let clock = PresentationClock(smoothing: 0.1)
    for _ in 0..<20 {
        clock.observe(target: 0, presented: 0.010)
    }
    let offset = clock.offset ?? 0
    #expect(offset > 0.008)
    #expect(offset < 0.0101)
}

@Test func concurrentSamplesKeepTheOffsetFinite() async {
    let clock = PresentationClock()
    await withTaskGroup(of: Void.self) { group in
        for thread in 0..<8 {
            group.addTask {
                for step in 0..<200 {
                    let delay = Double((thread + step) % 7) / 1000
                    clock.observe(target: 1, presented: 1 + delay)
                }
            }
        }
    }
    let offset = clock.offset ?? -1
    #expect(offset.isFinite)
    #expect(offset >= 0)
    #expect(offset <= clock.maxOffset)
}
