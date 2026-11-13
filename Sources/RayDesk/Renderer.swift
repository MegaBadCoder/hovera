import MetalKit
import CoreVideo
import simd
import RayDeskCore

enum ScreenTextMode: String, CaseIterable {
    case original, soft, softDimmed
}

final class Renderer: NSObject, MTKViewDelegate {
    let sceneTimings = FrameTimeline(capacity: 240)
    let warpTimings = FrameTimeline(capacity: 240)
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let gridPipeline: MTLRenderPipelineState
    private let skyPipeline: MTLRenderPipelineState
    private let skyDepthState: MTLDepthStencilState
    private let nebulaBakePipeline: MTLRenderPipelineState
    private var nebulaMap: MTLTexture?
    private let gridVertices: MTLBuffer
    private let gridVertexCount: Int
    private let depthState: MTLDepthStencilState
    private let sampler: MTLSamplerState
    private weak var outputLayer: CAMetalLayer?
    private var originalDisplaySyncEnabled = true
    private(set) var displaySyncEnabled = true
    private let restIndicator: RestStatusIndicator
    private let rotationalCompositor: RotationalCompositor
    private(set) var independentReprojection: AsyncReprojection?
    private var independentPool: ReprojectionFramePool?
    private var independentEpoch = 0
    var independentSource: ReprojectionPoseSource? {
        didSet { invalidateIndependentFrames() }
    }
    var suspendsIndependentScene = false {
        didSet { invalidateIndependentFrames() }
    }
    private let placeholder: MTLTexture
    private var textureCache: CVMetalTextureCache?

    private let scene: SpatialScene
    private let filter: OrientationFilter

    static let verticalFOVRange: ClosedRange<Double> = 10...60
    static let defaultVerticalFOV = 23.6
    var verticalFOV = Renderer.defaultVerticalFOV {
        didSet { if verticalFOV != oldValue { invalidateIndependentFrames() } }
    }
    var showsGrid = false
    var worldLockedPresentation = true {
        didSet { resetWorldLockSmoothing(invalidateResources: true) }
    }
    var worldLockSmoothing = true {
        didSet { resetWorldLockSmoothing() }
    }
    var adaptiveVSync = false {
        didSet { resetWorldLockSmoothing() }
    }
    var scanoutEnabled = true
    var scanoutBottomToTop = false
    var restSmoothing = false {
        didSet { resetWorldLockSmoothing() }
    }
    var restStrength: RestStabilizationStrength = .light {
        didSet { resetWorldLockSmoothing() }
    }
    var restTolerance = 1.0 {
        didSet { resetWorldLockSmoothing() }
    }
    var showsRestIndicator = false {
        didSet { independentEpoch += 1 }
    }
    private(set) var restPhase: RestStabilizationPhase = .waiting
    private var worldLockStabilizer = OrientationStabilizer.worldLocked
    private var worldLockPrediction = WorldLockPrediction()
    private var restPresentation = RestPresentationController()
    private var adaptivePresentationClock = AdaptivePresentationClock()
    private var presentationPacer = PresentationFramePacer(refreshPeriod: 1 / 120)
    private var presentationRefreshPeriod = 1.0 / 120
    private(set) var restStabilizing = false
    private(set) var restCorrection = 0.0
    private var lastWorldLockSampleTime: Double?
    private(set) var lastReprojectionAngle = 0.0
    private(set) var lastReprojectionApplied = false
    private var reprojectionAllocationFailed = false
    let headPipeline: HeadPipeline
    var calibration: ViewCalibration {
        get { headPipeline.calibration }
        set {
            headPipeline.calibration = newValue
            resetWorldLockSmoothing(invalidateResources: true)
        }
    }
    var stabilizer: OrientationStabilizer {
        get { headPipeline.stabilizer }
        set { headPipeline.stabilizer = newValue }
    }
    private var lastFrameTime = CACurrentMediaTime()
    private var stallStarted: [Int: Double] = [:]
    /// Порог намеренно грубый: дисплей не перерисовывается, пока на нём ничего не меняется,
    /// поэтому пауза захвата в секунды — норма. В лог попадают только длинные паузы,
    /// такие как перестроение пространств на жест Mission Control.
    private static let stallReportThreshold: TimeInterval = 8
    var showsScreenBorders = true
    var screenTextMode = ScreenTextMode.original

    var slots: [ScreenSlot] = []
    var cursorScreen: Int?
    var draggingScreen: Int?
    var snappedNeighbor: Int?
    var onFrame: ((simd_quatd) -> Void)?
    /// Время, на которое заявляет кадр дисплейный линк, секунды; `nil` — считать «сейчас + кадр».
    var nextTargetTime: Double?
    /// Измеренная поправка «заявленное время кадра → показанный кадр».
    let presentation = PresentationClock()
    /// Внешняя поза от трекера очков (VITURE): ориентация, положение в мировых осях
    /// и рассчитанный для этой позы горизонт предсказания в секундах.
    /// Если задана и вернёт значение, заменяет свой фильтр ориентации.
    /// К позе применяется ручная поправка вида; сглаживание — только вне закреплённого режима.
    var externalPose: ((Double) -> (orientation: simd_quatd, position: SIMD3<Double>, predictionHorizon: Double)?)? {
        didSet { invalidateIndependentFrames() }
    }
    /// `true`, если последний кадр нарисован по внешней ориентации, а не по фильтру.
    private(set) var usedExternalOrientation = false
    /// Горизонт предсказания последнего кадра, секунды.
    private(set) var lastPredictionHorizon = 0.0
    /// Подстраивать ли горизонт предсказания по фактической ошибке прошлых кадров.
    var adaptivePrediction = false
    private var tuner = PredictionTuner()
    private var pendingPrediction: (time: Double, orientation: simd_quatd, angularVelocity: SIMD3<Double>)?

    private(set) var currentHeadOffset = SIMD3<Double>.zero
    private(set) var currentHead = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    private(set) var meditation = MeditationTransition()
    var breathingEnabled = false
    var headOffset: ((simd_quatd) -> SIMD3<Double>)?
    private var headFollower = RateLimitedFollower(timeConstant: 0.02, maxSpeed: 0.8)
    private var breathingVisibility = 0.0
    private var meditationStart = CACurrentMediaTime()
    private let skyClockStart = CACurrentMediaTime()

    private struct Uniforms {
        var mvp: simd_float4x4
        var border: SIMD4<Float>
        var textStyle = SIMD4<Float>.zero
    }

    private struct SkyUniforms {
        var inverseViewProjection: simd_float4x4
        var params: SIMD4<Float>
    }

    init(view: MTKView, scene: SpatialScene, filter: OrientationFilter) throws {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw RendererError.noMetal
        }
        self.device = device
        self.queue = queue
        self.scene = scene
        self.filter = filter
        headPipeline = HeadPipeline(filter: filter)

        view.device = device
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 4
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = 120

        rotationalCompositor = try RotationalCompositor(device: device, pixelFormat: view.colorPixelFormat,
                                                        depthFormat: view.depthStencilPixelFormat, sampleCount: view.sampleCount)

        restIndicator = try RestStatusIndicator(device: device, pixelFormat: view.colorPixelFormat)

        let library = try device.makeLibrary(source: Renderer.shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "screenVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "screenFragment")
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        descriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        descriptor.rasterSampleCount = view.sampleCount
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let skyDescriptor = MTLRenderPipelineDescriptor()
        skyDescriptor.vertexFunction = library.makeFunction(name: "skyVertex")
        skyDescriptor.fragmentFunction = library.makeFunction(name: "skyFragment")
        skyDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        skyDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        skyDescriptor.rasterSampleCount = view.sampleCount
        skyPipeline = try device.makeRenderPipelineState(descriptor: skyDescriptor)

        let bakeDescriptor = MTLRenderPipelineDescriptor()
        bakeDescriptor.vertexFunction = library.makeFunction(name: "skyVertex")
        bakeDescriptor.fragmentFunction = library.makeFunction(name: "nebulaBakeFragment")
        bakeDescriptor.colorAttachments[0].pixelFormat = .rgba16Float
        nebulaBakePipeline = try device.makeRenderPipelineState(descriptor: bakeDescriptor)

        let gridDescriptor = MTLRenderPipelineDescriptor()
        gridDescriptor.vertexFunction = library.makeFunction(name: "gridVertex")
        gridDescriptor.fragmentFunction = library.makeFunction(name: "gridFragment")
        gridDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        gridDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        gridDescriptor.rasterSampleCount = view.sampleCount
        gridPipeline = try device.makeRenderPipelineState(descriptor: gridDescriptor)

        let lines = Renderer.worldGridLines()
        gridVertexCount = lines.count
        gridVertices = device.makeBuffer(bytes: lines, length: MemoryLayout<SIMD4<Float>>.stride * lines.count)!

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: depthDescriptor)!
        let skyDepthDescriptor = MTLDepthStencilDescriptor()
        skyDepthDescriptor.depthCompareFunction = .always
        skyDepthDescriptor.isDepthWriteEnabled = false
        skyDepthState = device.makeDepthStencilState(descriptor: skyDepthDescriptor)!

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.maxAnisotropy = 8
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: samplerDescriptor)!

        let placeholderDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: 1, height: 1, mipmapped: false)
        placeholder = device.makeTexture(descriptor: placeholderDescriptor)!
        var gray: [UInt8] = [40, 40, 40, 255]
        placeholder.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &gray, bytesPerRow: 4)

        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        super.init()
        outputLayer = view.layer as? CAMetalLayer
        originalDisplaySyncEnabled = outputLayer?.displaySyncEnabled ?? true
        outputLayer?.maximumDrawableCount = AsyncReprojection.maximumDrawableCount
        presentationRefreshPeriod = 1 / Double(max(1, view.preferredFramesPerSecond))
        presentationPacer = PresentationFramePacer(refreshPeriod: presentationRefreshPeriod)
    }

    func startIndependentReprojection(view: MTKView, framesPerSecond: Int) throws {
        stopIndependentReprojection()
        let displayID = view.window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let reportedRate = displayID.flatMap { CGDisplayCopyDisplayMode($0.uint32Value)?.refreshRate } ?? 0
        let actualRate = reportedRate.isFinite && (30...240).contains(reportedRate) ? reportedRate : Double(max(1, framesPerSecond))
        presentationRefreshPeriod = 1 / actualRate
        log(String(format: "scanout timing: configured=%dHz displayMode=%.3fHz period=%.3fms",
                   framesPerSecond, reportedRate, presentationRefreshPeriod * 1000))
        guard let layer = view.layer as? CAMetalLayer else { throw RendererError.noMetal }
        let presenter = try AsyncReprojection(device: device, pixelFormat: view.colorPixelFormat)
        view.delegate = nil
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        independentReprojection = presenter
        presenter.start(layer: layer, framesPerSecond: Int(actualRate.rounded()), refreshPeriod: presentationRefreshPeriod)
    }

    func stopIndependentReprojection() {
        independentReprojection?.stop()
        independentReprojection = nil
        setFallbackDisplaySyncEnabled(originalDisplaySyncEnabled)
        invalidateIndependentFrames()
    }

    private func invalidateIndependentFrames() {
        independentEpoch += 1
        independentPool?.invalidate()
        independentPool = nil
        independentReprojection?.use(nil)
    }

    func prepareIndependentPool(size: CGSize) throws -> ReprojectionFramePool {
        let displaySize = SIMD2(Int(size.width), Int(size.height))
        if let independentPool, independentPool.resources[0].displaySize == displaySize { return independentPool }
        invalidateIndependentFrames()
        let resources = try (0..<3).map { _ in try rotationalCompositor.makeTarget(displaySize: displaySize) }
        let pool = ReprojectionFramePool(resources: resources)
        independentPool = pool
        independentReprojection?.use(pool)
        return pool
    }

    private func observeIndependentPresentation() {
        guard let state = independentReprojection?.snapshot,
              state.epoch == independentEpoch, let orientation = state.orientation else { return }
        currentHead = orientation
        currentHeadOffset = state.position
        lastPredictionHorizon = state.horizon
        lastReprojectionAngle = state.angle
        lastReprojectionApplied = worldLockedPresentation
        usedExternalOrientation = state.external
        displaySyncEnabled = state.displaySyncEnabled
        restPhase = state.restPhase
        restStabilizing = state.restStabilizing
        restCorrection = state.restCorrection
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func toggleMeditation() {
        meditation.toggle()
        if meditation.isActive, meditation.progress == 0 {
            meditationStart = CACurrentMediaTime()
        }
        if meditation.isActive, nebulaMap == nil {
            nebulaMap = bakeNebula()
        }
    }

    private func bakeNebula() -> MTLTexture? {
        let size = Renderer.nebulaMapSize
        let descriptor = MTLTextureDescriptor.textureCubeDescriptor(pixelFormat: .rgba16Float, size: size, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let map = device.makeTexture(descriptor: descriptor), let commandBuffer = queue.makeCommandBuffer() else { return nil }
        var faceSize = Float(size)
        for face in 0..<6 {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = map
            pass.colorAttachments[0].slice = face
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
            var faceIndex = UInt32(face)
            encoder.setRenderPipelineState(nebulaBakePipeline)
            encoder.setFragmentBytes(&faceIndex, length: MemoryLayout<UInt32>.stride, index: 0)
            encoder.setFragmentBytes(&faceSize, length: MemoryLayout<Float>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        commandBuffer.commit()
        return map
    }

    private static let nebulaMapSize = 1024

    func draw(in view: MTKView) {
        let target = nextTargetTime ?? CACurrentMediaTime() + 1.0 / 60
        nextTargetTime = nil
        draw(in: view, targetTime: target)
    }

    func draw(in view: MTKView, targetTime: Double) {
        dispatchPrecondition(condition: .onQueue(.main))
        let now = CACurrentMediaTime()
        guard !suspendsIndependentScene else { return }
        let presentTime = independentReprojection == nil ? presentation.presentTime(target: targetTime) : targetTime
        lastReprojectionApplied = false
        lastReprojectionAngle = 0
        let external = externalPose?(presentTime)
        if independentReprojection != nil, externalPose != nil, external == nil { return }
        if usedExternalOrientation != (external != nil) { resetWorldLockSmoothing() }
        usedExternalOrientation = external != nil
        let head: simd_quatd
        if let external {
            lastPredictionHorizon = external.predictionHorizon
            head = worldLockedPresentation ? calibration.apply(to: external.orientation)
                : headPipeline.stabilizedExternal(external.orientation, dt: now - lastFrameTime)
        } else {
            if adaptivePrediction {
                evaluatePendingPrediction()
            }
            if worldLockedPresentation {
                let sample = headPipeline.worldLockedSample(at: presentTime)
                lastPredictionHorizon = sample.horizon
                head = sample.orientation
            } else {
                lastPredictionHorizon = headPipeline.predictionHorizon(at: presentTime)
                head = headPipeline.renderedOrientation(at: presentTime, frameInterval: now - lastFrameTime)
            }
            rememberPrediction(for: presentTime, orientation: head)
        }
        let frameSeconds = min(now - lastFrameTime, 0.1)
        meditation.advance(by: frameSeconds)
        let breathingTarget = breathingEnabled ? 1.0 : 0.0
        breathingVisibility += max(-frameSeconds, min(frameSeconds, breathingTarget - breathingVisibility))
        lastFrameTime = now
        currentHead = head
        defer {
            observeIndependentPresentation()
            onFrame?(currentHead)
        }
        scene.tick(head: head)
        let baseOffset = external.map { calibration.apply(toPosition: $0.position) } ?? headOffset?(head) ?? .zero
        currentHeadOffset = headFollower.follow(baseOffset, dt: frameSeconds)

        guard let commandBuffer = queue.makeCommandBuffer() else { return }
        let size = view.drawableSize
        guard size.width > 0, size.height > 0 else { return }
        var writingPool: ReprojectionFramePool?
        var ticket: ReprojectionFramePool.Ticket?
        var submitted = false
        defer {
            if !submitted, let writingPool, let ticket { writingPool.complete(ticket, metadata: nil) }
        }
        let reprojectionTarget: RotationalCompositor.Target?
        if independentReprojection != nil {
            do {
                let pool = try prepareIndependentPool(size: size)
                guard let reserved = pool.reserve() else { return }
                writingPool = pool
                ticket = reserved
                reprojectionTarget = pool.resources[reserved.index]
                reprojectionAllocationFailed = false
            } catch {
                if !reprojectionAllocationFailed { log("independent scene allocation failed: \(error)") }
                reprojectionAllocationFailed = true
                return
            }
        } else {
            reprojectionTarget = prepareReprojection(size: size)
        }
        var uploads: [(slot: ScreenSlot, upload: CapturedTexture.Upload)] = []
        for (index, slot) in slots.enumerated() {
            if meditation.eased < 1, scene.focus.map({ $0.screen == index }) ?? true,
               let cache = textureCache,
               let upload = slot.contents.prepare(device: device, cache: cache, command: commandBuffer) {
                uploads.append((slot, upload))
            }
            _ = slot.noteFrameArrived()
            trackStalls(slot: slot, at: now)
        }
        guard let pass = reprojectionTarget?.pass ?? view.currentRenderPassDescriptor,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let overscan = reprojectionTarget?.overscan ?? SIMD2<Float>(repeating: 1)
        let renderFOV = 2 * atan(tan(Float(verticalFOV * .pi / 360)) * overscan.y)
        let projection = simd_float4x4.perspective(
            fovY: renderFOV,
            aspect: Float(size.width / size.height) * overscan.x / overscan.y,
            near: 0.05, far: 100
        )
        let rotationOnly = simd_float4x4(simd_quatf(vector: SIMD4<Float>(head.inverse.vector)))
        let offset = currentHeadOffset
        let viewMatrix = rotationOnly * .translation(SIMD3(Float(-offset.x), Float(-offset.y), Float(-offset.z)))

        let skyAmount = Float(meditation.eased)
        if skyAmount > 0, let nebulaMap {
            let breathing = Float(Breathing.openness(at: now - meditationStart))
            var sky = SkyUniforms(
                inverseViewProjection: (projection * rotationOnly).inverse,
                params: SIMD4(Float(now - skyClockStart), skyAmount, breathing, Float(breathingVisibility))
            )
            encoder.setRenderPipelineState(skyPipeline)
            encoder.setDepthStencilState(skyDepthState)
            encoder.setFragmentBytes(&sky, length: MemoryLayout<SkyUniforms>.stride, index: 0)
            encoder.setFragmentTexture(nebulaMap, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setFragmentSamplerState(sampler, index: 0)

        let screenOpacity = 1 - skyAmount
        for (i, (slot, pose)) in zip(slots, scene.screens).enumerated() where screenOpacity > 0 {
            if let focus = scene.focus, focus.screen != i { continue }
            let model = (scene.focus?.pose ?? pose).modelMatrix
            let texture = uploads.first(where: { $0.slot === slot })?.upload.texture ?? slot.texture ?? placeholder
            let selectedForSwap = scene.swapSource == i
            let moving = selectedForSwap || scene.grabbed == i || draggingScreen == i || snappedNeighbor == i
            let borderAlpha: Float = moving ? 1.0 : (!showsScreenBorders ? 0 : (cursorScreen == i ? 0.6 : 0.25))
            var uniforms = Uniforms(
                mvp: projection * viewMatrix * model,
                border: SIMD4((selectedForSwap ? 10 : 3) / Float(texture.width), (selectedForSwap ? 10 : 3) / Float(texture.height), borderAlpha, screenOpacity),
                textStyle: SIMD4(screenTextMode == .original ? 0 : 1, screenTextMode == .softDimmed ? 1 : 0, 0, 0)
            )
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        if skyAmount == 0, showsGrid {
            encoder.setRenderPipelineState(gridPipeline)
            if showsGrid {
                var gridUniforms = Uniforms(mvp: projection * viewMatrix, border: SIMD4(0.15, 0.75, 0.3, 1))
                encoder.setVertexBuffer(gridVertices, offset: 0, index: 1)
                encoder.setVertexBytes(&gridUniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.setFragmentBytes(&gridUniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: gridVertexCount)
            }
        }
        encoder.endEncoding()

        if let writingPool, let ticket {
            let source: ReprojectionPoseSource
            if external != nil {
                guard let independentSource else { return }
                source = independentSource
            } else {
                source = .rayNeo(filter, bias: headPipeline.predictionBias,
                                 limit: headPipeline.maxPrediction, fallback: headPipeline.predictionSeconds)
            }
            let frame = ReprojectionFrame(orientation: head, position: currentHeadOffset,
                                          verticalFOV: Float(verticalFOV * .pi / 180), calibration: calibration,
                                          source: source, worldLocked: worldLockedPresentation,
                                          smoothing: worldLockSmoothing, adaptiveVSync: adaptiveVSync, restSmoothing: restSmoothing,
                                          restTolerance: restTolerance, restStrength: restStrength, indicatorYaw: showsRestIndicator ? scene.centerYaw : nil,
                                          epoch: independentEpoch, created: now,
                                          scanoutEnabled: scanoutEnabled, scanoutBottomToTop: scanoutBottomToTop)
            commandBuffer.addCompletedHandler { buffer in
                writingPool.complete(ticket, metadata: buffer.status == .completed ? frame : nil)
            }
            submitted = true
            commitScene(commandBuffer, uploads: uploads, cpuStart: now)
            return
        }
        if let reprojectionTarget {
            commitScene(commandBuffer, uploads: uploads, cpuStart: now)
            presentReprojectedScene(reprojectionTarget, sceneHead: head, externalSource: external != nil,
                                    view: view, targetTime: targetTime, presentTime: presentTime)
            return
        }

        guard let drawable = view.currentDrawable else { return }
        setFallbackDisplaySyncEnabled(originalDisplaySyncEnabled)
        restPhase = .disabled
        restStabilizing = false
        restCorrection = 0
        do {
            try encodeRestIndicator(phase: .disabled, head: head, destination: drawable.texture, commandBuffer: commandBuffer)
        } catch {
            log("rest indicator encode failed: \(error)")
            return
        }

        drawable.addPresentedHandler { [presentation] drawable in
            presentation.observe(target: targetTime, presented: drawable.presentedTime)
        }
        commandBuffer.present(drawable)
        commitScene(commandBuffer, uploads: uploads, cpuStart: now)
    }

    private func commitScene(_ command: MTLCommandBuffer, uploads: [(slot: ScreenSlot, upload: CapturedTexture.Upload)], cpuStart: Double) {
        let timingID = sceneTimings.begin(cpuStart: cpuStart, committed: CACurrentMediaTime(), sourceTime: nil, synchronized: nil)
        for entry in uploads { entry.slot.contents.commit(entry.upload) }
        command.addCompletedHandler { [sceneTimings] buffer in
            sceneTimings.completed(timingID, gpuStart: buffer.gpuStartTime, gpuEnd: buffer.gpuEndTime)
            if buffer.status == .error {
                DispatchQueue.main.async {
                    for entry in uploads { entry.slot.contents.invalidate(entry.upload) }
                }
            }
            _ = uploads
        }
        command.commit()
    }

    private func prepareReprojection(size: CGSize) -> RotationalCompositor.Target? {
        guard worldLockedPresentation else { return nil }
        do {
            let target = try rotationalCompositor.prepare(displaySize: SIMD2(Int(size.width), Int(size.height)))
            reprojectionAllocationFailed = false
            return target
        } catch {
            if !reprojectionAllocationFailed { log("rotational reprojection allocation failed: \(error)") }
            reprojectionAllocationFailed = true
            return nil
        }
    }

    private func lateOrientation(at time: Double, externalSource: Bool, fallback: simd_quatd)
        -> (orientation: simd_quatd, motion: simd_quatd, stable: Bool, scanoutBudget: Double) {
        if externalSource {
            if let source = independentSource, source.predictsFromOrientation,
               let pose = source.sample(time) {
                lastPredictionHorizon = pose.horizon
                let motion = calibration.apply(to: pose.orientation)
                let predicted = worldLockPrediction.predict(motion, at: CACurrentMediaTime(),
                                                           sampleTime: pose.sampleTime, horizon: pose.horizon, smoothing: worldLockSmoothing)
                return (predicted, motion, pose.isStable, max(0, pose.maximumPredictionHorizon - pose.horizon))
            }
            guard let pose = externalPose?(time) else { return (fallback, fallback, false, 0) }
            lastPredictionHorizon = pose.predictionHorizon
            let head = calibration.apply(to: pose.orientation)
            return (head, head, false, 0)
        }
        let source = ReprojectionPoseSource.rayNeo(filter, bias: headPipeline.predictionBias,
                                                 limit: headPipeline.maxPrediction, fallback: headPipeline.predictionSeconds)
        guard let sample = source.sample(time) else { return (fallback, fallback, false, 0) }
        lastPredictionHorizon = sample.horizon
        let motion = calibration.apply(to: sample.orientation)
        let predicted = worldLockPrediction.predict(motion, at: CACurrentMediaTime(),
                                                   sampleTime: sample.sampleTime, horizon: sample.horizon, smoothing: worldLockSmoothing)
        return (predicted, motion, sample.isStable, max(0, sample.maximumPredictionHorizon - sample.horizon))
    }

    private func presentReprojectedScene(_ target: RotationalCompositor.Target, sceneHead: simd_quatd,
                                        externalSource: Bool, view: MTKView, targetTime: Double, presentTime: Double) {
        guard let drawable = view.currentDrawable else { return }
        let now = CACurrentMediaTime()
        if adaptiveVSync {
            let source: ReprojectionPoseSource? = externalSource ? independentSource
                : .rayNeo(filter, bias: headPipeline.predictionBias,
                          limit: headPipeline.maxPrediction, fallback: headPipeline.predictionSeconds)
            let sample = source?.sample(now)
            let motion = sample.map { calibration.apply(to: $0.orientation) } ?? sceneHead
            _ = restPresentation.filter(motion, motion: motion, at: now, restSmoothing: restSmoothing,
                                        adaptiveVSync: true, stable: sample?.isStable == true,
                                        strength: restStrength, tolerance: restTolerance)
        }
        let frameClock = adaptivePresentationClock
        let latePresentTime = adaptiveVSync
            ? frameClock.targetTime(now: now, displayTarget: targetTime, synchronized: restPresentation.displaySyncEnabled)
            : max(presentTime, now)
        let late = lateOrientation(at: latePresentTime, externalSource: externalSource, fallback: sceneHead)
        let framePacer = presentationPacer
        framePacer.updateMotion(late.motion, at: now, stable: adaptiveVSync && late.stable)
        if framePacer.consumeDrain(at: now) { return }
        guard let commandBuffer = queue.makeCommandBuffer() else { return }
        let predictedHead = late.orientation
        let smoothsExternalPose = !adaptiveVSync && externalSource && independentSource?.predictsFromOrientation != true
        let baseHead = smoothsExternalPose ? smoothWorldLockedOrientation(predictedHead) : predictedHead
        let lateHead = adaptiveVSync ? baseHead
            : restPresentation.filter(baseHead, motion: late.motion, at: now,
                                      restSmoothing: restSmoothing, adaptiveVSync: false,
                                      stable: late.stable, strength: restStrength, tolerance: restTolerance)
        restPhase = restPresentation.phase
        restStabilizing = restPresentation.isSmoothing
        restCorrection = restPresentation.correctionRadians
        setFallbackDisplaySyncEnabled(adaptiveVSync ? restPresentation.displaySyncEnabled : originalDisplaySyncEnabled)
        let scanout = ScanoutPrediction(reference: lateHead, angularVelocity: worldLockPrediction.predictionAngularVelocity,
                                         duration: presentationRefreshPeriod, maximumAdditionalTime: late.scanoutBudget,
                                         enabled: scanoutEnabled && late.stable, bottomToTop: scanoutBottomToTop)
        let warp = RotationalReprojection(scene: sceneHead, displayTop: scanout.top, displayBottom: scanout.bottom, verticalFOV: Float(verticalFOV * .pi / 180),
                                         aspect: Float(target.displaySize.x) / Float(target.displaySize.y), overscan: target.overscan)
        do {
            try rotationalCompositor.encode(warp, source: target.color, destination: drawable.texture, commandBuffer: commandBuffer)
            try encodeRestIndicator(phase: restPhase, head: lateHead, destination: drawable.texture, commandBuffer: commandBuffer)
        } catch {
            log("rotational reprojection encode failed: \(error)")
            return
        }
        currentHead = lateHead
        lastReprojectionAngle = 2 * acos(min(1, abs(simd_dot(sceneHead.vector, lateHead.vector))))
        lastReprojectionApplied = true
        if !externalSource { rememberPrediction(for: latePresentTime, orientation: predictedHead) }
        let adaptive = adaptiveVSync
        let submittedDisplaySync = displaySyncEnabled
        let timingID = warpTimings.begin(cpuStart: now, committed: CACurrentMediaTime(), sourceTime: nil,
                                         synchronized: submittedDisplaySync)
        commandBuffer.addCompletedHandler { [warpTimings] buffer in
            warpTimings.completed(timingID, gpuStart: buffer.gpuStartTime, gpuEnd: buffer.gpuEndTime)
        }
        drawable.addPresentedHandler { [presentation, warpTimings] drawable in
            warpTimings.presented(timingID, at: drawable.presentedTime)
            if adaptive {
                frameClock.observe(now: now, displayTarget: targetTime, presented: drawable.presentedTime,
                                   synchronized: submittedDisplaySync)
                framePacer.observe(renderStart: now, presented: drawable.presentedTime, now: CACurrentMediaTime())
            } else {
                presentation.observe(target: targetTime, presented: drawable.presentedTime)
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func encodeRestIndicator(phase: RestStabilizationPhase, head: simd_quatd,
                                     destination: MTLTexture, commandBuffer: MTLCommandBuffer) throws {
        guard showsRestIndicator else { return }
        try restIndicator.encode(phase: phase, strength: restStrength, adaptiveSync: adaptiveVSync && worldLockedPresentation ? displaySyncEnabled : nil, head: head, position: currentHeadOffset,
                                 anchorYaw: scene.centerYaw, verticalFOV: Float(verticalFOV * .pi / 180),
                                 destination: destination, commandBuffer: commandBuffer)
    }

    private func setFallbackDisplaySyncEnabled(_ enabled: Bool) {
        guard independentReprojection == nil else { return }
        if outputLayer?.displaySyncEnabled != enabled { outputLayer?.displaySyncEnabled = enabled }
        displaySyncEnabled = outputLayer?.displaySyncEnabled ?? true
    }

    private func resetWorldLockSmoothing(invalidateResources: Bool = false) {
        if invalidateResources { invalidateIndependentFrames() }
        else { independentEpoch += 1 }
        worldLockStabilizer = .worldLocked
        worldLockPrediction = WorldLockPrediction()
        restPresentation = RestPresentationController()
        adaptivePresentationClock = AdaptivePresentationClock()
        presentationPacer = PresentationFramePacer(refreshPeriod: presentationRefreshPeriod)
        restPhase = .waiting
        restStabilizing = false
        restCorrection = 0
        lastWorldLockSampleTime = nil
    }

    private func smoothWorldLockedOrientation(_ orientation: simd_quatd) -> simd_quatd {
        guard worldLockSmoothing else { return orientation }
        let now = CACurrentMediaTime()
        let dt = lastWorldLockSampleTime.map { now - $0 } ?? 0
        if dt > 0.1 { resetWorldLockSmoothing() }
        lastWorldLockSampleTime = now
        return worldLockStabilizer.filter(orientation, dt: dt)
    }

    private func drawLines(_ points: [SIMD4<Float>], color: SIMD4<Float>, viewProjection: simd_float4x4, encoder: MTLRenderCommandEncoder) {
        var vertices = points
        var uniforms = Uniforms(mvp: viewProjection, border: color)
        encoder.setVertexBytes(&vertices, length: MemoryLayout<SIMD4<Float>>.stride * vertices.count, index: 1)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: vertices.count)
    }

    /// Пишет в лог, когда кадр на панели перестаёт обновляться дольше порога и когда снова оживает.
    ///
    /// Тишина захвата бывает двух видов, и различить их по одному потоку нельзя: на дисплее
    /// ничего не меняется, либо оконный сервер не отдаёт содержимое дисплея потоку захвата.
    /// Второе случается на перестроении пространств: в момент Mission Control панель
    /// замирает на последнем кадре, хотя дисплей продолжает перерисовываться.
    private func trackStalls(slot: ScreenSlot, at now: Double) {
        guard let silentFor = slot.capture.silentFor else { return }
        if silentFor > Self.stallReportThreshold {
            if stallStarted[slot.index] == nil {
                stallStarted[slot.index] = now
                log(String(format: "screen %d: no new capture frames for %.1f s, the picture may be stale", slot.index + 1, silentFor))
            }
            return
        }
        if let started = stallStarted.removeValue(forKey: slot.index), now - started > Self.stallReportThreshold {
            log(String(format: "screen %d: capture alive again after %.1f s", slot.index + 1, now - started))
        }
    }

    private func rememberPrediction(for presentTime: Double, orientation: simd_quatd) {
        guard adaptivePrediction else {
            pendingPrediction = nil
            return
        }
        pendingPrediction = (presentTime, orientation, filter.angularVelocity)
    }

    private func evaluatePendingPrediction() {
        guard let pending = pendingPrediction else { return }
        pendingPrediction = nil
        guard CACurrentMediaTime() - pending.time < 0.25 else { return }
        let actual = headPipeline.calibration.apply(to: filter.orientation(atUptime: pending.time))
        tuner.observe(predicted: pending.orientation, actual: actual, angularVelocity: pending.angularVelocity)
        headPipeline.predictionBias = tuner.value
    }

    private static func worldGridLines() -> [SIMD4<Float>] {
        let radius = 3.0
        func point(yawDegrees: Double, pitchDegrees: Double) -> SIMD4<Float> {
            let p = yawPitchQuat(yaw: yawDegrees * .pi / 180, pitch: pitchDegrees * .pi / 180).act(SIMD3(0, 0, -radius))
            return SIMD4(Float(p.x), Float(p.y), Float(p.z), 1)
        }
        var lines: [SIMD4<Float>] = []
        for pitch in [-30.0, -15.0, 0.0, 15.0, 30.0] {
            for yaw in stride(from: 0.0, to: 360.0, by: 2.0) {
                lines.append(point(yawDegrees: yaw, pitchDegrees: pitch))
                lines.append(point(yawDegrees: yaw + 2, pitchDegrees: pitch))
            }
        }
        for yaw in stride(from: 0.0, to: 360.0, by: 15.0) {
            let halfHeight = yaw == 0 ? 30.0 : 3.0
            lines.append(point(yawDegrees: yaw, pitchDegrees: -halfHeight))
            lines.append(point(yawDegrees: yaw, pitchDegrees: halfHeight))
        }
        return lines
    }

    enum RendererError: Error { case noMetal }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms { float4x4 mvp; float4 border; float4 textStyle; };
    struct VertexOut { float4 position [[position]]; float2 uv; };

    constant float sharpenAmount = 0.6;

    vertex VertexOut screenVertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
        const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        float2 c = corners[vid];
        VertexOut out;
        out.position = u.mvp * float4(c, 0, 1);
        out.uv = float2(c.x * 0.5 + 0.5, 0.5 - c.y * 0.5);
        return out;
    }

    vertex float4 gridVertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]], const device float4 *points [[buffer(1)]]) {
        return u.mvp * points[vid];
    }

    fragment float4 gridFragment(constant Uniforms &u [[buffer(0)]]) {
        return float4(u.border.rgb, 1);
    }

    float3 sampleCatmullRom(texture2d<float> tex, sampler s, float2 uv, float lod) {
        float2 size = float2(tex.get_width(uint(lod)), tex.get_height(uint(lod)));
        float2 position = uv * size;
        float2 texel1 = floor(position - 0.5) + 0.5;
        float2 f = position - texel1;
        float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
        float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
        float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
        float2 w3 = f * f * (-0.5 + 0.5 * f);
        float2 w12 = w1 + w2;
        float2 t0 = (texel1 - 1.0) / size;
        float2 t12 = (texel1 + w2 / w12) / size;
        float2 t3 = (texel1 + 2.0) / size;
        float3 result = 0;
        result += tex.sample(s, float2(t0.x, t0.y), level(lod)).rgb * w0.x * w0.y;
        result += tex.sample(s, float2(t12.x, t0.y), level(lod)).rgb * w12.x * w0.y;
        result += tex.sample(s, float2(t3.x, t0.y), level(lod)).rgb * w3.x * w0.y;
        result += tex.sample(s, float2(t0.x, t12.y), level(lod)).rgb * w0.x * w12.y;
        result += tex.sample(s, float2(t12.x, t12.y), level(lod)).rgb * w12.x * w12.y;
        result += tex.sample(s, float2(t3.x, t12.y), level(lod)).rgb * w3.x * w12.y;
        result += tex.sample(s, float2(t0.x, t3.y), level(lod)).rgb * w0.x * w3.y;
        result += tex.sample(s, float2(t12.x, t3.y), level(lod)).rgb * w12.x * w3.y;
        result += tex.sample(s, float2(t3.x, t3.y), level(lod)).rgb * w3.x * w3.y;
        return max(result, 0.0);
    }

    float3 sampleScreen(texture2d<float> tex, sampler s, float2 uv) {
        float2 texels = uv * float2(tex.get_width(), tex.get_height());
        float footprint = max(length(dfdx(texels)), length(dfdy(texels)));
        float lod = clamp(floor(log2(max(footprint, 1.0))), 0.0, float(tex.get_num_mip_levels() - 1));
        float3 center = sampleCatmullRom(tex, s, uv, lod);
        float2 across = dfdx(uv);
        float2 down = dfdy(uv);
        float3 left = tex.sample(s, uv - across, level(lod)).rgb;
        float3 right = tex.sample(s, uv + across, level(lod)).rgb;
        float3 up = tex.sample(s, uv - down, level(lod)).rgb;
        float3 below = tex.sample(s, uv + down, level(lod)).rgb;
        float3 lowest = min(center, min(min(left, right), min(up, below)));
        float3 highest = max(center, max(max(left, right), max(up, below)));
        float3 blurred = (left + right + up + below) * 0.25;
        return clamp(center + sharpenAmount * (center - blurred), lowest, highest);
    }

    fragment float4 screenFragment(VertexOut in [[stage_in]],
                                   constant Uniforms &u [[buffer(0)]],
                                   texture2d<float> tex [[texture(0)]],
                                   sampler s [[sampler(0)]]) {
        float3 color = u.textStyle.x > 0.5 ? tex.sample(s, in.uv).rgb : sampleScreen(tex, s, in.uv);
        float2 edge = min(in.uv, 1 - in.uv);
        if (edge.x < u.border.x || edge.y < u.border.y) {
            color = mix(color, float3(0.55, 0.75, 1.0), u.border.z);
        }
        if (u.textStyle.y > 0.5) {
            float peak = max(color.r, max(color.g, color.b));
            if (peak > 0.25) {
                float highlight = peak - 0.25;
                float softened = 0.25 + highlight / (1.0 + (7.0 / 6.0) * highlight);
                color *= softened / peak;
            }
        }
        return float4(color, u.border.w);
    }
    """ + skyShaderSource
}
