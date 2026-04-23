import AppKit
import WebKit

final class HistorySearchPanel: NSObject, WKScriptMessageHandler {
    struct VoiceWordPayload: Codable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    struct EntryPayload: Codable {
        let timestamp: String
        let title: String
        let subtitle: String
        let cleaned: String
        let transcript: String
        let note: String
        let words: [VoiceWordPayload]
        let hasAudio: Bool
    }

    var onSpeakEntry: ((String) -> Void)?
    var onPlayWord: ((String, TimeInterval, TimeInterval) -> Void)?
    var onEditNote: ((String) -> Void)?

    private var panel: NSPanel?
    private var webView: WKWebView?
    private var entriesByTimestamp: [String: HistoryEntry] = [:]

    func show(entries: [HistoryEntry]) {
        DispatchQueue.main.async { [weak self] in
            self?.showOnMain(entries: entries)
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }

        switch action {
        case "speak":
            guard let timestamp = body["timestamp"] as? String else { return }
            onSpeakEntry?(timestamp)
        case "copy":
            guard let timestamp = body["timestamp"] as? String,
                  let entry = entriesByTimestamp[timestamp] else { return }
            let text = (entry.cleaned ?? entry.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            NotificationHelper.sendStatus("\u{2705} Copied history text", subtitle: String(text.prefix(60)))
        case "playWord":
            guard let timestamp = body["timestamp"] as? String,
                  let start = body["start"] as? Double,
                  let end = body["end"] as? Double else { return }
            onPlayWord?(timestamp, start, end)
        case "note":
            guard let timestamp = body["timestamp"] as? String else { return }
            onEditNote?(timestamp)
        default:
            break
        }
    }

    private func showOnMain(entries: [HistoryEntry]) {
        if panel == nil { buildPanel() }
        guard let panel, let webView else { return }

        entriesByTimestamp = Dictionary(uniqueKeysWithValues: entries.map { ($0.timestamp, $0) })

        let payload = entries
            .filter { $0.pending != true }
            .sorted { $0.timestamp > $1.timestamp }
            .map(Self.payload(from:))
        let data = try? JSONEncoder().encode(payload)
        let json = String(data: data ?? Data("[]".utf8), encoding: .utf8) ?? "[]"

        webView.evaluateJavaScript("loadEntries(\(json)); focusSearch();", completionHandler: nil)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private static func payload(from entry: HistoryEntry) -> EntryPayload {
        let cleaned = (entry.cleaned ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let transcript = (entry.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = HistoryManager.relativeTime(entry.timestamp) + " · " + HistoryManager.timeString(from: entry.timestamp)
        let title = cleaned.isEmpty ? String(transcript.prefix(80)) : String(cleaned.prefix(80))
        let words = entry.structuredTranscript?.sentences.flatMap(\.words).map {
            VoiceWordPayload(text: $0.text, start: $0.start, end: $0.end)
        } ?? []
        return EntryPayload(
            timestamp: entry.timestamp,
            title: title.isEmpty ? entry.timestamp : title,
            subtitle: subtitle,
            cleaned: cleaned,
            transcript: transcript,
            note: entry.note ?? "",
            words: words,
            hasAudio: entry.wavPath != nil
        )
    }

    private func buildPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Search Dictation History"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.center()
        panel.minSize = NSSize(width: 620, height: 420)
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "history")

        let webView = WKWebView(frame: panel.contentView?.bounds ?? .zero, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")
        panel.contentView?.addSubview(webView)
        webView.loadHTMLString(Self.htmlTemplate, baseURL: nil)

        self.panel = panel
        self.webView = webView
    }

    private static let htmlTemplate = """
    <!DOCTYPE html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <style>
    :root{
      --bg:#141416;
      --panel:#1d1f22;
      --panel-2:#23262a;
      --text:#ece8df;
      --muted:rgba(236,232,223,.62);
      --rule:rgba(236,232,223,.08);
      --accent:#d9a45f;
      --accent-2:#93b2d4;
      --chip:rgba(255,255,255,.06);
    }
    *{box-sizing:border-box}
    html,body{margin:0;padding:0;background:var(--bg);color:var(--text);font-family:"Iowan Old Style","Charter","Georgia",ui-serif,serif}
    body{padding:24px 28px 36px;-webkit-font-smoothing:antialiased}
    .shell{max-width:960px;margin:0 auto}
    .top{position:sticky;top:0;padding-bottom:18px;background:linear-gradient(180deg,var(--bg) 75%,rgba(20,20,22,0));z-index:3}
    .title{font-size:28px;line-height:1.1;margin:0 0 8px}
    .sub{font-family:-apple-system,system-ui,sans-serif;font-size:13px;color:var(--muted);margin-bottom:14px}
    .search{width:100%;height:46px;border-radius:14px;border:1px solid var(--rule);background:var(--panel);color:var(--text);padding:0 16px;font-size:16px;outline:none}
    .search:focus{border-color:rgba(217,164,95,.45);box-shadow:0 0 0 3px rgba(217,164,95,.08)}
    .empty{padding:28px 0;color:var(--muted);font-family:-apple-system,system-ui,sans-serif}
    .list{display:flex;flex-direction:column;gap:14px}
    .entry{background:linear-gradient(180deg,var(--panel),var(--panel-2));border:1px solid var(--rule);border-radius:18px;padding:18px 18px 16px;box-shadow:0 20px 50px rgba(0,0,0,.18)}
    .entry-head{display:flex;gap:12px;align-items:flex-start;justify-content:space-between;margin-bottom:10px}
    .entry-title{font-size:22px;line-height:1.25}
    .entry-sub{font-family:-apple-system,system-ui,sans-serif;font-size:12px;letter-spacing:.02em;color:var(--muted);margin-top:4px}
    .actions{display:flex;gap:8px;flex-shrink:0}
    .btn{height:30px;padding:0 11px;border-radius:999px;border:none;background:var(--chip);color:var(--text);cursor:pointer;font:12px/30px -apple-system,system-ui,sans-serif}
    .btn:hover{background:rgba(255,255,255,.12)}
    .body{font-size:18px;line-height:1.58}
    .raw{margin-top:10px;padding-top:10px;border-top:1px solid var(--rule);font-size:15px;color:var(--muted)}
    .label{display:block;font:11px/1.2 -apple-system,system-ui,sans-serif;color:var(--accent);text-transform:uppercase;letter-spacing:.08em;margin-bottom:4px}
    .word-strip{margin-top:12px;padding-top:12px;border-top:1px solid var(--rule);display:flex;flex-wrap:wrap;gap:8px}
    .word{border:none;border-radius:999px;padding:6px 10px;background:rgba(147,178,212,.1);color:var(--text);cursor:pointer;font:13px/1.2 -apple-system,system-ui,sans-serif}
    .word:hover{background:rgba(147,178,212,.2);color:#fff}
    .hint{margin-top:8px;font:12px/1.4 -apple-system,system-ui,sans-serif;color:var(--muted)}
    mark{background:rgba(217,164,95,.22);color:inherit;padding:0 2px;border-radius:3px}
    </style></head><body>
    <div class="shell">
      <div class="top">
        <h1 class="title">Dictation History</h1>
        <div class="sub">Search your saved transcripts, replay them aloud, or click a timed word to hear how you said it.</div>
        <input id="search" class="search" type="search" placeholder="Search transcripts, cleaned text, or timestamps" oninput="render()">
      </div>
      <div id="results"></div>
    </div>
    <script>
    const post=(action,extra)=>window.webkit.messageHandlers.history.postMessage(Object.assign({action},extra||{}));
    const esc=s=>String(s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
    let allEntries=[];
    function focusSearch(){const el=document.getElementById('search'); if(el) el.focus();}
    function highlight(text,query){
      const safe=esc(text);
      if(!query) return safe;
      const pattern=query.replace(/[.*+?^${}()|[\\]\\\\]/g,'\\\\$&');
      return safe.replace(new RegExp('('+pattern+')','ig'),'<mark>$1</mark>');
    }
    function filteredEntries(){
      const query=(document.getElementById('search').value||'').trim().toLowerCase();
      if(!query) return allEntries;
      return allEntries.filter(entry=>{
        return [entry.title, entry.subtitle, entry.cleaned, entry.transcript, entry.note].some(part=>
          String(part||'').toLowerCase().indexOf(query)>=0
        );
      });
    }
    function render(){
      const query=(document.getElementById('search').value||'').trim();
      const entries=filteredEntries();
      const root=document.getElementById('results');
      if(!entries.length){
        root.innerHTML='<div class="empty">No history entries match that search yet.</div>';
        return;
      }
      root.innerHTML='<div class="list">'+entries.map(entry=>{
        const body=entry.cleaned||entry.transcript||'';
        const note=entry.note
          ? '<div class="raw"><span class="label">Note</span>'+highlight(entry.note,query)+'</div>'
          : '';
        const raw=entry.transcript&&entry.cleaned&&entry.transcript!==entry.cleaned
          ? '<div class="raw"><span class="label">Raw Transcript</span>'+highlight(entry.transcript,query)+'</div>'
          : '';
        const words=entry.hasAudio && entry.words && entry.words.length
          ? '<div class="word-strip">'+entry.words.map(word=>'<button class="word" onclick="playWord(event,\\''+entry.timestamp+'\\','+word.start+','+word.end+')">'+esc(word.text)+'</button>').join('')+'</div><div class="hint">Click a word to replay that moment from your recording.</div>'
          : '';
        const buttons='<div class="actions"><button class="btn" onclick="speakEntry(event,\\''+entry.timestamp+'\\')">Speak</button><button class="btn" onclick="copyEntry(event,\\''+entry.timestamp+'\\')">Copy</button><button class="btn" onclick="editNote(event,\\''+entry.timestamp+'\\')">Note</button></div>';
        return '<article class="entry"><div class="entry-head"><div><div class="entry-title">'+highlight(entry.title,query)+'</div><div class="entry-sub">'+esc(entry.subtitle)+'</div></div>'+buttons+'</div><div class="body">'+highlight(body,query)+'</div>'+note+raw+words+'</article>';
      }).join('')+'</div>';
    }
    function loadEntries(entries){allEntries=entries||[]; render();}
    function speakEntry(event,timestamp){event.preventDefault(); post('speak',{timestamp});}
    function copyEntry(event,timestamp){event.preventDefault(); post('copy',{timestamp});}
    function playWord(event,timestamp,start,end){event.preventDefault(); post('playWord',{timestamp,start,end});}
    function editNote(event,timestamp){event.preventDefault(); post('note',{timestamp});}
    </script></body></html>
    """
}
