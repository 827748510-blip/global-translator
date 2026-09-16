import AppKit
import Carbon.HIToolbox
import Foundation
import GlobalTranslatorCore

@MainActor
public protocol HotkeyRegistering: AnyObject {
    func register(id: UInt32, shortcut: KeyboardShortcutSpec, handler: @escaping () -> Void) throws
    func unregister(id: UInt32)
    func unregisterAll()
}

@MainActor
public final class NullHotkeyRegistrar: HotkeyRegistering {
    public init() {}
    public func register(id: UInt32, shortcut: KeyboardShortcutSpec, handler: @escaping () -> Void) throws {}
    public func unregister(id: UInt32) {}
    public func unregisterAll() {}
}

@MainActor
public final class RecordingHotkeyRegistrar: HotkeyRegistering {
    public private(set) var registered: [UInt32: KeyboardShortcutSpec] = [:]
    public var errorToThrow: HotkeyRegistrationError?
    private var handlers: [UInt32: () -> Void] = [:]

    public init() {}

    public func register(id: UInt32, shortcut: KeyboardShortcutSpec, handler: @escaping () -> Void) throws {
        if let errorToThrow { throw errorToThrow }
        guard shortcut.isValid else { throw HotkeyRegistrationError.invalid }
        registered[id] = shortcut
        handlers[id] = handler
    }

    public func unregister(id: UInt32) {
        registered.removeValue(forKey: id)
        handlers.removeValue(forKey: id)
    }

    public func unregisterAll() {
        registered.removeAll()
        handlers.removeAll()
    }

    public func fire(_ id: UInt32) {
        handlers[id]?()
    }
}

@MainActor
public final class CarbonHotkeyRegistrar: HotkeyRegistering {
    private var hotKeys: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var handlerRef: EventHandlerRef?

    public init() {}

    deinit {
        for key in hotKeys.values {
            UnregisterEventHotKey(key)
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    public func register(id: UInt32, shortcut: KeyboardShortcutSpec, handler: @escaping () -> Void) throws {
        guard shortcut.isValid else { throw HotkeyRegistrationError.invalid }
        unregister(id)
        installHandlerIfNeeded()
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status == OSStatus(-9878) {
            throw HotkeyRegistrationError.alreadyInUse
        }
        guard status == noErr, let hotKeyRef else {
            throw HotkeyRegistrationError.failed
        }
        hotKeys[id] = hotKeyRef
        handlers[id] = handler
    }

    public func unregister(id: UInt32) {
        if let existing = hotKeys.removeValue(forKey: id) {
            UnregisterEventHotKey(existing)
        }
        handlers.removeValue(forKey: id)
    }

    public func unregisterAll() {
        for key in hotKeys.values {
            UnregisterEventHotKey(key)
        }
        hotKeys.removeAll()
        handlers.removeAll()
    }

    nonisolated func handle(id: UInt32) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.invoke(id)
            }
        }
    }

    private func invoke(_ id: UInt32) {
        handlers[id]?()
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        var ref: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            globalTranslatorHotkeyHandler,
            1,
            &eventType,
            userData,
            &ref
        )
        if status == noErr {
            handlerRef = ref
        }
    }

    private static let signature: OSType = 0x47545354
}

private func globalTranslatorHotkeyHandler(
    _: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(-9874) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    let registrar = Unmanaged<CarbonHotkeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
    registrar.handle(id: hotKeyID.id)
    return noErr
}

extension KeyboardShortcutSpec {
    public init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        self.init(
            keyCode: keyCode,
            control: modifierFlags.contains(.control),
            option: modifierFlags.contains(.option),
            shift: modifierFlags.contains(.shift),
            command: modifierFlags.contains(.command)
        )
    }
}
