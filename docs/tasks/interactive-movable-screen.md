# Интерактивные перемещаемые экраны в RayDesk

**Status:** executing
**Branch:** interactive-movable-screen
**Worktree:** none
**Mode:** interactive

## Design

**Цель.** В очках пользователь не может работать с приложениями: курсор живёт в раскладке дисплеев macOS, а не там, куда он смотрит, поэтому в экране в очках его «нет» и кликать не выходит. Нужно: несколько виртуальных мониторов в пространстве, курсор, который приходит туда, куда смотришь, перемещение экранов мышью и тесты.

**Решения (согласованы с пользователем):**

1. **Архитектура: библиотека `RayDeskCore` + тонкое приложение `RayDesk`.** В Core только чистая логика без AppKit, Metal, IOKit и ScreenCaptureKit: декодер RayNeo, фильтр ориентации, поза экрана, пересечение луча взгляда с экранами, маппинг uv ↔ глобальные координаты macOS, расчёт раскладки дисплеев, математика перетаскивания, правило прыжка курсора. Приложение — обвязка: HID, виртуальные дисплеи, захват, Metal, event tap, меню. Тесты — Swift Testing в `RayDeskCoreTests`, `swift test` без очков. Вариант «`@testable import` исполняемого таргета» отвергнут: мешает `main.swift`, тесты тянут AppKit и Metal.

2. **Несколько мониторов.** По умолчанию 2 виртуальных монитора macOS, пункты меню «Добавить экран» и «Убрать экран», максимум 4. Новый экран ставится туда, куда смотрит пользователь. У каждого экрана своя поза (yaw, pitch, дистанция, ширина), свой SCStream и своя текстура. Рендер рисует все экраны с буфером глубины. Позы сохраняются в UserDefaults списком. Отвергнут вариант «каждое окно — отдельная панель»: клики пришлось бы эмулировать, это отдельная большая задача.

3. **Курсор прыгает к взгляду.** Каждый кадр луч взгляда пересекается с экранами → (экран, uv). Если взгляд задержался на экране S не меньше 200 мс, курсор находится на другом дисплее (или на MacBook) и не зажата кнопка мыши, то при первом движении мыши курсор переносится в точку взгляда на S. Внутри одного экрана курсор ходит как обычно. Раскладка дисплеев macOS повторяет пространство: виртуальные экраны стоят в ряд слева направо по yaw, вплотную друг к другу; пересчёт после окончания перемещения экрана, не во время. Режим `forAppOnly` — раскладка откатывается при выходе. Экран с курсором подсвечивается рамкой.

4. **Перемещение мышью.** ⌃⌥ + зажатая кнопка + перетаскивание двигает экран под курсором по сфере вокруг головы: курсор стоит на месте относительно экрана, клик в приложение не проходит. ⌃⌥ + скролл — ближе/дальше. Реализация — CGEventTap, нужно разрешение Accessibility; без него перетаскивание отключено с сообщением, хоткеи работают. Хоткеи (⌃⌥G, ⌃⌥Space, ⌃⌥↑↓, ⌃⌥=−) действуют на экран под взглядом.

**Обратная совместимость.** Внешних потребителей нет. Старые ключи `yaw`/`pitch`/`distance`/`width` в UserDefaults не мигрируются — поза один раз сбрасывается на дефолт (согласовано).

**Неизвестные (проверить первыми):**
- двигает ли курсор подмена координат события `mouseMoved` в event tap без задержки; запасной путь — `CGWarpMouseCursorPosition` + `CGAssociateMouseAndMouseCursorPosition(true)`;
- производительность 2–4 захватов 3840×2160 одновременно; запасной путь — захват в 1× (1920×1080).

TDD: yes (Core — чистые функции с чёткими входами и выходами; обвязка AppKit/Metal/event tap проверяется вручную в очках)

### Invariants
- `RayDeskCore` не импортирует AppKit, Metal, MetalKit, IOKit, ScreenCaptureKit, Carbon и `CGVirtualDisplayPrivate` — только Foundation и simd.
- Раскладка дисплеев меняется только через `CGCompleteDisplayConfiguration(_, .forAppOnly)`.
- Курсор не прыгает, пока зажата любая кнопка мыши и пока идёт перетаскивание экрана.
- Событие мыши с зажатыми ⌃⌥ во время перетаскивания экрана не доходит до приложений (tap возвращает `nil`); все прочие события проходят без изменений, кроме одного `mouseMoved` в момент прыжка курсора.
- Количество экранов в пределах 1…4.
- Виртуальные экраны в раскладке macOS не перекрываются и стоят вплотную.

### Principles
- Чистая логика в Core, побочные эффекты в приложении: функции Core получают состояние аргументами и возвращают решение, а не вызывают системные API.
- Без тихих фолбэков: если нет разрешения (запись экрана, Accessibility), пользователь видит сообщение, а зависящая от него функция выключена.
- Углы в радианах, расстояния в метрах, координаты дисплеев — глобальные точки macOS (верхний левый угол, y вниз); единицы указываются в имени или доке, если неочевидны.
- Код без поясняющих комментариев; доккомментарии только на публичном API Core, по-русски.

## Plan

Approach: сначала вынести существующую чистую логику в `RayDeskCore` и покрыть тестами, затем по TDD добавить в Core пространственную модель (позы, пересечение взгляда, маппинг, раскладка, перетаскивание, правило прыжка курсора) и только потом переписать обвязку приложения под несколько экранов и event tap.

### Phase 1 — Библиотека RayDeskCore и тесты существующей логики

- **1.1** `Package.swift` (modify) — таргеты `RayDeskCore` (Foundation+simd), `RayDeskCoreTests` (Swift Testing), `RayDesk` зависит от `RayDeskCore`.
- **1.2** `Sources/RayDesk/{RayNeoProtocol,OrientationFilter,Math}.swift` → `Sources/RayDeskCore/` (move) — типы и методы становятся `public`, доккомментарии по-русски на публичном API.
  - Invariant: Core импортирует только Foundation и simd.
- **1.3** `Tests/RayDeskCoreTests/RayNeoDecoderTests.swift` (create) — реальный кадр из пробы очков, dt по tick, отказ по magic/type, повтор tick, переполнение tick.
- **1.4** `Tests/RayDeskCoreTests/OrientationFilterTests.swift` (create) — покой с g по +Y → pitch≈0; g с +Z → взгляд вниз (pitch<0); вращение +Y 90°/с 1 с → yaw≈+90° (влево); смещение гироскопа выучивается в покое.
- Commit: `Core: вынести декодер, фильтр и математику в RayDeskCore, тесты`

### Phase 2 — Пространственная модель в Core (TDD)

- **2.1** `Sources/RayDeskCore/ScreenPose.swift` (create)
  - `public struct ScreenPose: Codable, Equatable { yaw, pitch, distance, width: Double; aspect: Double /* ширина/высота */ }`
  - `var rotation: simd_quatd`, `var height: Double`, `var angularWidth: Double`, `var modelMatrix: simd_float4x4`
  - `func intersect(rayDirection: SIMD3<Double>) -> (t: Double, uv: SIMD2<Double>)?` — uv: u вправо, v вниз, [0,1]².
- **2.2** `Sources/RayDeskCore/Gaze.swift` (create)
  - `public struct GazeHit: Equatable { screen: Int; uv: SIMD2<Double> }`
  - `public func gazeHit(head: simd_quatd, screens: [ScreenPose]) -> GazeHit?` — ближайший по t.
- **2.3** `Sources/RayDeskCore/DisplayGeometry.swift` (create)
  - `public func globalPoint(uv:, in bounds: CGRect) -> CGPoint`, `public func uv(of point: CGPoint, in bounds: CGRect) -> SIMD2<Double>?`
  - `public func arrangeDisplays(screenYaws: [Double], screenSizes: [CGSize], main: CGRect, glasses: CGSize) -> (screens: [CGPoint], glasses: CGPoint)` — ряд над MacBook слева направо по убыванию yaw, вплотную, по центру; очки слева от MacBook, низом по его низу.
  - Invariant: экраны вплотную и без перекрытий.
- **2.4** `Sources/RayDeskCore/ScreenDrag.swift` (create)
  - `public func dragged(_ pose: ScreenPose, byPoints delta: CGVector, displayPointWidth: Double) -> ScreenPose` — экран сдвигается ровно под мышью; pitch в пределах ±80°.
  - `public func scrolled(_ pose: ScreenPose, by delta: Double) -> ScreenPose` — дистанция ×1.05^(−delta), 0.4…6 м.
- **2.5** `Sources/RayDeskCore/CursorWarpPolicy.swift` (create)
  - `public struct CursorWarpPolicy { dwell: TimeInterval = 0.2; mutating func observeGaze(screen: Int?, at: TimeInterval); func warpTarget(cursorScreen: Int?, buttonsDown: Bool, at: TimeInterval) -> Int? }`
  - Invariant: при зажатой кнопке — `nil`.
- **2.6** `Sources/RayDeskCore/SpatialScene.swift` (create) — заменяет `ScreenPlacement`.
  - `public final class SpatialScene { screens: [ScreenPose]; grabbed: Int?; maxScreens = 4 }`
  - `addScreen(head:) -> Bool`, `removeLastScreen() -> Bool`, `place(_ index:, head:)`, `toggleGrab(_ index:, head:)`, `tick(head:)`, `adjustDistance(_:by:)`, `adjustWidth(_:by:)`, `encoded() -> Data`, `static func decode(_ data: Data?, default count: Int, aspect: Double) -> [ScreenPose]` (1…4; мусор → дефолт).
  - Invariant: 1 ≤ screens.count ≤ 4.
- **2.7** Тесты `Tests/RayDeskCoreTests/{ScreenPose,Gaze,DisplayGeometry,ScreenDrag,CursorWarpPolicy,SpatialScene}Tests.swift` пишутся первыми, до реализации.
- Commit: `Core: пространственная модель экранов, взгляд, раскладка, перетаскивание, правило курсора`

### Phase 3 — Несколько экранов в приложении

- **3.1** `Sources/RayDesk/ScreenSlot.swift` (create) — `VirtualScreen` + `DisplayCapture` + номер кадра; `displayBounds: CGRect`.
- **3.2** `Sources/RayDesk/Renderer.swift` (modify) — рисует все слоты, `depth32Float` + depth state, модель из `ScreenPose.modelMatrix`, подсветка рамки: курсорный экран / захваченный экран; отдаёт `currentHead`.
- **3.3** `Sources/RayDesk/AppDelegate.swift` (modify) — слоты из `SpatialScene`, меню «Добавить экран» / «Убрать экран», раскладка через `arrangeDisplays` + `.forAppOnly` после старта, добавления, удаления и конца перетаскивания; хоткеи действуют на экран под взглядом (или последний, если взгляд мимо); сохранение `SpatialScene` в UserDefaults под ключом `screens.v2`. Режим «следовать за головой» удаляется: для нескольких экранов он неоднозначен.
  - Invariant: раскладка только через `.forAppOnly`.
- **3.4** `Sources/RayDesk/ScreenPlacement.swift` (delete).
- Commit: `App: несколько виртуальных мониторов в пространстве`

### Phase 4 — Мышь: перетаскивание и прыжок курсора

- **4.1** `Sources/RayDesk/MouseTap.swift` (create) — `CGEvent.tapCreate(.cgSessionEventTap, .headInsertEventTap, .defaultTap, mask: mouse moved/down/up/dragged (L/R/O) + scrollWheel)`; запуск на главном runloop.
  - ⌃⌥ + leftMouseDown на виртуальном экране (или экране под взглядом) → начало перетаскивания, `CGAssociateMouseAndMouseCursorPosition(0)`, событие → `nil`; dragged → `dragged(...)` по `mouseEventDeltaX/Y`, → `nil`; up → конец, ассоциация обратно, пересчёт раскладки, → `nil`.
  - ⌃⌥ + scrollWheel → `scrolled(...)` для экрана под курсором/взглядом, → `nil`.
  - mouseMoved без кнопок → `CursorWarpPolicy.warpTarget`; если есть цель — `event.location = globalPoint(uv:in:)` и `CGWarpMouseCursorPosition` как запасной путь.
  - Без Accessibility (`AXIsProcessTrustedWithOptions` с prompt) tap не создаётся, в меню строка «Перетаскивание мышью: нужно разрешение Accessibility».
  - Invariant: при перетаскивании событие не доходит до приложений; прочие события проходят без изменений.
- **4.2** `AppDelegate.swift` (modify) — `observeGaze` каждый кадр из рендера, передача состояния в `MouseTap`.
- Commit: `App: перетаскивание экранов мышью и прыжок курсора к взгляду`

### Test strategy
- Phase 1–2: `swift test`, Core покрыт тестами по пунктам 1.3, 1.4, 2.7; в Phase 2 тесты пишутся первыми и падают.
- Phase 3–4: ручная проверка в очках (uverify): два экрана видны, добавление/удаление, клик по окну на виртуальном экране, прыжок курсора, ⌃⌥-перетаскивание и скролл, откат раскладки после выхода.

### Open questions / risks / rollback
- Подмена `location` у `mouseMoved` в tap может не сдвинуть курсор — тогда `CGWarpMouseCursorPosition` + `CGAssociateMouseAndMouseCursorPosition(1)` (проверяется первым в Phase 4).
- 4 захвата 3840×2160 могут грузить GPU — тогда захват в 1×.
- Обратная совместимость: старые ключи UserDefaults не читаются, поза сбрасывается (согласовано в Design, Phase 3.3).
- Откат: ветка `interactive-movable-screen`, каждая фаза — отдельный коммит.

## Verify
<empty — filled by up:uverify>

## Conclusion
<empty — filled by up:ureview>

### Hands-off decisions
<empty — populated only when Mode is hands-off>

### Deferred (needs user input)
<empty — populated only when Mode is hands-off and a choice had no conservative default>
