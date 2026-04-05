import Carbon
import CoreGraphics
import Foundation

final class HotkeyService {

    private var hotkeyRefs: [EventHotKeyRef] = []
    fileprivate static var callbacks: [UInt32: () -> Void] = [:]
    private var handlerRef: EventHandlerRef?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retryTimer: Timer?

    fileprivate static var fnCallback: (() -> Void)?
    fileprivate static var fnDown = false
    fileprivate static var fnDirtied = false

    fileprivate static var ctrlOptCallback: (() -> Void)?
    fileprivate static var ctrlOptDown = false
    fileprivate static var ctrlOptDirtied = false

    fileprivate static weak var sharedTap: HotkeyService?

    static func reenableTap() {
        if let tap = sharedTap?.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            Log.debug("[HOTKEY] Re-enabled event tap after system disabled it")
        }
    }

    func install() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(), carbonCallback, 1, &eventType, nil, &handlerRef
        )
        if status == noErr { Log.debug("Carbon event handler installed") }
    }

    // MARK: - Fn + Ctrl+Option (CGEvent tap with auto-retry)

    func installModifierHotkeys(fnAction: @escaping () -> Void, ctrlOptAction: @escaping () -> Void) {
        HotkeyService.fnCallback = fnAction
        HotkeyService.ctrlOptCallback = ctrlOptAction

        if tryCreateTap() { return }

        Log.info("[HOTKEY] Waiting for Accessibility — retrying every 3s")
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] timer in
            if self?.tryCreateTap() == true {
                timer.invalidate()
                self?.retryTimer = nil
            }
        }
    }

    private func tryCreateTap() -> Bool {
        guard eventTap == nil else { return true }

        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask,
            callback: modifierCallback, userInfo: nil
        ) else { return false }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        HotkeyService.sharedTap = self
        Log.info("[HOTKEY] Fn + Ctrl+Option tap installed!")
        return true
    }

    // MARK: - Carbon hotkey

    func register(keyCode: UInt32, modifiers: UInt32, id: UInt32, callback: @escaping () -> Void) {
        HotkeyService.callbacks[id] = callback
        let hotkeyID = EventHotKeyID(signature: 0x4754, id: id)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(keyCode, modifiers, hotkeyID, GetApplicationEventTarget(), 0, &ref)
        if let ref { hotkeyRefs.append(ref) }
    }

    func unregisterAll() {
        retryTimer?.invalidate()
        for ref in hotkeyRefs { UnregisterEventHotKey(ref) }
        hotkeyRefs.removeAll()
        HotkeyService.callbacks.removeAll()
        HotkeyService.fnCallback = nil
        HotkeyService.ctrlOptCallback = nil
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        eventTap = nil
        runLoopSource = nil
    }
}

// MARK: - Callbacks

private func carbonCallback(
    _: EventHandlerCallRef?, event: EventRef?, _: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hkID = EventHotKeyID()
    guard GetEventParameter(event, EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID) == noErr
    else { return OSStatus(eventNotHandledErr) }
    if let cb = HotkeyService.callbacks[hkID.id] { DispatchQueue.main.async { cb() } }
    return noErr
}

private func modifierCallback(
    _: CGEventTapProxy, type: CGEventType, event: CGEvent, _: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        DispatchQueue.main.async { HotkeyService.reenableTap() }
        return Unmanaged.passRetained(event)
    }

    let f = event.flags

    if type == .flagsChanged {
        let hasFn = f.contains(.maskSecondaryFn)
        let hasCtrl = f.contains(.maskControl)
        let hasOpt = f.contains(.maskAlternate)
        let hasCmd = f.contains(.maskCommand)
        let hasShift = f.contains(.maskShift)

        // Fn
        if hasFn && !HotkeyService.fnDown {
            HotkeyService.fnDown = true
            HotkeyService.fnDirtied = hasCtrl || hasOpt || hasCmd || hasShift
        } else if !hasFn && HotkeyService.fnDown {
            HotkeyService.fnDown = false
            if !HotkeyService.fnDirtied, let cb = HotkeyService.fnCallback {
                DispatchQueue.main.async { cb() }
            }
            HotkeyService.fnDirtied = false
        }
        if HotkeyService.fnDown && (hasCtrl || hasOpt || hasCmd || hasShift) {
            HotkeyService.fnDirtied = true
        }

        // Ctrl+Option
        let both = hasCtrl && hasOpt
        if both && !HotkeyService.ctrlOptDown {
            HotkeyService.ctrlOptDown = true
            HotkeyService.ctrlOptDirtied = hasCmd || hasShift || hasFn
        } else if HotkeyService.ctrlOptDown && both && (hasCmd || hasShift || hasFn) {
            HotkeyService.ctrlOptDirtied = true
        } else if HotkeyService.ctrlOptDown && !both {
            HotkeyService.ctrlOptDown = false
            if !HotkeyService.ctrlOptDirtied, let cb = HotkeyService.ctrlOptCallback {
                DispatchQueue.main.async { cb() }
            }
            HotkeyService.ctrlOptDirtied = false
        }

        return Unmanaged.passRetained(event)
    }

    if type == .keyDown || type == .keyUp {
        if HotkeyService.fnDown { HotkeyService.fnDirtied = true }
        if HotkeyService.ctrlOptDown { HotkeyService.ctrlOptDirtied = true }
    }

    return Unmanaged.passRetained(event)
}
