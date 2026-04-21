import AppKit

final class StatusBarController: NSObject {

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private weak var appDelegate: AppDelegate?

    private var stopItem: NSMenuItem!
    private var denoiseItem: NSMenuItem!
    private var dialogItem: NSMenuItem!
    private var sttSubmenu: NSMenu!
    private var ttsSubmenu: NSMenu!
    private var costItem: NSMenuItem!
    private var audiosSubmenu: NSMenu!
    private var textsSubmenu: NSMenu!
    private var voiceSubmenu: NSMenu!
    private var speedSubmenu: NSMenu!

    init(delegate: AppDelegate) {
        self.appDelegate = delegate
        super.init()
        buildStatusItem()
        refreshCost()
    }

    @discardableResult
    private func add(_ title: String, action: Selector? = nil, key: String = "", submenu: NSMenu? = nil, to parent: NSMenu? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let sm = submenu { item.submenu = sm }
        (parent ?? menu).addItem(item)
        return item
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = ConfigManager.iconIdle
        menu = NSMenu()
        menu.autoenablesItems = false

        add("Speech \u{2192} Text  (Fn)", action: #selector(handleRecord))
        add("Speak Selection  (Ctrl+Option)", action: #selector(handleSpeak))
        add("Live Dictation (Cmd+Shift+Space)", action: #selector(handleLiveDictation))
        stopItem = add("\u{23F9} Stop", action: #selector(handleStop))
        stopItem.isHidden = true
        menu.addItem(.separator())

        audiosSubmenu = makeSubmenu()
        add("Recent Audios", submenu: audiosSubmenu)
        textsSubmenu = makeSubmenu()
        add("Recent Texts", submenu: textsSubmenu)
        buildHistoryItems()
        menu.addItem(.separator())

        denoiseItem = add("Denoise Recording (experimental)", action: #selector(handleToggleDenoise))
        denoiseItem.state = ConfigManager.denoiseBeforeSTT ? .on : .off

        sttSubmenu = makeSubmenu()
        for entry in ConfigManager.sttModels {
            let mi = add(entry.label, action: #selector(handleSetSTTMode(_:)), to: sttSubmenu)
            mi.representedObject = entry.mode.rawValue
            mi.state = entry.mode == ConfigManager.defaultSTTMode ? .on : .off
        }
        add("STT Engine", submenu: sttSubmenu)

        ttsSubmenu = makeSubmenu()
        for entry in ConfigManager.ttsEngines {
            let mi = add(entry.label, action: #selector(handleSetTTSEngine(_:)), to: ttsSubmenu)
            mi.representedObject = entry.engine.rawValue
            mi.state = entry.engine == ConfigManager.defaultTTSEngine ? .on : .off
        }
        add("TTS Engine", submenu: ttsSubmenu)

        voiceSubmenu = makeSubmenu()
        rebuildVoiceSubmenu(for: ConfigManager.defaultTTSEngine)
        add("Voice", submenu: voiceSubmenu)

        speedSubmenu = makeSubmenu()
        for rate in ["0.75x", "1.0x", "1.25x", "1.5x", "1.75x", "2.0x"] {
            let si = add(rate, action: #selector(handleSetSpeed(_:)), to: speedSubmenu)
            si.state = rate == "1.25x" ? .on : .off
        }
        add("Playback Speed", submenu: speedSubmenu)

        dialogItem = add("Show TTS Dialog", action: #selector(handleToggleDialog))
        dialogItem.state = ConfigManager.showTTSDialog ? .on : .off
        costItem = add("Usage: $0.00 (3 days)", action: #selector(handleRefreshCost))
        menu.addItem(.separator())
        add("Edit Dictionary...", action: #selector(handleEditDictionary))
        add("Quit", action: #selector(handleQuit))
        statusItem.menu = menu
    }

    private func makeSubmenu() -> NSMenu {
        let sm = NSMenu()
        sm.autoenablesItems = false
        return sm
    }

    /// Radio-select within `submenu`: set .on where `match(item)` is true, .off elsewhere.
    private func selectRadio(in submenu: NSMenu, match: (NSMenuItem) -> Bool) {
        for i in 0..<submenu.numberOfItems {
            if let item = submenu.item(at: i) { item.state = match(item) ? .on : .off }
        }
    }

    // MARK: - Icon & Controls

    func updateIcon(_ state: AppDelegate.AppState) {
        let icon: String
        switch state {
        case .idle:       icon = ConfigManager.iconIdle
        case .recording:  icon = ConfigManager.iconRecording
        case .processing: icon = ConfigManager.iconProcessing
        case .speaking:   icon = ConfigManager.iconSpeaking
        }
        DispatchQueue.main.async { [weak self] in self?.statusItem.button?.title = icon }
    }

    /// Shown in the menu bar title when Secure Input is eating events.
    func setSecureInputWarning(_ active: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let base = self.statusItem.button?.title ?? ConfigManager.iconIdle
            let stripped = base.hasPrefix("\u{1F512}") ? String(base.dropFirst()) : base
            self.statusItem.button?.title = active ? "\u{1F512}\(stripped)" : stripped
            self.statusItem.button?.toolTip = active ? "Secure Input is active — hotkeys paused by macOS. Dismiss any password field." : nil
        }
    }

    func setStopVisible(_ visible: Bool) {
        DispatchQueue.main.async { [weak self] in self?.stopItem.isHidden = !visible }
    }

    // MARK: - History

    func refreshHistory() {
        DispatchQueue.main.async { [weak self] in self?.buildHistoryItems() }
    }

    private func buildHistoryItems() {
        guard let delegate = appDelegate else { return }
        let entries = delegate.history.load()
        audiosSubmenu.removeAllItems()
        textsSubmenu.removeAllItems()
        var audioCount = 0
        for entry in entries.reversed() {
            guard let ttsPath = entry.ttsWavPath, FileManager.default.fileExists(atPath: ttsPath) else { continue }
            let ago = HistoryManager.relativeTime(entry.timestamp)
            let preview = String((entry.cleaned ?? "").prefix(40))
            let item = add("\(ago) -- \(preview)", action: #selector(handleReplaySpoken(_:)), to: audiosSubmenu)
            item.representedObject = entry.cleaned ?? ""
            audioCount += 1
        }
        if audioCount == 0 { audiosSubmenu.addItem(NSMenuItem(title: "(none)", action: nil, keyEquivalent: "")) }
        var textCount = 0
        for entry in entries.reversed() {
            guard entry.pending == true, entry.wavPath != nil else { continue }
            let ago = HistoryManager.relativeTime(entry.timestamp)
            let item = add("\u{1F504} \(ago) -- [tap to retry transcription]", action: #selector(handleRetryPending(_:)), to: textsSubmenu)
            item.representedObject = entry.timestamp
            textCount += 1
        }
        for entry in entries.reversed() {
            let text = entry.cleaned ?? entry.transcript
            guard let text, !text.isEmpty, entry.wavPath != nil else { continue }
            let ago = HistoryManager.relativeTime(entry.timestamp)
            let item = add("\(ago) -- \(String(text.prefix(40)))", action: #selector(handleReuseText(_:)), to: textsSubmenu)
            item.representedObject = text
            textCount += 1
        }
        if textCount == 0 { textsSubmenu.addItem(NSMenuItem(title: "(none)", action: nil, keyEquivalent: "")) }
    }

    // MARK: - Cost

    func refreshCost() {
        guard let delegate = appDelegate else { return }
        let (cost, totals) = delegate.usage.costLastNDays(3)
        DispatchQueue.main.async { [weak self] in
            self?.costItem.title = String(format: "Usage: $%.4f (3 days) | %d calls", cost, totals.calls)
        }
    }

    // MARK: - Dictionary

    @objc private func handleEditDictionary(_ sender: NSMenuItem) {
        appDelegate?.hotkeys.disableTap()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Custom Dictionary"
        alert.informativeText = "Add words the STT should recognize (comma-separated).\nExample: Qwen, Groq, Svelte, Tauri"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        textField.isEditable = true
        textField.isSelectable = true
        textField.font = NSFont.systemFont(ofSize: 13)
        textField.stringValue = ConfigManager.loadDictionary()
        textField.placeholderString = "Qwen, Groq, Svelte, Tauri"
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField
        let response = alert.runModal()
        appDelegate?.hotkeys.enableTap()
        guard response == .alertFirstButtonReturn else { return }
        let words = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        try? words.write(toFile: ConfigManager.dictionaryPath, atomically: true, encoding: .utf8)
        NotificationHelper.send(title: "GroqTalk", message: "Dictionary saved (\(words.components(separatedBy: ",").count) words)")
    }

    // MARK: - Actions

    @objc private func handleRecord(_ sender: NSMenuItem) { appDelegate?.toggleRecording() }
    @objc private func handleSpeak(_ sender: NSMenuItem) { appDelegate?.speakSelected() }
    @objc private func handleLiveDictation(_ sender: NSMenuItem) { appDelegate?.toggleLiveDictation() }
    @objc private func handleStop(_ sender: NSMenuItem) { appDelegate?.stopAll() }

    @objc private func handleToggleDenoise(_ sender: NSMenuItem) {
        ConfigManager.denoiseBeforeSTT.toggle()
        denoiseItem.state = ConfigManager.denoiseBeforeSTT ? .on : .off
        Log.info("[DENOISE] toggled: \(ConfigManager.denoiseBeforeSTT ? "ON" : "OFF")")
    }

    @objc private func handleToggleDialog(_ sender: NSMenuItem) {
        ConfigManager.showTTSDialog.toggle()
        dialogItem.state = ConfigManager.showTTSDialog ? .on : .off
    }

    @objc private func handleSetSTTMode(_ sender: NSMenuItem) {
        guard let d = appDelegate, let raw = sender.representedObject as? String,
              let mode = ConfigManager.STTMode(rawValue: raw) else { return }
        d.sttMode = mode
        selectRadio(in: sttSubmenu) { ($0.representedObject as? String) == raw }
        d.stopWhisperServer()
        d.stopMLXSTTServer()
        switch mode {
        case .parakeet: break   // uses mlx_audio.server (already running for TTS)
        case .localSmall: d.startWhisperServer()
        case .localLarge: d.startMLXSTTServer()
        }
    }

    @objc private func handleSetVoice(_ sender: NSMenuItem) {
        guard let voice = sender.representedObject as? String else { return }
        appDelegate?.currentVoice = voice
        selectRadio(in: voiceSubmenu) { ($0.representedObject as? String) == voice }
    }

    @objc private func handleSetTTSEngine(_ sender: NSMenuItem) {
        guard let d = appDelegate, let raw = sender.representedObject as? String,
              let engine = ConfigManager.TTSEngine(rawValue: raw) else { return }
        d.ttsEngine = engine
        let entry = ConfigManager.ttsEngineEntry(engine)
        d.currentVoice = entry.defaultVoice
        selectRadio(in: ttsSubmenu) { ($0.representedObject as? String) == raw }
        rebuildVoiceSubmenu(for: engine)
        Log.info("[TTS] engine switched to \(entry.label) — model \(entry.model)")
        d.restartKokoroServer()
    }

    private func rebuildVoiceSubmenu(for engine: ConfigManager.TTSEngine) {
        voiceSubmenu.removeAllItems()
        let entry = ConfigManager.ttsEngineEntry(engine)
        let currentVoice = appDelegate?.currentVoice ?? entry.defaultVoice
        for voice in entry.voices {
            let vi = add(voice, action: #selector(handleSetVoice(_:)), to: voiceSubmenu)
            vi.representedObject = voice
            vi.state = voice == currentVoice ? .on : .off
        }
    }

    @objc private func handleSetSpeed(_ sender: NSMenuItem) {
        let rate = Float(sender.title.replacingOccurrences(of: "x", with: "")) ?? 1.25
        appDelegate?.playbackRate = rate
        selectRadio(in: speedSubmenu) { $0.title == sender.title }
    }

    @objc private func handleRefreshCost(_ sender: NSMenuItem) { refreshCost() }

    @objc private func handleReplaySpoken(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String, !text.isEmpty else { return }
        appDelegate?.reuseText(text)
    }

    @objc private func handleReuseText(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        appDelegate?.reuseText(text)
    }

    @objc private func handleRetryPending(_ sender: NSMenuItem) {
        guard let timestamp = sender.representedObject as? String else { return }
        appDelegate?.retryPending(timestamp: timestamp)
    }

    @objc private func handleQuit(_ sender: NSMenuItem) { appDelegate?.quit() }
}
