import Testing
import MetalKit
@testable import RayDeskCore

@Suite struct FrameTimelineTests {
    @Test func recordsTheActualMetalClockWithoutAVisibleWindow() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let buffer = try #require(device.makeBuffer(length: 4096, options: .storageModeShared))
        let command = try #require(queue.makeCommandBuffer())
        let start = CACurrentMediaTime()
        let encoder = try #require(command.makeBlitCommandEncoder())
        encoder.fill(buffer: buffer, range: 0..<4096, value: 7)
        encoder.endEncoding()
        let timeline = FrameTimeline(capacity: 2)
        let frame = timeline.begin(cpuStart: start, committed: CACurrentMediaTime(), sourceTime: nil, synchronized: nil)
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        timeline.completed(frame, gpuStart: command.gpuStartTime, gpuEnd: command.gpuEndTime)
        #expect(timeline.summary(synchronized: nil).frames == 1)
        #expect(timeline.summary(synchronized: nil).gpuQueueMillisecondsP95.map { $0 >= 0 } == true)
    }

    @Test func separatesGPUExecutionFromPresentationWaitRegardlessOfCallbackOrder() throws {
        let timeline = FrameTimeline(capacity: 4)
        let frame = timeline.begin(cpuStart: 100, committed: 100.002, sourceTime: 99.999, synchronized: false)
        timeline.presented(frame, at: 100.025)
        #expect(timeline.summary(synchronized: false).gpuMillisecondsP95 == nil)
        timeline.completed(frame, gpuStart: 100.005, gpuEnd: 100.006)
        let result = timeline.summary(synchronized: false)
        #expect(result.frames == 1)
        #expect(abs(try #require(result.gpuMillisecondsP95) - 1) < 1e-8)
        #expect(abs(try #require(result.gpuQueueMillisecondsP95) - 3) < 1e-8)
        #expect(abs(try #require(result.presentWaitMillisecondsP95) - 19) < 1e-8)
        #expect(abs(try #require(result.sourceAgeMillisecondsP95) - 1) < 1e-8)
        #expect(timeline.summary(synchronized: true).frames == 0)
    }

    @Test func overwrittenRowsRejectLateCallbacksAndUnpresentedFramesHaveNoWait() {
        let timeline = FrameTimeline(capacity: 2)
        let old = timeline.begin(cpuStart: 100, committed: 100.001, sourceTime: nil, synchronized: nil)
        for value in 101...102 {
            let time = Double(value)
            let frame = timeline.begin(cpuStart: time, committed: time + 0.001, sourceTime: nil, synchronized: nil)
            timeline.completed(frame, gpuStart: time + 0.002, gpuEnd: time + 0.003)
            timeline.presented(frame, at: 0)
        }
        timeline.completed(old, gpuStart: 100.002, gpuEnd: 100.5)
        let result = timeline.summary(synchronized: nil)
        #expect(result.frames == 2)
        #expect(result.presentWaitMillisecondsP95 == nil)
        #expect(result.gpuMillisecondsP95.map { abs($0 - 1) < 1e-8 } == true)
    }
}
