import Testing
import simd
@testable import RayDeskCore

private let pacingIdentity = simd_quatd(angle: 0, axis: SIMD3(0, 1, 0))

@discardableResult
private func recordPacingFrames(_ pacer: PresentationFramePacer, start: Double = 100,
                                count: Int, delayPeriods: Double = 3, rate: Double = 120) -> Double {
    var presented = start
    for index in 0..<count {
        let renderStart = start + Double(index) / rate
        presented = renderStart + delayPeriods / rate
        pacer.updateMotion(pacingIdentity, at: renderStart, stable: true)
        pacer.observe(renderStart: renderStart, presented: presented, now: presented)
    }
    return presented
}

@Suite struct PresentationFramePacerTests {
    @Test func sustainedPresentationDelayRequestsExactlyOneSkip() {
        let pacer = PresentationFramePacer(refreshPeriod: 1 / 120)
        let before = recordPacingFrames(pacer, count: 29)
        #expect(!pacer.consumeDrain(at: before))
        let time = recordPacingFrames(pacer, start: 100 + 29.0 / 120, count: 1)
        #expect(pacer.consumeDrain(at: time))
        #expect(!pacer.consumeDrain(at: time))
        #expect(pacer.snapshot.skipped == 1)
    }

    @Test func aTimelyPresentationBreaksTheDelayStreak() {
        let pacer = PresentationFramePacer(refreshPeriod: 1 / 120)
        recordPacingFrames(pacer, count: 29)
        recordPacingFrames(pacer, start: 100.25, count: 1, delayPeriods: 1)
        let time = recordPacingFrames(pacer, start: 100.3, count: 29)
        #expect(!pacer.consumeDrain(at: time))
        #expect(pacer.snapshot.overStreak == 29)
    }

    @Test(arguments: [60.0, 90.0, 120.0, 144.0])
    func thresholdUsesTheConfiguredRefreshPeriod(rate: Double) throws {
        let pacer = PresentationFramePacer(refreshPeriod: 1 / rate)
        let timely = recordPacingFrames(pacer, count: 40, delayPeriods: 2.1, rate: rate)
        #expect(!pacer.consumeDrain(at: timely))
        let delayed = recordPacingFrames(pacer, start: 101, count: 30, delayPeriods: 2.3, rate: rate)
        #expect(pacer.consumeDrain(at: delayed))
        #expect(abs(try #require(pacer.snapshot.latencyPeriods) - 2.3) < 1e-9)
    }

    @Test func rapidMovementCancelsAPendingSkip() {
        let pacer = PresentationFramePacer(refreshPeriod: 1 / 120)
        let time = recordPacingFrames(pacer, count: 30)
        #expect(pacer.snapshot.drainRequested)
        let turned = simd_quatd(angle: 0.2, axis: SIMD3(0, 1, 0))
        pacer.updateMotion(turned, at: time + 1 / 120, stable: true)
        #expect(!pacer.consumeDrain(at: time + 1 / 120))
        #expect(!pacer.snapshot.drainRequested)
    }

    @Test(arguments: [false, true])
    func missingTrackingOrAPauseCancelsAPendingSkip(pause: Bool) {
        let pacer = PresentationFramePacer(refreshPeriod: 1 / 120)
        let time = recordPacingFrames(pacer, count: 30)
        pacer.updateMotion(pacingIdentity, at: time + (pause ? 0.2 : 0.001), stable: pause)
        #expect(!pacer.consumeDrain(at: time + (pause ? 0.2 : 0.001)))
        #expect(!pacer.snapshot.drainRequested)
    }

    @Test func unobservedHeadMotionExpiresBeforeConsumingASkip() {
        let pacer = PresentationFramePacer(refreshPeriod: 1 / 120)
        let time = recordPacingFrames(pacer, count: 30)
        #expect(!pacer.consumeDrain(at: time + 0.2))
        #expect(!pacer.snapshot.drainRequested)
    }

    @Test func sustainedDelayCannotSkipAgainDuringCooldown() {
        let pacer = PresentationFramePacer(refreshPeriod: 1 / 120)
        let first = recordPacingFrames(pacer, count: 30)
        #expect(pacer.consumeDrain(at: first))
        let early = recordPacingFrames(pacer, start: 100.5, count: 100)
        #expect(!pacer.consumeDrain(at: early))
        let later = recordPacingFrames(pacer, start: first + 3.01, count: 30)
        #expect(pacer.consumeDrain(at: later))
        #expect(pacer.snapshot.skipped == 2)
    }

    @Test func oldCallbacksAndInvalidTimestampsCannotCreateASkip() {
        let pacer = PresentationFramePacer(refreshPeriod: 1 / 120)
        let time = recordPacingFrames(pacer, count: 29)
        for _ in 0..<40 {
            pacer.observe(renderStart: 99, presented: time, now: time)
            pacer.observe(renderStart: 102, presented: 0, now: 102)
            pacer.observe(renderStart: 102, presented: .nan, now: 102)
            pacer.observe(renderStart: 102, presented: 101, now: 102)
            pacer.observe(renderStart: .infinity, presented: 103, now: 103)
        }
        #expect(!pacer.consumeDrain(at: time))
        #expect(pacer.snapshot.overStreak == 29)
        let next = recordPacingFrames(pacer, start: 100 + 29.0 / 120, count: 1)
        #expect(pacer.consumeDrain(at: next))
    }

    @Test func aNewSessionDoesNotReceiveTheOldSessionsPendingSkip() {
        let old = PresentationFramePacer(refreshPeriod: 1 / 120)
        let time = recordPacingFrames(old, count: 30)
        let current = PresentationFramePacer(refreshPeriod: 1 / 120)
        #expect(old.snapshot.drainRequested)
        #expect(!current.consumeDrain(at: time))
        #expect(current.snapshot.skipped == 0)
    }

    @Test func aSyntheticBacklogAdvancesWithoutSendingAnotherFrame() {
        let pacer = PresentationFramePacer(refreshPeriod: 1 / 120)
        var backlog = 3
        let unpacedBacklog = backlog
        var maximumSkippedRun = 0
        var skippedRun = 0
        for index in 0..<600 {
            let now = 100 + Double(index) / 120
            pacer.updateMotion(pacingIdentity, at: now, stable: true)
            let skip = pacer.consumeDrain(at: now)
            skippedRun = skip ? skippedRun + 1 : 0
            maximumSkippedRun = max(maximumSkippedRun, skippedRun)
            if skip { backlog -= 1 }
            let renderStart = now - Double(backlog) / 120
            pacer.observe(renderStart: renderStart, presented: now, now: now)
        }
        #expect(pacer.snapshot.skipped == 1)
        #expect(backlog == 2)
        #expect(unpacedBacklog == 3)
        #expect(maximumSkippedRun == 1)
    }

    @Test func periodicMicroMotionDoesNotEraseTheMeasuredDelayStreak() {
        let pacer = PresentationFramePacer(refreshPeriod: 1 / 120)
        for index in 0..<480 {
            let time = 100 + Double(index) / 120
            let angle = 0.05 * Double.pi / 180 * sin(2 * .pi * 1.5 * time)
            pacer.updateMotion(simd_quatd(angle: angle, axis: SIMD3(0, 1, 0)), at: time, stable: true)
            _ = pacer.consumeDrain(at: time)
            pacer.observe(renderStart: time - 3 / 120, presented: time, now: time)
        }
        #expect(pacer.snapshot.skipped >= 1)
        #expect(pacer.snapshot.skipped <= 2)
    }
}
