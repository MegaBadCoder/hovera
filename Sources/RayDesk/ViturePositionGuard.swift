import simd

struct ViturePositionGuard {
    private struct Sample {
        let time: Double
        let position: SIMD3<Double>
    }

    private let recoverySeconds = 0.75
    private let maximumSampleGap = 0.25
    private let recoveryRadius = 0.03
    private var history: [Sample] = []
    private var candidate: Sample?
    private var previousTime: Double?
    private var offset = SIMD3<Double>.zero
    private var output = SIMD3<Double>.zero
    private(set) var isHolding = true

    mutating func update(_ position: SIMD3<Double>?, stable: Bool, at time: Double) -> SIMD3<Double> {
        guard time.isFinite else { hold(); return output }
        let dt = previousTime.map { time - $0 }
        previousTime = time
        if let dt, dt <= 0 || dt > maximumSampleGap { hold() }
        guard stable, let position, position.x.isFinite, position.y.isFinite, position.z.isFinite else {
            hold()
            return output
        }
        if !isHolding {
            history.removeAll { time - $0.time > 1 }
            let plausible = history.allSatisfy { sample in
                let elapsed = time - sample.time
                let allowance = elapsed < 0.1 ? 0.04 + 2 * elapsed : 0.12 + 0.6 * elapsed
                return length(position - sample.position) <= allowance
            }
            if plausible {
                output = position + offset
                history.append(Sample(time: time, position: position))
                return output
            }
            hold()
        }
        if let candidate, length(position - candidate.position) <= recoveryRadius {
            if time - candidate.time >= recoverySeconds {
                offset = output - position
                isHolding = false
                history = [Sample(time: time, position: position)]
                self.candidate = nil
            }
        } else {
            candidate = Sample(time: time, position: position)
        }
        return output
    }

    private mutating func hold() {
        isHolding = true
        candidate = nil
        history.removeAll(keepingCapacity: true)
    }
}
