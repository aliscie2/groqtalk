import AppKit

final class StatusBarController: NSObject {

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private weak var appDelegate: AppDelegate?

    private var stopItem: NSMenuItem!
    private var enhanceItem: NSMenuItem!
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

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = ConfigManager.iconIdle

        menu = NSMenu()
        menu.autoenablesItems = false

        let recordItem = NSMenuItem(title: "Speech \u{2192} Text  (Fn)", action: #selector(handleRecord), keyEquivalent: "")
        recordItem.target = self
        menu.addItem(recordItem)

        let speakItem = NSMenuItem(title: "Speak Selection  (Ctrl+Option)", action: #selector(handleSpeak), keyEquivalent: "")
        speakItem.target = self
        menu.addItem(speakItem)

        stopItem = NSMenuItem(title: "\u{23F9} Stop", action: #selector(handleStop), keyEquivalent: "")
        stopItem.target = self
        stopItem.isHidden = true
        menu.addItem(stopItem)

        menu.addItem(.separator())

        let audiosItem = NSMenuItem(title: "Recent Audios", action: nil, keyEquivalent: "")
        audiosSubmenu = NSMenu()
        audiosSubmenu.autoenablesItems = false
        audiosItem.submenu = audiosSubmenu
        menu.addItem(audiosItem)

        let textsItem = NSMenuItem(title: "Recent Texts", action: nil, keyEquivalent: "")
        textsSubmenu = NSMenu()
        textsSubmenu.autoenablesItems = false
        textsItem.submenu = textsSubmenu
        menu.addItem(textsItem)

        buildHistoryItems()

        menu.addItem(.separator())

        enhanceItem = NSMenuItem(title: "Enhance Text (LLM)", action: #selector(handleToggleEnhance), keyEquivalent: "")
        enhanceItem.target = self
        enhanceItem.state = .off
        menu.addItem(enhanceItem)

        let voiceItem = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
        voiceSubmenu = NSMenu()
        voiceSubmenu.autoenablesItems = false
        for voice in ConfigManager.ttsVoices {
            let vi = NSMenuItem(title: voice, action: #selector(handleSetVoice(_:)), keyEquivalent: "")
            vi.target = self
            vi.representedObject = voice
            vi.state = voice == ConfigManager.ttsVoice ? .on : .off
            voiceSubmenu.addItem(vi)
        }
        voiceItem.submenu = voiceSubmenu
        menu.addItem(voiceItem)

        let speedItem = NSMenuItem(title: "Playback Speed", action: nil, keyEquivalent: "")
        speedSubmenu = NSMenu()
        speedSubmenu.autoenablesItems = false
        for rate in ["0.75x", "1.0x", "1.25x", "1.5x", "1.75x", "2.0x"] {
            let si = NSMenuItem(title: rate, action: #selector(handleSetSpeed(_:)), keyEquivalent: "")
            si.target = self
            si.state = rate == "1.25x" ? .on : .off
            speedSubmenu.addItem(si)
        }
        speedItem.submenu = speedSubmenu
        menu.addItem(speedItem)

        costItem = NSMenuItem(title: "Usage: $0.00 (3 days)", action: #selector(handleRefreshCost), keyEquivalent: "")
        costItem.target = self
        menu.addItem(costItem)

        menu.addItem(.separator())

        let apiKeyItem = NSMenuItem(title: "Set API Keys...", action: #selector(handleSetAPIKey), keyEquivalent: "")
        apiKeyItem.target = self
        menu.addItem(apiKeyItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(handleQuit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
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
            let item = NSMenuItem(title: "\(ago) -- \(preview)", action: #selector(handleReplayEntry(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ttsPath
            audiosSubmenu.addItem(item)
            audioCount += 1
        }
        if audioCount == 0 { audiosSubmenu.addItem(NSMenuItem(title: "(none)", action: nil, keyEquivalent: "")) }

        var textCount = 0
        // Show pending recordings first (failed transcriptions)
        for entry in entries.reversed() {
            guard entry.pending == true, entry.wavPath != nil else { continue }
            let ago = HistoryManager.relativeTime(entry.timestamp)
            let item = NSMenuItem(title: "\u{1F504} \(ago) -- [tap to retry transcription]", action: #selector(handleRetryPending(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.timestamp
            textsSubmenu.addItem(item)
            textCount += 1
        }

        for entry in entries.reversed() {
            let text = entry.cleaned ?? entry.transcript
            guard let text, !text.isEmpty, entry.wavPath != nil else { continue }
            let ago = HistoryManager.relativeTime(entry.timestamp)
            let item = NSMenuItem(title: "\(ago) -- \(String(text.prefix(40)))", action: #selector(handleReuseText(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = text
            textsSubmenu.addItem(item)
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

    // MARK: - API Key Dialog

    @objc private func handleSetAPIKey(_ sender: NSMenuItem) { promptAPIKey() }

    func promptAPIKey() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Set API Keys"
        alert.informativeText = "Groq (STT) + OpenAI (TTS)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 120))

        let groqLabel = NSTextField(labelWithString: "Groq API Key (STT):")
        groqLabel.frame = NSRect(x: 0, y: 96, width: 340, height: 18)
        container.addSubview(groqLabel)

        let groqInput = NSSecureTextField(frame: NSRect(x: 0, y: 70, width: 340, height: 24))
        groqInput.placeholderString = "gsk_..."
        container.addSubview(groqInput)

        let openaiLabel = NSTextField(labelWithString: "OpenAI API Key (TTS):")
        openaiLabel.frame = NSRect(x: 0, y: 40, width: 340, height: 18)
        container.addSubview(openaiLabel)

        let openaiInput = NSSecureTextField(frame: NSRect(x: 0, y: 14, width: 340, height: 24))
        openaiInput.placeholderString = "sk-..."
        container.addSubview(openaiInput)

        let envPath = ConfigManager.configDir + "/.env"
        if let contents = try? String(contentsOfFile: envPath, encoding: .utf8) {
            for line in contents.components(separatedBy: "\n") {
                if line.hasPrefix("GROQ_API_KEY=") {
                    groqInput.stringValue = String(line.dropFirst("GROQ_API_KEY=".count))
                }
                if line.hasPrefix("OPENAI_API_KEY=") {
                    openaiInput.stringValue = String(line.dropFirst("OPENAI_API_KEY=".count))
                }
            }
        }

        alert.accessoryView = container
        alert.window.initialFirstResponder = groqInput

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let groqKey = groqInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let openaiKey = openaiInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !groqKey.isEmpty else { return }

        var envContent = "GROQ_API_KEY=\(groqKey)\n"
        if !openaiKey.isEmpty { envContent += "OPENAI_API_KEY=\(openaiKey)\n" }

        let dir = ConfigManager.configDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? envContent.write(toFile: envPath, atomically: true, encoding: .utf8)

        appDelegate?.reloadAPIKey()
        NotificationHelper.send(title: "GroqTalk", message: "API keys saved!")
    }

    // MARK: - Actions

    @objc private func handleRecord(_ sender: NSMenuItem) { appDelegate?.toggleRecording() }
    @objc private func handleSpeak(_ sender: NSMenuItem) { appDelegate?.speakSelected() }
    @objc private func handleStop(_ sender: NSMenuItem) { appDelegate?.stopAll() }

    @objc private func handleToggleEnhance(_ sender: NSMenuItem) {
        guard let d = appDelegate else { return }
        d.enhanceText.toggle()
        enhanceItem.state = d.enhanceText ? .on : .off
    }

    @objc private func handleSetVoice(_ sender: NSMenuItem) {
        guard let voice = sender.representedObject as? String else { return }
        appDelegate?.currentVoice = voice
        for i in 0..<voiceSubmenu.numberOfItems {
            voiceSubmenu.item(at: i)?.state = voiceSubmenu.item(at: i)?.representedObject as? String == voice ? .on : .off
        }
    }

    @objc private func handleSetSpeed(_ sender: NSMenuItem) {
        let rate = Float(sender.title.replacingOccurrences(of: "x", with: "")) ?? 1.25
        appDelegate?.playbackRate = rate
        for i in 0..<speedSubmenu.numberOfItems {
            speedSubmenu.item(at: i)?.state = speedSubmenu.item(at: i)?.title == sender.title ? .on : .off
        }
    }

    @objc private func handleRefreshCost(_ sender: NSMenuItem) { refreshCost() }

    @objc private func handleReplayEntry(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        appDelegate?.replayEntry(path: path)
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
