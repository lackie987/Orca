import AppKit
import Carbon.HIToolbox

/// A system-wide key combination: one physical key plus the modifiers that must be held.
struct HotkeyBinding: Equatable {
    let keyCode: UInt32
    let modifiers: NSEvent.ModifierFlags

    /// Caps lock and fn are not part of a registration; normalize so equality and Carbon agree.
    static let supportedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.supportedModifiers)
    }

    /// A bare key would be taken from every app, so a registration needs a deliberate modifier.
    var isUsable: Bool {
        !modifiers.intersection([.command, .option, .control]).isEmpty
    }

    /// Carbon's modifier mask; `NSEvent.ModifierFlags` cannot be passed to `RegisterEventHotKey`.
    fileprivate var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }
}

/// A named owner for a system-wide hotkey.
///
/// Slots are introduced by the feature that handles them; the centre ships no catalogue and
/// claims no key, so nothing is taken from other apps until `register` runs.
struct HotkeySlot: Hashable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// How long a registration stays installed.
enum HotkeyScope: Equatable {
    /// Installed for the process lifetime; use for keys that must work from other apps.
    case global
    /// Installed only while Orca is active, so other apps keep the combination.
    case whileActive
}

/// Owns Carbon registrations for hotkeys.
///
/// Registration is explicit: a slot only takes a key when a feature calls `register`, and the
/// handler defaults to an empty action so a slot can be reserved before its command exists.
/// A `whileActive` slot is released whenever Orca resigns active, so menu accelerators never
/// follow the user into other apps.
final class GlobalHotkeyCenter {
    static let shared = GlobalHotkeyCenter()

    private struct Definition {
        let slot: HotkeySlot
        let binding: HotkeyBinding
        let scope: HotkeyScope
        let handler: () -> Void
    }

    private struct Registration {
        let slot: HotkeySlot
        let binding: HotkeyBinding
        let scope: HotkeyScope
        let reference: EventHotKeyRef
        let handler: () -> Void
    }

    /// Identifies Orca's hotkeys in the Carbon event; 'ORCA'.
    private static let signature: OSType = 0x4F524341

    private var registrations: [UInt32: Registration] = [:]
    /// Definitions kept across deactivation so `applicationActivated` can install them again.
    private var scopedDefinitions: [HotkeySlot: Definition] = [:]
    private var nextIdentifier: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    private init() {}

    deinit {
        unregisterAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    // MARK: - Registration

    /// Installs the Carbon handler without claiming a key. Safe to call more than once.
    func prepare() {
        precondition(Thread.isMainThread, "Hotkeys are prepared on the main thread")
        guard eventHandler == nil else { return }
        installEventHandler()
    }

    /// Binds `binding` to `slot`, replacing whatever the slot owned before.
    ///
    /// Returns false when the combination has no usable modifier, is already bound to another
    /// slot, or was registered by another app first. A `whileActive` slot is accepted while
    /// Orca is inactive and installed on the next activation.
    @discardableResult
    func register(
        _ slot: HotkeySlot,
        binding: HotkeyBinding,
        scope: HotkeyScope = .global,
        handler: @escaping () -> Void = {}
    ) -> Bool {
        precondition(Thread.isMainThread, "Hotkeys are registered on the main thread")
        prepare()
        guard binding.isUsable else {
            NSLog("[Orca] Hotkey for %@ needs Command, Option or Control", slot.rawValue)
            return false
        }
        if let owner = occupiedSlot(for: binding, excluding: slot) {
            NSLog("[Orca] Hotkey for %@ is already bound to %@", slot.rawValue, owner.rawValue)
            return false
        }
        unregister(slot)

        let definition = Definition(slot: slot, binding: binding, scope: scope, handler: handler)
        guard scope == .whileActive else {
            return install(definition)
        }
        scopedDefinitions[slot] = definition
        guard NSApp?.isActive == true else { return true }
        return install(definition)
    }

    /// Releases the combination owned by `slot`, if any.
    func unregister(_ slot: HotkeySlot) {
        precondition(Thread.isMainThread, "Hotkeys are released on the main thread")
        scopedDefinitions.removeValue(forKey: slot)
        release(slot)
    }

    /// Releases every registered combination and drops pending definitions.
    func unregisterAll() {
        for registration in registrations.values {
            UnregisterEventHotKey(registration.reference)
        }
        registrations.removeAll()
        scopedDefinitions.removeAll()
    }

    /// The binding a slot owns, including a `whileActive` slot while Orca is inactive.
    func binding(for slot: HotkeySlot) -> HotkeyBinding? {
        registrations.values.first { $0.slot == slot }?.binding ?? scopedDefinitions[slot]?.binding
    }

    // MARK: - Application activation

    /// Installs every `whileActive` definition. Called when Orca becomes active.
    func applicationActivated() {
        precondition(Thread.isMainThread, "Hotkeys are installed on the main thread")
        prepare()
        for definition in scopedDefinitions.values
        where !registrations.values.contains(where: { $0.slot == definition.slot }) {
            _ = install(definition)
        }
    }

    /// Releases `whileActive` definitions so other apps keep their combinations.
    func applicationDeactivated() {
        precondition(Thread.isMainThread, "Hotkeys are released on the main thread")
        for identifier in registrations.filter({ $0.value.scope == .whileActive }).map(\.key) {
            if let registration = registrations.removeValue(forKey: identifier) {
                UnregisterEventHotKey(registration.reference)
            }
        }
    }

    // MARK: - Private

    private func occupiedSlot(for binding: HotkeyBinding, excluding slot: HotkeySlot) -> HotkeySlot? {
        if let active = registrations.values.first(where: { $0.slot != slot && $0.binding == binding }) {
            return active.slot
        }
        return scopedDefinitions.values.first(where: { $0.slot != slot && $0.binding == binding })?.slot
    }

    private func install(_ definition: Definition) -> Bool {
        var reference: EventHotKeyRef?
        let identifier = nextIdentifier
        nextIdentifier += 1
        let status = RegisterEventHotKey(
            definition.binding.keyCode,
            definition.binding.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: identifier),
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            NSLog("[Orca] RegisterEventHotKey failed for %@ (OSStatus %d)", definition.slot.rawValue, status)
            return false
        }
        registrations[identifier] = Registration(
            slot: definition.slot,
            binding: definition.binding,
            scope: definition.scope,
            reference: reference,
            handler: definition.handler
        )
        return true
    }

    private func release(_ slot: HotkeySlot) {
        for identifier in registrations.filter({ $0.value.slot == slot }).map(\.key) {
            if let registration = registrations.removeValue(forKey: identifier) {
                UnregisterEventHotKey(registration.reference)
            }
        }
    }

    // MARK: - Carbon events

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.hotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        if status != noErr {
            NSLog("[Orca] InstallEventHandler failed (OSStatus %d)", status)
        }
    }

    private static let hotKeyHandler: EventHandlerUPP = { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        var identifier = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &identifier
        )
        guard status == noErr else { return status }
        let center = Unmanaged<GlobalHotkeyCenter>.fromOpaque(context).takeUnretainedValue()
        return center.dispatch(identifier)
    }

    private func dispatch(_ identifier: EventHotKeyID) -> OSStatus {
        guard identifier.signature == Self.signature,
              let registration = registrations[identifier.id] else {
            return OSStatus(eventNotHandledErr)
        }
        registration.handler()
        return noErr
    }
}
