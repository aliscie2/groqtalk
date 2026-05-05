import AppKit
import Carbon
import CoreGraphics
import Foundation

final class HotkeyService {

    static let hotkeyIDLiveDictation: UInt32 = 1
    static let hotkeyIDDeleteLastSentence: UInt32 = 2

    private var hotkeyRefs: [EventHotKeyRef] = []
    fileprivate static var callbacks: [UInt32: () -> Void] = [:]
    private var handlerRef: EventHandlerRef?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retryTimer: Timer?
    private var healthTimer: Timer?

    fileprivate static var fnCallback: (() -> Void)?
    fileprivate static var fnDown = false
    fileprivate static var fnDirtied = false
    fileprivate static var fnShiftCallback: (() -> Void)?
    fileprivate static var fnShiftDown = false
    fileprivate static var fnShiftDirtied = false
    fileprivate static var fnCtrlCallback: (() -> Void)?
    fileprivate static var fnCtrlDown = false
    fileprivate static var fnCtrlDirtied = false
    fileprivate static var ctrlOptCallback: (() -> Void)?
    fileprivate static var ctrlOptDown = false
    fileprivate static var ctrlOptDirtied = false
    fileprivate static var transientKeyHandler: ((CGEventType, CGKeyCode, CGEventFlags) -> Bool)?

    fileprivate static weak var sharedTap: HotkeyService?

    static func reenableTap() {
        guard let tap = sharedTap?.eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.debug("[HOTKEY] Re-enabled event tap after system disabled it")
    }

    func install() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(), carbonCallback, 1, &eventType, nil, &handlerRef
        )
        if status == noErr { Log.debug("Carbon event handler installed") }
    }

    // MARK: - Fn / Shift+Fn / Fn+Ctrl / Ctrl+Option (CGEvent tap with auto-retry)

    func installModifierHotkeys(
        fnAction: @escaping () -> Void,
        fnShiftAction: @escaping () -> Void,
        fnCtrlAction: @escaping () -> Void,
        ctrlOptAction: @escaping () -> Void
    ) {
        HotkeyService.fnCallback = fnAction
        HotkeyService.fnShiftCallback = fnShiftAction
        HotkeyService.fnCtrlCallback = fnCtrlAction
        HotkeyService.ctrlOptCallback = ctrlOptAction

        _ = tryCreateTap()
        if eventTap == nil {
            Log.info("[HOTKEY] Waiting for permissions — retrying every 3s")
            retryTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] timer in
                if self?.tryCreateTap() == true { timer.invalidate(); self?.retryTimer = nil }
            }
        }
        installHealthMonitor()
    }

    /// Self-heal the tap against known silent-death scenarios (Stage Manager,
    /// display sleep, login-window cycles). See CLAUDE.md "Hotkey tap silent death".
    private func installHealthMonitor() {
        let nc = NSWorkspace.shared.notificationCenter
        let sel = #selector(rebuildTapAfterSystemEvent)
        for name: NSNotification.Name in [
            NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.activeSpaceDidChangeNotification,
        ] { nc.addObserver(self, selector: sel, name: name, object: nil) }

        healthTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkTapHealth()
        }
        if let t = healthTimer { RunLoop.main.add(t, forMode: .common) }
    }

    @objc private func rebuildTapAfterSystemEvent() {
        Log.info("[HOTKEY] system event — verifying tap health")
        checkTapHealth(force: true)
    }

    private func checkTapHealth(force: Bool = false) {
        guard let tap = eventTap else { _ = tryCreateTap(); return }
        if !CGEvent.tapIsEnabled(tap: tap) {
            Log.info("[HOTKEY] tap disabled — re-enabling")
            CGEvent.tapEnable(tap: tap, enable: true)
            if !CGEvent.tapIsEnabled(tap: tap) {
                Log.info("[HOTKEY] re-enable failed — rebuilding from scratch")
                teardownTap(); _ = tryCreateTap()
            }
        } else if force {
            // Post system transition: tap may report enabled but stop delivering.
            teardownTap(); _ = tryCreateTap()
        }
    }

    private func teardownTap() {
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        eventTap = nil
        runLoopSource = nil
    }

    private func tryCreateTap() -> Bool {
        guard eventTap == nil else { return true }
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: modifierCallback, userInfo: nil
        ) else { return false }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        HotkeyService.sharedTap = self
        Log.info("[HOTKEY] Fn + Shift+Fn + Ctrl+Option tap installed!")
        return true
    }

    // MARK: - Carbon hotkey

    func register(keyCode: UInt32, modifiers: UInt32, id: UInt32, callback: @escaping () -> Void) {
        HotkeyService.callbacks[id] = callback
        var ref: EventHotKeyRef?
        RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: 0x4754, id: id),
                            GetApplicationEventTarget(), 0, &ref)
        if let ref { hotkeyRefs.append(ref) }
    }

    /// Register Cmd+Shift+Space for live dictation toggle. (kVK_Space = 0x31)
    func installLiveDictationHotkey(action: @escaping () -> Void) {
        register(keyCode: 0x31, modifiers: UInt32(cmdKey) | UInt32(shiftKey),
                 id: HotkeyService.hotkeyIDLiveDictation, callback: action)
        Log.info("[HOTKEY] Live dictation registered (Cmd+Shift+Space)")
    }

    func installDeleteLastSentenceHotkey(action: @escaping () -> Void) {
        register(keyCode: 0x33, modifiers: UInt32(cmdKey) | UInt32(shiftKey),
                 id: HotkeyService.hotkeyIDDeleteLastSentence, callback: action)
        Log.info("[HOTKEY] Delete-last-sentence registered (Cmd+Shift+Delete)")
    }

    func disableTap() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        Log.debug("[HOTKEY] tap disabled for dialog")
    }

    func enableTap() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        Log.debug("[HOTKEY] tap re-enabled")
    }

    func setTransientKeyHandler(_ handler: ((CGEventType, CGKeyCode, CGEventFlags) -> Bool)?) {
        HotkeyService.transientKeyHandler = handler
    }

    func unregisterAll() {
        retryTimer?.invalidate()
        healthTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        for ref in hotkeyRefs { UnregisterEventHotKey(ref) }
        hotkeyRefs.removeAll()
        HotkeyService.callbacks.removeAll()
        HotkeyService.fnCallback = nil
        HotkeyService.fnShiftCallback = nil
        HotkeyService.fnCtrlCallback = nil
        HotkeyService.ctrlOptCallback = nil
        HotkeyService.transientKeyHandler = nil
        teardownTap()
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

/// Edge-triggered update of a solo-modifier latch. Fires `callback` on clean
/// release (no other modifier touched during hold). When `label` is set emits
/// diagnostic [HOTKEY] DOWN/UP logs — keep these for triage per CLAUDE.md.
private func updateSoloModifier(
    pressed: Bool, otherMods: Bool,
    down: inout Bool, dirtied: inout Bool,
    callback: (() -> Void)?, label: String?
) {
    if pressed && !down {
        down = true
        dirtied = otherMods
        if let label { Log.debug("[HOTKEY] \(label) DOWN (dirtied=\(dirtied))") }
    } else if down && pressed && otherMods {
        dirtied = true
    } else if down && !pressed {
        down = false
        let willFire = !dirtied && callback != nil
        if let label { Log.debug("[HOTKEY] \(label) UP (dirtied=\(dirtied), fire=\(willFire))") }
        if !dirtied, let cb = callback { DispatchQueue.main.async { cb() } }
        dirtied = false
    }
}

private func modifierCallback(
    _: CGEventTapProxy, type: CGEventType, event: CGEvent, _: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        DispatchQueue.main.async { HotkeyService.reenableTap() }
        return Unmanaged.passRetained(event)
    }

    if type == .flagsChanged {
        let f = event.flags
        let hasFn = f.contains(.maskSecondaryFn)
        let hasCtrl = f.contains(.maskControl)
        let hasOpt = f.contains(.maskAlternate)
        let hasCmd = f.contains(.maskCommand)
        let hasShift = f.contains(.maskShift)
        let wasTrackingFnGesture = HotkeyService.fnDown
            || HotkeyService.fnShiftDown
            || HotkeyService.fnCtrlDown

        updateSoloModifier(
            pressed: hasFn, otherMods: hasCtrl || hasOpt || hasCmd || hasShift,
            down: &HotkeyService.fnDown, dirtied: &HotkeyService.fnDirtied,
            callback: HotkeyService.fnCallback, label: "fn"
        )
        updateSoloModifier(
            pressed: hasFn && hasShift, otherMods: hasCtrl || hasOpt || hasCmd,
            down: &HotkeyService.fnShiftDown, dirtied: &HotkeyService.fnShiftDirtied,
            callback: HotkeyService.fnShiftCallback, label: "shift+fn"
        )
        updateSoloModifier(
            pressed: hasFn && hasCtrl, otherMods: hasOpt || hasCmd || hasShift,
            down: &HotkeyService.fnCtrlDown, dirtied: &HotkeyService.fnCtrlDirtied,
            callback: HotkeyService.fnCtrlCallback, label: "fn+ctrl"
        )
        updateSoloModifier(
            pressed: hasCtrl && hasOpt, otherMods: hasCmd || hasShift || hasFn,
            down: &HotkeyService.ctrlOptDown, dirtied: &HotkeyService.ctrlOptDirtied,
            callback: HotkeyService.ctrlOptCallback, label: "ctrl+opt"
        )

        if hasFn || wasTrackingFnGesture {
            return nil
        }
    } else if type == .keyDown || type == .keyUp {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if let handler = HotkeyService.transientKeyHandler, handler(type, keyCode, event.flags) {
            return nil
        }
        if HotkeyService.fnDown { HotkeyService.fnDirtied = true }
        if HotkeyService.fnShiftDown { HotkeyService.fnShiftDirtied = true }
        if HotkeyService.fnCtrlDown { HotkeyService.fnCtrlDirtied = true }
        if HotkeyService.ctrlOptDown { HotkeyService.ctrlOptDirtied = true }
    }

    return Unmanaged.passRetained(event)
}
