import AppKit

final class StatusBarController: NSObject, NSMenuDelegate {

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
        menu.delegate = self

        add("Speech \u{2192} Text  (Fn)", action: #selector(handleRecord))
        add("Speak Selection  (Ctrl+Option)", action: #selector(handleSpeak))
        add("Live Dictation (Cmd+Shift+Space)", action: #selector(handleLiveDictation))
        add("Delete Last Sentence (Cmd+Shift+Delete)", action: #selector(handleDeleteLastSentence))
        stopItem = add("\u{23F9} Stop", action: #selector(handleStop))
        stopItem.isHidden = true
        menu.addItem(.separator())

        audiosSubmenu = makeSubmenu()
        add("Recent Audios", submenu: audiosSubmenu)
        textsSubmenu = makeSubmenu()
        add("Recent Texts", submenu: textsSubmenu)
        buildHistoryItems()
        add("Search History...", action: #selector(handleOpenHistorySearch))
        menu.addItem(.separator())

        denoiseItem = add("Denoise Recording (experimental)", action: #selector(handleToggleDenoise))
        denoiseItem.state = ConfigManager.denoiseBeforeSTT ? .on : .off

        sttSubmenu = makeSubmenu()
        for entry in ConfigManager.availableSTTModels {
            let mi = add(entry.label, action: #selector(handleSetSTTMode(_:)), to: sttSubmenu)
            mi.representedObject = entry.mode.rawValue
            mi.state = entry.mode == ConfigManager.selectedSTTMode ? .on : .off
        }
        add("STT Engine", submenu: sttSubmenu)

        ttsSubmenu = makeSubmenu()
        for entry in ConfigManager.ttsEngines {
            let mi = add(entry.label, action: #selector(handleSetTTSEngine(_:)), to: ttsSubmenu)
            mi.representedObject = entry.engine.rawValue
            mi.state = entry.engine == ConfigManager.selectedTTSEngine ? .on : .off
        }
        add("TTS Engine", submenu: ttsSubmenu)

        voiceSubmenu = makeSubmenu()
        voiceSubmenu.delegate = self
        rebuildVoiceSubmenu(for: ConfigManager.selectedTTSEngine)
        add("Voice", submenu: voiceSubmenu)

        speedSubmenu = makeSubmenu()
        for rate in ["0.75x", "1.0x", "1.25x", "1.5x", "1.75x", "2.0x"] {
            let si = add(rate, action: #selector(handleSetSpeed(_:)), to: speedSubmenu)
            si.state = abs((Float(rate.replacingOccurrences(of: "x", with: "")) ?? 1.25) - ConfigManager.playbackRate) < 0.001 ? .on : .off
        }
        add("Playback Speed", submenu: speedSubmenu)

        dialogItem = add("Show TTS Dialog", action: #selector(handleToggleDialog))
        dialogItem.state = ConfigManager.showTTSDialog ? .on : .off
        add("Export Session Markdown", action: #selector(handleExportSession))
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

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard menu == voiceSubmenu, let voice = item?.representedObject as? String else { return }
        appDelegate?.previewVoice(voice)
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu == voiceSubmenu || menu == self.menu {
            appDelegate?.stopVoicePreview()
        }
    }

    private func buildHistoryItems() {
        guard let delegate = appDelegate else { return }
        let entries = delegate.history.load()
        audiosSubmenu.removeAllItems()
        textsSubmenu.removeAllItems()
        let recentAudios = HistoryManager.recentAudioEntries(from: entries, limit: 10)
        for entry in recentAudios {
            guard let ttsPath = entry.ttsWavPath else { continue }
            let ago = HistoryManager.relativeTime(entry.timestamp)
            let preview = String((HistoryManager.displayText(for: entry) ?? "[saved audio]").prefix(40))
            let item = add("\(ago) -- \(preview)", action: #selector(handleReplaySpoken(_:)), to: audiosSubmenu)
            item.representedObject = ttsPath
            item.toolTip = HistoryManager.displayText(for: entry) ?? ttsPath
        }
        if recentAudios.isEmpty { audiosSubmenu.addItem(NSMenuItem(title: "(none)", action: nil, keyEquivalent: "")) }

        let recentTexts = HistoryManager.recentTextEntries(from: entries, limit: 10)
        for entry in recentTexts {
            let ago = HistoryManager.relativeTime(entry.timestamp)
            if entry.pending == true {
                let item = add("\u{1F504} \(ago) -- [tap to retry transcription]", action: #selector(handleRetryPending(_:)), to: textsSubmenu)
                item.representedObject = entry.timestamp
                item.toolTip = "Retry this saved recording"
            } else if let text = HistoryManager.displayText(for: entry) {
                let item = add("\(ago) -- \(String(text.prefix(40)))", action: #selector(handleReuseText(_:)), to: textsSubmenu)
                item.representedObject = text
                item.toolTip = text
            }
        }
        if recentTexts.isEmpty { textsSubmenu.addItem(NSMenuItem(title: "(none)", action: nil, keyEquivalent: "")) }
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
    @objc private func handleSpeak(_ sender: NSMenuItem) { appDelegate?.toggleSpeakSelection() }
    @objc private func handleLiveDictation(_ sender: NSMenuItem) { appDelegate?.toggleLiveDictation() }
    @objc private func handleDeleteLastSentence(_ sender: NSMenuItem) { appDelegate?.deleteLastDictationSentence() }
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
        // Kick off a silent warmup so the first real dictation request does
        // not pay the model cold-load penalty right after an engine switch.
        d.warmSTT(mode: mode)
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
        d.currentVoice = ConfigManager.preferredVoice(for: engine)
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
    @objc private func handleExportSession(_ sender: NSMenuItem) { appDelegate?.exportSessionMarkdown() }
    @objc private func handleOpenHistorySearch(_ sender: NSMenuItem) { appDelegate?.openHistorySearch() }

    @objc private func handleReplaySpoken(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String, !path.isEmpty else { return }
        appDelegate?.replayEntry(path: path)
    }

    @objc private func handleReuseText(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        appDelegate?.insertRecentText(text)
    }

    @objc private func handleRetryPending(_ sender: NSMenuItem) {
        guard let timestamp = sender.representedObject as? String else { return }
        appDelegate?.retryPending(timestamp: timestamp)
    }

    @objc private func handleQuit(_ sender: NSMenuItem) { appDelegate?.quit() }
}
