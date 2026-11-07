import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import Vision
import simd

/// Камера очков VITURE и распознавание рук на её кадрах.
///
/// VITURE Luma Ultra отдаёт фронтальную камеру как обычное UVC-устройство
/// (`0x0C45:0x636B`), поэтому SDK для превью не нужен: берём поток через
/// AVFoundation и ищем на нём кисти запросом Vision. Частота распознавания
/// ограничена, чтобы не жечь процессор: кадры идут с камеры, а детекция — по
/// расписанию.
final class HandCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Одна кисть: точки в долях кадра, начало координат — левый верхний угол.
    struct Hand {
        var joints: [VNHumanHandPoseObservation.JointName: SIMD2<Double>]
        var confidence: Float
    }

    /// Последний кадр и найденные кисти.
    struct Frame {
        var image: CGImage
        var width: Int
        var height: Int
        var hands: [Hand]
    }

    /// Куда отдавать кадры; вызывается на главном потоке.
    var onFrame: ((Frame) -> Void)?

    /// Чья камера используется в строке состояния.
    private(set) var deviceName = ""

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "raydesk.hands.camera")
    private let context = CIContext()
    private var lastDetection = 0.0
    private var hands: [Hand] = []
    private var frameCount = 0
    private var lastRateTime = CACurrentMediaTime()
    private var rate = 0.0
    private static let detectionInterval = 0.1

    /// Кадров в секунду по последней секунде.
    var framesPerSecond: Double { rate }

    /// Ищет камеру очков VITURE среди UVC-устройств.
    ///
    /// - Returns: устройство либо `nil`, если очки не подключены.
    static func glassesCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
        let candidates = discovery.devices.isEmpty ? AVCaptureDevice.devices(for: .video) : discovery.devices
        return candidates.first { device in
            let id = device.uniqueID.uppercased()
            let model = (device.modelID ?? "").uppercased()
            return id.contains("3141") || model.contains("3141") || model.contains("636B") || id.contains("636B")
        }
    }

    /// Открывает камеру очков и запускает поток.
    ///
    /// - Throws: ошибку открытия устройства или настройки сессии.
    func start() throws {
        guard let device = Self.glassesCamera() else {
            throw NSError(domain: "RayDesk.HandCamera", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "камера очков VITURE не найдена"])
        }
        deviceName = device.localizedName
        try configure(device)
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        session.sessionPreset = .high
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw NSError(domain: "RayDesk.HandCamera", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "камера занята другим приложением"])
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw NSError(domain: "RayDesk.HandCamera", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "не удалось добавить выход видео"])
        }
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
    }

    /// Выбирает формат и частоту кадров.
    ///
    /// UVC-камера по умолчанию может отдавать 1080p на двух кадрах в секунду:
    /// в темноте автоэкспозиция удлиняет выдержку. Принудительно ставим 30 к/с,
    /// чтобы кадры шли ровно, а выдержка подстраивалась под этот предел.
    private func configure(_ device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        let target = 30.0
        let formats = device.formats.filter { format in
            format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= target && $0.maxFrameRate >= target }
        }
        if let format = formats.first(where: { $0.formatDescription.dimensions.width == 1920 }) ?? formats.first {
            device.activeFormat = format
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        let dimensions = device.activeFormat.formatDescription.dimensions
        log("hands camera format: \(dimensions.width)×\(dimensions.height)")
    }

    /// Останавливает поток.
    func stop() {
        guard session.isRunning else { return }
        session.stopRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = CACurrentMediaTime()
        frameCount += 1
        if now - lastRateTime >= 1 {
            rate = Double(frameCount) / (now - lastRateTime)
            frameCount = 0
            lastRateTime = now
        }
        if now - lastDetection >= Self.detectionInterval {
            lastDetection = now
            hands = detectHands(in: buffer)
        }
        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let image = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        let frame = Frame(image: image, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer), hands: hands)
        DispatchQueue.main.async { [onFrame] in onFrame?(frame) }
    }

    private func detectHands(in buffer: CVPixelBuffer) -> [Hand] {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let observations = request.results else { return [] }
        return observations.compactMap { observation in
            guard let points = try? observation.recognizedPoints(.all) else { return nil }
            var joints: [VNHumanHandPoseObservation.JointName: SIMD2<Double>] = [:]
            var total: Float = 0
            var count = 0
            for (name, point) in points where point.confidence > 0.3 {
                joints[name] = SIMD2(Double(point.location.x), 1 - Double(point.location.y))
                total += point.confidence
                count += 1
            }
            return Hand(joints: joints, confidence: count > 0 ? total / Float(count) : 0)
        }
    }
}
