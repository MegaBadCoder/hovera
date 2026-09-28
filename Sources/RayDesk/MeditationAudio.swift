import AVFoundation
import Synchronization
import RayDeskCore

final class MeditationAudio: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let parameters = SynthParameters()
    private var node: AVAudioSourceNode?
    private var stopGeneration = 0

    var neuralEffect: NeuralEffect {
        get { NeuralEffect.allCases[parameters.effect.load(ordering: .relaxed)] }
        set { parameters.effect.store(NeuralEffect.allCases.firstIndex(of: newValue) ?? 0, ordering: .relaxed) }
    }

    func start() throws {
        stopGeneration += 1
        if node == nil {
            let format = engine.outputNode.inputFormat(forBus: 0)
            let stereo = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2)!
            let box = SynthBox(synth: AmbientSynth(sampleRate: stereo.sampleRate, seed: UInt64(Date().timeIntervalSince1970)))
            let parameters = parameters
            let source = AVAudioSourceNode(format: stereo) { _, _, frameCount, bufferList in
                let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
                guard buffers.count >= 2,
                      let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                      let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
                else { return noErr }
                box.synth.targetVolume = Double(bitPattern: parameters.volume.load(ordering: .relaxed))
                box.synth.neuralEffect = NeuralEffect.allCases[parameters.effect.load(ordering: .relaxed)]
                box.synth.render(left: left, right: right, frames: Int(frameCount))
                return noErr
            }
            engine.attach(source)
            engine.connect(source, to: engine.mainMixerNode, format: stereo)
            node = source
        }
        if !engine.isRunning {
            try engine.start()
        }
        parameters.volume.store(1.0.bitPattern, ordering: .relaxed)
    }

    func stop() {
        parameters.volume.store(0.0.bitPattern, ordering: .relaxed)
        stopGeneration += 1
        let generation = stopGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + AmbientSynth.fadeSeconds + 0.5) { [weak self] in
            guard let self, stopGeneration == generation else { return }
            engine.stop()
        }
    }
}

private final class SynthParameters: Sendable {
    let volume = Atomic<UInt64>(0)
    let effect = Atomic<Int>(0)
}

private final class SynthBox: @unchecked Sendable {
    var synth: AmbientSynth

    init(synth: AmbientSynth) {
        self.synth = synth
    }
}
