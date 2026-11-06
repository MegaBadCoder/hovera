# Поддержка VITURE Luma Ultra в Hovera

**Status:** investigating (ждём пакет SDK)
**Branch:** —
**Worktree:** —
**Mode:** interactive

## Context

- VITURE выпускает официальный C-SDK для очков: Linux, macOS (aarch64), Windows, Android. Он даёт 3DoF/6DoF-трекинг, управление дисплеем и стриминг камеры. Документация открыта: `viture.com/en-US/developer/glasses-sdk/glasses`.
- Luma Ultra — устройство семейства Carina: VIO на очках фьюзит стереокамеры с IMU и отдаёт полную 6DoF-позу через `xr_device_provider_get_gl_pose_carina()`. Поза в OpenGL-осях `[px, py, pz, qw, qx, qy, qz]`, pitch и roll привязаны к гравитации и не дрейфуют.
- У Gen1/Gen2 другой путь: `xr_device_provider_open_imu()` + `register_imu_pose_callback()`; для Carina эти функции документированы как «no effect».
- Пакет SDK раскладывается как `libglasses/include` + `libglasses/lib`, библиотека линкуется как `glasses`.
- Публичной ссылки на macOS-архив нет: на `first.viture.com` лежат только Linux-сборки, остальное выдаётся через developer portal после входа. Проверены `release-updates/sdk`, типовые имена файлов на `static.viture.dev` — 404.
- В установленном `SpaceWalker.app` лежат `libcarina_vio.dylib` и `libcarina_vio_client.dylib`. Проверено: грузятся через `dlopen`, экспортируют `carina_a1088_viture_init`, `_start`, `_get_gl_pose`, `carina_init`, `carina_start`, `carina_vio_get_gl_pose`. Это обходной путь без официального пакета, но зависит от установленного SpaceWalker и его лицензии.
- Камера Luma Ultra видна как обычная UVC-камера `0C45:636B` (в USB-дереве — «USB 2.0 Camera»). Её можно взять через AVFoundation для камерной опоры мира.
- Дисплей очков: RayNeo объявляется как `SmartGlasses` (1920×1080, режимы 60/120 Гц), VITURE в системном профиле виден как `VITURE` с 1920×1200 @120 Гц.
- Вывод на дисплей VITURE уже поддержан отдельным коммитом: семейство определяется по имени дисплея, режим выбирается без масштабирования под родное разрешение, запись экрана берёт размер дисплея.

## Что осталось выяснить

- Точное имя дисплея VITURE в `NSScreen.localizedName` (сейчас очки отключены): если это тоже `SmartGlasses`, понадобится различать семейства по USB vendor id (`0x35CA` против `0x1BBB`) или по `CGDisplayModelNumber`.
- Формат пакета SDK для macOS: имя dylib (`libglasses.dylib`?), наличие заголовков, версия, лицензия на распространение вместе с Hovera.
- Как SDK переживает повторный `start/stop` и переподключение очков: нужно для нашей логики сна и переподключения.

## Что делаем, когда будет SDK

1. Слой источника позы: RayNeo HID (сейчас) и VITURE SDK за одним интерфейсом; Hovera получает ориентацию и, если есть, положение.
2. Для Carina — 6DoF-поза напрямую в рендер, без нашего `OrientationFilter`: pitch/roll уже привязаны к гравитации, дрейфа курса нет.
3. Управление дисплеем через SDK (режим 120 Гц), если `CGDisplayMode` окажется недостаточно.
4. Камера очков как источник для камерной опоры вместо камеры MacBook.

## Что можно сделать до SDK

- Различать семейство очков не только по имени дисплея, но и по USB vendor id — чтобы `SmartGlasses` не путался между RayNeo и VITURE.
- Подготовить интерфейс источника позы на текущем RayNeo-пути так, чтобы вторая реализация встала без правок рендера.
