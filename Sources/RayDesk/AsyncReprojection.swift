import MetalKit
import RayDeskCore
import simd

struct ReprojectionPose {
    let orientation: simd_quatd
    let horizon: Double
    let isStable: Bool
    let sampleTime: Double?
    let maximumPredictionHorizon: Double

    init(orientation: simd_quatd, horizon: Double, isStable: Bool = true, sampleTime: Double? = nil,
         maximumPredictionHorizon: Double = 0) {
        self.orientation = orientation
        self.horizon = horizon
        self.isStable = isStable
        self.sampleTime = sampleTime
        self.maximumPredictionHorizon = maximumPredictionHorizon
    }
}

struct ReprojectionPoseSource {
    let external: Bool
    let predictsFromOrientation: Bool
    let sample: (Double) -> ReprojectionPose?

    init(external: Bool, predictsFromOrientation: Bool = false,
         sample: @escaping (Double) -> ReprojectionPose?) {
        self.external = external
        self.predictsFromOrientation = predictsFromOrientation
        self.sample = sample
    }

    static func viture(_ tracker: VitureTracker, clock: @escaping () -> Double = CACurrentMediaTime) -> Self {
        Self(external: true, predictsFromOrientation: true) { [weak tracker] time in
            guard let tracker else { return nil }
            let ahead = max(0, min(0.05, time - clock()))
            guard let pose = tracker.poseSample(predictTime: ahead, extrapolate: false) else { return nil }
            let recent = (-0.005..<0.1).contains(clock() - pose.sampleTime)
            return ReprojectionPose(orientation: pose.pose.orientation, horizon: pose.predictionHorizon,
                                    isStable: pose.pose.isStable && recent, sampleTime: pose.sampleTime,
                                    maximumPredictionHorizon: pose.maximumPredictionHorizon)
        }
    }

    static func rayNeo(_ filter: OrientationFilter, bias: Double, limit: Double, fallback: Double) -> Self {
        Self(external: false, predictsFromOrientation: true) { time in
            let pose = filter.prediction(at: time, bias: bias, limit: limit, fallback: fallback, extrapolate: false)
            let recent = pose.sampleTime.map { (-0.005..<0.1).contains(time - $0) } ?? false
            return ReprojectionPose(orientation: pose.orientation, horizon: pose.horizon,
                                    isStable: pose.isReady && recent, sampleTime: pose.sampleTime,
                                    maximumPredictionHorizon: max(0, limit))
        }
    }
}

struct ReprojectionFrame {
    let orientation: simd_quatd
    let position: SIMD3<Double>
    let verticalFOV: Float
    let calibration: ViewCalibration
    let source: ReprojectionPoseSource
    let worldLocked: Bool
    let smoothing: Bool
    let adaptiveVSync: Bool
    let restSmoothing: Bool
    let restTolerance: Double
    let restStrength: RestStabilizationStrength
    let indicatorYaw: Double?
    let epoch: Int
    let created: Double
    var scanoutEnabled = true
    var scanoutBottomToTop = false
}

typealias ReprojectionFramePool = CompletedFramePool<RotationalCompositor.Target, ReprojectionFrame>

final class AsyncReprojection: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    static let maximumDrawableCount = 2
    let timings = FrameTimeline(capacity: 240)

    struct State {
        var presented = 0
        var submitted = 0
        var reused = 0
        var failed = 0
        var dropped = 0
        var frameAge = 0.0
        var maximumFrameAge = 0.0
        var maximumPresentGap = 0.0
        var lastPresentedTime = 0.0
        var orientation: simd_quatd?
        var position = SIMD3<Double>.zero
        var horizon = 0.0
        var angle = 0.0
        var external = false
        var epoch = -1
        var submittedEpoch = -1
        var error: String?
        var adaptiveVSync = false
        var displaySyncEnabled = true
        var presentedDisplaySyncEnabled = true
        var syncSwitches = 0
        var sampleTime = 0.0
        var poseTargetTime = 0.0
        var restPhase: RestStabilizationPhase = .waiting
        var restStabilizing = false
        var restCorrection = 0.0
        var scanoutDuration = 0.0
        var scanoutEndTargetTime = 0.0
        var scanoutBottomToTop = false
        var scanoutAngle = 0.0
        var receivedUpdates = 0
        var blockedUpdates = 0
        var outstandingGPUCommands = 0
        var pacing: PresentationFramePacer.Snapshot?
    }

    private let queue: MTLCommandQueue
    private let restIndicator: RestStatusIndicator
    private let compositor: RotationalCompositor
    private let lock = NSLock()
    private let submissionLock = NSLock()
    private var pool: ReprojectionFramePool?
    private var state = State()
    private var runLoop: CFRunLoop?
    private var stopping = false
    private var thread: Thread?
    private let stopped = DispatchSemaphore(value: 0)
    private var stabilizer = OrientationStabilizer.worldLocked
    private var worldLockPrediction = WorldLockPrediction()
    private var restPresentation = RestPresentationController()
    private var presentationClock = AdaptivePresentationClock()
    private(set) var presentationPacer = PresentationFramePacer(refreshPeriod: 1 / 120)
    private var presentationRefreshPeriod = 1.0 / 120
    private weak var outputLayer: CAMetalLayer?
    private var originalDisplaySyncEnabled = true
    private var originalMaximumDrawableCount = 3
    private var lastSampleTime: Double?
    private var lastOrientation: simd_quatd?
    private var epoch = -1
    private var lastSequence = -1
    private var inFlight = 0

    init(device: MTLDevice, pixelFormat: MTLPixelFormat) throws {
        guard let queue = device.makeCommandQueue() else { throw Renderer.RendererError.noMetal }
        self.queue = queue
        queue.label = "Independent rotational reprojection"
        compositor = try RotationalCompositor(device: device, pixelFormat: pixelFormat,
                                              depthFormat: .depth32Float, sampleCount: 4)
        restIndicator = try RestStatusIndicator(device: device, pixelFormat: pixelFormat)
        super.init()
    }

    var snapshot: State {
        lock.lock()
        defer { lock.unlock() }
        var result = state
        result.outstandingGPUCommands = inFlight
        return result
    }

    func use(_ pool: ReprojectionFramePool?) {
        submissionLock.lock()
        defer { submissionLock.unlock() }
        lock.lock()
        self.pool = pool
        state.orientation = nil
        lock.unlock()
    }

    @discardableResult
    func submit(using expectedPool: ReprojectionFramePool, _ body: () -> Void) -> Bool {
        submissionLock.lock()
        defer { submissionLock.unlock() }
        lock.lock()
        let acceptsFrame = !stopping && pool === expectedPool
        lock.unlock()
        guard acceptsFrame else { return false }
        body()
        return true
    }

    func start(layer: CAMetalLayer, framesPerSecond: Int, refreshPeriod: Double? = nil) {
        precondition(thread == nil)
        outputLayer = layer
        originalDisplaySyncEnabled = layer.displaySyncEnabled
        originalMaximumDrawableCount = layer.maximumDrawableCount
        layer.maximumDrawableCount = Self.maximumDrawableCount
        presentationRefreshPeriod = refreshPeriod ?? 1 / Double(max(1, framesPerSecond))
        precondition(presentationRefreshPeriod.isFinite && presentationRefreshPeriod > 0)
        presentationPacer = PresentationFramePacer(refreshPeriod: presentationRefreshPeriod)
        let thread = Thread { [self] in
            autoreleasepool {
                let link = CAMetalDisplayLink(metalLayer: layer)
                link.preferredFrameLatency = 2
                let rate = Float(max(1, framesPerSecond))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
                link.delegate = self
                lock.lock()
                runLoop = CFRunLoopGetCurrent()
                let shouldStop = stopping
                lock.unlock()
                if !shouldStop {
                    link.add(to: .current, forMode: .default)
                    CFRunLoopRun()
                }
                link.invalidate()
                setDisplaySyncEnabled(originalDisplaySyncEnabled)
                layer.maximumDrawableCount = originalMaximumDrawableCount
                lock.lock()
                runLoop = nil
                lock.unlock()
                stopped.signal()
            }
        }
        thread.name = "RayDesk independent reprojection"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    func drainPresentationIfNeeded(_ read: ReprojectionFramePool.Read, from pool: ReprojectionFramePool,
                                   motion: simd_quatd, at time: Double, stable: Bool, enabled: Bool) -> Bool {
        presentationPacer.updateMotion(motion, at: time, stable: enabled && stable)
        let skipped = presentationPacer.consumeDrain(at: time)
        let pacing = presentationPacer.snapshot
        lock.lock()
        state.pacing = pacing
        lock.unlock()
        if skipped { pool.release(read) }
        return skipped
    }

    func stop() {
        guard thread != nil else { return }
        submissionLock.lock()
        lock.lock()
        stopping = true
        let loop = runLoop
        pool = nil
        lock.unlock()
        submissionLock.unlock()
        if let loop {
            CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { CFRunLoopStop(loop) }
            CFRunLoopWakeUp(loop)
        }
        if stopped.wait(timeout: .now() + 2) == .timedOut {
            log("independent reprojection: worker stop timed out")
        }
        thread = nil
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        autoreleasepool {
            lock.lock()
            let currentPool = pool
            let canSubmit = !stopping && inFlight < 2
            state.receivedUpdates += 1
            if !canSubmit { state.blockedUpdates += 1 }
            lock.unlock()
            guard canSubmit else { return }
            guard let currentPool, let read = currentPool.acquire() else {
                setDisplaySyncEnabled(snapshot.adaptiveVSync ? true : originalDisplaySyncEnabled)
                return
            }
            let target = read.resource
            let texture = update.drawable.texture
            guard target.displaySize == SIMD2(texture.width, texture.height) else {
                currentPool.release(read)
                setDisplaySyncEnabled(snapshot.adaptiveVSync ? true : originalDisplaySyncEnabled)
                return
            }
            let frame = read.metadata
            let now = CACurrentMediaTime()
            if epoch != frame.epoch {
                epoch = frame.epoch
                stabilizer = .worldLocked
                worldLockPrediction = WorldLockPrediction()
                restPresentation = RestPresentationController()
                presentationClock = AdaptivePresentationClock()
                presentationPacer = PresentationFramePacer(refreshPeriod: presentationRefreshPeriod)
                lastSampleTime = nil
                lastOrientation = nil
                lastSequence = -1
            }
            let frameClock = presentationClock
            let framePacer = presentationPacer
            let synchronizedTarget = max(now, update.targetPresentationTimestamp)
            var poseTargetTime = frame.adaptiveVSync ? now : synchronizedTarget
            var pose = frame.worldLocked ? frame.source.sample(poseTargetTime) : nil
            var head = frame.orientation
            if frame.worldLocked {
                if let pose { lastOrientation = frame.calibration.apply(to: pose.orientation) }
                head = lastOrientation ?? frame.orientation
                let motionHead = head
                if drainPresentationIfNeeded(read, from: currentPool, motion: motionHead, at: now,
                                              stable: pose?.isStable == true, enabled: frame.adaptiveVSync) { return }
                if frame.adaptiveVSync {
                    _ = restPresentation.filter(head, motion: motionHead, at: now,
                                                restSmoothing: frame.restSmoothing, adaptiveVSync: true,
                                                stable: pose?.isStable == true, strength: frame.restStrength,
                                                tolerance: frame.restTolerance)
                    poseTargetTime = frameClock.targetTime(now: now, displayTarget: synchronizedTarget,
                                                          synchronized: restPresentation.displaySyncEnabled)
                    if let outputPose = frame.source.sample(poseTargetTime) {
                        pose = outputPose
                        head = frame.calibration.apply(to: outputPose.orientation)
                        lastOrientation = head
                    }
                }
                if frame.source.predictsFromOrientation {
                    head = worldLockPrediction.predict(head, at: now, sampleTime: pose?.sampleTime, horizon: pose?.horizon ?? 0,
                                                       smoothing: frame.smoothing)
                } else if frame.smoothing && !frame.adaptiveVSync {
                    let dt = lastSampleTime.map { now - $0 } ?? 0
                    if dt > 0.1 { stabilizer = .worldLocked }
                    head = stabilizer.filter(head, dt: dt)
                }
                if !frame.adaptiveVSync {
                    head = restPresentation.filter(head, motion: motionHead, at: now,
                                                   restSmoothing: frame.restSmoothing, adaptiveVSync: false,
                                                   stable: pose?.isStable == true, strength: frame.restStrength,
                                                   tolerance: frame.restTolerance)
                }
            } else {
                presentationPacer.updateMotion(head, at: now, stable: false)
            }
            lastSampleTime = now
            let adaptiveVSync = frame.worldLocked && frame.adaptiveVSync
            let requestedDisplaySync = adaptiveVSync ? restPresentation.displaySyncEnabled : originalDisplaySyncEnabled
            let scanout = ScanoutPrediction(reference: head, angularVelocity: worldLockPrediction.predictionAngularVelocity,
                                             duration: presentationRefreshPeriod,
                                             maximumAdditionalTime: (pose?.maximumPredictionHorizon ?? 0) - (pose?.horizon ?? 0),
                                             enabled: frame.scanoutEnabled && frame.worldLocked && frame.source.predictsFromOrientation && pose?.isStable == true,
                                             bottomToTop: frame.scanoutBottomToTop)
            let warp = RotationalReprojection(scene: frame.orientation, displayTop: scanout.top, displayBottom: scanout.bottom,
                                             verticalFOV: frame.verticalFOV,
                                             aspect: Float(target.displaySize.x) / Float(target.displaySize.y),
                                             overscan: target.overscan)
            guard let command = queue.makeCommandBuffer() else {
                currentPool.release(read)
                recordFailure("command buffer allocation")
                return
            }
            let restPhase: RestStabilizationPhase = frame.worldLocked ? restPresentation.phase : .disabled
            do {
                try compositor.encode(warp, source: target.color, destination: texture, commandBuffer: command)
                if let yaw = frame.indicatorYaw {
                    try restIndicator.encode(phase: restPhase, strength: frame.restStrength, adaptiveSync: adaptiveVSync ? restPresentation.displaySyncEnabled : nil, head: head,
                                             position: frame.position, anchorYaw: yaw, verticalFOV: frame.verticalFOV,
                                             destination: texture, commandBuffer: command)
                }
            } catch {
                currentPool.release(read)
                recordFailure(String(describing: error))
                return
            }
            let age = now - frame.created
            let angle = 2 * acos(min(1, abs(simd_dot(frame.orientation.vector, head.vector))))
            let displayHead = head
            let scanoutAngle = length(worldLockPrediction.predictionAngularVelocity) * scanout.duration
            let restStabilizing = frame.worldLocked && restPresentation.isSmoothing
            let restCorrection = frame.worldLocked ? restPresentation.correctionRadians : 0
            let accepted = submit(using: currentPool) {
                setDisplaySyncEnabled(requestedDisplaySync)
                let submittedDisplaySync = outputLayer?.displaySyncEnabled ?? requestedDisplaySync
                let timingID = timings.begin(cpuStart: now, committed: CACurrentMediaTime(),
                                             sourceTime: pose?.sampleTime, synchronized: submittedDisplaySync)
                lock.lock()
                state.adaptiveVSync = adaptiveVSync
                state.submittedEpoch = frame.epoch
                inFlight += 1
                state.submitted += 1
                if lastSequence == read.ticket.sequence { state.reused += 1 }
                state.frameAge = age
                state.maximumFrameAge = max(state.maximumFrameAge, age)
                lock.unlock()
                lastSequence = read.ticket.sequence
                command.addCompletedHandler { [self] command in
                    currentPool.release(read)
                    timings.completed(timingID, gpuStart: command.gpuStartTime, gpuEnd: command.gpuEndTime)
                    lock.lock()
                    inFlight -= 1
                    if command.status == .error {
                        state.failed += 1
                        state.error = command.error?.localizedDescription ?? "GPU command failed"
                    }
                    lock.unlock()
                }
                update.drawable.addPresentedHandler { [self] drawable in
                    timings.presented(timingID, at: drawable.presentedTime)
                    lock.lock()
                    defer { lock.unlock() }
                    let time = drawable.presentedTime
                    guard time > 0 else { state.dropped += 1; return }
                    guard pool === currentPool else { return }
                    guard state.submittedEpoch == frame.epoch else { return }
                    if adaptiveVSync {
                        frameClock.observe(now: now, displayTarget: synchronizedTarget, presented: time,
                                           synchronized: submittedDisplaySync)
                        framePacer.observe(renderStart: now, presented: time, now: CACurrentMediaTime())
                        state.pacing = framePacer.snapshot
                    }
                    state.presented += 1
                    if state.lastPresentedTime > 0 {
                        state.maximumPresentGap = max(state.maximumPresentGap, time - state.lastPresentedTime)
                    }
                    state.lastPresentedTime = time
                    state.orientation = displayHead
                    state.position = frame.position
                    state.presentedDisplaySyncEnabled = submittedDisplaySync
                    state.sampleTime = now
                    state.poseTargetTime = poseTargetTime
                    state.scanoutDuration = scanout.duration
                    state.scanoutEndTargetTime = poseTargetTime + scanout.duration
                    state.scanoutBottomToTop = frame.scanoutBottomToTop
                    state.scanoutAngle = scanoutAngle
                    state.horizon = pose?.horizon ?? 0
                    state.angle = angle
                    state.external = frame.source.external
                    state.epoch = frame.epoch
                    state.restPhase = restPhase
                    state.restStabilizing = restStabilizing
                    state.restCorrection = restCorrection
                }
                command.present(update.drawable)
                command.commit()
            }
            if !accepted { currentPool.release(read) }
        }
    }

    private func setDisplaySyncEnabled(_ enabled: Bool) {
        guard let outputLayer else { return }
        let changed = outputLayer.displaySyncEnabled != enabled
        if changed { outputLayer.displaySyncEnabled = enabled }
        lock.lock()
        state.displaySyncEnabled = outputLayer.displaySyncEnabled
        if changed { state.syncSwitches += 1 }
        lock.unlock()
    }

    private func recordFailure(_ message: String) {
        lock.lock()
        state.failed += 1
        state.error = message
        lock.unlock()
    }
}
