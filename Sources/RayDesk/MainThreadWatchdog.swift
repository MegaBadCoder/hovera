import Foundation

/// Завершает приложение, если главный поток не отвечает `limit` секунд.
///
/// Виртуальные дисплеи и перехват мыши RayDesk живут на главном потоке: когда он встаёт, вместе с ним
/// замирает оконный сервер и весь Mac. Выход приложения убирает виртуальные дисплеи, и система оживает.
final class MainThreadWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var lastBeat = ProcessInfo.processInfo.systemUptime
    private let queue = DispatchQueue(label: "raydesk.watchdog", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let limit: Double

    init(limit: Double = 5) {
        self.limit = limit
    }

    /// Запускает проверку раз в полсекунды.
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
        self.timer = timer
    }

    private func check() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.lastBeat = ProcessInfo.processInfo.systemUptime }
        }
        let silent = ProcessInfo.processInfo.systemUptime - lock.withLock { lastBeat }
        guard silent > limit else { return }
        log(String(format: "ERROR watchdog: main thread stuck for %.1f s, exiting so the displays come back", silent))
        _exit(3)
    }
}
