import CoreGraphics
import MetalKit

final class ScreenSlot {
    let index: Int
    let virtualScreen: VirtualScreen
    let capture = DisplayCapture()
    var seenGeneration = 0
    var texture: MTLTexture?
    private var cached: CGDirectDisplayID?
    private(set) var showsLiveFrame = true

    /// Тишина дольше этого порога означает, что кадр на панели уже не соответствует
    /// содержимому дисплея. Порог с запасом перекрывает штатные паузы захвата: дисплей
    /// не перерисовывается, пока на нём ничего не меняется, и короткие паузы — норма.
    static let stallThreshold: TimeInterval = 0.8

    /// Сколько панель молчит прямо сейчас, если молчит дольше порога.
    var stall: TimeInterval? {
        guard let silentFor = capture.silentFor, silentFor > Self.stallThreshold else { return nil }
        return silentFor
    }

    var displayBounds: CGRect { CGDisplayBounds(displayID) }

    /// Номер дисплея, который оконный сервер выдал этому виртуальному экрану.
    ///
    /// Номера меняются от запуска к запуску, порядок в списке дисплеев тоже: без опознания
    /// по серийному номеру экран получал чужие координаты и переезжал при каждом старте.
    var displayID: CGDirectDisplayID {
        if let cached { return cached }
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        for id in ids where CGDisplayVendorNumber(id) == VirtualScreen.vendorID && CGDisplaySerialNumber(id) == virtualScreen.serialNumber {
            cached = id
            return id
        }
        let fallback = virtualScreen.displayID
        cached = fallback
        return fallback
    }

    init(index: Int, pointWidth: Int = 1920, pointHeight: Int = 1080) {
        self.index = index
        virtualScreen = VirtualScreen(index: index, pointWidth: pointWidth, pointHeight: pointHeight)
    }

    func start() async throws {
        try await capture.start(displayID: displayID, width: virtualScreen.pixelWidth, height: virtualScreen.pixelHeight)
    }

    func stop() {
        capture.stop()
    }

    /// Отмечает, пришёл ли на этом кадре свежий захват.
    ///
    /// - Returns: `true`, если показывать панель можно: либо кадр только что обновился,
    ///   либо захват молчит не дольше `stallThreshold`.
    func noteFrameArrived() -> Bool {
        showsLiveFrame = (capture.silentFor ?? 0) <= Self.stallThreshold
        return showsLiveFrame
    }
}
