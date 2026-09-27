import Carbon.HIToolbox

final class Hotkeys {
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var eventHandler: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue().handlers[id.id]?()
            return noErr
        }, 1, &spec, context, &eventHandler)
    }

    func register(keyCode: Int, modifiers: Int = controlKey | optionKey, _ action: @escaping () -> Void) {
        let id = UInt32(handlers.count + 1)
        handlers[id] = action
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType(0x5244534B), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            log("hotkey keyCode \(keyCode) not registered: \(status)")
        }
        refs.append(ref)
    }
}
