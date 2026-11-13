import Testing
@testable import RayDesk

@Test func framePoolPublishesOnlyCompletedFramesAndProtectsReaders() throws {
    let pool = CompletedFramePool<Int, String>(resources: [10, 20, 30])
    let first = try #require(pool.reserve())
    #expect(pool.acquire() == nil)
    pool.complete(first, metadata: "first")
    let reading = try #require(pool.acquire())
    #expect(reading.resource == 10 && reading.metadata == "first")
    let second = try #require(pool.reserve())
    pool.complete(second, metadata: "second")
    let third = try #require(pool.reserve())
    #expect(third.index != reading.ticket.index)
    #expect(pool.reserve() == nil)
    pool.release(reading)
    let recycled = try #require(pool.reserve())
    #expect(recycled.index == first.index)
    pool.complete(third, metadata: nil)
    pool.complete(recycled, metadata: nil)
    #expect(pool.acquire()?.metadata == "second")
}

@Test func framePoolRejectsOldCompletionsAndInvalidatedGenerations() throws {
    let pool = CompletedFramePool<Int, Int>(resources: [0, 1, 2])
    let old = try #require(pool.reserve())
    let new = try #require(pool.reserve())
    pool.complete(new, metadata: 2)
    pool.complete(old, metadata: 1)
    let read = try #require(pool.acquire())
    #expect(read.metadata == 2)
    let pending = try #require(pool.reserve())
    pool.invalidate()
    pool.complete(pending, metadata: 3)
    #expect(pool.acquire() == nil)
    let next = try #require(pool.reserve())
    #expect(next.index != read.ticket.index)
    pool.release(read)
    pool.complete(next, metadata: 4)
    #expect(pool.acquire()?.metadata == 4)
}
