import Foundation

/// Сила «нейроэффекта»: насколько глубоко ритмично пульсирует громкость музыки.
public enum NeuralEffect: String, CaseIterable, Sendable {
    case off, low, medium, high

    /// Глубина провала громкости в каждом такте пульсации, 0…1.
    public var depth: Double {
        switch self {
        case .off: 0
        case .low: 0.15
        case .medium: 0.3
        case .high: 0.5
        }
    }
}

/// Генератор медитативного звука: тихие аккорды без мелодии, шум волн с медленными накатами
/// и ритмичная пульсация громкости музыки. Звук целиком синтезируется, без файлов.
///
/// `render` не выделяет память и не берёт блокировок, его можно звать из звукового потока.
public struct AmbientSynth {
    /// Частота пульсации громкости музыки, Гц.
    public static let modulationHz = 6.0
    /// За сколько секунд громкость проходит путь от тишины до полной и обратно.
    public static let fadeSeconds = 4.0
    /// Предел амплитуды на выходе: −1 dBFS.
    public static let peakLimit: Float = 0.891

    /// Громкость, к которой плавно идёт звук, 0…1.
    public var targetVolume = 0.0
    /// Сила пульсации музыки.
    public var neuralEffect = NeuralEffect.off

    var padLevel = 1.0
    var waveLevel = 1.0

    private let sampleRate: Double
    private var volume = 0.0
    private var time = 0.0
    private var random: UInt64
    private var phases: [Double]
    private var padSmoothed = (left: 0.0, right: 0.0)
    private var waveSmoothed = (left: 0.0, right: 0.0)
    private var rumble = (left: 0.0, right: 0.0)
    private var swells: [(start: Double, period: Double)]

    private static let chords: [[Double]] = [
        [146.83, 220.00, 277.18, 329.63],
        [123.47, 185.00, 220.00, 293.66],
        [98.00, 196.00, 246.94, 293.66],
        [110.00, 164.81, 246.94, 329.63],
    ]
    private static let chordSeconds = 16.0
    private static let chordCrossfadeSeconds = 4.0
    private static let detune = 0.0015
    private static let voicesPerChord = 4

    /// - Parameters:
    ///   - sampleRate: частота дискретизации выхода, Гц.
    ///   - seed: зерно случайности; одно и то же зерно даёт один и тот же звук.
    public init(sampleRate: Double, seed: UInt64) {
        self.sampleRate = sampleRate
        random = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        phases = Array(repeating: 0, count: Self.chords.count * Self.voicesPerChord * 2)
        swells = []
        swells = [(0, nextSwellPeriod()), (-3.7, nextSwellPeriod())]
    }

    /// Множитель громкости музыки с пульсацией: 1 на гребне, `1 − depth` во впадине.
    ///
    /// - Parameters:
    ///   - time: время, секунды.
    ///   - depth: глубина провала, 0…1.
    public static func neuralGain(time: Double, depth: Double) -> Double {
        1 - depth * (0.5 - 0.5 * cos(2 * .pi * modulationHz * time))
    }

    /// Дописывает очередные отсчёты в два канала.
    ///
    /// - Parameters:
    ///   - left: буфер левого канала, не меньше `frames` отсчётов.
    ///   - right: буфер правого канала, не меньше `frames` отсчётов.
    ///   - frames: сколько отсчётов сгенерировать.
    public mutating func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        let dt = 1 / sampleRate
        let volumeStep = dt / Self.fadeSeconds
        let depth = neuralEffect.depth
        for i in 0..<frames {
            if volume < targetVolume {
                volume = min(targetVolume, volume + volumeStep)
            } else if volume > targetVolume {
                volume = max(targetVolume, volume - volumeStep)
            }
            let gain = volume * volume
            guard gain > 0 else {
                left[i] = 0
                right[i] = 0
                time += dt
                continue
            }
            let pad = nextPad(dt: dt)
            let wave = nextWave(dt: dt)
            let music = Self.neuralGain(time: time, depth: depth) * padLevel * 0.45
            let l = (pad.left * music + wave.left * waveLevel * 0.35) * gain
            let r = (pad.right * music + wave.right * waveLevel * 0.35) * gain
            left[i] = Self.limit(l)
            right[i] = Self.limit(r)
            time += dt
        }
    }

    private static func limit(_ x: Double) -> Float {
        let ceiling = Double(peakLimit) * 0.999
        return Float(ceiling * tanh(x / ceiling))
    }

    private mutating func nextPad(dt: Double) -> (left: Double, right: Double) {
        let position = time / Self.chordSeconds
        let current = Int(position) % Self.chords.count
        let intoChord = time - floor(position) * Self.chordSeconds
        var left = 0.0
        var right = 0.0
        if intoChord < Self.chordCrossfadeSeconds, time >= Self.chordSeconds {
            let fade = intoChord / Self.chordCrossfadeSeconds
            let previous = (current + Self.chords.count - 1) % Self.chords.count
            let old = chordSample(previous, dt: dt)
            let new = chordSample(current, dt: dt)
            let outGain = cos(fade * .pi / 2)
            let inGain = sin(fade * .pi / 2)
            left = old.left * outGain + new.left * inGain
            right = old.right * outGain + new.right * inGain
        } else {
            let sample = chordSample(current, dt: dt)
            left = sample.left
            right = sample.right
        }
        let breath = 0.8 + 0.2 * sin(2 * .pi * 0.05 * time)
        let smoothing = 1 - exp(-2 * .pi * 1200 * dt)
        padSmoothed.left += (left * breath - padSmoothed.left) * smoothing
        padSmoothed.right += (right * breath - padSmoothed.right) * smoothing
        return padSmoothed
    }

    private mutating func chordSample(_ chord: Int, dt: Double) -> (left: Double, right: Double) {
        var left = 0.0
        var right = 0.0
        for voice in 0..<Self.voicesPerChord {
            let frequency = Self.chords[chord][voice]
            for side in 0..<2 {
                let index = (chord * Self.voicesPerChord + voice) * 2 + side
                let detuned = frequency * (side == 0 ? 1 - Self.detune : 1 + Self.detune)
                phases[index] += 2 * .pi * detuned * dt
                if phases[index] > 2 * .pi { phases[index] -= 2 * .pi }
                let tone = sin(phases[index]) + 0.2 * sin(2 * phases[index])
                left += tone * (side == 0 ? 0.7 : 0.3)
                right += tone * (side == 0 ? 0.3 : 0.7)
            }
        }
        let scale = 1.0 / Double(Self.voicesPerChord * 2)
        return (left * scale, right * scale)
    }

    private mutating func nextWave(dt: Double) -> (left: Double, right: Double) {
        let envelopes = (swellEnvelope(0), swellEnvelope(1))
        let noise = (nextNoise(), nextNoise())
        let brightLeft = 1 - exp(-2 * .pi * (250 + 1600 * envelopes.0) * dt)
        let brightRight = 1 - exp(-2 * .pi * (250 + 1600 * envelopes.1) * dt)
        waveSmoothed.left += (noise.0 - waveSmoothed.left) * brightLeft
        waveSmoothed.right += (noise.1 - waveSmoothed.right) * brightRight
        rumble.left = rumble.left * 0.999 + noise.0 * 0.02
        rumble.right = rumble.right * 0.999 + noise.1 * 0.02
        let left = waveSmoothed.left * (0.12 + 0.88 * envelopes.0) * 1.6 + rumble.left * 0.35
        let right = waveSmoothed.right * (0.12 + 0.88 * envelopes.1) * 1.6 + rumble.right * 0.35
        return (left, right)
    }

    private mutating func swellEnvelope(_ index: Int) -> Double {
        var swell = swells[index]
        while time - swell.start >= swell.period {
            swell.start += swell.period
            swell.period = nextSwellPeriod()
        }
        swells[index] = swell
        let phase = max(0, time - swell.start) / swell.period
        let rise = 0.35
        if phase < rise {
            let s = sin(.pi / 2 * phase / rise)
            return s * s
        }
        let c = cos(.pi / 2 * (phase - rise) / (1 - rise))
        return c * c
    }

    private mutating func nextSwellPeriod() -> Double {
        7 + 5 * (nextNoise() * 0.5 + 0.5)
    }

    private mutating func nextNoise() -> Double {
        random ^= random >> 12
        random ^= random << 25
        random ^= random >> 27
        let value = random &* 0x2545_F491_4F6C_DD1D
        return Double(value >> 11) / Double(1 << 53) * 2 - 1
    }
}
