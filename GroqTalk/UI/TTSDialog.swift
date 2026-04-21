import AppKit
import WebKit

final class TTSDialog: NSObject, WKScriptMessageHandler {
    static let shared = TTSDialog()

    var onChunkTap: ((Int) -> Void)?
    var onClose: (() -> Void)?
    var onPauseToggle: (() -> Void)?

    private var panel: NSPanel?
    private var webView: WKWebView?
    private var fadeOutWorkItem: DispatchWorkItem?

    private let panelWidth: CGFloat = 640
    private let corner: CGFloat = 18

    // MARK: - Public API

    func show(text: String, chunks: [String]) {
        Log.info("[DIALOG] show (\(text.count) chars, \(chunks.count) chunks)")
        DispatchQueue.main.async { [weak self] in self?.showOnMain(chunks) }
    }

    func enableChunk(_ index: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript("enableChunk(\(index))", completionHandler: nil)
        }
    }

    func setPaused(_ paused: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript("setPaused(\(paused))", completionHandler: nil)
        }
    }

    func setActiveChunk(_ index: Int) {
        Log.debug("[DIALOG] setActiveChunk \(index)")
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript("highlight(\(index))", completionHandler: nil)
        }
    }

    /// Supply word-level timestamps (from whisper.cpp `verbose_json`) for a
    /// specific TTS chunk. The dialog will karaoke-highlight words matching
    /// the current playhead once `setChunkPlayhead` is being called for that
    /// chunk.
    func setChunkWords(_ index: Int, words: [WordAligner.Word]) {
        let payload = words.map { ["t": $0.text, "s": $0.start, "e": $0.end] as [String: Any] }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(
                "setChunkWords(\(index), \(jsonString))", completionHandler: nil)
        }
    }

    /// Tell the dialog the current playback position (seconds) for the
    /// active chunk. Call this at ~15 Hz from Swift while the chunk plays;
    /// the page will flip the `.word-active` class to the matching word.
    func setChunkPlayhead(_ index: Int, time: TimeInterval) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(
                "setChunkPlayhead(\(index), \(time))", completionHandler: nil)
        }
    }

    func finish() {
        Log.info("[DIALOG] finish")
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript("finished()", completionHandler: nil)
            self?.scheduleFadeOut(after: 1.2)
        }
    }

    func close() {
        Log.info("[DIALOG] close")
        DispatchQueue.main.async { [weak self] in self?.dismissOnMain() }
    }

    func error(_ message: String) {
        Log.info("[DIALOG] error: \(message)")
        DispatchQueue.main.async { [weak self] in
            let escaped = message.replacingOccurrences(of: "'", with: "\\'")
            self?.webView?.evaluateJavaScript("showError('\(escaped)')", completionHandler: nil)
            self?.scheduleFadeOut(after: 2.5)
        }
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    // MARK: - Show / Dismiss

    private func showOnMain(_ chunks: [String]) {
        fadeOutWorkItem?.cancel()

        if panel == nil { buildPanel() }
        guard let panel, let webView else {
            Log.error("[DIALOG] panel missing"); return
        }

        let prettyChunks = chunks.map { TextPrettifier.prettify($0) }
        let jsonData = try? JSONSerialization.data(withJSONObject: prettyChunks)
        let jsonString = String(data: jsonData ?? Data("[]".utf8), encoding: .utf8) ?? "[]"

        webView.evaluateJavaScript("loadChunks(\(jsonString))", completionHandler: nil)

        let lineEstimate = chunks.joined().count / 45
        let screenH = NSScreen.main?.visibleFrame.height ?? 800
        let maxH = screenH * 0.65
        let estimatedH = min(maxH, CGFloat(max(3, lineEstimate)) * 38 + 80)

        var frame = NSRect(x: 0, y: 0, width: panelWidth, height: estimatedH)
        if let v = NSScreen.main?.visibleFrame {
            frame.origin = NSPoint(x: v.midX - panelWidth / 2, y: v.midY - estimatedH / 2 + 60)
        }
        panel.setFrame(frame, display: true)
        webView.frame = panel.contentView!.bounds

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
        }
    }

    private func dismissOnMain() {
        fadeOutWorkItem?.cancel()
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
        })
    }

    private func scheduleFadeOut(after t: TimeInterval) {
        let w = DispatchWorkItem { [weak self] in self?.dismissOnMain() }
        fadeOutWorkItem = w
        DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: w)
    }

    // MARK: - Panel + WKWebView

    private func buildPanel() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = false
        p.acceptsMouseMovedEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.appearance = NSAppearance(named: .darkAqua)

        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "tts")

        let wv = WKWebView(frame: NSRect(origin: .zero, size: p.frame.size), configuration: config)
        wv.autoresizingMask = [.width, .height]
        wv.setValue(false, forKey: "drawsBackground")
        wv.wantsLayer = true
        wv.layer?.cornerRadius = corner
        wv.layer?.masksToBounds = true

        p.contentView?.wantsLayer = true
        p.contentView?.layer?.cornerRadius = corner
        p.contentView?.layer?.masksToBounds = true
        p.contentView?.addSubview(wv)

        wv.loadHTMLString(Self.htmlTemplate, baseURL: nil)

        self.panel = p
        self.webView = wv
    }

    // MARK: - JS Bridge

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }
        switch action {
        case "jump":
            if let index = body["index"] as? Int {
                Log.info("[DIALOG] JS jump \(index)")
                onChunkTap?(index)
            }
        case "close":
            Log.info("[DIALOG] JS close")
            onClose?()
        case "pause":
            Log.info("[DIALOG] JS pause toggle")
            onPauseToggle?()
        default: break
        }
    }

    // MARK: - HTML

    private static let htmlTemplate = """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      * { box-sizing: border-box; margin: 0; padding: 0; }
      html, body {
        background: rgba(38, 40, 48, 0.94);
        font-family: -apple-system, "SF Pro Rounded", "Helvetica Neue", sans-serif;
        font-size: 18px;
        line-height: 1.7;
        color: rgba(255,255,255, 0.55);
        padding: 40px 32px 28px 32px;
        overflow-y: auto;
        overflow-x: hidden;
        -webkit-font-smoothing: antialiased;
        user-select: none;
        cursor: default;
      }
      body::-webkit-scrollbar { width: 0; }

      /* Top controls */
      .top-controls {
        position: fixed;
        top: 10px;
        left: 14px;
        display: flex;
        gap: 6px;
        z-index: 100;
      }
      .ctrl-btn {
        width: 24px;
        height: 24px;
        border-radius: 50%;
        border: none;
        background: rgba(255,255,255, 0.08);
        color: rgba(255,255,255, 0.5);
        font-size: 11px;
        line-height: 24px;
        text-align: center;
        cursor: pointer;
        transition: all 0.12s;
        padding: 0;
      }
      .ctrl-btn:hover {
        background: rgba(255,255,255, 0.18);
        color: #fff;
      }
      .ctrl-btn.close:hover { background: rgba(255,90,90, 0.7); }
      .ctrl-btn.close { font-size: 14px; }

      /* Chunks */
      .chunk {
        border-radius: 6px;
        padding: 4px 8px;
        margin: 2px -8px;
        transition: all 0.15s ease;
        display: block;
      }
      .chunk.enabled {
        cursor: pointer;
      }
      .chunk.enabled:hover {
        background: rgba(255,255,255, 0.06);
      }
      .chunk.disabled {
        opacity: 0.4;
        cursor: default;
      }
      .chunk.active {
        color: #ffffff;
        font-weight: 500;
        background: rgba(196, 181, 253, 0.15);
        border-left: 3px solid rgba(196, 181, 253, 0.7);
        padding-left: 12px;
        opacity: 1;
      }
      .chunk.done {
        color: rgba(255,255,255, 0.72);
        opacity: 1;
      }
      .finished .chunk {
        color: rgba(255,255,255, 0.88);
        font-weight: normal;
        background: none;
        border-left: none;
        padding-left: 8px;
        opacity: 1;
      }

      strong { font-weight: 600; }
      em { font-style: italic; }
      code {
        font-family: "SF Mono", "JetBrains Mono", monospace;
        font-size: 0.88em;
        background: rgba(255,255,255, 0.08);
        padding: 1px 5px;
        border-radius: 4px;
      }
      h1, h2, h3 { color: rgba(255,255,255, 0.9); font-weight: 600; margin-top: 4px; }
      h1 { font-size: 1.4em; } h2 { font-size: 1.2em; } h3 { font-size: 1.05em; }

      pre { overflow-x: auto; margin: 4px 0; }
      pre code {
        display: block;
        padding: 10px 14px;
        font-size: 13px;
        line-height: 1.4;
        white-space: pre;
      }
      .table-wrap {
        overflow-x: auto;
        margin: 6px 0;
        -webkit-overflow-scrolling: touch;
      }
      table {
        min-width: 100%;
        border-collapse: collapse;
        font-size: 15px;
        white-space: nowrap;
      }
      th, td {
        padding: 6px 12px;
        text-align: left;
        border-bottom: 1px solid rgba(255,255,255,0.1);
      }
      th {
        color: rgba(255,255,255,0.85);
        font-weight: 600;
        border-bottom: 2px solid rgba(255,255,255,0.2);
      }

      /* List item chunks */
      .chunk.list-item {
        padding-left: 20px;
        position: relative;
      }
      .chunk.list-item::before {
        content: '\\2022';
        position: absolute;
        left: 6px;
        color: rgba(196, 181, 253, 0.6);
      }

      /* Header chunks */
      .chunk.header-chunk {
        font-size: 1.15em;
        font-weight: 600;
        color: rgba(255,255,255, 0.75);
        padding-top: 8px;
      }
      .chunk.header-chunk.active {
        color: #ffffff;
      }

      /* Code block chunks */
      .chunk.code-chunk {
        font-family: "SF Mono", "JetBrains Mono", monospace;
        font-size: 0.82em;
        background: rgba(255,255,255, 0.04);
        border-radius: 8px;
        padding: 10px 14px;
        line-height: 1.5;
        white-space: pre-wrap;
      }

      /* Table header chunk (column names) */
      .chunk.table-header {
        color: rgba(196, 181, 253, 0.8);
        font-weight: 600;
        font-size: 0.85em;
        text-transform: uppercase;
        letter-spacing: 0.6px;
        border-bottom: 1px solid rgba(196, 181, 253, 0.2);
        padding-bottom: 6px;
        margin-bottom: 2px;
      }

      /* Table-row cards */
      .kv-row {
        display: flex;
        gap: 10px;
        padding: 3px 0;
        align-items: baseline;
      }
      .kv-key {
        color: rgba(196, 181, 253, 0.85);
        font-weight: 600;
        font-size: 0.82em;
        text-transform: uppercase;
        letter-spacing: 0.5px;
        min-width: 60px;
        flex-shrink: 0;
      }
      .kv-val {
        color: rgba(255,255,255, 0.88);
      }
      .chunk.table-row {
        border-left: 2px solid rgba(196, 181, 253, 0.25);
        padding-left: 14px;
        margin-left: -4px;
      }
      .chunk.table-row.active {
        border-left: 3px solid rgba(196, 181, 253, 0.7);
      }

      .error {
        color: #fca5a5;
        font-weight: 500;
        text-align: center;
        padding: 20px;
      }

      /* Karaoke word highlight */
      .word-active { background: rgba(196,181,253,0.35); color: #fff; padding: 1px 3px; border-radius: 3px; transition: background 0.08s; }
    </style>
    </head>
    <body>
    <div class="top-controls">
      <button class="ctrl-btn close" onclick="doClose()" title="Close (Esc)">&times;</button>
      <button class="ctrl-btn" id="pauseBtn" onclick="doPause()" title="Pause/Resume (Ctrl+Option)">&#9208;</button>
    </div>
    <div id="content"></div>
    <script>
    function hasBoxChars(s) {
      for (var i = 0; i < s.length; i++) {
        var c = s.charCodeAt(i);
        if (c >= 0x2500 && c <= 0x257F) return true;
        if (c >= 0x2550 && c <= 0x256C) return true;
      }
      return false;
    }

    function isPipeTable(s) {
      var lines = s.split('\\n').filter(function(l) { return l.trim(); });
      if (lines.length < 2) return false;
      var pipeLines = lines.filter(function(l) { return l.indexOf('|') >= 0; });
      return pipeLines.length >= 2;
    }

    function esc(s) {
      return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
    }

    function inlineMd(s) {
      return esc(s)
        .replace(/`([^`]+)`/g, '<code>$1</code>')
        .replace(/\\*\\*([^*]+)\\*\\*/g, '<strong>$1</strong>')
        .replace(/\\*([^*]+)\\*/g, '<em>$1</em>');
    }

    function renderPipeTable(s) {
      var lines = s.split('\\n').filter(function(l) { return l.trim(); });
      var html = '<div class="table-wrap"><table>';
      var headerDone = false;
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim();
        if (/^[|\\s:\\-]+$/.test(line)) { headerDone = true; continue; }
        var cells = line.split('|').map(function(c) { return c.trim(); }).filter(function(c) { return c; });
        var tag = (!headerDone && i === 0) ? 'th' : 'td';
        html += '<tr>' + cells.map(function(c) { return '<'+tag+'>'+inlineMd(c)+'</'+tag+'>'; }).join('') + '</tr>';
      }
      return html + '</table></div>';
    }

    function isKVChunk(s) {
      var lines = s.split('\\n').filter(function(l) { return l.trim(); });
      if (lines.length < 1) return false;
      var kvCount = lines.filter(function(l) { return /^[^:]{1,40}: .+/.test(l.trim()); }).length;
      return kvCount === lines.length && kvCount >= 1;
    }

    function renderKV(s) {
      var lines = s.split('\\n').filter(function(l) { return l.trim(); });
      return lines.map(function(l) {
        var idx = l.indexOf(': ');
        if (idx < 0) return '<div>' + esc(l) + '</div>';
        var key = l.substring(0, idx).trim();
        var val = l.substring(idx + 2).trim();
        return '<div class="kv-row"><span class="kv-key">' + esc(key) + '</span><span class="kv-val">' + inlineMd(val) + '</span></div>';
      }).join('');
    }

    function isArrowRow(s) {
      return s.indexOf('\\u2192') >= 0 && s.split('\\u2192').length >= 2;
    }

    function renderArrowRow(s) {
      var parts = s.split('\\u2192').map(function(p) { return p.trim(); });
      return '<div class="kv-row"><span class="kv-key" style="text-transform:none;font-size:1em;">' + inlineMd(parts[0]) + '</span><span class="kv-val">' + inlineMd(parts.slice(1).join(' \\u2192 ')) + '</span></div>';
    }

    function isTableHeader(s) {
      return s.indexOf('\\u2502') >= 0 && s.split('\\u2502').length >= 2;
    }

    function md(s) {
      if (hasBoxChars(s)) {
        return '<pre><code>' + s.replace(/&/g,'&amp;').replace(/</g,'&lt;') + '</code></pre>';
      }
      if (isPipeTable(s)) {
        return renderPipeTable(s);
      }
      if (isKVChunk(s)) {
        return renderKV(s);
      }
      if (isTableHeader(s)) {
        return esc(s).replace(/\\u2502/g, '<span style="opacity:0.3;margin:0 8px;">|</span>');
      }
      if (isArrowRow(s)) {
        return renderArrowRow(s);
      }
      return s
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/^### (.+)$/gm, '<h3>$1</h3>')
        .replace(/^## (.+)$/gm, '<h2>$1</h2>')
        .replace(/^# (.+)$/gm, '<h1>$1</h1>')
        .replace(/```[\\s\\S]*?```/g, function(m) {
          return '<pre><code>' + m.slice(3,-3).trim() + '</code></pre>';
        })
        .replace(/`([^`]+)`/g, '<code>$1</code>')
        .replace(/\\*\\*([^*]+)\\*\\*/g, '<strong>$1</strong>')
        .replace(/\\*([^*]+)\\*/g, '<em>$1</em>')
        .replace(/\\n/g, '<br>');
    }

    let activeIdx = -1;
    let enabledSet = new Set();
    // Per-chunk word timing data: chunkWords[chunkIdx] = [{t,s,e}, ...]
    const chunkWords = {};
    // Currently-highlighted word span per chunk (for fast swap on playhead tick)
    const activeWordSpan = {};

    function chunkType(c) {
      var t = c.trim();
      if (isKVChunk(t)) return 'table-row';
      if (t.indexOf('\\u2502') >= 0 && t.split('\\u2502').length >= 2) return 'table-header';
      if (t.indexOf('\\u2192') >= 0 && t.split('\\u2192').length >= 2) return 'table-row';
      if (/^#{1,3} /.test(t)) return 'header-chunk';
      if (/^[-*] /.test(t) || /^\\d{1,3}[\\.\\)] /.test(t)) return 'list-item';
      if (t.startsWith('```')) return 'code-chunk';
      return '';
    }

    function loadChunks(chunks) {
      const el = document.getElementById('content');
      el.className = '';
      enabledSet.clear();
      activeIdx = -1;
      el.innerHTML = chunks.map((c, i) => {
        var ct = chunkType(c);
        var cls = 'chunk disabled' + (ct ? ' ' + ct : '');
        return '<div class="' + cls + '" data-i="' + i + '" onclick="tryJump(' + i + ')">' + md(c) + '</div>';
      }).join('');
    }

    function enableChunk(i) {
      enabledSet.add(i);
      const el = document.querySelector('[data-i="' + i + '"]');
      if (el) { el.classList.remove('disabled'); el.classList.add('enabled'); }
    }

    function highlight(i) {
      document.querySelectorAll('.chunk.active').forEach(e => e.classList.remove('active'));
      document.querySelectorAll('.chunk').forEach(e => {
        const idx = parseInt(e.dataset.i);
        if (idx < i) { e.classList.add('done'); e.classList.remove('disabled'); e.classList.add('enabled'); }
        else e.classList.remove('done');
      });
      const el = document.querySelector('[data-i="' + i + '"]');
      if (el) {
        el.classList.add('active');
        el.classList.remove('disabled');
        el.classList.add('enabled');
        el.scrollIntoView({ behavior: 'smooth', block: 'center' });
      }
      activeIdx = i;
    }

    function finished() {
      document.querySelectorAll('.chunk.active').forEach(e => e.classList.remove('active'));
      document.querySelectorAll('.chunk.done').forEach(e => e.classList.remove('done'));
      document.querySelectorAll('.chunk.disabled').forEach(e => {
        e.classList.remove('disabled'); e.classList.add('enabled');
      });
      document.getElementById('content').classList.add('finished');
    }

    function showError(msg) {
      document.getElementById('content').innerHTML = '<div class="error">\\u26A0\\uFE0F  ' + msg + '</div>';
    }

    // Walk text nodes inside a chunk element and wrap each whitespace-separated
    // word token in a <span class="w" data-wi="N">. Structural children
    // (<code>, <strong>, etc.) are recursed into so formatted words still
    // receive indices in left-to-right reading order.
    function wrapChunkWords(chunkEl) {
      if (!chunkEl || chunkEl.dataset.wrapped === '1') return 0;
      let counter = 0;
      const walk = (node) => {
        if (node.nodeType === Node.TEXT_NODE) {
          const text = node.nodeValue;
          if (!text || !text.trim()) return;
          const parts = text.split(/(\\s+)/); // keep whitespace
          const frag = document.createDocumentFragment();
          for (const p of parts) {
            if (!p) continue;
            if (/^\\s+$/.test(p)) {
              frag.appendChild(document.createTextNode(p));
            } else {
              const span = document.createElement('span');
              span.className = 'w';
              span.dataset.wi = String(counter++);
              span.textContent = p;
              frag.appendChild(span);
            }
          }
          node.parentNode.replaceChild(frag, node);
        } else if (node.nodeType === Node.ELEMENT_NODE) {
          // Skip elements that would be visually weird to wrap
          const tag = node.tagName;
          if (tag === 'PRE' || tag === 'TABLE') return;
          const kids = Array.from(node.childNodes);
          for (const k of kids) walk(k);
        }
      };
      const kids = Array.from(chunkEl.childNodes);
      for (const k of kids) walk(k);
      chunkEl.dataset.wrapped = '1';
      chunkEl.dataset.wcount = String(counter);
      return counter;
    }

    function setChunkWords(i, words) {
      chunkWords[i] = words || [];
      const el = document.querySelector('[data-i="' + i + '"]');
      if (!el) return;
      wrapChunkWords(el);
    }

    function setChunkPlayhead(i, t) {
      const words = chunkWords[i];
      if (!words || !words.length) return;
      const el = document.querySelector('[data-i="' + i + '"]');
      if (!el) return;
      // Find the word whose [start,end) contains t (linear scan — tiny N).
      let idx = -1;
      for (let k = 0; k < words.length; k++) {
        if (t >= words[k].s && t < words[k].e) { idx = k; break; }
      }
      if (idx < 0) {
        // Past the last word end? Keep last span lit briefly; otherwise clear.
        const last = words[words.length - 1];
        if (last && t >= last.e) idx = -1;
      }
      const prev = activeWordSpan[i];
      if (prev && prev.dataset.wi === String(idx)) return; // no change
      if (prev) prev.classList.remove('word-active');
      if (idx >= 0) {
        const span = el.querySelector('.w[data-wi="' + idx + '"]');
        if (span) {
          span.classList.add('word-active');
          activeWordSpan[i] = span;
          return;
        }
      }
      activeWordSpan[i] = null;
    }

    function tryJump(i) {
      if (!enabledSet.has(i) && i > activeIdx) return; // not yet generated
      window.webkit.messageHandlers.tts.postMessage({ action: 'jump', index: i });
    }

    function doClose() {
      window.webkit.messageHandlers.tts.postMessage({ action: 'close' });
    }

    function doPause() {
      window.webkit.messageHandlers.tts.postMessage({ action: 'pause' });
    }

    function setPaused(paused) {
      var btn = document.getElementById('pauseBtn');
      if (btn) btn.innerHTML = paused ? '&#9654;' : '&#9208;';
    }

    // Arrow key navigation
    document.addEventListener('keydown', function(e) {
      if (e.key === 'ArrowDown' || e.key === 'ArrowRight') {
        e.preventDefault();
        const next = activeIdx + 1;
        const total = document.querySelectorAll('.chunk').length;
        if (next < total && enabledSet.has(next)) {
          window.webkit.messageHandlers.tts.postMessage({ action: 'jump', index: next });
        }
      } else if (e.key === 'ArrowUp' || e.key === 'ArrowLeft') {
        e.preventDefault();
        const prev = activeIdx - 1;
        if (prev >= 0) {
          window.webkit.messageHandlers.tts.postMessage({ action: 'jump', index: prev });
        }
      } else if (e.key === 'Escape') {
        doClose();
      }
    });
    </script>
    </body>
    </html>
    """
}
