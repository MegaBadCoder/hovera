import Foundation

/// Завершает приложение, если главный поток не отвечает `limit` секунд.
///
/// Виртуальные дисплеи и перехват мыши RayDesk живут на главном потоке: когда он встаёт, вместе с ним
/// замирает оконный сервер и весь Mac. Выход приложения убирает виртуальные дисплеи, и система оживает.
///
/// Живость отмечают итерации главного цикла в общих режимах, а также блоки в главной очереди: открытое
/// меню, перетаскивание или модальное окно зависанием не считаются — цикл в них крутится, а вставший
/// поток не даёт ни того, ни другого.
final class MainThreadWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var lastBeat = ProcessInfo.processInfo.systemUptime
    private let queue = DispatchQueue(label: "raydesk.watchdog", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var observer: CFRunLoopObserver?
    private let limit: Double

    init(limit: Double = 5) {
        self.limit = limit
    }

    /// Ставит наблюдателя за главным циклом и запускает проверку раз в полсекунды.
    ///
    /// - Important: вызывается с главного потока — наблюдатель вешается на его цикл.
    func start() {
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.allActivities.rawValue, true, 0) { [weak self] _, _ in
            self?.beat()
        }
        if let observer {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
        self.observer = observer

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
        self.timer = timer
    }

    private func beat() {
        lock.withLock { lastBeat = ProcessInfo.processInfo.systemUptime }
    }

    private func check() {
        DispatchQueue.main.async { [weak self] in self?.beat() }
        let silent = ProcessInfo.processInfo.systemUptime - lock.withLock { lastBeat }
        guard silent > limit else { return }
        log(String(format: "ERROR watchdog: main thread stuck for %.1f s, exiting so the displays come back", silent))
        _exit(3)
    }
}
