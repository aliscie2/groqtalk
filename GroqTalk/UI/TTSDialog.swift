import AppKit
import WebKit

final class TTSDialog: NSObject, WKScriptMessageHandler {
    static let shared = TTSDialog()

    var onChunkTap: ((Int) -> Void)?
    var onWordTap: ((Int, TimeInterval) -> Void)?
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

    /// Inform the dialog how long (seconds) chunk `index`'s audio is so
    /// click-to-seek can map word positions proportionally before whisper
    /// alignment arrives.
    func setChunkDuration(_ index: Int, duration: TimeInterval) {
        js("setChunkDuration(\(index), \(duration))")
    }

    func setPaused(_ paused: Bool) { js("setPaused(\(paused))") }

    func setActiveChunk(_ index: Int) {
        Log.debug("[DIALOG] setActiveChunk \(index)")
        js("highlight(\(index))")
    }

    /// Supply word-level timestamps (from whisper.cpp `verbose_json`) for
    /// karaoke highlighting once `setChunkPlayhead` is called.
    func setChunkWords(_ index: Int, words: [WordAligner.Word]) {
        let payload = words.map { ["t": $0.text, "s": $0.start, "e": $0.end] as [String: Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        js("setChunkWords(\(index), \(json))")
    }

    /// Current playback position (seconds) for the active chunk. Call at
    /// ~15 Hz during playback to drive the `.word-active` class swap.
    func setChunkPlayhead(_ index: Int, time: TimeInterval) {
        js("setChunkPlayhead(\(index), \(time))")
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
            "wordTap": { [weak self] b in
                if let c = b["chunk"] as? Int, let t = b["time"] as? Double {
                    Log.info("[DIALOG] JS wordTap chunk=\(c) t=\(String(format: "%.2f", t))")
                    self?.onWordTap?(c, t)
                }
            },
            "wordsWrapped": { b in
                Log.info("[DIALOG] wrapped \(b["total"] as? Int ?? 0) words across \(b["chunks"] as? Int ?? 0) chunks")
            },
            "chunkFallback": { b in
                Log.info("[DIALOG] click missed word, chunk fallback → \(b["chunk"] as? Int ?? -1)")
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
    *{box-sizing:border-box;margin:0;padding:0}
    html,body{background:rgba(38,40,48,.94);font-family:-apple-system,"SF Pro Rounded","Helvetica Neue",sans-serif;font-size:22px;line-height:1.65;color:rgba(255,255,255,.55);padding:40px 32px 28px;overflow-y:auto;overflow-x:hidden;-webkit-font-smoothing:antialiased;user-select:none;cursor:default}
    body::-webkit-scrollbar{width:0}
    .top-controls{position:fixed;top:10px;left:14px;display:flex;gap:6px;z-index:100}
    .ctrl-btn{width:24px;height:24px;border-radius:50%;border:none;background:rgba(255,255,255,.08);color:rgba(255,255,255,.5);font-size:11px;line-height:24px;text-align:center;cursor:pointer;transition:all .12s;padding:0}
    .ctrl-btn:hover{background:rgba(255,255,255,.18);color:#fff}
    .ctrl-btn.close{font-size:14px}
    .ctrl-btn.close:hover{background:rgba(255,90,90,.7)}
    .chunk{border-radius:6px;padding:4px 8px;margin:2px -8px;transition:all .15s ease;display:block}
    .chunk.enabled{cursor:pointer}
    .chunk.enabled:hover{background:rgba(255,255,255,.06)}
    .chunk.disabled{opacity:.4;cursor:default}
    .chunk.active{color:#fff;font-weight:500;background:rgba(196,181,253,.15);border-left:3px solid rgba(196,181,253,.7);padding-left:12px;opacity:1}
    .chunk.done{color:rgba(255,255,255,.72);opacity:1}
    .finished .chunk{color:rgba(255,255,255,.88);font-weight:normal;background:none;border-left:none;padding-left:8px;opacity:1}
    strong{font-weight:600}em{font-style:italic}
    code{font-family:"SF Mono","JetBrains Mono",monospace;font-size:.88em;background:rgba(255,255,255,.08);padding:1px 5px;border-radius:4px}
    h1,h2,h3{color:rgba(255,255,255,.9);font-weight:600;margin-top:4px}
    h1{font-size:1.4em}h2{font-size:1.2em}h3{font-size:1.05em}
    pre{overflow-x:auto;margin:4px 0}
    pre code{display:block;padding:10px 14px;font-size:13px;line-height:1.4;white-space:pre}
    .table-wrap{overflow-x:auto;margin:6px 0;-webkit-overflow-scrolling:touch}
    table{min-width:100%;border-collapse:collapse;font-size:15px;white-space:nowrap}
    th,td{padding:6px 12px;text-align:left;border-bottom:1px solid rgba(255,255,255,.1)}
    th{color:rgba(255,255,255,.85);font-weight:600;border-bottom:2px solid rgba(255,255,255,.2)}
    .chunk.list-item{padding-left:20px;position:relative}
    .chunk.list-item::before{content:'\\2022';position:absolute;left:6px;color:rgba(196,181,253,.6)}
    .chunk.header-chunk{font-size:1.15em;font-weight:600;color:rgba(255,255,255,.75);padding-top:8px}
    .chunk.header-chunk.active{color:#fff}
    .chunk.code-chunk{font-family:"SF Mono","JetBrains Mono",monospace;font-size:.82em;background:rgba(255,255,255,.04);border-radius:8px;padding:10px 14px;line-height:1.5;white-space:pre-wrap}
    .chunk.table-header{color:rgba(196,181,253,.8);font-weight:600;font-size:.85em;text-transform:uppercase;letter-spacing:.6px;border-bottom:1px solid rgba(196,181,253,.2);padding-bottom:6px;margin-bottom:2px}
    .kv-row{display:flex;gap:10px;padding:3px 0;align-items:baseline}
    .kv-key{color:rgba(196,181,253,.85);font-weight:600;font-size:.82em;text-transform:uppercase;letter-spacing:.5px;min-width:60px;flex-shrink:0}
    .kv-val{color:rgba(255,255,255,.88)}
    .chunk.table-row{border-left:2px solid rgba(196,181,253,.25);padding-left:14px;margin-left:-4px}
    .chunk.table-row.active{border-left:3px solid rgba(196,181,253,.7)}
    .error{color:#fca5a5;font-weight:500;text-align:center;padding:20px}
    .w{cursor:pointer;border-radius:3px;transition:background .08s}
    .w:hover{background:rgba(255,255,255,.08)}
    .word-active{background:rgba(196,181,253,.35);color:#fff;padding:1px 3px}
    </style></head><body>
    <div class="top-controls">
      <button class="ctrl-btn close" onclick="post('close')" title="Close (Esc)">&times;</button>
      <button class="ctrl-btn" id="pauseBtn" onclick="post('pause')" title="Pause/Resume (Ctrl+Option)">&#9208;</button>
    </div>
    <div id="content"></div>
    <script>
    const BOX=/[\\u2500-\\u257F]/, VBAR='\\u2502', ARROW='\\u2192';
    const post=(action,extra)=>window.webkit.messageHandlers.tts.postMessage(Object.assign({action},extra||{}));
    const esc=s=>s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
    const inlineMd=s=>esc(s).replace(/`([^`]+)`/g,'<code>$1</code>').replace(/\\*\\*([^*]+)\\*\\*/g,'<strong>$1</strong>').replace(/\\*([^*]+)\\*/g,'<em>$1</em>');
    const nonEmpty=s=>s.split('\\n').filter(l=>l.trim());
    function isPipeTable(s){const ls=nonEmpty(s);return ls.length>=2 && ls.filter(l=>l.indexOf('|')>=0).length>=2;}
    function isKVChunk(s){const ls=nonEmpty(s);if(!ls.length)return false;const n=ls.filter(l=>/^[^:]{1,40}: .+/.test(l.trim())).length;return n===ls.length&&n>=1;}
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
      if(t.indexOf(VBAR)>=0&&t.split(VBAR).length>=2)return 'table-header';
      if(t.indexOf(ARROW)>=0&&t.split(ARROW).length>=2)return 'table-row';
      if(/^#{1,3} /.test(t))return 'header-chunk';
      if(/^[-*] /.test(t)||/^\\d{1,3}[\\.\\)] /.test(t))return 'list-item';
      if(t.startsWith('```'))return 'code-chunk';
      return '';}

    let activeIdx=-1;
    const enabledSet=new Set();
    const chunkWords={};      // whisper-aligned [{t,s,e},...] per chunk
    const chunkDuration={};   // seconds per chunk (from WAV fetch)
    const activeWordSpan={};  // currently-lit span per chunk
    function setChunkDuration(i,d){chunkDuration[i]=d;}

    // Walk text nodes, wrap whitespace-separated tokens in <span class="w" data-wi=N>.
    // Recurses into inline children (<code>, <strong>) but skips <pre>/<table>.
    function wrapChunkWords(el){
      if(!el||el.dataset.wrapped==='1')return 0;
      let n=0;
      const walk=(node)=>{
        if(node.nodeType===Node.TEXT_NODE){
          const text=node.nodeValue;
          if(!text||!text.trim())return;
          const frag=document.createDocumentFragment();
          for(const p of text.split(/(\\s+)/)){
            if(!p)continue;
            if(/^\\s+$/.test(p))frag.appendChild(document.createTextNode(p));
            else{const s=document.createElement('span');s.className='w';s.dataset.wi=String(n++);s.textContent=p;frag.appendChild(s);}
          }
          node.parentNode.replaceChild(frag,node);
        }else if(node.nodeType===Node.ELEMENT_NODE){
          if(node.tagName==='PRE'||node.tagName==='TABLE')return;
          Array.from(node.childNodes).forEach(walk);
        }
      };
      Array.from(el.childNodes).forEach(walk);
      el.dataset.wrapped='1';
      el.dataset.wcount=String(n);
      return n;
    }

    function loadChunks(chunks){
      const el=document.getElementById('content');
      el.className='';
      enabledSet.clear();
      activeIdx=-1;
      el.innerHTML=chunks.map((c,i)=>{
        const ct=chunkType(c);
        return '<div class="chunk disabled'+(ct?' '+ct:'')+'" data-i="'+i+'">'+md(c)+'</div>';
      }).join('');
      // Wrap words immediately so clicks work before whisper alignment arrives.
      // Use PROPORTIONAL seek (wi/wcount * duration) because TextCleaner expands
      // "URL" → "U R L" etc, so aligned[] word count diverges from DOM wrap count
      // — indexing aligned[wi] would produce wrong-seek (click word 10, hear 4).
      let total=0;
      document.querySelectorAll('.chunk').forEach(chunkEl=>{
        const i=parseInt(chunkEl.dataset.i);
        total+=wrapChunkWords(chunkEl);
        chunkEl.addEventListener('click',ev=>{
          const span=ev.target.closest('.w');
          if(span){
            const wi=parseInt(span.dataset.wi);
            const wcount=parseInt(chunkEl.dataset.wcount)||1;
            const dur=chunkDuration[i];
            const t=(dur&&wcount>0)?(wi/wcount)*dur:wi*0.25;
            ev.stopPropagation();
            post('wordTap',{chunk:i,time:t});
          }else{
            // Fallback path — if you see this for a clearly-on-word click,
            // wrapChunkWords didn't produce spans for that chunk.
            post('chunkFallback',{chunk:i});
            tryJump(i);
          }
        });
      });
      post('wordsWrapped',{total:total,chunks:chunks.length});
    }

    function enableChunk(i){
      enabledSet.add(i);
      const el=document.querySelector('[data-i="'+i+'"]');
      if(el){el.classList.remove('disabled');el.classList.add('enabled');}
    }

    function highlight(i){
      document.querySelectorAll('.chunk.active').forEach(e=>e.classList.remove('active'));
      document.querySelectorAll('.chunk').forEach(e=>{
        const idx=parseInt(e.dataset.i);
        if(idx<i){e.classList.add('done');e.classList.remove('disabled');e.classList.add('enabled');}
        else e.classList.remove('done');
      });
      const el=document.querySelector('[data-i="'+i+'"]');
      if(el){el.classList.add('active');el.classList.remove('disabled');el.classList.add('enabled');
        el.scrollIntoView({behavior:'smooth',block:'center'});}
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

    // Words were wrapped at loadChunks — this just supplies refined timings.
    function setChunkWords(i,words){chunkWords[i]=words||[];}

    function setChunkPlayhead(i,t){
      const words=chunkWords[i];
      if(!words||!words.length)return;
      const el=document.querySelector('[data-i="'+i+'"]');
      if(!el)return;
      let idx=-1;
      for(let k=0;k<words.length;k++){if(t>=words[k].s&&t<words[k].e){idx=k;break;}}
      const prev=activeWordSpan[i];
      if(prev&&prev.dataset.wi===String(idx))return;
      if(prev)prev.classList.remove('word-active');
      if(idx>=0){
        const span=el.querySelector('.w[data-wi="'+idx+'"]');
        if(span){span.classList.add('word-active');activeWordSpan[i]=span;return;}
      }
      activeWordSpan[i]=null;
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
