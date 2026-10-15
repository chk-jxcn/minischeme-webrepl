/**
 * The running app's own web page (apps/<id>/web.html), as the board shows it
 * in the first tab of its web page.
 *
 * WASM device: the page comes gzip'd out of the app's image
 * (wasm_app_web_page); a small script put in front of it answers its calls to
 * /api/app/call through the parent window, which runs the app's
 * (app-web name body) on the simulated device (wasm_app_web_call).
 * ESP32 over HTTP: the board's own page opens in a new tab.
 */

/* Put in front of the app's page: its fetch('/api/app/call?...') and
 * fetch('/api/app/file?...') (binary bodies too) go to the WebREPL */
const AW_SHIM = `<script>(function(){
var real = window.fetch, seq = 0, waiting = {};
window.addEventListener('message', function (e) {
  var d = e.data; if (!d || !d.appAnswer || !waiting[d.id]) return;
  var done = waiting[d.id]; delete waiting[d.id];
  if (d.bytes) { done(new Response(d.bytes, {status: d.status || 200})); return; }
  done(new Response(d.text, {status: d.status || (d.failed ? 500 : 200),
    headers: {'Content-Type': /^\\s*[\\[{]/.test(d.text) ? 'application/json' : 'text/plain'}}));
});
window.fetch = function (url, opts) {
  var u = String(url), file = u.indexOf('/api/app/file') >= 0;
  if (!file && u.indexOf('/api/app/call') < 0) return real.apply(this, arguments);
  var id = ++seq, b = opts && opts.body != null ? opts.body : '';
  var kind = Object.prototype.toString.call(b);
  var bytes = kind === '[object ArrayBuffer]' ? Promise.resolve(b)
    : ArrayBuffer.isView(b) ? Promise.resolve(b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength))
    : (b && typeof b.arrayBuffer === 'function') ? b.arrayBuffer() : Promise.resolve(null);
  return (file ? bytes : Promise.resolve(String(b))).then(function (body) {
    return new Promise(function (resolve) {
      waiting[id] = resolve;
      window.parent.postMessage({appCall: !file, appFile: file, id: id, url: u,
        method: (opts && opts.method) || 'GET', body: body}, '*');
    });
  });
};
})();</script>`;

class AppWebPanel {
    /**
     * @param {object} opts
     * @param {() => object} opts.getTarget {kind:'wasm', exports, memory} or {kind:'url', url}, or throws a message
     * @param {(kind: string, text: string) => void} [opts.log] terminal output
     * @param {() => void} [opts.afterCall] after a call (redraw the simulated screen)
     */
    constructor({ getTarget, log, afterCall }) {
        this.getTarget = getTarget;
        this.log = log || (() => {});
        this.afterCall = afterCall || (() => {});
        this.target = null;
        this._build();
        window.addEventListener('message', (e) => this._onMessage(e));
    }

    _build() {
        const root = document.createElement('div');
        root.className = 'fm-overlay aw-overlay';
        root.hidden = true;
        root.innerHTML = `
            <div class="fm-dialog aw-dialog" role="dialog" aria-modal="true" aria-labelledby="aw-title">
                <div class="fm-head">
                    <span class="fm-title" id="aw-title">🌐 应用网页</span>
                    <span class="fm-target"></span>
                    <button class="fm-close" data-act="close" title="关闭 (Esc)" aria-label="关闭">&times;</button>
                </div>
                <div class="fm-toolbar">
                    <span class="aw-note">设备网页的第一个选项卡：应用自带的页面，调用由模拟设备上的 (app-web name body) 回答</span>
                    <span class="fm-spacer"></span>
                    <button class="pill-btn" data-act="reload">⟳ 重新载入</button>
                </div>
                <iframe class="aw-frame" title="应用网页"></iframe>
                <div class="fm-status" role="status" aria-live="polite"></div>
            </div>`;
        document.body.appendChild(root);
        this.el = {
            root, title: root.querySelector('#aw-title'), target: root.querySelector('.fm-target'),
            frame: root.querySelector('.aw-frame'), status: root.querySelector('.fm-status'),
        };
        root.addEventListener('click', (e) => {
            if (e.target === root) { this.close(); return; }
            const btn = e.target.closest('[data-act]');
            if (!btn) return;
            if (btn.dataset.act === 'close') this.close();
            if (btn.dataset.act === 'reload') this.load();
        });
        root.addEventListener('keydown', (e) => {
            if (e.key === 'Escape') { e.preventDefault(); this.close(); }
        });
    }

    async open() {
        try {
            this.target = this.getTarget();
        } catch (e) {
            this.log('error', `🌐 应用网页: ${e.message || e}`);
            return;
        }
        if (this.target.kind === 'url') {
            window.open(this.target.url, '_blank', 'noopener');
            return;
        }
        this.el.root.hidden = false;
        this.el.root.tabIndex = -1;
        this.el.root.focus();
        await this.load();
    }

    close() {
        this.el.root.hidden = true;
        this.el.frame.srcdoc = '';
    }

    _status(text, kind) {
        this.el.status.textContent = text || '';
        this.el.status.className = 'fm-status' + (kind ? ` fm-status-${kind}` : '');
    }

    _str(ptr) {
        const mem = new Uint8Array(this.target.memory().buffer);
        let end = ptr;
        while (mem[end]) end++;
        return new TextDecoder().decode(mem.subarray(ptr, end));
    }

    async load() {
        const ex = this.target.exports();
        if (!ex || !ex.wasm_app_web_page) {
            this._status('WASM 引擎没有应用网页接口 (需要新版 minischeme_vm.wasm)', 'error');
            return;
        }
        const name = this._str(ex.wasm_app_web_name());
        this.el.title.textContent = `🌐 ${name || '应用'} 的网页`;
        this.el.target.textContent = 'WASM 设备仿真';
        const ptr = ex.wasm_app_web_page();
        const len = ex.wasm_app_web_len();
        if (!ptr || !len) {
            this.el.frame.srcdoc = '<p style="font-family:sans-serif;color:#93a4b8">这个应用没有自带网页（apps/&lt;id&gt;/web.html）。</p>';
            this._status('');
            return;
        }
        const gz = new Uint8Array(this.target.memory().buffer, ptr, len).slice();
        try {
            const stream = new Blob([gz]).stream().pipeThrough(new DecompressionStream('gzip'));
            let html = await new Response(stream).text();
            html = /<head[^>]*>/i.test(html) ? html.replace(/<head[^>]*>/i, (m) => m + AW_SHIM) : AW_SHIM + html;
            this.el.frame.srcdoc = html;
            this._status(`页面 ${(len / 1024).toFixed(1)} KB (gzip)`);
        } catch (e) {
            this._status(`页面解压失败: ${e.message || e}`, 'error');
        }
    }

    /* /api/app/file: the app's own files in the simulated SPIFFS */
    _onFile(e, d) {
        const ex = this.target.exports();
        let q;
        try { q = new URL(d.url, 'http://device/').searchParams; } catch (err) { q = new URLSearchParams(); }
        const name = q.get('name') || '';
        const nb = new TextEncoder().encode(name + '\0');
        const np = ex.wasm_alloc_buffer(nb.length);
        new Uint8Array(this.target.memory().buffer).set(nb, np);
        let reply;
        if (d.method === 'GET') {
            const ptr = ex.wasm_app_file_read(np);
            const len = ex.wasm_app_file_len();
            reply = ptr ? { bytes: new Uint8Array(this.target.memory().buffer, ptr, len).slice().buffer }
                        : { text: '{"success":false,"error":"no such file"}', status: 404 };
        } else {
            const data = q.get('delete') === '1' ? null : new Uint8Array(d.body || new ArrayBuffer(0));
            let dp = 0;
            if (data) {
                dp = ex.wasm_alloc_buffer(data.length || 1);
                new Uint8Array(this.target.memory().buffer).set(data, dp);
            }
            const text = this._str(ex.wasm_app_file_write(np, dp, data ? data.length : 0));
            if (dp && ex.wasm_free_buffer) ex.wasm_free_buffer(dp);
            reply = { text, failed: !/"success":true/.test(text) };
            this.log(reply.failed ? 'error' : 'info', `🌐 /api/app/file ${data ? 'write' : 'delete'} ${name}: ${text}`);
        }
        if (ex.wasm_free_buffer) ex.wasm_free_buffer(np);
        this.afterCall();
        e.source.postMessage(Object.assign({ appAnswer: true, id: d.id }, reply), '*');
    }

    _onMessage(e) {
        const d = e.data;
        if (d && d.appFile && e.source === this.el.frame.contentWindow && this.target) {
            this._onFile(e, d);
            return;
        }
        if (!d || !d.appCall || e.source !== this.el.frame.contentWindow || !this.target) return;
        const ex = this.target.exports();
        let fn = '';
        try { fn = new URL(d.url, 'http://device/').searchParams.get('fn') || ''; } catch (err) { fn = ''; }
        const enc = new TextEncoder();
        const nameBytes = enc.encode(fn + '\0');
        const bodyBytes = enc.encode(d.body || '');
        const np = ex.wasm_alloc_buffer(nameBytes.length + bodyBytes.length + 1);
        const mem = new Uint8Array(this.target.memory().buffer);
        mem.set(nameBytes, np);
        mem.set(bodyBytes, np + nameBytes.length);
        const text = this._str(ex.wasm_app_web_call(np, np + nameBytes.length, bodyBytes.length));
        if (ex.wasm_free_buffer) ex.wasm_free_buffer(np);
        const failed = !!ex.wasm_app_web_failed();
        this.log(failed ? 'error' : 'info', `🌐 (app-web "${fn}") ${failed ? text : `→ ${text.length} B`}`);
        this.afterCall();
        e.source.postMessage({ appAnswer: true, id: d.id, text, failed }, '*');
    }
}

if (typeof window !== 'undefined') window.AppWebPanel = AppWebPanel;
