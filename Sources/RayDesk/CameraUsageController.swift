import Foundation
import RayDeskCore

final class CameraUsageController {
    enum Consumer: Hashable {
        case centering, calibration, debug, learning
    }

    private let start: (@escaping (Error?) -> Void) -> Void
    private let stop: () -> Void
    private var consumers: Set<Consumer> = []
    private var waiting: [(consumer: Consumer, completion: (Error?) -> Void)] = []
    private var running = false
    private var starting = false
    private var generation = 0

    init(start: @escaping (@escaping (Error?) -> Void) -> Void, stop: @escaping () -> Void) {
        self.start = start
        self.stop = stop
    }

    static func needsCentering(family: GlassesDisplayFamily?, visible: Bool, enabled: Bool) -> Bool {
        family == .rayNeo && visible && enabled
    }

    func isRequested(_ consumer: Consumer) -> Bool {
        consumers.contains(consumer)
    }

    func request(_ consumer: Consumer, completion: @escaping (Error?) -> Void) {
        consumers.insert(consumer)
        if running { completion(nil); return }
        waiting.append((consumer, completion))
        guard !starting else { return }
        starting = true
        let request = generation
        start { [weak self] error in
            guard let self, generation == request else { return }
            starting = false
            running = error == nil
            let callbacks = waiting
            waiting.removeAll()
            for callback in callbacks where generation == request && consumers.contains(callback.consumer) {
                callback.completion(error)
            }
        }
    }

    func release(_ consumer: Consumer) {
        guard consumers.remove(consumer) != nil else { return }
        waiting.removeAll { $0.consumer == consumer }
        if consumers.isEmpty { stopAll() }
    }

    func stopAll() {
        generation += 1
        consumers.removeAll()
        waiting.removeAll()
        running = false
        starting = false
        stop()
    }
}
