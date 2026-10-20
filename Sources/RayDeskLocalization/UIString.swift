/// Строка интерфейса приложения.
///
/// Оба языка лежат рядом в одном случае: расхождение и пропуск видны в диффе, а `switch` без `default`
/// не даёт добавить случай без перевода.
public enum UIString: CaseIterable {
    case statusStarting
    case statusError
    case statusLine
    case statusGyroBias
    case statusCompassOff
    case statusCompassError
    case statusFieldChanged
    case statusDiagnostics
    case mouseTapChecking
    case mouseTapNeedsAccessibility
    case mouseTapRunning

    case menuScreens
    case menuFocusZoom
    case menuSwapScreen
    case saySelectFocusPoint
    case menuPlaceHere
    case menuGrab
    case menuMoveMode
    case menuMacScreenOff
    case menuPrimaryScreen
    case menuCloser
    case menuFarther
    case menuBigger
    case menuSmaller
    case menuTiltBack
    case menuTiltForward
    case menuTurnLeft
    case menuTurnRight
    case menuTiltAllBack
    case menuTiltAllForward
    case menuGatherScreens
    case menuArrangeInArc
    case menuJoin
    case menuJoinHinge
    case menuJoinGaze
    case menuAddScreen
    case menuRemoveScreen
    case menuCursorToGaze
    case menuWindowToGaze

    case menuCentreHeading
    case menuRecentreWorld
    case menuMarkReference
    case menuCompass
    case menuCalibrateCompass
    case menuCalibrateGyroScale
    case menuRecalibrateGyro

    case menuCamera
    case menuGlassesTracking
    case menuWallMode
    case menuCameraCalibration
    case menuLearnGlassesShape
    case menuGlassesOutline
    case menuFirmwareZeroRestore
    case menuCameraFieldOfView
    case menuWallDepth
    case menuEyeArc
    case menuCameraDebugWindow

    case menuPicture
    case menuTogglePicture
    case menuScreenBorders
    case menuFieldOfView
    case menuFieldOfViewWider
    case menuFieldOfViewNarrower
    case menuMorePrediction
    case menuLessPrediction
    case menuStabilization
    case menuStabilizationOff
    case menuStabilizationWeak
    case menuStabilizationMedium
    case menuStabilizationStrong
    case menuHorizonGrid
    case menuGridManual
    case menuRecordGlassesVideo

    case menuMeditation
    case menuMeditationToggle
    case menuBreathing
    case menuNeuralEffect
    case menuNeuralEffectOff
    case menuNeuralEffectLow
    case menuNeuralEffectMedium
    case menuNeuralEffectHigh

    case menuSettings
    case menuQuit

    case alertGlassesMissing
    case alertMetalFailed
    case alertScreenRecording
    case alertCaptureFailed
    case alertMouseTapFailed
    case alertCompassCalibrationFailed
    case alertGlassesRecordingFailed
    case settingGrid
    case settingCompass
    case settingReset
    case settingNotSaved

    case sayGlassesCold
    case sayGyroScaleStart
    case sayGyroScaleTimeout
    case sayGyroZeroMeasured
    case sayGyroScaleDone
    case sayGyroNotUpright
    case sayGyroWrongTurnCount
    case signalCompassStart
    case signalCompassFieldChanged
    case signalCompassDone
    case signalCompassTooFewSamples
    case signalCompassTooFlat
    case signalCompassNoisy
    case sayCalibrationDone
    case sayCameraUnavailableSystem
    case sayCameraUnavailablePrivacy
    case sayCameraAngleChanged
    case sayWallModeGlasses
    case sayWallModeFace
    case sayGlassesShapeLearned
    case sayGlassesShapeFailed
    case sayGlassesLearning
    case sayWindowTarget
    case sayWindowNoAccessibility
    case sayWindowNoFrontWindow
    case sayWindowNotMovable
    case sayMeditationAudioFailed

    case calibrationWindowTitle
    case calibrationTitleInitial
    case calibrationHintInitial
    case calibrationApply
    case calibrationCancel
    case calibrationRetry
    case calibrationPreviewLabel
    case calibrationSteadinessLabel
    case calibrationCameraSettingsChanged
    case calibrationTitleSitStill
    case calibrationTitleTurnLeft
    case calibrationTitleReturnToCentre
    case calibrationTitleTurnRight
    case calibrationTitleReturnToStart
    case calibrationTitleReady
    case calibrationTitleTryAgain
    case calibrationStepCentre
    case calibrationStepTurnLeft
    case calibrationStepCheckCentre
    case calibrationStepTurnRight
    case calibrationStepCheckReturn
    case calibrationStepCheckPassed
    case calibrationStepNotApplied
    case calibrationLookAndHold
    case calibrationCentreRemembered

    case hintFaceInsideOutline
    case hintRefreshBeforeApply
    case hintReferenceStale
    case hintNoCameraFrames
    case hintFaceNotRecognised
    case hintFaceCropped
    case hintMoveCloser
    case hintHoldHeadStraight
    case hintLookStraightAndCentre
    case hintTurnLeftFifteen
    case hintTurnRightFifteen
    case hintReturnToStart
    case hintFreezeForSecond
    case hintHoldRemembering
    case hintHoldPosition
    case hintCentreRememberedApply
    case hintShiftOnReturn
    case hintSensorMismatch
    case hintEstimatesDiverged
    case hintHeadingMismatch
    case hintHeadingMatched

    case cameraDebugTitle
    case cameraDebugReadings
    case cameraDebugVerdictLearning
    case cameraDebugVerdictTurned
    case cameraDebugVerdictTilted
    case cameraDebugVerdictFast
    case cameraDebugCalibrated
    case glassesOutlineTitle
    case glassesOutlineStep
    case glassesOutlineHintLive
    case glassesOutlineHintFrozen
    case glassesOutlineHintApplied
    case glassesOutlineHintEmpty
    case glassesOutlineFreeze
    case glassesOutlineResume
    case glassesOutlineUndo
    case glassesOutlineApply
    case glassesOutlineClear
    case glassesOutlineStatus
    case glassesOutlinePenOn
    case glassesOutlinePenOff
    case glassesOutlineLegend
    case glassesOutlineNeedsLearning
    case cameraNoteNoFace
    case cameraNoteShapeNotLearned
    case cameraNoteLearningShape
    case cameraNoteGlassesFound
    case cameraNoteGlassesNotFound
    case cameraNoteAxesLinked
    case cameraNoteAxesLearning
    case cameraNoteRotation
    case cameraLogGlasses
    case cameraLogNoFace
    case cameraLogNeck
    case cameraLogHead
    case rotationSourceFace
    case rotationSourceGyroAndFace
    case rotationSourceGyro

    /// Текст строки на заданном языке.
    ///
    /// Подстановки (`%@`, `%d`, `%.0f`) идут в одном порядке в обоих языках, чтобы вызов
    /// `String(format:)` не зависел от выбранного языка.
    public func text(_ language: AppLanguage) -> String {
        switch language {
        case .ru: russian
        case .en: english
        }
    }

    private var russian: String {
        switch self {
        case .statusStarting: "Запуск…"
        case .statusError: "Ошибка — см. окно"
        case .statusLine: "IMU %@ %d Гц · взгляд %.0f° / %.0f° · экранов %d · FOV %.1f° · компас %@ · %.0f°"
        case .statusGyroBias: "ноль %.3f %.3f %.3f °/с"
        case .statusCompassOff: " · компас выкл"
        case .statusCompassError: " · компас расходится %.1f°"
        case .statusFieldChanged: " · поле изменилось"
        case .statusDiagnostics: " · %@ · %.1f °C · предсказание %.0f мс · пересчётов нуля прошивкой отменено %d"
        case .mouseTapChecking: "Перетаскивание мышью: проверка разрешений…"
        case .mouseTapNeedsAccessibility: "Перетаскивание мышью: нужно разрешение «Универсальный доступ»"
        case .mouseTapRunning: "⌃⌥ + тащить — двигать экран, ⌃⌥ + скролл — ближе/дальше"

        case .menuScreens: "Экраны"
        case .menuFocusZoom: "Увеличить точку / вернуть раскладку   ⌃⌥Z"
        case .menuSwapScreen: "Выбрать экран / обменять взглядом   ⌃⌥S"
        case .saySelectFocusPoint: "Кликните точку на виртуальном экране для увеличения. Control Option Z — отмена."
        case .menuPlaceHere: "Взять экран по центру / поставить по взгляду   ⌃⌥Space"
        case .menuGrab: "Взять / отпустить экран   ⌃⌥G"
        case .menuMoveMode: "Режим перемещения: стрелки двигают экран   ⌃⌥⇧M"
        case .menuMacScreenOff: "Погасить MacBook и убрать туда курсор   ⌃⌥⇧B"
        case .menuPrimaryScreen: "Главный экран — под взглядом, повтор — MacBook   ⌃⌥⇧P"
        case .menuCloser: "Ближе   ⌃⌥↑"
        case .menuFarther: "Дальше   ⌃⌥↓"
        case .menuBigger: "Больше   ⌃⌥="
        case .menuSmaller: "Меньше   ⌃⌥−"
        case .menuTiltBack: "Наклонить назад   ⌃⌥⇧↑"
        case .menuTiltForward: "Наклонить вперёд   ⌃⌥⇧↓"
        case .menuTurnLeft: "Довернуть экран влево   ⌃⌥⇧←"
        case .menuTurnRight: "Довернуть экран вправо   ⌃⌥⇧→"
        case .menuTiltAllBack: "Наклонить все назад   ⌃⌥⌘↑"
        case .menuTiltAllForward: "Наклонить все вперёд   ⌃⌥⌘↓"
        case .menuGatherScreens: "Собрать экраны перед собой   ⌃⌥⇧G"
        case .menuArrangeInArc: "Собрать дугой, край к краю   ⌃⌥A"
        case .menuJoin: "Стыковка экранов"
        case .menuJoinHinge: "Как тройной монитор: вертикально, стык по всей длине"
        case .menuJoinGaze: "По взгляду: каждый экран смотрит на вас"
        case .menuAddScreen: "Добавить экран"
        case .menuRemoveScreen: "Убрать экран"
        case .menuCursorToGaze: "Курсор — туда, куда смотрю   ⌃⌥J"
        case .menuWindowToGaze: "Окно — туда, куда смотрю   ⌃⌥W"

        case .menuCentreHeading: "Центр и курс"
        case .menuRecentreWorld: "«Вперёд» = куда смотрю   ⌃⌥R"
        case .menuMarkReference: "Метка: смотрю на средний экран (только в лог)   ⌃⌥M"
        case .menuCompass: "Компас"
        case .menuCalibrateCompass: "Калибровка компаса   ⌃⌥K"
        case .menuCalibrateGyroScale: "Калибровка масштаба гироскопа (очки на столе)"
        case .menuRecalibrateGyro: "Перекалибровать гироскоп"

        case .menuCamera: "Камера"
        case .menuGlassesTracking: "Положение головы по очкам (MediaPipe)"
        case .menuWallMode: "Удержание центра камерой"
        case .menuCameraCalibration: "Калибровка камерой с подсказками…   ⌃⌥⇧K"
        case .menuLearnGlassesShape: "Выучить форму очков (старт/стоп)"
        case .menuGlassesOutline: "Обвести очки на кадре"
        case .menuFirmwareZeroRestore: "Отменять пересчёты нуля гироскопа прошивкой"
        case .menuCameraFieldOfView: "Угол обзора камеры (масштаб вперёд-назад)"
        case .menuWallDepth: "Сила вперёд-назад"
        case .menuEyeArc: "Дуга глаз при повороте"
        case .menuCameraDebugWindow: "Окно отладки (рамка и точки лица)"

        case .menuPicture: "Картинка"
        case .menuTogglePicture: "Скрыть / показать картинку   ⌃⌥H"
        case .menuScreenBorders: "Рамка вокруг экранов"
        case .menuFieldOfView: "Угол обзора"
        case .menuFieldOfViewWider: "Угол обзора больше   ⌃⌥]"
        case .menuFieldOfViewNarrower: "Угол обзора меньше   ⌃⌥["
        case .menuMorePrediction: "Предсказание больше   ⌃⌥0"
        case .menuLessPrediction: "Предсказание меньше   ⌃⌥9"
        case .menuStabilization: "Стабилизация картинки"
        case .menuStabilizationOff: "Выключена"
        case .menuStabilizationWeak: "Слабая"
        case .menuStabilizationMedium: "Средняя"
        case .menuStabilizationStrong: "Сильная"
        case .menuHorizonGrid: "Сетка горизонта   ⌃⌥D"
        case .menuGridManual: "Настроить сетку вручную   ⌃⌥C (стрелки, ⌃⌥, ⌃⌥.)"
        case .menuRecordGlassesVideo: "Записать видео очков (старт/стоп)   ⌃⌥V"

        case .menuMeditation: "Медитация"
        case .menuMeditationToggle: "Включить / выключить   ⌃⌥⇧Z"
        case .menuBreathing: "Дыхание (вдох 4 с, выдох 6 с)"
        case .menuNeuralEffect: "Нейроэффект"
        case .menuNeuralEffectOff: "Выключен"
        case .menuNeuralEffectLow: "Слабый"
        case .menuNeuralEffectMedium: "Средний"
        case .menuNeuralEffectHigh: "Сильный"

        case .menuSettings: "Настройки"
        case .menuQuit: "Выйти   ⌃⌥Q"

        case .alertGlassesMissing: "Очки не найдены среди дисплеев. Подключите RayNeo и перезапустите."
        case .alertMetalFailed: "Не удалось запустить Metal: %@"
        case .alertScreenRecording: "Нужно разрешение на запись экрана.\n\nСистемные настройки → Конфиденциальность и безопасность → Запись экрана и системного звука → включите RayDesk, затем перезапустите RayDesk.\n\nПока в очках будет серый прямоугольник вместо экрана."
        case .alertCaptureFailed: "Захват экрана %d не запустился: %@"
        case .alertMouseTapFailed: "Не удалось создать перехватчик событий мыши (CGEvent.tapCreate вернул nil)."
        case .alertCompassCalibrationFailed: "Калибровка компаса: %@"
        case .alertGlassesRecordingFailed: "Запись видео очков: %@"
        case .settingGrid: "Настройка сетки"
        case .settingCompass: "Калибровка компаса"
        case .settingReset: "%@ сброшена, настройте заново."
        case .settingNotSaved: "Не удалось сохранить настройку."

        case .sayGlassesCold: "Очки холодные: %.0f°. Масштаб гироскопа зависит от прогрева — наденьте их на пару минут, я запущу калибровку сама, когда будет %.0f°."
        case .sayGyroScaleStart: "Очки прогреты до %.0f°. Калибровка масштаба гироскопа: поставьте очки на стол как на голове, дужками вниз, прижмите дужку к краю ноутбука и не трогайте."
        case .sayGyroScaleTimeout: "Калибровка гироскопа прервана: время вышло."
        case .sayGyroZeroMeasured: "Ноль измерен. Медленно поверните очки на два полных оборота и прижмите дужку к тому же краю. Потом не трогайте."
        case .sayGyroScaleDone: "Готово при %.0f°. Гироскоп ошибался на %.1f процента, поправка сохранена. Дальше: откалибруйте компас и проверьте уход меткой."
        case .sayGyroNotUpright: "Не получилось: очки лежат не так, как на голове. Поставьте их на дужки и начните заново."
        case .sayGyroWrongTurnCount: "Не получилось: насчитал не два оборота. Начните заново."
        case .signalCompassStart: "Калибровка компаса. Двадцать пять секунд медленно поворачивайте голову во все стороны: влево, вправо, вверх, вниз и к плечам."
        case .signalCompassFieldChanged: "Магнитное поле у очков изменилось, например от наушников. Чтобы экраны держались точнее, откалибруйте компас: Control Option K."
        case .signalCompassDone: "Компас откалиброван."
        case .signalCompassTooFewSamples: "Не получилось: от очков пришло мало данных компаса. Попробуйте ещё раз."
        case .signalCompassTooFlat: "Не получилось: мало поворотов. Повторите и крутите головой шире, особенно наклоны к плечам."
        case .signalCompassNoisy: "Не получилось: поле сильно искажено. Отодвиньтесь от магнитов и колонок и повторите."
        case .sayCalibrationDone: "Калибровка готова."
        case .sayCameraUnavailableSystem: "Камера недоступна. Разрешите доступ к камере в настройках macOS."
        case .sayCameraUnavailablePrivacy: "Камера недоступна. Разрешите RayDesk доступ к камере в настройках конфиденциальности."
        case .sayCameraAngleChanged: "Угол камеры изменён. Посмотрите в камеру и посидите спокойно, я заново запомню положение головы."
        case .sayWallModeGlasses: "Калибровка камерой включена. Посмотрите в камеру и посидите спокойно две секунды, я запомню положение головы."
        case .sayWallModeFace: "Удержание центра по лицу включено. Посмотрите на камеру и задержитесь на секунду. Для ручного выравнивания используйте R."
        case .sayGlassesShapeLearned: "Форма очков запомнена."
        case .sayGlassesShapeFailed: "Форма очков не набралась. Проверьте, что лицо видно в камеру, и попробуйте ещё раз."
        case .sayGlassesLearning: "Смотрите в камеру ноутбука и секунд двадцать медленно крутите головой влево, вправо, вверх и вниз. Руки держите подальше от лица. Потом выберите этот пункт ещё раз."
        case .sayWindowTarget: "Посмотрите на экран, куда перенести окно."
        case .sayWindowNoAccessibility: "Нужно разрешение «Универсальный доступ» для RayDesk."
        case .sayWindowNoFrontWindow: "Нет активного окна."
        case .sayWindowNotMovable: "Это окно не переносится."
        case .sayMeditationAudioFailed: "Не удалось включить звук медитации."

        case .calibrationWindowTitle: "Калибровка камерой"
        case .calibrationTitleInitial: "Расположитесь перед камерой"
        case .calibrationHintInitial: "Посмотрите прямо в камеру ноутбука"
        case .calibrationApply: "Применить"
        case .calibrationCancel: "Отмена"
        case .calibrationRetry: "Начать заново"
        case .calibrationPreviewLabel: "Превью камеры с контуром головы и очков"
        case .calibrationSteadinessLabel: "Устойчивость положения"
        case .calibrationCameraSettingsChanged: "Настройки камеры изменились. Нажмите «Начать заново»"
        case .calibrationTitleSitStill: "Расположитесь и замрите"
        case .calibrationTitleTurnLeft: "Поверните голову влево"
        case .calibrationTitleReturnToCentre: "Вернитесь в центр"
        case .calibrationTitleTurnRight: "Поверните голову вправо"
        case .calibrationTitleReturnToStart: "Вернитесь в исходное положение"
        case .calibrationTitleReady: "Калибровка готова"
        case .calibrationTitleTryAgain: "Попробуем ещё раз"
        case .calibrationStepCentre: "Настройка центра"
        case .calibrationStepTurnLeft: "2 / 5 · Поворот влево"
        case .calibrationStepCheckCentre: "3 / 5 · Проверка центра"
        case .calibrationStepTurnRight: "4 / 5 · Поворот вправо"
        case .calibrationStepCheckReturn: "5 / 5 · Проверка возврата"
        case .calibrationStepCheckPassed: "5 / 5 · Проверка пройдена"
        case .calibrationStepNotApplied: "Калибровка не применена"
        case .calibrationLookAndHold: "Посмотрите в камеру и замрите на секунду"
        case .calibrationCentreRemembered: "Центр запомнен"

        case .hintFaceInsideOutline: "Расположите лицо внутри контура и посмотрите в камеру"
        case .hintRefreshBeforeApply: "Посмотрите в камеру — обновим положение перед применением"
        case .hintReferenceStale: "Опора устарела. Вернитесь в центр — заново запомним положение"
        case .hintNoCameraFrames: "Кадры камеры не поступают. Проверьте камеру"
        case .hintFaceNotRecognised: "Лицо не распознано уверенно. Посмотрите в камеру"
        case .hintFaceCropped: "Лицо обрезано. Расположитесь ближе к центру кадра"
        case .hintMoveCloser: "Приблизьтесь немного к камере"
        case .hintHoldHeadStraight: "Держите голову ровнее"
        case .hintLookStraightAndCentre: "Посмотрите прямо в камеру и расположитесь по центру"
        case .hintTurnLeftFifteen: "Медленно поверните голову влево примерно на 15°"
        case .hintTurnRightFifteen: "Теперь медленно поверните голову вправо примерно на 15°"
        case .hintReturnToStart: "Вернитесь в исходное положение и посмотрите в камеру"
        case .hintFreezeForSecond: "Замрите на секунду"
        case .hintHoldRemembering: "Хорошо. Не двигайтесь — запоминаю положение"
        case .hintHoldPosition: "Хорошо. Удерживайте положение"
        case .hintCentreRememberedApply: "Центр запомнен. Нажмите «Применить» — поворачивать голову не нужно"
        case .hintShiftOnReturn: "При возврате обнаружено смещение. Снова посмотрите в центр"
        case .hintSensorMismatch: "Камера и датчик не согласовали поворот. Повторите калибровку"
        case .hintEstimatesDiverged: "Оценки камеры и датчика разошлись. Повторите калибровку"
        case .hintHeadingMismatch: "Направление после возврата не совпало. Повторите калибровку"
        case .hintHeadingMatched: "Направление после поворотов совпало. Можно применить калибровку"

        case .cameraDebugTitle: "RayDesk — камера"
        case .cameraDebugReadings: " шея: x %+.1f  y %+.1f  z %+.1f см\n от камеры: поворот %+.0f°  наклон %+.0f°  рамка %.3f%@"
        case .cameraDebugVerdictLearning: "  · смотрите в камеру, запоминаю"
        case .cameraDebugVerdictTurned: "  · голова отвёрнута от камеры"
        case .cameraDebugVerdictTilted: "  · голова сильно наклонена"
        case .cameraDebugVerdictFast: "  · быстрый поворот"
        case .cameraDebugCalibrated: " · калибровка камерой"
        case .glassesOutlineTitle: "Обведите очки на кадре камеры"
        case .glassesOutlineStep: "Меню → Камера → «Выучить форму очков» включает обучение, «Обвести очки» открывает это окно"
        case .glassesOutlineHintLive: "Нажмите «Заморозить кадр», чтобы кадр перестал двигаться: так контур ляжет точнее. Клик — точка контура, правый клик — убрать последнюю"
        case .glassesOutlineNeedsLearning: "Сначала включите «Выучить форму очков» в том же меню: обводка идёт в форму, пока обучение включено"
        case .glassesOutlineHintFrozen: "Обведите оправу по кругу: клик — точка, правый клик — убрать последнюю. Готово — «Применить обводку», дальше «Дальше» и поверните голову"
        case .glassesOutlineHintApplied: "Обводка принята: точек формы %d. Нажмите «Дальше», поверните голову и обведите очки ещё раз — с двух-трёх ракурсов форма ложится точнее"
        case .glassesOutlineHintEmpty: "Лицо в кадре не найдено: смотрите в камеру и наденьте очки"
        case .glassesOutlineFreeze: "Заморозить кадр"
        case .glassesOutlineResume: "Дальше"
        case .glassesOutlineUndo: "Убрать точку"
        case .glassesOutlineApply: "Применить обводку"
        case .glassesOutlineClear: "Сбросить форму"
        case .glassesOutlineStatus: "кадров в форме %d · точек формы %d"
        case .glassesOutlinePenOn: "Перо: рисую контур"
        case .glassesOutlinePenOff: "Перо: правлю клетки"
        case .glassesOutlineLegend: "Клетки формы: голубые — очки, синие — из обводки, серые — ещё не размечены. Клик по клетке считает её очками, клик с Shift — кожей"
        case .cameraNoteNoFace: "лицо не найдено"
        case .cameraNoteShapeNotLearned: "форма очков не выучена: меню → «Выучить форму очков»"
        case .cameraNoteLearningShape: "учу форму очков: кадров %d"
        case .cameraNoteGlassesFound: "очки найдены, совпадение формы %.0f%%"
        case .cameraNoteGlassesNotFound: "очки не найдены"
        case .cameraNoteAxesLinked: "оси гироскопа и камеры связаны"
        case .cameraNoteAxesLearning: "оси гироскопа и камеры учатся: покрутите головой влево-вправо и вверх-вниз"
        case .cameraNoteRotation: "%@ · поворот: %@ · %@"
        case .cameraLogGlasses: "CAMERA по очкам: найдены в %d из %d кадров/с, с лицом %d · совпадение формы %.0f%% · курс по камере: расхождение %.1f°, доворот %.2f°, уплывание гироскопа %.2f°/с, масштаб курса камеры %.2f · возраст замера %.2f с"
        case .cameraLogNoFace: "CAMERA лицо не найдено · кадров %d/с"
        case .cameraLogNeck: "CAMERA шея сдвинута x %.1f y %.1f z %.1f см · задержка кадра %.0f мс%@"
        case .cameraLogHead: "CAMERA голова x %.1f y %.1f z %.1f см · дрожь %.1f %.1f %.1f мм · кадров %d/с, с лицом %d"
        case .rotationSourceFace: "лицо"
        case .rotationSourceGyroAndFace: "гироскоп + лицо"
        case .rotationSourceGyro: "гироскоп"
        }
    }

    private var english: String {
        switch self {
        case .statusStarting: "Starting…"
        case .statusError: "Error — see the window"
        case .statusLine: "IMU %@ %d Hz · gaze %.0f° / %.0f° · screens %d · FOV %.1f° · compass %@ · %.0f°"
        case .statusGyroBias: "zero %.3f %.3f %.3f °/s"
        case .statusCompassOff: " · compass off"
        case .statusCompassError: " · compass off by %.1f°"
        case .statusFieldChanged: " · field changed"
        case .statusDiagnostics: " · %@ · %.1f °C · prediction %.0f ms · firmware zero resets cancelled %d"
        case .mouseTapChecking: "Mouse dragging: checking permissions…"
        case .mouseTapNeedsAccessibility: "Mouse dragging: Accessibility permission required"
        case .mouseTapRunning: "⌃⌥ + drag — move a screen, ⌃⌥ + scroll — closer / further"

        case .menuScreens: "Screens"
        case .menuFocusZoom: "Zoom into a point / restore layout   ⌃⌥Z"
        case .menuSwapScreen: "Select screen / swap by gaze   ⌃⌥S"
        case .saySelectFocusPoint: "Click a point on a virtual screen to zoom in. Control Option Z cancels."
        case .menuPlaceHere: "Pick a screen at the centre / place it by gaze   ⌃⌥Space"
        case .menuGrab: "Grab / release a screen   ⌃⌥G"
        case .menuMoveMode: "Move mode: arrows move the screen   ⌃⌥⇧M"
        case .menuMacScreenOff: "Blank the MacBook and keep the cursor out   ⌃⌥⇧B"
        case .menuPrimaryScreen: "Primary screen — where I look, press again for the MacBook   ⌃⌥⇧P"
        case .menuCloser: "Closer   ⌃⌥↑"
        case .menuFarther: "Further   ⌃⌥↓"
        case .menuBigger: "Bigger   ⌃⌥="
        case .menuSmaller: "Smaller   ⌃⌥−"
        case .menuTiltBack: "Tilt back   ⌃⌥⇧↑"
        case .menuTiltForward: "Tilt forward   ⌃⌥⇧↓"
        case .menuTurnLeft: "Turn the screen left   ⌃⌥⇧←"
        case .menuTurnRight: "Turn the screen right   ⌃⌥⇧→"
        case .menuTiltAllBack: "Tilt all back   ⌃⌥⌘↑"
        case .menuTiltAllForward: "Tilt all forward   ⌃⌥⌘↓"
        case .menuGatherScreens: "Gather the screens in front of me   ⌃⌥⇧G"
        case .menuArrangeInArc: "Arrange in an arc, edge to edge   ⌃⌥A"
        case .menuJoin: "Screen joining"
        case .menuJoinHinge: "Like a triple monitor: upright, joined along the whole edge"
        case .menuJoinGaze: "By gaze: each screen faces you"
        case .menuAddScreen: "Add a screen"
        case .menuRemoveScreen: "Remove a screen"
        case .menuCursorToGaze: "Cursor to where I look   ⌃⌥J"
        case .menuWindowToGaze: "Window to where I look   ⌃⌥W"

        case .menuCentreHeading: "Centre and heading"
        case .menuRecentreWorld: "\"Forward\" = where I look   ⌃⌥R"
        case .menuMarkReference: "Mark: looking at the middle screen (log only)   ⌃⌥M"
        case .menuCompass: "Compass"
        case .menuCalibrateCompass: "Calibrate the compass   ⌃⌥K"
        case .menuCalibrateGyroScale: "Calibrate the gyroscope scale (glasses on the table)"
        case .menuRecalibrateGyro: "Recalibrate the gyroscope"

        case .menuCamera: "Camera"
        case .menuGlassesTracking: "Head position from the glasses (MediaPipe)"
        case .menuWallMode: "Hold the centre with the camera"
        case .menuCameraCalibration: "Guided camera calibration…   ⌃⌥⇧K"
        case .menuLearnGlassesShape: "Learn the glasses shape (start/stop)"
        case .menuGlassesOutline: "Trace the glasses in a frame"
        case .menuFirmwareZeroRestore: "Undo the firmware's gyroscope zero resets"
        case .menuCameraFieldOfView: "Camera field of view (forward/backward scale)"
        case .menuWallDepth: "Forward/backward strength"
        case .menuEyeArc: "Eye arc when turning"
        case .menuCameraDebugWindow: "Debug window (box and face points)"

        case .menuPicture: "Picture"
        case .menuTogglePicture: "Hide / show the picture   ⌃⌥H"
        case .menuScreenBorders: "Border around the screens"
        case .menuFieldOfView: "Field of view"
        case .menuFieldOfViewWider: "Field of view wider   ⌃⌥]"
        case .menuFieldOfViewNarrower: "Field of view narrower   ⌃⌥["
        case .menuMorePrediction: "More prediction   ⌃⌥0"
        case .menuLessPrediction: "Less prediction   ⌃⌥9"
        case .menuStabilization: "Picture stabilisation"
        case .menuStabilizationOff: "Off"
        case .menuStabilizationWeak: "Weak"
        case .menuStabilizationMedium: "Medium"
        case .menuStabilizationStrong: "Strong"
        case .menuHorizonGrid: "Horizon grid   ⌃⌥D"
        case .menuGridManual: "Adjust the grid manually   ⌃⌥C (arrows, ⌃⌥, ⌃⌥.)"
        case .menuRecordGlassesVideo: "Record glasses video (start/stop)   ⌃⌥V"

        case .menuMeditation: "Meditation"
        case .menuMeditationToggle: "Turn on / off   ⌃⌥⇧Z"
        case .menuBreathing: "Breathing (inhale 4 s, exhale 6 s)"
        case .menuNeuralEffect: "Neural effect"
        case .menuNeuralEffectOff: "Off"
        case .menuNeuralEffectLow: "Low"
        case .menuNeuralEffectMedium: "Medium"
        case .menuNeuralEffectHigh: "High"

        case .menuSettings: "Settings"
        case .menuQuit: "Quit   ⌃⌥Q"

        case .alertGlassesMissing: "No glasses found among the displays. Connect RayNeo and restart."
        case .alertMetalFailed: "Could not start Metal: %@"
        case .alertScreenRecording: "Screen Recording permission is required.\n\nSystem Settings → Privacy & Security → Screen & System Audio Recording → turn on RayDesk, then restart RayDesk.\n\nUntil then the glasses show a grey rectangle instead of the screen."
        case .alertCaptureFailed: "Screen %d capture did not start: %@"
        case .alertMouseTapFailed: "Could not create the mouse event tap (CGEvent.tapCreate returned nil)."
        case .alertCompassCalibrationFailed: "Compass calibration: %@"
        case .alertGlassesRecordingFailed: "Glasses video recording: %@"
        case .settingGrid: "Grid calibration"
        case .settingCompass: "Compass calibration"
        case .settingReset: "%@ was reset, set it up again."
        case .settingNotSaved: "Could not save the setting."

        case .sayGlassesCold: "The glasses are cold: %.0f°. The gyroscope scale depends on warm-up — put them on for a couple of minutes, and I will start the calibration myself once they reach %.0f°."
        case .sayGyroScaleStart: "The glasses are warm at %.0f°. Gyroscope scale calibration: put the glasses on the table the way they sit on your head, temples down, press a temple against the edge of the laptop and keep still."
        case .sayGyroScaleTimeout: "Gyroscope calibration interrupted: time is up."
        case .sayGyroZeroMeasured: "Zero measured. Slowly turn the glasses two full revolutions, keeping the temple against the same edge. Then keep still."
        case .sayGyroScaleDone: "Done at %.0f°. The gyroscope was off by %.1f percent, the correction is saved. Next: calibrate the compass and check the drift with a mark."
        case .sayGyroNotUpright: "That did not work: the glasses are not lying the way they sit on your head. Stand them on the temples and start again."
        case .sayGyroWrongTurnCount: "That did not work: I counted more or fewer than two revolutions. Start again."
        case .signalCompassStart: "Compass calibration. For twenty-five seconds, slowly turn your head in every direction: left, right, up, down and towards your shoulders."
        case .signalCompassFieldChanged: "The magnetic field around the glasses has changed, for example because of headphones. For steadier screens, calibrate the compass: Control Option K."
        case .signalCompassDone: "The compass is calibrated."
        case .signalCompassTooFewSamples: "That did not work: too little compass data came from the glasses. Try again."
        case .signalCompassTooFlat: "That did not work: too few turns. Repeat and turn your head wider, especially towards your shoulders."
        case .signalCompassNoisy: "That did not work: the field is badly distorted. Move away from magnets and speakers and try again."
        case .sayCalibrationDone: "Calibration is done."
        case .sayCameraUnavailableSystem: "The camera is unavailable. Allow camera access in the macOS settings."
        case .sayCameraUnavailablePrivacy: "The camera is unavailable. Allow RayDesk camera access in the privacy settings."
        case .sayCameraAngleChanged: "The camera angle has changed. Look at the camera and sit still; I will remember the head position again."
        case .sayWallModeGlasses: "Camera calibration is on. Look at the camera and sit still for two seconds; I will remember the head position."
        case .sayWallModeFace: "Face-based centring is on. Look at the camera and hold for a second. For manual alignment use R."
        case .sayGlassesShapeLearned: "The glasses shape is remembered."
        case .sayGlassesShapeFailed: "The glasses shape was not captured. Check that your face is visible to the camera and try again."
        case .sayGlassesLearning: "Look at the laptop camera and slowly turn your head left, right, up and down for about twenty seconds. Keep your hands away from your face. Then choose this item again."
        case .sayWindowTarget: "Look at the screen you want to move the window to."
        case .sayWindowNoAccessibility: "RayDesk needs the Accessibility permission."
        case .sayWindowNoFrontWindow: "There is no active window."
        case .sayWindowNotMovable: "This window cannot be moved."
        case .sayMeditationAudioFailed: "Could not start the meditation audio."

        case .calibrationWindowTitle: "Camera calibration"
        case .calibrationTitleInitial: "Sit in front of the camera"
        case .calibrationHintInitial: "Look straight at the laptop camera"
        case .calibrationApply: "Apply"
        case .calibrationCancel: "Cancel"
        case .calibrationRetry: "Start over"
        case .calibrationPreviewLabel: "Camera preview with the head and glasses outline"
        case .calibrationSteadinessLabel: "Position steadiness"
        case .calibrationCameraSettingsChanged: "The camera settings have changed. Press \"Start over\""
        case .calibrationTitleSitStill: "Sit still"
        case .calibrationTitleTurnLeft: "Turn your head left"
        case .calibrationTitleReturnToCentre: "Return to the centre"
        case .calibrationTitleTurnRight: "Turn your head right"
        case .calibrationTitleReturnToStart: "Return to the starting position"
        case .calibrationTitleReady: "Calibration is ready"
        case .calibrationTitleTryAgain: "Let us try again"
        case .calibrationStepCentre: "Centring"
        case .calibrationStepTurnLeft: "2 / 5 · Turn left"
        case .calibrationStepCheckCentre: "3 / 5 · Centre check"
        case .calibrationStepTurnRight: "4 / 5 · Turn right"
        case .calibrationStepCheckReturn: "5 / 5 · Return check"
        case .calibrationStepCheckPassed: "5 / 5 · Check passed"
        case .calibrationStepNotApplied: "Calibration not applied"
        case .calibrationLookAndHold: "Look at the camera and hold still for a second"
        case .calibrationCentreRemembered: "Centre remembered"

        case .hintFaceInsideOutline: "Put your face inside the outline and look at the camera"
        case .hintRefreshBeforeApply: "Look at the camera — the position will be refreshed before applying"
        case .hintReferenceStale: "The reference is stale. Return to the centre — the position will be remembered again"
        case .hintNoCameraFrames: "No camera frames are arriving. Check the camera"
        case .hintFaceNotRecognised: "The face is not recognised with confidence. Look at the camera"
        case .hintFaceCropped: "The face is cropped. Move closer to the centre of the frame"
        case .hintMoveCloser: "Move a little closer to the camera"
        case .hintHoldHeadStraight: "Hold your head straighter"
        case .hintLookStraightAndCentre: "Look straight at the camera and centre yourself"
        case .hintTurnLeftFifteen: "Slowly turn your head left by about 15°"
        case .hintTurnRightFifteen: "Now slowly turn your head right by about 15°"
        case .hintReturnToStart: "Return to the starting position and look at the camera"
        case .hintFreezeForSecond: "Freeze for a second"
        case .hintHoldRemembering: "Good. Do not move — remembering the position"
        case .hintHoldPosition: "Good. Hold the position"
        case .hintCentreRememberedApply: "Centre remembered. Press \"Apply\" — there is no need to turn your head"
        case .hintShiftOnReturn: "A shift was found on the way back. Look at the centre again"
        case .hintSensorMismatch: "The camera and the sensor did not agree on the turn. Repeat the calibration"
        case .hintEstimatesDiverged: "The camera and sensor estimates diverged. Repeat the calibration"
        case .hintHeadingMismatch: "The heading after the return did not match. Repeat the calibration"
        case .hintHeadingMatched: "The heading matched after the turns. You can apply the calibration"

        case .cameraDebugTitle: "RayDesk — camera"
        case .cameraDebugReadings: " neck: x %+.1f  y %+.1f  z %+.1f cm\n from the camera: turn %+.0f°  tilt %+.0f°  box %.3f%@"
        case .cameraDebugVerdictLearning: "  · look at the camera, learning"
        case .cameraDebugVerdictTurned: "  · the head is turned away from the camera"
        case .cameraDebugVerdictTilted: "  · the head is tilted too far"
        case .cameraDebugVerdictFast: "  · a fast turn"
        case .cameraDebugCalibrated: " · camera calibration"
        case .glassesOutlineTitle: "Trace the glasses in the camera frame"
        case .glassesOutlineStep: "Menu → Camera → \"Trace the glasses\". Learning stays on while the window is open"
        case .glassesOutlineHintLive: "Press \"Freeze frame\" so the picture stops moving: the contour lands more accurately. Click to add a point, right-click to drop the last one"
        case .glassesOutlineNeedsLearning: "Turn on \"Learn the glasses shape\" in the same menu first: the outline goes into the shape while learning is on"
        case .glassesOutlineHintFrozen: "Trace the frame all the way round: click to add a point, right-click to drop the last one. Then \"Apply outline\", then \"Next\" and turn your head"
        case .glassesOutlineHintApplied: "Outline taken: %d shape points. Press \"Next\", turn your head and trace the glasses again — two or three angles make the shape fit better"
        case .glassesOutlineHintEmpty: "No face in the frame: look at the camera and put the glasses on"
        case .glassesOutlineFreeze: "Freeze frame"
        case .glassesOutlineResume: "Next"
        case .glassesOutlineUndo: "Drop point"
        case .glassesOutlineApply: "Apply outline"
        case .glassesOutlineClear: "Reset shape"
        case .glassesOutlineStatus: "%d frames in the shape · %d shape points"
        case .glassesOutlinePenOn: "Pen: drawing the contour"
        case .glassesOutlinePenOff: "Pen: editing cells"
        case .glassesOutlineLegend: "Shape cells: light blue — glasses, dark blue — from an outline, grey — not marked yet. Clicking a cell counts it as glasses, Shift-click as skin"
        case .cameraNoteNoFace: "no face found"
        case .cameraNoteShapeNotLearned: "the glasses shape is not learned: menu → \"Learn the glasses shape\""
        case .cameraNoteLearningShape: "learning the glasses shape: %d frames"
        case .cameraNoteGlassesFound: "glasses found, shape match %.0f%%"
        case .cameraNoteGlassesNotFound: "no glasses found"
        case .cameraNoteAxesLinked: "the gyroscope and camera axes are linked"
        case .cameraNoteAxesLearning: "the gyroscope and camera axes are learning: turn your head left and right, up and down"
        case .cameraNoteRotation: "%@ · rotation: %@ · %@"
        case .cameraLogGlasses: "CAMERA from the glasses: found in %d of %d frames/s, with a face %d · shape match %.0f%% · heading by camera: discrepancy %.1f°, correction %.2f°, gyroscope drift %.2f°/s, camera heading scale %.2f · reading age %.2f s"
        case .cameraLogNoFace: "CAMERA no face found · %d frames/s"
        case .cameraLogNeck: "CAMERA neck offset x %.1f y %.1f z %.1f cm · frame latency %.0f ms%@"
        case .cameraLogHead: "CAMERA head x %.1f y %.1f z %.1f cm · jitter %.1f %.1f %.1f mm · %d frames/s, with a face %d"
        case .rotationSourceFace: "face"
        case .rotationSourceGyroAndFace: "gyroscope + face"
        case .rotationSourceGyro: "gyroscope"
        }
    }
}
