import Foundation

final class CompletedFramePool<Resource, Metadata>: @unchecked Sendable {
    struct Ticket: Equatable {
        let index: Int
        let generation: Int
        let sequence: Int
    }
    struct Read {
        let ticket: Ticket
        let resource: Resource
        let metadata: Metadata
    }
    let resources: [Resource]
    private let lock = NSLock()
    private var writing: [Ticket?]
    private var readers: [Int]
    private var latest: Read?
    private var generation = 0
    private var sequence = 0

    init(resources: [Resource]) {
        precondition(!resources.isEmpty)
        self.resources = resources
        writing = Array(repeating: nil, count: resources.count)
        readers = Array(repeating: 0, count: resources.count)
    }

    func reserve() -> Ticket? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = resources.indices.first(where: {
            writing[$0] == nil && readers[$0] == 0 && latest?.ticket.index != $0
        }) else { return nil }
        sequence += 1
        let ticket = Ticket(index: index, generation: generation, sequence: sequence)
        writing[index] = ticket
        return ticket
    }

    func complete(_ ticket: Ticket, metadata: Metadata?) {
        lock.lock()
        defer { lock.unlock() }
        guard writing[ticket.index] == ticket else { return }
        writing[ticket.index] = nil
        guard ticket.generation == generation, let metadata,
              ticket.sequence > (latest?.ticket.sequence ?? -1) else { return }
        latest = Read(ticket: ticket, resource: resources[ticket.index], metadata: metadata)
    }

    func acquire() -> Read? {
        lock.lock()
        defer { lock.unlock() }
        guard let latest else { return nil }
        readers[latest.ticket.index] += 1
        return latest
    }

    func release(_ read: Read) {
        lock.lock()
        defer { lock.unlock() }
        precondition(readers[read.ticket.index] > 0)
        readers[read.ticket.index] -= 1
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        latest = nil
    }
}
