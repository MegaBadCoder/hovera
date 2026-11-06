# Поддержка VITURE Luma Ultra в Hovera

**Status:** executing (PH1 сделан)
**Branch:** viture-support
**Worktree:** `.worktrees/viture-support`
**Mode:** interactive
**Goal:** Hovera выводит картинку на VITURE Luma Ultra и держит экраны в пространстве по 6DoF-позе очков: поворот головы без дрейфа курса, наклон без ухода горизонта, положение в комнате — от VIO. Очки RayNeo работают как раньше, а без установленного SDK приложение запускается и не падает.

## Context

- VITURE выпускает официальный C-SDK; macOS-пакет v2.4.2 получен через developer portal и лежит в `Vendor/viture/aarch64` (в git не попадает). Внутри `libglasses.dylib` (обёртка) и `libcarina_vio.dylib` (VIO), плюс заголовки и демо.
- Luma Ultra — `XR_DEVICE_TYPE_VITURE_CARINA`. VIO считает 6DoF на очках: поза в осях OpenGL (X вправо, Y вверх, Z назад), pitch и roll привязаны к гравитации.
- `xr_device_provider_get_gl_pose_carina(handle, pose, predict_time, status)` принимает время предсказания — можно просить позу сразу к моменту показа кадра.
- `xr_device_provider_reset_origin_carina(handle, pose)` переносит позицию и курс, не трогая pitch/roll.
- Колбэки Carina: поза с частотой камеры (25 Гц), IMU, VSync, стереокадры. Колбэки не принимают пользовательского контекста.
- В USB-дереве очки видны как IOUSBHostDevice с vendor id `0x35CA`; у Luma Ultra product id `0x1104`. Камера очков — отдельное UVC-устройство `0C45:636B`.
- Дисплей VITURE объявляется как `VITURE` (1920×1200, 120 Гц); вывод на него уже поддержан в main.
- Зависимость от SDK не должна быть жёсткой: у пользователя могут быть только RayNeo, а Hovera — единственное приложение.

## Design

Подключаем SDK через `dlopen`, а не линковкой: библиотека грузится как отдельный Swift-модуль `VitureSDK`, приложение работает и без неё, а на VITURE переключается, если нашлись очки и библиотека.

Слои:

1. `VitureSDK` — загрузчик (`dlopen`), типы функций C, обёртка устройства, перечисление USB. Ничего не знает про рендер.
2. `VitureTracker` в приложении — жизненный цикл: найти очки, создать дескриптор, включить 6DoF, инициализировать, зарегистрировать IMU-колбэк, запустить. Держит последнюю позу и умеет отдать её с предсказанием.
3. Интеграция в рендер: при активном VITURE ориентация кадра берётся из позы SDK, а не из `OrientationFilter`; калибровки наклона и компаса не применяются, потому что VIO сам держит гравитацию; `Recenter` вызывает `reset_origin_carina`.
4. Дисплей: 1920×1200@120 через `CGDisplayMode`; если режима нет — SDK-команда смены режима (в PH4, если понадобится).

Почему так: RayNeo-путь остаётся нетронутым, обе пары очков живут в одном приложении, а решение использовать SDK не оставляет нам чужого кода в сборке.

TDD: yes для `VitureSDK` (разбор позы, пути поиска, перечисление USB), живая проверка — только в очках.

### Invariants

- IV1 — Без `libglasses.dylib` приложение запускается, RayNeo-трекинг и рендер не меняются.
- IV2 — Оси позы SDK совпадают с осями мира Hovera: X вправо, Y вверх, Z назад; пересчёт не нужен.
- IV3 — 6DoF включается до `initialize`, иначе SDK игнорирует настройку.
- IV4 — `Recenter` на VITURE не меняет pitch и roll: только позиция и курс.
- IV5 — Ошибка SDK на любом шаге не роняет приложение, а отключает VITURE-трекинг с записью в лог.

### Principles

- PC1 — Пока VITURE-путь не проверен в очках, он не включается сам: нужен явный флаг или найденные очки плюс подтверждённая поза.
- PC2 — SDK-логи и ошибки пишем в наш лог, но не в консоль по умолчанию.

### Assumptions

- AS1 — Product id Luma Ultra — `0x1104`; список остальных моделей не нужен, пока поддержана одна пара.
- AS2 — Для Carina `initialize` не требует файла калибровки от нас, кеш SDK создаёт сам, если дать каталог.
- AS3 — Устройство можно открыть, пока не запущен SpaceWalker; одновременный доступ не проверен.

### Unknowns

- UK1 — Единицы и частота IMU-колбэка Carina: нужны для сглаживания и проверки предсказания.
- UK2 — Можно ли звать `get_gl_pose_carina` из рендер-потока: в демо SDK позу опрашивают из отдельного потока.
- UK3 — Что делает SDK, если очки отключить во время работы: нужен ли полный пересоздатель дескриптора.

## Plan

Approach: сначала обёртка SDK и проверки без очков, потом жизненный цикл трекера в приложении, и только затем подмена ориентации в рендере. Каждый шаг коммитится отдельно; после PH2 приложение уже умеет логировать позу, это и будет первая живая проверка.

### PH1 — Модуль VitureSDK

- 1.1 `Sources/VitureSDK/ViturePose.swift` (create) — `ViturePose`, разбор `[px, py, pz, qw, qx, qy, qz]`, обратная упаковка для `reset_origin`.
- 1.2 `Sources/VitureSDK/VitureLibrary.swift` (create) — `VitureLibrary` (dlopen, dlsym, пути поиска, `createDevice`), `VitureDevice` (жизненный цикл, 6DoF, поза с предсказанием, `resetOrigin`, колбэки), мост колбэков без контекста.
- 1.3 `Sources/VitureSDK/VitureUSB.swift` (create) — перечисление очков по vendor id `0x35CA`.
- 1.4 `Package.swift:11` (modify) — цель `VitureSDK`, зависимости для `RayDesk` и тестов.
- 1.5 `Tests/RayDeskCoreTests/VitureSDKTests.swift` (create) — разбор и упаковка позы, нормализация, пути поиска, ошибка загрузки, USB-перечисление без очков.
- Respects: IV1, IV2, IV5, AS1.
- Commit: `feat(viture): загрузчик официального SDK через dlopen`

### PH2 — Жизненный цикл VITURE-трекера

- 2.1 `Sources/VitureSDK/VitureLibrary.swift` (modify) — кэш-каталог для SDK по умолчанию (`~/Library/Caches/RayDesk/viture`).
- 2.2 `Sources/RayDesk/VitureTracker.swift` (create) — поиск очков, создание, 6DoF, инициализация, старт, опрос позы в отдельном потоке (250 Гц), `recenter`, остановка при потере устройства.
- 2.3 `Sources/RayDesk/AppDelegate.swift` (modify) — при старте: если есть очки VITURE и SDK грузится, запускать трекер и писать в лог позу раз в секунду; флаг `VITURE` в строке состояния.
- 2.4 Тесты: на `VitureTracker` — только чистая часть (парсинг позы, статус готовности); живое — в PH5.
- Respects: IV1, IV3, IV5, UK2.
- Commit: `feat(viture): жизненный цикл трекера`

### PH3 — Поза VITURE в рендере

- 3.1 `Sources/RayDesk/Renderer.swift` (modify) — источник ориентации: если VITURE активен, кадр рисуется по позе SDK с `predict_time` до момента показа, `OrientationFilter` не используется.
- 3.2 `Sources/RayDesk/AppDelegate.swift` (modify) — `Recenter` на VITURE зовёт `resetOrigin`, калибровки наклона и компаса не применяются.
- 3.3 `Sources/RayDeskCore/GlassesDisplay.swift` (modify) — если панель умеет 120 Гц, брать её для VITURE (тест на выбор режима).
- Respects: IV2, IV4, AS3.
- Commit: `feat(viture): поза SDK в рендере и режим 120 Гц`

### PH4 — Камера очков (после проверки PH2–PH3 в железе)

- 4.1 `Sources/RayDesk/VitureCamera.swift` (create) — UVC-камера `0C45:636B` через AVFoundation вместо камеры MacBook.
- 4.2 `Sources/RayDesk/AppDelegate.swift` (modify) — переключатель «Камера: очки».
- Commit: `feat(viture): камера очков для камерной опоры`

### Test strategy

- PH1: юнит-тесты (сделаны), сборка без SDK (проверяется отсутствием динамической зависимости).
- PH2–PH3: живая проверка в очках — поза в логе, дрожание/дрейф на месте, recenter не кренит горизонт, 120 Гц.
- Регрессия: полный набор тестов Hovera остаётся зелёным, RayNeo-путь не меняется.

### Order & dependencies

- PH1 блокирует PH2; PH2 блокирует PH3; PH4 — после живой проверки, отдельной задачей.
- Покрытие дизайна: IV1 — PH1/2; IV2 — PH1 (тест осей) и PH3; IV3 — PH2; IV4 — PH3; IV5 — PH2; AS1 — PH1; AS2/AS3/UK1–UK3 — живая проверка в PH2.

### Risks / rollback

- RK1 — SDK тянет за собой `libcarina_vio` через `@rpath`; в app bundle оба файла должны лежать в `Contents/Frameworks`. Откат: трекер не стартует, приложение живёт на RayNeo.
- RK2 — Очки заняты SpaceWalker; SDK вернёт ошибку. Откат: пишем в лог и оставляем RayNeo-путь.
- RK3 — Предсказание SDK и наш `present-time` считают время в разных шкалах; сверить на живой сессии, при расхождении — не передавать `predict_time`, а сглаживать самим.
- RK4 — `dlclose` в `deinit` библиотеки может быть небезопасен при активном потоке SDK; закрываем библиотеку только после `stop/shutdown` устройства.

### Interfaces

- IF1 — `VitureLibrary.load(searchPaths:)`, `createDevice(productID:)`, `VitureDevice.pose(predictTime:)`, `resetOrigin(to:)`, `registerCallbacks(...)`. Продюсер PH1, потребитель PH2/PH3.
- IF2 — `VitureTracker.pose(predictTime:) -> ViturePose?` и `recenter()`. Продюсер PH2, потребитель PH3.
- IF3 — источник ориентации в `Renderer` (замыкание, возвращающее ориентацию к моменту показа). Продюсер PH3, потребитель — рендер.

### Interface graph

- PH1 -> IF1 @ Sources/VitureSDK
- PH2 IF1 -> IF2 @ Sources/RayDesk/VitureTracker.swift
- PH3 IF2 -> @ Sources/RayDesk/Renderer.swift

## Verify

Result: passed (PH1–PH3 на уровне кода и тестов; живая проверка в очках — отложена, VITURE к машине не подключены)

- CK1 (IV1) — сборка и запуск без `libglasses.dylib`: зависимость только через `dlopen`, в `Package.swift` нет линковки с SDK; тест `missingLibraryReportsEveryPathItTried` — held.
- CK2 (IV2) — оси позы: `ViturePose` декодирует `[px,py,pz,qw,qx,qy,qz]` в `SIMD3`/`simd_quatd` без переворота, roundtrip через `floats` проверен — held.
- CK3 (IV3) — 6DoF включается в `VitureTracker.start` до `initialize` — held по коду, живая проверка статуса позы нужна.
- CK4 (IV4) — `recenterToGaze` на VITURE зовёт `resetOrigin`, калибровка сетки и `alignYawToZero` не выполняются, значит pitch/roll не трогаются — held по коду.
- CK5 (IV5) — ошибки SDK ловятся в `startVitureTracking` и пишутся в лог; `VitureTracker.start` возвращает `nil`, если очков нет — held.
- CK6 (PC1) — при отсутствии очков `externalOrientation` не ставится, рендер идёт прежним путём — held.
- CK7 — 120 Гц: выбор режима для VITURE идёт к 120, для RayNeo остаётся 60 (`refreshRateNearestToTheTargetWins`) — held.
- CK8 — полный набор тестов 318 зелёный — held.
- CK9 (UK1–UK3, AS2, AS3) — реальная частота IMU-колбэка, поведение при отключении очков, потокобезопасность `get_gl_pose` и предсказание в шкале SDK — deferred: нужны подключённые VITURE.

Smoke: `swift build --disable-sandbox` — собирается; `swift test --disable-sandbox` — 318 тестов; `dlopen` официального SDK отдаёт `GetVersionString() == 2.4.2`.

Goal: proxy only — код готов к живой проверке, но 6DoF-мир, дрожание и горизонт в очках ещё не наблюдались.

### Deviations from plan

- Позиция из 6DoF не подключена к рендеру в PH3: сначала нужно вживую сверить знаки и масштаб осей SDK с тем, что ожидает `viewMatrix`; перенесено в PH4 вместе с камерой очков.
- Колбэк IMU Carina не регистрируется: поза берётся опросом `get_gl_pose_carina` с `predict_time`, чего достаточно до живой проверки (UK1 всё равно не выяснен).

## Conclusion

Сделаны три шага из четырёх: загрузчик SDK, жизненный цикл трекера, поза в рендере и переключение панели VITURE на 120 Гц. RayNeo-путь не изменён: всё VITURE-специфичное включается только при найденных очках и загруженном SDK.

Что осталось:
- живая проверка: подключить VITURE, собрать из worktree, посмотреть `VITURE pose:` в логе, оценить дрейф/дрожание, recenter и 120 Гц;
- PH4: позиция 6DoF в рендере (после сверки знаков) и камера очков как источник камерной опоры.
