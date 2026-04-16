import AppKit
import WebKit

final class TTSDialog: NSObject, WKScriptMessageHandler {
    static let shared = TTSDialog()

    var onChunkTap: ((Int) -> Void)?
    var onClose: (() -> Void)?

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

    func setActiveChunk(_ index: Int) {
        Log.debug("[DIALOG] setActiveChunk \(index)")
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript("highlight(\(index))", completionHandler: nil)
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

      /* Close button */
      .close-btn {
        position: fixed;
        top: 10px;
        left: 14px;
        width: 24px;
        height: 24px;
        border-radius: 50%;
        border: none;
        background: rgba(255,255,255, 0.10);
        color: rgba(255,255,255, 0.5);
        font-size: 14px;
        line-height: 24px;
        text-align: center;
        cursor: pointer;
        z-index: 100;
        transition: all 0.12s;
      }
      .close-btn:hover {
        background: rgba(255,90,90, 0.7);
        color: #fff;
      }

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

      .error {
        color: #fca5a5;
        font-weight: 500;
        text-align: center;
        padding: 20px;
      }
    </style>
    </head>
    <body>
    <button class="close-btn" onclick="doClose()" title="Close">&times;</button>
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

    function md(s) {
      if (hasBoxChars(s)) {
        return '<pre><code>' + s.replace(/&/g,'&amp;').replace(/</g,'&lt;') + '</code></pre>';
      }
      if (isPipeTable(s)) {
        return renderPipeTable(s);
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

    function loadChunks(chunks) {
      const el = document.getElementById('content');
      el.className = '';
      enabledSet.clear();
      activeIdx = -1;
      el.innerHTML = chunks.map((c, i) =>
        '<div class="chunk disabled" data-i="' + i + '" onclick="tryJump(' + i + ')">' + md(c) + '</div>'
      ).join('');
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

    function tryJump(i) {
      if (!enabledSet.has(i) && i > activeIdx) return; // not yet generated
      window.webkit.messageHandlers.tts.postMessage({ action: 'jump', index: i });
    }

    function doClose() {
      window.webkit.messageHandlers.tts.postMessage({ action: 'close' });
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
