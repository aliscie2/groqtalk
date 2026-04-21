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

    private let panelWidth: CGFloat = 720
    private let corner: CGFloat = 18

    // MARK: - Public API

    func show(text: String, chunks: [String]) {
        Log.info("[DIALOG] show (\(text.count) chars, \(chunks.count) chunks)")
        DispatchQueue.main.async { [weak self] in self?.showOnMain(chunks) }
    }

    func enableChunk(_ index: Int) { js("enableChunk(\(index))") }

    func setPaused(_ paused: Bool) { js("setPaused(\(paused))") }

    func setActiveChunk(_ index: Int) {
        Log.debug("[DIALOG] setActiveChunk \(index)")
        js("highlight(\(index))")
    }

    func finish() {
        Log.info("[DIALOG] finish")
        js("finished()")
        DispatchQueue.main.async { [weak self] in self?.scheduleFadeOut(after: 1.2) }
    }

    func close() {
        Log.info("[DIALOG] close")
        DispatchQueue.main.async { [weak self] in self?.dismissOnMain() }
    }

    func error(_ message: String) {
        Log.info("[DIALOG] error: \(message)")
        let escaped = message.replacingOccurrences(of: "'", with: "\\'")
        js("showError('\(escaped)')")
        DispatchQueue.main.async { [weak self] in self?.scheduleFadeOut(after: 2.5) }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    private func js(_ code: String) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(code, completionHandler: nil)
        }
    }

    // MARK: - Show / Dismiss

    private func showOnMain(_ chunks: [String]) {
        fadeOutWorkItem?.cancel()
        if panel == nil { buildPanel() }
        guard let panel, let webView else { Log.error("[DIALOG] panel missing"); return }

        let pretty = chunks.map { TextPrettifier.prettify($0) }
        let data = try? JSONSerialization.data(withJSONObject: pretty)
        let json = String(data: data ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        webView.evaluateJavaScript("loadChunks(\(json))", completionHandler: nil)

        let lineEstimate = chunks.joined().count / 45
        let screenH = NSScreen.main?.visibleFrame.height ?? 800
        let estimatedH = min(screenH * 0.65, CGFloat(max(3, lineEstimate)) * 38 + 80)

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
        }, completionHandler: { [weak self] in self?.panel?.orderOut(nil) })
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
            backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
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
        let handlers: [String: ([String: Any]) -> Void] = [
            "jump": { [weak self] b in
                if let i = b["index"] as? Int { Log.info("[DIALOG] JS jump \(i)"); self?.onChunkTap?(i) }
            },
            "close": { [weak self] _ in Log.info("[DIALOG] JS close"); self?.onClose?() },
            "pause": { [weak self] _ in Log.info("[DIALOG] JS pause toggle"); self?.onPauseToggle?() },
        ]
        handlers[action]?(body)
    }

    // MARK: - HTML

    private static let htmlTemplate = """
    <!DOCTYPE html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1"><style>
    :root{
      --bg-panel:#1A1A1C;
      --bg-elevated:#222225;
      --text-body:rgba(232,230,225,.86);
      --text-active:rgba(245,243,238,1);
      --text-done:rgba(232,230,225,.38);
      --text-muted:rgba(232,230,225,.54);
      --accent:#E8B468;
      --rule:rgba(232,230,225,.08);
    }
    *{box-sizing:border-box;margin:0;padding:0}
    html,body{background:var(--bg-panel);
      font-family:"Iowan Old Style","Charter","Georgia",ui-serif,serif;
      font-size:20px;line-height:1.55;letter-spacing:.005em;
      color:var(--text-body);
      padding:48px 56px 36px;overflow-y:auto;overflow-x:hidden;
      -webkit-font-smoothing:antialiased;user-select:none;cursor:default}
    body::-webkit-scrollbar{width:0}
    #content{max-width:62ch;margin:0 auto}

    /* Chunks: continuous prose, separated only by whitespace + accent bar. */
    .chunk{display:block;margin:1.2em 0;padding-left:18px;margin-left:-20px;
      border-left:2px solid transparent;transition:color 180ms ease,border-color 180ms ease}
    .chunk.enabled{cursor:pointer}
    .chunk.enabled:hover{color:var(--text-active)}
    .chunk.disabled{color:var(--text-done)}
    .chunk.active{color:var(--text-active);border-left-color:var(--accent);background:linear-gradient(90deg,rgba(232,180,104,.08),transparent 92%);border-radius:4px}
    .chunk.done{color:var(--text-done);transition:color 220ms ease}
    .finished .chunk{color:var(--text-body);border-left-color:transparent}

    /* Markdown */
    strong{color:var(--text-active);font-weight:600}
    em{font-style:italic}
    h1,h2,h3{font-family:-apple-system,"SF Pro Text",system-ui,sans-serif;
      line-height:1.25;color:var(--text-active)}
    h1{font-size:28px;font-weight:600;margin:1.6em 0 .5em}
    h2{font-size:22px;font-weight:600;margin:1.4em 0 .4em}
    h3{font-size:18px;font-weight:600;margin:1.2em 0 .3em;color:var(--text-muted)}
    code{font-family:"SF Mono","JetBrains Mono",ui-monospace,monospace;
      font-size:.88em;background:var(--bg-elevated);padding:2px 6px;border-radius:4px}
    pre{background:var(--bg-elevated);padding:14px 16px;border-radius:8px;
      overflow-x:auto;margin:1em 0}
    pre code{display:block;font-size:14px;line-height:1.5;padding:0;background:transparent}
    blockquote{border-left:2px solid var(--rule);padding-left:14px;
      color:var(--text-muted);font-style:italic;margin:1em 0}
    ul,ol{padding-left:1.4em;margin:.8em 0}
    li{margin:.25em 0}
    hr{border:0;border-top:1px solid var(--rule);margin:1.6em 0}

    /* Table rendering (pipe / box input converted to real tables). */
    .table-wrap{overflow-x:auto;margin:1em 0}
    table{border-collapse:collapse;font-size:.92em;font-family:-apple-system,system-ui,sans-serif}
    th,td{padding:6px 12px;border-bottom:1px solid var(--rule);text-align:left}
    th{color:var(--text-active);font-weight:600}

    /* Special chunk types kept lean — no background cards. */
    .chunk.header-chunk{font-family:-apple-system,"SF Pro Text",system-ui,sans-serif;
      font-size:22px;font-weight:600;color:var(--text-muted)}
    .chunk.header-chunk.active{color:var(--text-active)}
    .chunk.code-chunk{font-family:"SF Mono","JetBrains Mono",ui-monospace,monospace;
      font-size:14px;background:var(--bg-elevated);padding:12px 16px;border-radius:8px;
      white-space:pre-wrap;line-height:1.5}
    .chunk.list-item{padding-left:1.4em;position:relative;margin-left:0}
    .chunk.list-item::before{content:'\\2022';position:absolute;left:.4em;color:var(--accent);opacity:.7}
    .kv-row{display:flex;gap:10px;padding:3px 0;align-items:baseline}
    .kv-key{color:var(--accent);font-weight:600;font-size:.82em;text-transform:uppercase;
      letter-spacing:.5px;min-width:60px;flex-shrink:0}
    .kv-val{color:var(--text-body)}

    /* Controls auto-hide; reveal on mousemove. Kindle-style. */
    .top-controls{position:fixed;top:14px;right:14px;display:flex;gap:6px;z-index:100;
      opacity:0;transition:opacity 160ms ease}
    body.mouse-active .top-controls{opacity:1}
    .ctrl-btn{width:28px;height:28px;border-radius:50%;border:none;
      background:rgba(255,255,255,.06);color:var(--text-muted);
      font-size:13px;line-height:28px;text-align:center;cursor:pointer;
      transition:all 120ms ease;padding:0}
    .ctrl-btn:hover{background:rgba(255,255,255,.14);color:var(--text-active)}
    .ctrl-btn.close{font-size:16px}

    .error{color:#fca5a5;font-weight:500;text-align:center;padding:20px;
      font-family:-apple-system,system-ui,sans-serif}

    /* Thin amber progress bar across the bottom — peripheral, non-clinical. */
    #prog{position:fixed;bottom:10px;left:50%;transform:translateX(-50%);
      height:2px;width:140px;background:var(--rule);border-radius:1px}
    #prog::after{content:'';display:block;height:100%;width:var(--p,0%);
      background:var(--accent);border-radius:1px;transition:width 220ms ease}

    /* Respect macOS Reduce Motion + Increase Contrast. */
    @media (prefers-reduced-motion: reduce){
      .chunk,.chunk.done,#prog::after{transition:none!important}
      html{scroll-behavior:auto}
    }
    @media (prefers-contrast: more){
      :root{--text-body:rgba(245,243,238,.96);--rule:rgba(232,230,225,.25)}
    }
    </style></head><body>
    <div class="top-controls">
      <button class="ctrl-btn close" onclick="post('close')" title="Close (Esc)">&times;</button>
      <button class="ctrl-btn" id="pauseBtn" onclick="post('pause')" title="Pause/Resume (Ctrl+Option)">&#9208;</button>
    </div>
    <div id="content"></div>
    <div id="prog"></div>
    <script>
    // Auto-hide top controls: show on mouse movement, hide after 1.8s idle.
    (function(){
      let t; document.body.classList.add('mouse-active');
      const kick=()=>{document.body.classList.add('mouse-active');
        clearTimeout(t);t=setTimeout(()=>document.body.classList.remove('mouse-active'),1800);};
      document.addEventListener('mousemove',kick);kick();
    })();
    </script>
    <script>
    const BOX=/[\\u2500-\\u257F]/, VBAR='\\u2502', ARROW='\\u2192';
    const post=(action,extra)=>window.webkit.messageHandlers.tts.postMessage(Object.assign({action},extra||{}));
    const esc=s=>s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
    const inlineMd=s=>esc(s).replace(/`([^`]+)`/g,'<code>$1</code>').replace(/\\*\\*([^*]+)\\*\\*/g,'<strong>$1</strong>').replace(/\\*([^*]+)\\*/g,'<em>$1</em>');
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
      // Every segment must be short (≤28 chars) and contain no end-of-sentence punctuation.
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
      if(BOX.test(s))return '<pre><code>'+s.replace(/&/g,'&amp;').replace(/</g,'&lt;')+'</code></pre>';
      if(isPipeTable(s))return renderPipeTable(s);
      if(isKVChunk(s))return renderKV(s);
      if(s.indexOf(VBAR)>=0&&s.split(VBAR).length>=2)return esc(s).replace(/\\u2502/g,'<span style="opacity:0.3;margin:0 8px;">|</span>');
      if(s.indexOf(ARROW)>=0&&s.split(ARROW).length>=2)return renderArrowRow(s);
      return s.replace(/&/g,'&amp;').replace(/</g,'&lt;')
        .replace(/^### (.+)$/gm,'<h3>$1</h3>').replace(/^## (.+)$/gm,'<h2>$1</h2>').replace(/^# (.+)$/gm,'<h1>$1</h1>')
        .replace(/```[\\s\\S]*?```/g,m=>'<pre><code>'+m.slice(3,-3).trim()+'</code></pre>')
        .replace(/`([^`]+)`/g,'<code>$1</code>').replace(/\\*\\*([^*]+)\\*\\*/g,'<strong>$1</strong>').replace(/\\*([^*]+)\\*/g,'<em>$1</em>').replace(/\\n/g,'<br>');}
    function chunkType(c){const t=c.trim();
      if(isKVChunk(t))return 'table-row';
      if(isTokenRow(t,VBAR))return 'table-header';
      if(isTokenRow(t,ARROW))return 'table-row';
      if(/^#{1,3} /.test(t))return 'header-chunk';
      if(/^[-*] /.test(t)||/^\\d{1,3}[\\.\\)] /.test(t))return 'list-item';
      if(t.startsWith('```'))return 'code-chunk';
      return '';}

    let activeIdx=-1;
    const enabledSet=new Set();

    function loadChunks(chunks){
      const el=document.getElementById('content');
      el.className='';
      enabledSet.clear();
      activeIdx=-1;
      el.innerHTML=chunks.map((c,i)=>{
        const ct=chunkType(c);
        return '<div class="chunk disabled'+(ct?' '+ct:'')+'" data-i="'+i+'" onclick="tryJump('+i+')">'+md(c)+'</div>';
      }).join('');
      // Per-word click-to-seek and karaoke highlighting were removed: Kokoro
      // doesn't emit native timestamps, and re-running whisper or extrapolating
      // from character weights is a trick. Clicking a chunk still jumps to
      // that chunk (chunk boundaries ARE accurate — they're the audio split).
    }

    function enableChunk(i){
      enabledSet.add(i);
      const el=document.querySelector('[data-i="'+i+'"]');
      if(el){el.classList.remove('disabled');el.classList.add('enabled');}
    }

    function highlight(i){
      document.querySelectorAll('.chunk.active').forEach(e=>e.classList.remove('active'));
      const all=document.querySelectorAll('.chunk');
      all.forEach(e=>{
        const idx=parseInt(e.dataset.i);
        if(idx<i){e.classList.add('done');e.classList.remove('disabled');e.classList.add('enabled');}
        else e.classList.remove('done');
      });
      const el=document.querySelector('[data-i="'+i+'"]');
      if(el){el.classList.add('active');el.classList.remove('disabled');el.classList.add('enabled');
        const sm=matchMedia('(prefers-reduced-motion: reduce)').matches?'auto':'smooth';
        el.scrollIntoView({behavior:sm,block:'center'});}
      // Progress bar — fraction of chunks completed.
      const total=Math.max(1,all.length-1);
      const prog=document.getElementById('prog');
      if(prog)prog.style.setProperty('--p',(i/total*100)+'%');
      activeIdx=i;
    }

    function finished(){
      document.querySelectorAll('.chunk.active').forEach(e=>e.classList.remove('active'));
      document.querySelectorAll('.chunk.done').forEach(e=>e.classList.remove('done'));
      document.querySelectorAll('.chunk.disabled').forEach(e=>{e.classList.remove('disabled');e.classList.add('enabled');});
      document.getElementById('content').classList.add('finished');
    }

    function showError(msg){
      document.getElementById('content').innerHTML='<div class="error">\\u26A0\\uFE0F  '+msg+'</div>';
    }

    function tryJump(i){
      if(!enabledSet.has(i)&&i>activeIdx)return;
      post('jump',{index:i});
    }

    function setPaused(paused){
      const btn=document.getElementById('pauseBtn');
      if(btn)btn.innerHTML=paused?'&#9654;':'&#9208;';
    }

    document.addEventListener('keydown',e=>{
      if(e.key==='ArrowDown'||e.key==='ArrowRight'||e.key==='n'){
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
