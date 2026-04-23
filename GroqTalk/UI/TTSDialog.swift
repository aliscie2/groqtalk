import AppKit
import WebKit

final class TTSDialog: NSObject, WKScriptMessageHandler, NSWindowDelegate {
    static let shared = TTSDialog()

    var onChunkTap: ((Int) -> Void)?
    var onWordTap: ((Int, Int) -> Void)?
    var onClose: (() -> Void)?
    var onPauseToggle: (() -> Void)?
    var onRecordToggle: (() -> Void)?
    var onChunkVoiceSelect: ((Int, String) -> Void)?
    var voiceOptionsProvider: (() -> (voices: [String], current: String))?

    private var window: NSWindow?
    private var webView: WKWebView?
    private var currentPayload: DialogPayload?
    private var currentMarkdownSource = ""
    private var currentPlainSource = ""
    private var pendingVoiceChunkIndex: Int?
    private var restoringMenuBarOnly = false
    private var hasPresentedWindow = false
    private var localKeyMonitor: Any?

    private let defaultColumnWidth: CGFloat = 560
    private let minColumnWidth: CGFloat = 520
    private let maxColumnWidth: CGFloat = 720
    private let minColumnHeight: CGFloat = 300
    private let defaultLeftInset: CGFloat = 24
    private let defaultTopBottomInset: CGFloat = 28
    private static let frameAutosaveName = "GroqTalkTTSDialogWindow"

    // MARK: - Public API

    func show(text: String, chunks: [String], playbackRate: Float) {
        Log.info("[DIALOG] show (\(text.count) chars, \(chunks.count) chunks)")
        DispatchQueue.main.async { [weak self] in
            self?.showOnMain(text: text, chunks: chunks, playbackRate: playbackRate)
        }
    }

    func enableChunk(_ index: Int) { js("enableChunk(\(index))") }

    func setPaused(_ paused: Bool) { js("setPaused(\(paused))") }

    func setActiveChunk(_ index: Int) {
        Log.debug("[DIALOG] setActiveChunk \(index)")
        js("highlight(\(index))")
    }

    func setActiveWord(dialogIndex: Int, wordIndex: Int?) {
        if let wordIndex {
            js("highlightWord(\(dialogIndex),\(wordIndex))")
        } else {
            js("clearActiveWord()")
        }
    }

    func finish() {
        Log.info("[DIALOG] finish")
        js("finished()")
    }

    func close() {
        Log.info("[DIALOG] close")
        DispatchQueue.main.async { [weak self] in self?.closeOnMain() }
    }

    func error(_ message: String) {
        Log.info("[DIALOG] error: \(message)")
        let escaped = message.replacingOccurrences(of: "'", with: "\\'")
        js("showError('\(escaped)')")
    }

    var isVisible: Bool {
        guard let window else { return false }
        return window.isVisible || window.isMiniaturized
    }

    private func js(_ code: String) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(code, completionHandler: nil)
        }
    }

    // MARK: - Show / Dismiss

    private func showOnMain(text: String, chunks: [String], playbackRate: Float) {
        if window == nil { buildWindow() }
        guard let window, let webView else { Log.error("[DIALOG] window missing"); return }

        let payload = DialogCapabilities.buildPayload(chunks: chunks, playbackRate: playbackRate)
        currentPayload = payload
        currentMarkdownSource = text.trimmingCharacters(in: .whitespacesAndNewlines)
        currentPlainSource = DialogCapabilities.plainText(from: TextPrettifier.prettify(text))

        let data = try? JSONEncoder().encode(payload)
        let json = String(data: data ?? Data("{\"chunks\":[],\"playbackRate\":1}".utf8), encoding: .utf8)
            ?? "{\"chunks\":[],\"playbackRate\":1}"
        webView.evaluateJavaScript("loadChunks(\(json))", completionHandler: nil)

        resizeWindowForCurrentSpeech(payload: payload, window: window)
        webView.frame = window.contentView?.bounds ?? window.frame

        promoteAppForWindowing()
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeFirstResponder(webView)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1.0
        }
        hasPresentedWindow = true
    }

    private func resizeWindowForCurrentSpeech(payload: DialogPayload, window: NSWindow) {
        guard let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }

        let restoredSavedFrame = !hasPresentedWindow
            && !window.isMiniaturized
            && window.setFrameUsingName(Self.frameAutosaveName)

        let seedFrame = (hasPresentedWindow || restoredSavedFrame || window.isMiniaturized)
            ? window.frame
            : defaultFrame(in: visibleFrame)
        let targetFrame = autosizedFrame(for: payload, visibleFrame: visibleFrame, seedFrame: seedFrame)

        if window.frame.equalTo(targetFrame) { return }
        window.setFrame(targetFrame, display: true, animate: hasPresentedWindow && !window.isMiniaturized)
    }

    private func defaultFrame(in visibleFrame: NSRect) -> NSRect {
        let height = max(
            420,
            min(visibleFrame.height - (defaultTopBottomInset * 2), visibleFrame.height * 0.82)
        )
        let width = min(defaultColumnWidth, max(minColumnWidth, visibleFrame.width * 0.38))
        return NSRect(
            x: visibleFrame.minX + defaultLeftInset,
            y: visibleFrame.maxY - height - defaultTopBottomInset,
            width: width,
            height: height
        )
    }

    private func autosizedFrame(
        for payload: DialogPayload,
        visibleFrame: NSRect,
        seedFrame: NSRect
    ) -> NSRect {
        let chunks = payload.chunks
        let plainText = chunks.map(\.plain).joined(separator: "\n\n")
        let characterCount = plainText.count
        let wordCount = chunks.reduce(0) { $0 + $1.words }
        let wideContent = chunks.contains { chunk in
            let markdown = chunk.markdown
            return markdown.contains("```")
                || markdown.contains("|")
                || markdown.contains("\u{2192}")
                || markdown.contains("http://")
                || markdown.contains("https://")
        }
        let longestLine = plainText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(\.count)
            .max() ?? 0

        let screenMaxWidth = min(maxColumnWidth, max(minColumnWidth, visibleFrame.width * 0.46))
        let preferredWidth: CGFloat
        if wideContent || longestLine > 96 {
            preferredWidth = 680
        } else if characterCount <= 220 && chunks.count <= 2 {
            preferredWidth = 540
        } else if characterCount > 1_200 || chunks.count > 8 {
            preferredWidth = 620
        } else {
            preferredWidth = 580
        }
        let width = clamp(preferredWidth, minColumnWidth, screenMaxWidth)

        let contentWidth = max(320, width - 122)
        let charactersPerLine = max(28, Int(contentWidth / 9.3))
        let estimatedContentHeight = chunks.reduce(CGFloat(0)) { total, chunk in
            let lines = estimatedLineCount(for: chunk.plain, charactersPerLine: charactersPerLine)
            let lineHeight: CGFloat = chunk.markdown.contains("```") ? 23 : 31
            let cardChrome: CGFloat = 56
            return total + (CGFloat(lines) * lineHeight) + cardChrome
        }

        let topBottomChrome: CGFloat = 142
        let desiredHeight = estimatedContentHeight + topBottomChrome
        let compactMinimum: CGFloat
        if characterCount <= 140 && chunks.count <= 1 {
            compactMinimum = minColumnHeight
        } else if wordCount < 90 {
            compactMinimum = 360
        } else {
            compactMinimum = 420
        }
        let maxHeightRatio: CGFloat = characterCount > 1_800 || chunks.count > 10 ? 0.88 : 0.78
        let maxHeight = min(
            visibleFrame.height - (defaultTopBottomInset * 2),
            visibleFrame.height * maxHeightRatio
        )
        let height = clamp(desiredHeight, compactMinimum, max(maxHeight, compactMinimum))

        let anchoredTop = seedFrame.maxY.isFinite ? seedFrame.maxY : visibleFrame.maxY - defaultTopBottomInset
        var x = seedFrame.minX.isFinite ? seedFrame.minX : visibleFrame.minX + defaultLeftInset
        var y = anchoredTop - height

        x = clamp(x, visibleFrame.minX + defaultLeftInset, visibleFrame.maxX - width - defaultLeftInset)
        y = clamp(y, visibleFrame.minY + defaultTopBottomInset, visibleFrame.maxY - height - defaultTopBottomInset)

        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func estimatedLineCount(for text: String, charactersPerLine: Int) -> Int {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return max(1, lines.reduce(0) { total, line in
            total + max(1, Int(ceil(Double(line.count) / Double(charactersPerLine))))
        })
    }

    private func clamp(_ value: CGFloat, _ lowerBound: CGFloat, _ upperBound: CGFloat) -> CGFloat {
        min(max(value, lowerBound), upperBound)
    }

    private func closeOnMain() {
        guard let window else { return }
        window.orderOut(nil)
        maybeRestoreMenuBarOnly()
    }

    private func promoteAppForWindowing() {
        if NSApp.activationPolicy() != .regular {
            _ = NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func maybeRestoreMenuBarOnly() {
        guard !restoringMenuBarOnly else { return }
        guard let window else { return }
        guard !window.isVisible, !window.isMiniaturized else { return }
        let otherWindowOpen = NSApp.windows.contains {
            $0 !== window && ($0.isVisible || $0.isMiniaturized)
        }
        guard !otherWindowOpen else { return }
        restoringMenuBarOnly = true
        DispatchQueue.main.async {
            _ = NSApp.setActivationPolicy(.prohibited)
            self.restoringMenuBarOnly = false
        }
    }

    // MARK: - Clipboard

    private func copyChunk(_ index: Int) {
        guard let payload = currentPayload, payload.chunks.indices.contains(index) else { return }
        writeClipboard(payload.chunks[index].plain, title: "Copied paragraph")
    }

    private func copyAll(mode: String) {
        let text: String
        if mode == "markdown" {
            text = currentMarkdownSource
        } else {
            text = currentPlainSource
        }
        writeClipboard(text, title: mode == "markdown" ? "Copied Markdown" : "Copied text")
    }

    private func writeClipboard(_ text: String, title: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(trimmed, forType: .string)
        NotificationHelper.sendStatus("\u{2705} \(title)", subtitle: String(trimmed.prefix(60)))
    }

    // MARK: - Window + WKWebView

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: defaultColumnWidth, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1.0)
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.appearance = NSAppearance(named: .darkAqua)
        window.title = "GroqTalk"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.minSize = NSSize(width: minColumnWidth, height: minColumnHeight)
        window.setFrameAutosaveName(Self.frameAutosaveName)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "tts")

        let webView = WKWebView(frame: NSRect(origin: .zero, size: window.frame.size), configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")
        window.contentView?.addSubview(webView)
        webView.loadHTMLString(Self.htmlTemplate, baseURL: nil)

        self.window = window
        self.webView = webView

        if localKeyMonitor == nil {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, NSApp.keyWindow === window else { return event }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
                    return event
                }
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "f", "r":
                    self.onRecordToggle?()
                    return nil
                default:
                    return event
                }
            }
        }
    }

    // MARK: - JS Bridge

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }

        let handlers: [String: ([String: Any]) -> Void] = [
            "jump": { [weak self] body in
                if let index = body["index"] as? Int {
                    Log.info("[DIALOG] JS jump \(index)")
                    self?.onChunkTap?(index)
                }
            },
            "jumpWord": { [weak self] body in
                if let index = body["index"] as? Int,
                   let wordIndex = body["wordIndex"] as? Int {
                    Log.info("[DIALOG] JS jumpWord chunk=\(index) word=\(wordIndex)")
                    self?.onWordTap?(index, wordIndex)
                }
            },
            "close": { [weak self] _ in
                Log.info("[DIALOG] JS close")
                self?.onClose?()
            },
            "pause": { [weak self] _ in
                Log.info("[DIALOG] JS pause toggle")
                self?.onPauseToggle?()
            },
            "record": { [weak self] _ in
                Log.info("[DIALOG] JS record toggle")
                self?.onRecordToggle?()
            },
            "copyChunk": { [weak self] body in
                if let index = body["index"] as? Int { self?.copyChunk(index) }
            },
            "copyAll": { [weak self] body in
                let mode = body["mode"] as? String ?? "plain"
                self?.copyAll(mode: mode)
            },
            "voiceMenu": { [weak self] body in
                if let index = body["index"] as? Int {
                    self?.showVoiceMenu(forChunk: index)
                }
            },
        ]
        handlers[action]?(body)
    }

    @objc private func handleVoiceMenuSelection(_ sender: NSMenuItem) {
        guard let voice = sender.representedObject as? String,
              let chunkIndex = pendingVoiceChunkIndex else { return }
        onChunkVoiceSelect?(chunkIndex, voice)
    }

    private func showVoiceMenu(forChunk index: Int) {
        guard let window,
              let contentView = window.contentView,
              let provider = voiceOptionsProvider else { return }

        let options = provider()
        guard !options.voices.isEmpty else { return }

        let menu = NSMenu(title: "Replay Voice")
        for voice in options.voices {
            let item = NSMenuItem(title: voice, action: #selector(handleVoiceMenuSelection(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = voice
            item.state = voice == options.current ? .on : .off
            menu.addItem(item)
        }

        pendingVoiceChunkIndex = index
        let screenPoint = NSEvent.mouseLocation
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let localPoint = contentView.convert(windowPoint, from: nil)
        menu.popUp(positioning: nil, at: localPoint, in: contentView)
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onClose?()
        return false
    }

    func windowDidMiniaturize(_ notification: Notification) {
        promoteAppForWindowing()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        promoteAppForWindowing()
    }

    // MARK: - HTML

    private static let htmlTemplate = """
    <!DOCTYPE html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1"><style>
    :root{
      --bg-panel:#171615;
      --bg-elevated:#242220;
      --bg-card:rgba(255,248,232,.045);
      --bg-card-hover:rgba(255,248,232,.075);
      --text-body:rgba(238,234,226,.88);
      --text-active:rgba(245,243,238,1);
      --text-done:rgba(238,234,226,.34);
      --text-muted:rgba(238,234,226,.56);
      --accent:#F0B35B;
      --accent-soft:rgba(240,179,91,.16);
      --accent-question:#7FB7F0;
      --accent-code:#8ED4A8;
      --accent-list:#D9CA83;
      --accent-table:#B9A8F3;
      --rule:rgba(238,234,226,.11);
      --entity-person:#FFD08A;
      --entity-place:#9BD1FF;
      --entity-organization:#E2B1FF;
      --number:#F4D675;
      --caps:#FF9A7A;
      --link:#8EC6FF;
      --link-hover:#D6ECFF;
      --link-rule:rgba(142,198,255,.40);
      --link-bg:rgba(142,198,255,.12);
      --shadow:0 18px 54px rgba(0,0,0,.28);
    }
    *{box-sizing:border-box;margin:0;padding:0}
    html,body{background:
      radial-gradient(circle at 18% -8%,rgba(240,179,91,.18),transparent 34%),
      radial-gradient(circle at 120% 15%,rgba(127,183,240,.12),transparent 30%),
      linear-gradient(180deg,#1d1b19 0%,var(--bg-panel) 44%,#121110 100%);
      font-family:"Iowan Old Style","Charter","Georgia",ui-serif,serif;
      font-size:20px;line-height:1.55;letter-spacing:.005em;
      color:var(--text-body);
      padding:56px 28px 86px;overflow-y:auto;overflow-x:hidden;
      -webkit-font-smoothing:antialiased;user-select:none;cursor:default}
    body::-webkit-scrollbar{width:0}
    #content{max-width:58ch;margin:0 auto;padding:2px 0}

    /* Chunks are quiet cards: readable as prose, but structured enough to scan. */
    .chunk{display:block;position:relative;margin:1.05em 0;padding:18px 62px 18px 50px;
      border:1px solid transparent;border-left:3px solid transparent;border-radius:18px;
      background:transparent;box-shadow:none;
      transition:color 180ms ease,border-color 180ms ease,background 180ms ease,box-shadow 180ms ease,transform 180ms ease}
    .chunk.enabled{cursor:pointer}
    .chunk.enabled:hover{color:var(--text-active);background:var(--bg-card-hover);border-color:var(--rule)}
    .chunk.disabled{color:var(--text-done)}
    .chunk.active{color:var(--text-active);border-color:rgba(240,179,91,.24);border-left-color:var(--accent);
      background:linear-gradient(135deg,rgba(240,179,91,.13),rgba(255,248,232,.045) 42%,rgba(0,0,0,.08));
      box-shadow:var(--shadow);transform:translateY(-1px)}
    .chunk.question{border-left-color:rgba(127,183,240,.38)}
    .chunk.question.active{border-color:rgba(127,183,240,.28);border-left-color:var(--accent-question);
      background:linear-gradient(135deg,rgba(127,183,240,.16),rgba(255,248,232,.045) 48%,rgba(0,0,0,.08))}
    .chunk.done{color:var(--text-done);transition:color 220ms ease}
    .finished .chunk{color:var(--text-body);border-left-color:transparent}
    .chunk-body{position:relative;white-space:normal;overflow-wrap:break-word;word-break:normal}
    .chunk-index{position:absolute;left:18px;top:20px;
      font-family:-apple-system,"SF Pro Text",system-ui,sans-serif;font-size:11px;font-weight:700;
      color:rgba(238,234,226,.42);letter-spacing:.08em}
    .chunk-kind{position:absolute;right:42px;top:-9px;height:18px;padding:0 8px;border-radius:999px;
      font-family:-apple-system,"SF Pro Text",system-ui,sans-serif;font-size:9px;font-weight:700;line-height:18px;
      letter-spacing:.08em;text-transform:uppercase;color:rgba(255,255,255,.72);
      background:rgba(255,255,255,.08);border:1px solid rgba(255,255,255,.08);opacity:0}
    .chunk.active .chunk-kind,.chunk:hover .chunk-kind{opacity:1}
    .chunk.question .chunk-kind{background:rgba(127,183,240,.16);border-color:rgba(127,183,240,.22);color:#CFE7FF}
    .chunk.code-chunk .chunk-kind{background:rgba(142,212,168,.14);border-color:rgba(142,212,168,.20);color:#CFF6DA}
    .chunk.list-item .chunk-kind{background:rgba(217,202,131,.14);border-color:rgba(217,202,131,.20);color:#F4E6A6}
    .chunk.table-row .chunk-kind,.chunk.table-header .chunk-kind{background:rgba(185,168,243,.15);border-color:rgba(185,168,243,.22);color:#E4DBFF}

    .chunk-copy,.chunk-voice{position:absolute;top:2px;width:26px;height:26px;border:none;border-radius:50%;
      background:rgba(255,255,255,.06);color:var(--text-muted);opacity:0;cursor:pointer;
      transition:opacity 140ms ease,background 140ms ease,color 140ms ease;font-size:12px;line-height:26px}
    .chunk-copy{right:0}
    .chunk-voice{right:32px}
    .chunk:hover .chunk-copy,.chunk.active .chunk-copy,.chunk:hover .chunk-voice,.chunk.active .chunk-voice{opacity:1}
    .chunk-copy:hover,.chunk-voice:hover{background:rgba(255,255,255,.14);color:var(--text-active)}
    .word-jump{
      display:inline;white-space:normal;cursor:pointer;border-radius:6px;padding:0 1px;
      transition:background 120ms ease,color 120ms ease,box-shadow 120ms ease
    }
    .word-jump.active-word{
      color:var(--text-active);background:rgba(240,179,91,.16);
      box-shadow:inset 0 -1px rgba(240,179,91,.34),0 0 0 1px rgba(240,179,91,.14)
    }
    .word-jump:hover{
      color:var(--text-active);background:rgba(240,179,91,.12);
      box-shadow:inset 0 -1px rgba(240,179,91,.28)
    }

    /* Markdown */
    strong{color:var(--text-active);font-weight:600}
    em{font-style:italic}
    h1,h2,h3{font-family:-apple-system,"SF Pro Text",system-ui,sans-serif;
      line-height:1.25;color:var(--text-active)}
    h1{font-size:28px;font-weight:600;margin:1.6em 0 .5em}
    h2{font-size:22px;font-weight:600;margin:1.4em 0 .4em}
    h3{font-size:18px;font-weight:600;margin:1.2em 0 .3em;color:var(--text-muted)}
    code{font-family:"SF Mono","JetBrains Mono",ui-monospace,monospace;
      font-size:.88em;background:rgba(142,212,168,.10);color:#CFF6DA;
      padding:2px 6px;border-radius:6px;border:1px solid rgba(142,212,168,.13)}
    pre{background:var(--bg-elevated);padding:14px 16px;border-radius:8px;
      overflow-x:auto;margin:1em 0}
    pre code{display:block;font-size:14px;line-height:1.5;padding:0;background:transparent}
    blockquote{border-left:2px solid var(--rule);padding-left:14px;
      color:var(--text-muted);font-style:italic;margin:1em 0}
    ul,ol{padding-left:1.4em;margin:.8em 0}
    li{margin:.25em 0}
    hr{border:0;border-top:1px solid var(--rule);margin:1.6em 0}
    a.doc-link{
      color:var(--link);text-decoration:none;border-bottom:1px solid var(--link-rule);
      font-family:-apple-system,"SF Pro Text",system-ui,sans-serif;font-size:.92em;font-weight:500;
      line-height:1.35;word-break:break-word;overflow-wrap:anywhere;
      transition:color 120ms ease,border-color 120ms ease,background 120ms ease;box-decoration-break:clone;-webkit-box-decoration-break:clone}
    a.doc-link:hover{color:var(--link-hover);border-bottom-color:rgba(207,226,255,.58);
      background:var(--link-bg);border-radius:4px}
    a.doc-link:focus-visible{outline:1px solid var(--link-rule);outline-offset:2px;border-radius:4px}

    /* Table rendering (pipe / box input converted to real tables). */
    .table-wrap{overflow-x:auto;margin:1em 0}
    table{border-collapse:collapse;font-size:.92em;font-family:-apple-system,system-ui,sans-serif}
    th,td{padding:6px 12px;border-bottom:1px solid var(--rule);text-align:left}
    th{color:var(--text-active);font-weight:600}

    /* Smart styling */
    .entity{font-weight:650;border-radius:7px;padding:0 4px;box-decoration-break:clone;-webkit-box-decoration-break:clone}
    .entity-person{color:var(--entity-person);background:rgba(255,208,138,.10)}
    .entity-place{color:var(--entity-place);background:rgba(155,209,255,.10)}
    .entity-organization{color:var(--entity-organization);background:rgba(226,177,255,.10)}
    .first-mention{font-weight:800;color:var(--text-active);box-shadow:inset 0 -1px rgba(255,255,255,.22)}
    .quoted-speech{font-style:italic;color:var(--text-active)}
    .number-highlight{color:var(--number);font-weight:650;background:rgba(244,214,117,.10);border-radius:6px;padding:0 3px}
    .auto-code{font-family:"SF Mono","JetBrains Mono",ui-monospace,monospace;
      font-size:.88em;background:rgba(255,255,255,.05);padding:1px 5px;border-radius:4px}
    .all-caps{color:var(--caps);font-weight:700;letter-spacing:.04em}

    /* Special chunk types stay readable while adding scan-friendly cues. */
    .chunk.header-chunk{font-family:-apple-system,"SF Pro Text",system-ui,sans-serif;
      font-size:22px;font-weight:700;color:var(--text-muted);background:rgba(255,255,255,.035)}
    .chunk.header-chunk.active{color:var(--text-active)}
    .chunk.code-chunk{font-family:"SF Mono","JetBrains Mono",ui-monospace,monospace;
      font-size:14px;background:linear-gradient(135deg,rgba(142,212,168,.11),rgba(255,255,255,.035));
      padding:18px 62px 18px 50px;border-radius:18px;white-space:pre-wrap;line-height:1.5}
    .chunk.list-item{padding-left:54px;position:relative;margin-left:0}
    .chunk.list-item::before{content:'\\2022';position:absolute;left:28px;top:18px;color:var(--accent-list);opacity:.9}
    .kv-row{display:flex;gap:10px;padding:3px 0;align-items:baseline}
    .kv-key{color:var(--accent);font-weight:600;font-size:.82em;text-transform:uppercase;
      letter-spacing:.5px;min-width:60px;flex-shrink:0}
    .kv-val{color:var(--text-body);min-width:0;flex:1}

    /* Controls behave more like a native toolbar cluster. */
    .top-controls{position:fixed;top:14px;left:14px;display:flex;gap:6px;z-index:100;
      padding:5px;border-radius:999px;background:rgba(10,10,10,.26);backdrop-filter:blur(18px);
      border:1px solid rgba(255,255,255,.08)}
    .ctrl-btn{height:28px;border-radius:999px;border:none;
      background:rgba(255,255,255,.06);color:var(--text-muted);
      font-size:11px;line-height:28px;text-align:center;cursor:pointer;
      transition:all 120ms ease;padding:0 10px;font-family:-apple-system,system-ui,sans-serif}
    .ctrl-btn.icon{width:28px;padding:0;border-radius:50%;font-size:13px}
    .ctrl-btn:hover{background:rgba(255,255,255,.14);color:var(--text-active)}

    .error{color:#fca5a5;font-weight:500;text-align:center;padding:20px;
      font-family:-apple-system,system-ui,sans-serif}

    #progressWrap{position:fixed;bottom:12px;left:50%;transform:translateX(-50%);
      display:flex;flex-direction:column;gap:8px;align-items:center;z-index:90}
    #progressLabel{font-family:-apple-system,system-ui,sans-serif;font-size:12px;color:var(--text-muted);
      padding:5px 10px;border-radius:999px;background:rgba(10,10,10,.22);border:1px solid rgba(255,255,255,.07)}

    /* Thin amber progress bar across the bottom — peripheral, non-clinical. */
    #prog{height:3px;width:188px;background:var(--rule);border-radius:999px;overflow:hidden}
    #prog::after{content:'';display:block;height:100%;width:var(--p,0%);
      background:var(--accent);border-radius:1px;transition:width 220ms ease}

    /* Respect macOS Reduce Motion + Increase Contrast. */
    @media (prefers-reduced-motion: reduce){
      .chunk,.chunk.done,#prog::after,.chunk-copy,.ctrl-btn{transition:none!important}
      html{scroll-behavior:auto}
    }
    @media (prefers-contrast: more){
      :root{--text-body:rgba(245,243,238,.96);--rule:rgba(232,230,225,.25)}
    }
    </style></head><body>
    <div class="top-controls">
      <button class="ctrl-btn" onclick="post('record')" title="Record / stop recording (F or Fn)">Rec</button>
      <button class="ctrl-btn" onclick="copyAll(event,'plain')" title="Copy all plain text">Copy</button>
      <button class="ctrl-btn" onclick="copyAll(event,'markdown')" title="Copy all Markdown">MD</button>
      <button class="ctrl-btn icon" id="pauseBtn" onclick="post('pause')" title="Pause/Resume (Ctrl+Option)">&#9208;</button>
    </div>
    <div id="content"></div>
    <div id="progressWrap">
      <div id="progressLabel"></div>
      <div id="prog"></div>
    </div>
    <script>
    const BOX=/[\\u2500-\\u257F]/, VBAR='\\u2502', ARROW='\\u2192';
    const post=(action,extra)=>window.webkit.messageHandlers.tts.postMessage(Object.assign({action},extra||{}));
    const esc=s=>s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
    const escAttr=s=>String(s).replace(/&/g,'&amp;').replace(/"/g,'&quot;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
    const normalizeKey=s=>s.toLocaleLowerCase().replace(/[^a-z0-9]+/g,' ').trim();
    const addQuoteEmphasis=html=>html.replace(/([“"])([^“”"\\n]+)([”"])/g,'$1<em class="quoted-speech">$2</em>$3');
    const inlineMarkup=s=>addQuoteEmphasis(
      esc(s)
        .replace(/`([^`]+)`/g,'<code>$1</code>')
        .replace(/\\*\\*([^*]+)\\*\\*/g,'<strong>$1</strong>')
        .replace(/\\*([^*]+)\\*/g,'<em>$1</em>')
    );
    function renderDocLink(label,target){
      const cleanLabel=(label||'').trim();
      const cleanTarget=(target||'').trim();
      return '<a class="doc-link" href="'+escAttr(cleanTarget)+'" title="'+escAttr(cleanTarget)+'">'+inlineMarkup(cleanLabel)+'</a>';
    }
    function stashMarkdownLinks(s){
      const links=[];
      const text=s.replace(/\\[([^\\]]+)\\]\\(([^)\\n]+)\\)/g,(_,label,target)=>{
        const idx=links.push(renderDocLink(label,target))-1;
        return '\\u0001LINK'+idx+'\\u0002';
      });
      return {text,links};
    }
    function restoreMarkdownLinks(html,links){
      return html.replace(/\\u0001LINK(\\d+)\\u0002/g,(_,idx)=>links[Number(idx)]||'');
    }
    const inlineMd=s=>{
      const stashed=stashMarkdownLinks(s);
      return restoreMarkdownLinks(inlineMarkup(stashed.text),stashed.links);
    };
    const nonEmpty=s=>s.split('\\n').filter(l=>l.trim());
    function isPipeTable(s){const ls=nonEmpty(s);return ls.length>=2 && ls.filter(l=>l.indexOf('|')>=0).length>=2;}
    // Only fire when EVERY line is "Key: value" and there are at least 2 lines.
    // A single "Note: something" line in prose should not be styled as KV.
    function isKVChunk(s){const ls=nonEmpty(s);if(ls.length<2)return false;
      return ls.every(l=>/^[^:]{1,40}: .+/.test(l.trim()));}
    // Only fire on a SINGLE-LINE chunk whose tokens between `sep` are all
    // short labels (no sentence prose). Used to detect "A → B → C" rows
    // without misclassifying sentences that happen to contain a → mid-text.
    function isTokenRow(s,sep){const t=s.trim();
      if(t.indexOf('\\n')>=0)return false;
      const parts=t.split(sep).map(p=>p.trim()).filter(Boolean);
      if(parts.length<2)return false;
      return parts.every(p=>p.length<=28 && !/[.!?]/.test(p));}
    function renderPipeTable(s){const ls=nonEmpty(s);let html='<div class="table-wrap"><table>',hdrDone=false;
      for(let i=0;i<ls.length;i++){const line=ls[i].trim();
        if(/^[|\\s:\\-]+$/.test(line)){hdrDone=true;continue;}
        const cells=line.split('|').map(c=>c.trim()).filter(Boolean);
        const tag=(!hdrDone&&i===0)?'th':'td';
        html+='<tr>'+cells.map(c=>'<'+tag+'>'+inlineMd(c)+'</'+tag+'>').join('')+'</tr>';}
      return html+'</table></div>';}
    function renderKV(s){return nonEmpty(s).map(l=>{const i=l.indexOf(': ');if(i<0)return '<div>'+esc(l)+'</div>';
      return '<div class="kv-row"><span class="kv-key">'+esc(l.substring(0,i).trim())+'</span><span class="kv-val">'+inlineMd(l.substring(i+2).trim())+'</span></div>';}).join('');}
    function renderArrowRow(s){const p=s.split(ARROW).map(x=>x.trim());
      return '<div class="kv-row"><span class="kv-key" style="text-transform:none;font-size:1em;">'+inlineMd(p[0])+'</span><span class="kv-val">'+inlineMd(p.slice(1).join(' '+ARROW+' '))+'</span></div>';}
    function md(s){
      if(/^[-*] /.test(s.trim())||/^\\d{1,3}[\\.\\)] /.test(s.trim()))s=s.trim().replace(/^[-*]\\s+/,'').replace(/^\\d{1,3}[\\.\\)]\\s+/,'');
      if(BOX.test(s))return '<pre><code>'+s.replace(/&/g,'&amp;').replace(/</g,'&lt;')+'</code></pre>';
      if(isPipeTable(s))return renderPipeTable(s);
      if(isKVChunk(s))return renderKV(s);
      if(isTokenRow(s,VBAR))return esc(s).replace(/\\u2502/g,'<span style="opacity:0.3;margin:0 8px;">|</span>');
      if(isTokenRow(s,ARROW))return renderArrowRow(s);
      const stashed=stashMarkdownLinks(s);
      const html=esc(stashed.text)
        .replace(/^### (.+)$/gm,'<h3>$1</h3>').replace(/^## (.+)$/gm,'<h2>$1</h2>').replace(/^# (.+)$/gm,'<h1>$1</h1>')
        .replace(/```[\\s\\S]*?```/g,m=>'<pre><code>'+m.slice(3,-3).trim()+'</code></pre>')
        .replace(/`([^`]+)`/g,'<code>$1</code>').replace(/\\*\\*([^*]+)\\*\\*/g,'<strong>$1</strong>').replace(/\\*([^*]+)\\*/g,'<em>$1</em>').replace(/\\n/g,'<br>');
      return restoreMarkdownLinks(addQuoteEmphasis(html),stashed.links);
    }
    function chunkType(c){const t=c.trim();
      if(isKVChunk(t))return 'table-row';
      if(isTokenRow(t,VBAR))return 'table-header';
      if(isTokenRow(t,ARROW))return 'table-row';
      if(/^#{1,3} /.test(t))return 'header-chunk';
      if(/^[-*] /.test(t)||/^\\d{1,3}[\\.\\)] /.test(t))return 'list-item';
      if(t.startsWith('```'))return 'code-chunk';
      return '';}

    function chunkKindLabel(ct,chunk){
      if(chunk.isQuestion)return 'Question';
      if(ct==='header-chunk')return 'Heading';
      if(ct==='code-chunk')return 'Code';
      if(ct==='list-item')return 'List';
      if(ct==='table-row'||ct==='table-header')return 'Data';
      return '';
    }

    function chunkIndexLabel(i){
      return String(i+1).padStart(2,'0');
    }

    function isBoundary(text,start,end){
      const before=start<=0?' ':text[start-1];
      const after=end>=text.length?' ':text[end];
      return !/[A-Za-z0-9]/.test(before)&&!/[A-Za-z0-9]/.test(after);
    }

    function collectRegexMatches(text,regex,className,priority,matches){
      regex.lastIndex=0;
      let match;
      while((match=regex.exec(text))!==null){
        const start=match.index;
        const end=start+match[0].length;
        matches.push({start,end,className,priority});
        if(match.index===regex.lastIndex)regex.lastIndex++;
      }
    }

    function collectPhraseMatches(text,chunk,matches){
      const firstSet=new Set((chunk.firstMentions||[]).map(normalizeKey));
      const entities=(chunk.entities||[]).slice().sort((a,b)=>b.text.length-a.text.length);
      const haystack=text.toLocaleLowerCase();
      entities.forEach(entity=>{
        const needle=entity.text.toLocaleLowerCase();
        if(!needle)return;
        let cursor=0;
        while(true){
          const idx=haystack.indexOf(needle,cursor);
          if(idx<0)break;
          const end=idx+needle.length;
          if(isBoundary(text,idx,end)){
            const classes=['entity','entity-'+entity.kind];
            if(firstSet.has(normalizeKey(entity.text)))classes.push('first-mention');
            matches.push({start:idx,end,className:classes.join(' '),priority:100});
          }
          cursor=end;
        }
      });
    }

    function resolveMatches(matches){
      const accepted=[];
      matches.sort((a,b)=>(b.priority-a.priority)||((b.end-b.start)-(a.end-a.start))||(a.start-b.start));
      matches.forEach(match=>{
        const overlaps=accepted.some(other=>Math.max(other.start,match.start)<Math.min(other.end,match.end));
        if(!overlaps)accepted.push(match);
      });
      return accepted.sort((a,b)=>a.start-b.start);
    }

    function styleText(text,chunk){
      const matches=[];
      collectPhraseMatches(text,chunk,matches);
      collectRegexMatches(text,/(?:\\bv?\\d+(?:\\.\\d+){1,}\\b)|(?:\\b[a-z]+(?:[A-Z][a-z0-9]+)+\\b)|(?:\\b[a-z0-9]+_[a-z0-9_]+\\b)/g,'auto-code',80,matches);
      collectRegexMatches(text,/(?:[$€£₹]\\d[\\d,]*(?:\\.\\d+)?)|(?:\\b\\d{1,2}:\\d{2}\\s?(?:AM|PM)?\\b)|(?:\\b\\d[\\d,]*(?:\\.\\d+)?(?:\\s?(?:ms|s|m|h|days?|people|users?|GB|MB|KB|%))?\\b)/g,'number-highlight',60,matches);
      collectRegexMatches(text,/\\b[A-Z]{3,}\\b/g,'all-caps',40,matches);
      const resolved=resolveMatches(matches);
      if(!resolved.length)return esc(text);
      let out='',cursor=0;
      resolved.forEach(match=>{
        out+=esc(text.slice(cursor,match.start));
        out+='<span class="'+match.className+'">'+esc(text.slice(match.start,match.end))+'</span>';
        cursor=match.end;
      });
      out+=esc(text.slice(cursor));
      return out;
    }

    function decorateChunk(el,chunk){
      const root=el.querySelector('.chunk-body')||el;
      const walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT,{
        acceptNode(node){
          if(!node.nodeValue||!node.nodeValue.trim())return NodeFilter.FILTER_REJECT;
          const parent=node.parentElement;
          if(!parent)return NodeFilter.FILTER_REJECT;
          if(parent.closest('code, pre, a'))return NodeFilter.FILTER_REJECT;
          return NodeFilter.FILTER_ACCEPT;
        }
      });
      const nodes=[];
      let node;
      while((node=walker.nextNode()))nodes.push(node);
      nodes.forEach(textNode=>{
        const styled=styleText(textNode.nodeValue,chunk);
        if(styled===esc(textNode.nodeValue))return;
        const span=document.createElement('span');
        span.innerHTML=styled;
        textNode.replaceWith(...span.childNodes);
      });
    }

    function makeWordsClickable(el,chunkIndex){
      const root=el.querySelector('.chunk-body')||el;
      const walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT,{
        acceptNode(node){
          if(!node.nodeValue||!node.nodeValue.trim())return NodeFilter.FILTER_REJECT;
          const parent=node.parentElement;
          if(!parent)return NodeFilter.FILTER_REJECT;
          if(parent.closest('code, pre, button, .word-jump'))return NodeFilter.FILTER_REJECT;
          return NodeFilter.FILTER_ACCEPT;
        }
      });
      const nodes=[];
      let node;
      while((node=walker.nextNode()))nodes.push(node);

      let wordIndex=0;
      nodes.forEach(textNode=>{
        const pieces=textNode.nodeValue.split(/(\\s+)/);
        const fragment=document.createDocumentFragment();
        let changed=false;

        pieces.forEach(piece=>{
          if(!piece)return;
          if(/^\\s+$/.test(piece)){
            fragment.appendChild(document.createTextNode(piece));
            return;
          }
          changed=true;
          const currentWord=wordIndex++;
          const span=document.createElement('span');
          span.className='word-jump';
          span.dataset.wordIndex=String(currentWord);
          span.textContent=piece;
          span.title='Speak from here';
          span.addEventListener('click',event=>{
            event.preventDefault();
            event.stopPropagation();
            post('jumpWord',{index:chunkIndex,wordIndex:currentWord});
          });
          fragment.appendChild(span);
        });

        if(changed)textNode.replaceWith(fragment);
      });
    }

    let activeIdx=-1;
    let activeWordEl=null;
    let currentPayload={chunks:[],playbackRate:1};
    const enabledSet=new Set();

    function estimateSeconds(words,rate){
      const wpm=165*Math.max(0.75,rate||1);
      return words/(wpm/60);
    }

    function formatEta(seconds){
      if(seconds<=10)return 'almost done';
      if(seconds<60)return 'about '+(Math.max(5,Math.round(seconds/5)*5))+' sec left';
      if(seconds<90)return 'about 1 min left';
      return 'about '+Math.round(seconds/60)+' min left';
    }

    function updateProgressLabel(i){
      const label=document.getElementById('progressLabel');
      if(!label)return;
      const total=currentPayload.chunks.length;
      if(!total){label.textContent='';return;}
      if(i<0){
        const totalWords=currentPayload.chunks.reduce((sum,chunk)=>sum+(chunk.words||0),0);
        label.textContent=total+' paragraphs · '+formatEta(estimateSeconds(totalWords,currentPayload.playbackRate));
        return;
      }
      const current=Math.max(0,Math.min(i,total-1));
      const remainingWords=currentPayload.chunks.slice(current+1).reduce((sum,chunk)=>sum+(chunk.words||0),0);
      label.textContent='paragraph '+(current+1)+' of '+total+' · '+formatEta(estimateSeconds(remainingWords,currentPayload.playbackRate));
    }

    function loadChunks(payload){
      currentPayload=payload||{chunks:[],playbackRate:1};
      const el=document.getElementById('content');
      el.className='';
      enabledSet.clear();
      activeIdx=-1;
      activeWordEl=null;
      el.innerHTML=currentPayload.chunks.map((chunk,i)=>{
        const ct=chunkType(chunk.markdown);
        const question=chunk.isQuestion?' question':'';
        const kind=chunkKindLabel(ct,chunk);
        const kindBadge=kind?'<span class="chunk-kind">'+kind+'</span>':'';
        return '<div class="chunk disabled'+(ct?' '+ct:'')+question+'" data-i="'+i+'" onclick="tryJump('+i+')"><span class="chunk-index">'+chunkIndexLabel(i)+'</span>'+kindBadge+'<button class="chunk-voice" onclick="openVoiceMenu(event,'+i+')" title="Replay paragraph with a different voice">&#128266;</button><button class="chunk-copy" onclick="copyChunk(event,'+i+')" title="Copy paragraph">&#10697;</button><div class="chunk-body">'+md(chunk.markdown)+'</div></div>';
      }).join('');
      currentPayload.chunks.forEach((chunk,i)=>{
        const node=document.querySelector('[data-i="'+i+'"]');
        if(node){
          decorateChunk(node,chunk);
          makeWordsClickable(node,i);
        }
      });
      updateProgressLabel(-1);
      const prog=document.getElementById('prog');
      if(prog)prog.style.setProperty('--p','0%');
    }

    function enableChunk(i){
      enabledSet.add(i);
      const el=document.querySelector('[data-i="'+i+'"]');
      if(el){el.classList.remove('disabled');el.classList.add('enabled');}
    }

    function highlight(i){
      clearActiveWord();
      document.querySelectorAll('.chunk.active').forEach(e=>e.classList.remove('active'));
      const all=document.querySelectorAll('.chunk');
      all.forEach(e=>{
        const idx=parseInt(e.dataset.i,10);
        if(idx<i){e.classList.add('done');e.classList.remove('disabled');e.classList.add('enabled');}
        else e.classList.remove('done');
      });
      const el=document.querySelector('[data-i="'+i+'"]');
      if(el){
        el.classList.add('active');
        el.classList.remove('disabled');
        el.classList.add('enabled');
        const sm=matchMedia('(prefers-reduced-motion: reduce)').matches?'auto':'smooth';
        el.scrollIntoView({behavior:sm,block:'center'});
      }
      const total=Math.max(1,all.length);
      const prog=document.getElementById('prog');
      if(prog)prog.style.setProperty('--p',(((i+1)/total)*100)+'%');
      updateProgressLabel(i);
      activeIdx=i;
    }

    function clearActiveWord(){
      if(activeWordEl){
        activeWordEl.classList.remove('active-word');
        activeWordEl=null;
      }
    }

    function highlightWord(chunkIndex,wordIndex){
      const selector='[data-i="'+chunkIndex+'"] .word-jump[data-word-index="'+wordIndex+'"]';
      const next=document.querySelector(selector);
      if(!next)return;
      if(activeWordEl===next)return;
      clearActiveWord();
      next.classList.add('active-word');
      activeWordEl=next;
    }

    function finished(){
      clearActiveWord();
      document.querySelectorAll('.chunk.active').forEach(e=>e.classList.remove('active'));
      document.querySelectorAll('.chunk.done').forEach(e=>e.classList.remove('done'));
      document.querySelectorAll('.chunk.disabled').forEach(e=>{e.classList.remove('disabled');e.classList.add('enabled');});
      document.getElementById('content').classList.add('finished');
      document.getElementById('progressLabel').textContent='Done · '+currentPayload.chunks.length+' paragraphs';
      const prog=document.getElementById('prog');
      if(prog)prog.style.setProperty('--p','100%');
    }

    function showError(msg){
      clearActiveWord();
      document.getElementById('content').innerHTML='<div class="error">\\u26A0\\uFE0F  '+msg+'</div>';
      document.getElementById('progressLabel').textContent='Playback error';
    }

    function tryJump(i){
      if(!enabledSet.has(i)&&i>activeIdx)return;
      post('jump',{index:i});
    }

    function setPaused(paused){
      const btn=document.getElementById('pauseBtn');
      if(btn)btn.innerHTML=paused?'&#9654;':'&#9208;';
    }

    function copyChunk(event,index){
      event.stopPropagation();
      post('copyChunk',{index});
    }

    function copyAll(event,mode){
      event.stopPropagation();
      post('copyAll',{mode});
    }

    function openVoiceMenu(event,index){
      event.stopPropagation();
      post('voiceMenu',{index});
    }

    document.addEventListener('click',e=>{
      const link=e.target.closest('a.doc-link');
      if(link){
        e.preventDefault();
        e.stopPropagation();
      }
    });

    document.addEventListener('keydown',e=>{
      if((e.key==='f'||e.key==='F'||e.key==='r'||e.key==='R')&&!e.metaKey&&!e.ctrlKey&&!e.altKey){
        e.preventDefault();
        post('record');
      }else if(e.key==='ArrowDown'||e.key==='ArrowRight'||e.key==='n'){
        e.preventDefault();
        const next=activeIdx+1;
        if(next<document.querySelectorAll('.chunk').length&&enabledSet.has(next))post('jump',{index:next});
      }else if(e.key==='ArrowUp'||e.key==='ArrowLeft'||e.key==='p'){
        e.preventDefault();
        if(activeIdx-1>=0)post('jump',{index:activeIdx-1});
      }else if(e.key==='Escape'){post('close');}
      else if(e.key===' '){e.preventDefault();post('pause');}
    });
    </script></body></html>
    """
}
