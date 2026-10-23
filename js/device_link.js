/**
 * @file device_link.js
 * @brief Links the WebREPL to real ESP32 hardware.
 *
 * Transports (both carry MSBC bytecode compiled in the browser):
 * - HttpDeviceLink:   firmware HTTP API (GET /api/info, POST /api/exec, /api/upload,
 *                     /api/reset, /api/fs/list|read|delete|rename, /api/display,
 *                     /api/input)
 * - SerialDeviceLink: Web Serial + the firmware's UART line protocol
 *     "@INFO" | "@EXEC <base64>" | "@BEGIN <size> [path]" "@DATA <base64>" "@END run|save"
 *     | "@LS" | "@APPS" | "@READ <offset> <path>" | "@RM <path>" | "@MV <from> <to>" | "@RESET"
 *     | "@INPUT button=1|0 [light=<n>|off]" | "@SCREEN <from>" (KEY 18, a screenshot)
 *   Every command is answered by exactly one "@OK {json}" / "@ERR {json}" line.
 *   Any other line is device log / display output and goes to onLog.
 *
 * Both expose the same file manager calls: fsList(), fsRead(path),
 * fsWrite(path, bytes), fsRemove(path), fsRename(from, to) and reset().
 * - SimDeviceLink:    local sim_esp32 process behind server.py
 */

const SERIAL_EXEC_INLINE_MAX = 1024; // base64 chars sent in a single @EXEC line
const SERIAL_CHUNK_BYTES = 768;      // raw bytes per @DATA line (1024 base64 chars)

function bytesToBase64(bytes) {
    let bin = '';
    for (let i = 0; i < bytes.length; i += 0x8000) {
        bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    }
    return btoa(bin);
}

function utf8ToBase64(text) {
    return bytesToBase64(new TextEncoder().encode(text));
}

function base64ToBytes(b64) {
    const bin = atob(b64);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
}

/* Throws the device's error message unless the reply reports success */
function expectSuccess(r, what) {
    if (!r || !r.success) throw new Error((r && r.error) || `${what}失败`);
    return r;
}

class HttpDeviceLink {
    constructor(host, password = '') {
        let h = (host || '').trim().replace(/\/+$/, '');
        if (h && !/^https?:\/\//i.test(h)) h = 'http://' + h;
        this.base = h;
        this.password = password || (typeof getHttpAuthPassword === 'function' ? getHttpAuthPassword() : localStorage.getItem("minischeme_http_password") || '');
        this.kind = 'http';
        this.onLog = null;
    }

    get label() { return `ESP32 HTTP ${this.base.replace(/^https?:\/\//, '')}`; }

    /* fetch with a timeout; read(res) consumes the body before the timer ends */
    async _fetch(path, options, timeoutMs, read) {
        const ctrl = new AbortController();
        const timer = setTimeout(() => ctrl.abort(), timeoutMs);
        try {
            const opts = { ...options };
            const headers = { ...(opts.headers || {}) };
            const pwd = this.password || (typeof getHttpAuthPassword === 'function' ? getHttpAuthPassword() : localStorage.getItem("minischeme_http_password") || '');
            if (pwd) {
                // The password goes in the X-MiniScheme-Auth header (the firmware's
                // CORS preflight allows it), not in the URL where it would stay in
                // history and logs. A header value must be Latin-1: other passwords
                // fall back to the percent-encoded ?auth= the firmware also reads.
                if (/^[\x20-\x7e]*$/.test(pwd)) {
                    headers['X-MiniScheme-Auth'] = pwd;
                } else {
                    const sep = path.includes('?') ? '&' : '?';
                    path = path + sep + 'auth=' + encodeURIComponent(pwd);
                }
            }
            opts.headers = headers;
            const res = await fetch(this.base + path, { ...opts, signal: ctrl.signal });
            if (res.status === 401 || res.status === 403) {
                let detail = '';
                try {
                    const r = await res.json();
                    if (r && r.error) detail = r.error;
                } catch (_) {}
                if (detail && detail.includes('origin not allowed')) {
                    throw new Error(`HTTP 403 跨源访问受限: 设备固件拦截了公网域名访问 (${detail})。请升级设备固件至最新版本，或通过本地 WebREPL (http://127.0.0.1:8087) 进行连接。`);
                }
                if (detail) {
                    throw new Error(`HTTP ${res.status} 未授权/拒绝访问 (${detail}): 请检查硬件访问密码或设备权限配置`);
                }
                throw new Error(`HTTP ${res.status} 密码错误/未授权: 请检查硬件访问密码`);
            }
            if (!res.ok) throw new Error(`HTTP ${res.status}`);
            return await read(res);
        } catch (e) {
            if (e.name === 'AbortError') throw new Error('设备响应超时');
            if (typeof window !== 'undefined' && window.location && window.location.protocol === 'https:' && this.base.startsWith('http:')) {
                console.warn('[HttpDeviceLink] Potential Mixed-Content or CORS block:', e);
                if (e instanceof TypeError || (e.message && e.message.includes('fetch'))) {
                    throw new Error(`连接硬件失败 (可能受浏览器安全策略限制): HTTPS 页面访问本地 HTTP 设备时，若被拦截，请点击地址栏左侧网站设置图标将【不安全内容】设为【允许】，或在本地运行 WebREPL (http://127.0.0.1:8087)。(${e.message || e})`);
                }
            }
            throw e;
        } finally {
            clearTimeout(timer);
        }
    }

    async _json(path, options = {}, timeoutMs = 20000) {
        return this._fetch(path, options, timeoutMs, (res) => res.json());
    }

    async connect() { return this.info(); }
    async disconnect() {}
    async info() { return this._json('/api/info', {}, 5000); }

    /* Screen mirror and real figures (firmware with /api/screen, /api/stats).
     * since / from: this viewer's cursor (minischeme_mirror.h); full=1 is for
     * firmware from before cursors, which ignores them */
    async screen({ since = 0, from = 0, full = false } = {}) {
        const q = `?since=${since}&from=${from}` + (full ? '&full=1' : '');
        return this._fetch('/api/screen' + q, {}, 10000, (res) => res.arrayBuffer());
    }

    async stats() { return this._json('/api/stats', {}, 5000); }

    /* text/plain keeps the request "simple" (no CORS preflight) */
    async exec(bytes, timeoutMs = 20000) {
        return this._json('/api/exec', { method: 'POST', headers: { 'Content-Type': 'text/plain' }, body: bytes }, timeoutMs);
    }

    async evalSource(source) {
        return this._json('/api/eval', { method: 'POST', headers: { 'Content-Type': 'text/plain' }, body: source });
    }

    async upload(bytes, path, run) {
        const q = `?path=${encodeURIComponent(path)}&run=${run ? 1 : 0}`;
        return this._json('/api/upload' + q, { method: 'POST', headers: { 'Content-Type': 'text/plain' }, body: bytes }, 60000);
    }

    /* File manager; POSTs without a body stay CORS-simple */
    async fsList() { return expectSuccess(await this._json('/api/fs/list', {}, 10000), '读取文件列表'); }

    async fsRead(path) {
        return this._fetch('/api/fs/read?path=' + encodeURIComponent(path), {}, 60000, async (res) => {
            // Errors come back as JSON, file contents as application/octet-stream
            if ((res.headers.get('Content-Type') || '').includes('json')) expectSuccess(await res.json(), '读取文件');
            return new Uint8Array(await res.arrayBuffer());
        });
    }

    async fsWrite(path, bytes) { return expectSuccess(await this.upload(bytes, path, false), '保存文件'); }

    async fsRemove(path) {
        return expectSuccess(await this._json('/api/fs/delete?path=' + encodeURIComponent(path), { method: 'POST' }), '删除');
    }

    async fsRename(from, to) {
        const q = `?from=${encodeURIComponent(from)}&to=${encodeURIComponent(to)}`;
        return expectSuccess(await this._json('/api/fs/rename' + q, { method: 'POST' }), '重命名');
    }

    async reset() { return expectSuccess(await this._json('/api/reset', { method: 'POST' }, 5000), '重启'); }
    /* the installed apps with their metadata (the board's settings page uses the same list) */
    async apps() { return expectSuccess(await this._json('/api/apps?meta=1', {}, 15000), '读取应用列表'); }

    /* Color bits / scheme applied on the board and saved to config.ini:
     * {bits: 4, palette: 'amber'} (either may be left out) */
    async display({ bits, palette }) {
        const q = new URLSearchParams();
        if (bits) q.set('color_bits', String(bits));
        if (palette) q.set('palette', palette);
        return expectSuccess(await this._json('/api/display?' + q, { method: 'POST' }, 10000), '设置显示');
    }

    /* KEY 18 and the light sensor of the page: {button: true|false}, {light: 0..4095 | 'off'}.
     * Sent one after another, so a release never overtakes its press. */
    input(params) {
        const q = new URLSearchParams();
        if (params.button !== undefined) q.set('button', params.button ? '1' : '0');
        if (params.light !== undefined) q.set('light', String(params.light));
        const send = () => this._json('/api/input?' + q, { method: 'POST' }, 5000);
        this._inputChain = (this._inputChain || Promise.resolve()).catch(() => {}).then(send);
        return this._inputChain;
    }
}

class SerialDeviceLink {
    constructor(baudRate = 115200) {
        this.baudRate = baudRate;
        this.kind = 'serial';
        this.port = null;
        this.reader = null;
        this.writer = null;
        this.onLog = null;
        this.onReady = null;
        this._pending = null;   // { resolve, reject, timer }
        this._queue = Promise.resolve();
        this._rx = '';
        this._closing = false;
    }

    static supported() { return typeof navigator !== 'undefined' && 'serial' in navigator; }

    get label() {
        const info = this.port && this.port.getInfo ? this.port.getInfo() : {};
        const vid = info.usbVendorId ? info.usbVendorId.toString(16).padStart(4, '0') : '';
        return `ESP32 串口${vid ? ' (USB ' + vid + ')' : ''} @ ${this.baudRate}`;
    }

    async connect() {
        if (!SerialDeviceLink.supported()) {
            throw new Error('当前浏览器不支持 Web Serial，请使用 Chrome / Edge 并通过 http://localhost 访问');
        }
        this.port = await navigator.serial.requestPort();
        await this.port.open({ baudRate: this.baudRate, bufferSize: 8192 });
        this.writer = this.port.writable.getWriter();
        this._closing = false;
        this._readLoopPromise = this._readLoop();
        // The board may reset when the port opens; retry until the firmware answers
        let lastErr = null;
        for (let i = 0; i < 6; i++) {
            try {
                return await this.info(1500);
            } catch (e) {
                lastErr = e;
            }
        }
        throw lastErr || new Error('设备无响应');
    }

    async disconnect() {
        this._closing = true;
        if (this._pending) {
            this._pending.reject(new Error('串口已断开'));
            this._pending = null;
        }
        try { if (this.reader) await this.reader.cancel(); } catch (e) { /* ignore */ }
        if (this._readLoopPromise) {
            try { await this._readLoopPromise; } catch (e) { /* ignore */ }
            this._readLoopPromise = null;
        }
        try { if (this.writer) this.writer.releaseLock(); } catch (e) { /* ignore */ }
        try { if (this.port) await this.port.close(); } catch (e) { /* ignore */ }
        this.port = this.reader = this.writer = null;
    }

    /* Release locks and close port while returning the SerialPort instance so other tools (e.g. firmware flasher) can reuse it */
    async releasePort() {
        this._closing = true;
        if (this._pending) {
            this._pending.reject(new Error('串口已断开'));
            this._pending = null;
        }
        try { if (this.reader) await this.reader.cancel(); } catch (e) { /* ignore */ }
        if (this._readLoopPromise) {
            try { await this._readLoopPromise; } catch (e) { /* ignore */ }
            this._readLoopPromise = null;
        }
        try { if (this.writer) this.writer.releaseLock(); } catch (e) { /* ignore */ }
        const p = this.port;
        try { if (p) await p.close(); } catch (e) { /* ignore */ }
        this.port = this.reader = this.writer = null;
        return p;
    }

    async _readLoop() {
        const decoder = new TextDecoder();
        while (this.port && this.port.readable && !this._closing) {
            this.reader = this.port.readable.getReader();
            try {
                for (;;) {
                    const { value, done } = await this.reader.read();
                    if (done) break;
                    this._rx += decoder.decode(value, { stream: true });
                    let nl;
                    while ((nl = this._rx.indexOf('\n')) >= 0) {
                        const line = this._rx.slice(0, nl).replace(/\r$/, '');
                        this._rx = this._rx.slice(nl + 1);
                        this._onLine(line);
                    }
                }
            } catch (e) {
                if (!this._closing && this.onLog) this.onLog(`[串口错误] ${e.message}`);
            } finally {
                try { this.reader.releaseLock(); } catch (e) { /* ignore */ }
            }
        }
    }

    _onLine(line) {
        // The REPL prompt has no newline, so a reply can arrive glued to it
        const at = line.search(/@(OK|ERR|READY) /);
        if (at > 0) {
            const prefix = line.slice(0, at).replace(/^minischeme>\s*/, '');
            if (prefix.trim() && this.onLog) this.onLog(prefix);
            line = line.slice(at);
        }
        if (line.startsWith('@OK ') || line.startsWith('@ERR ')) {
            let data;
            try {
                data = JSON.parse(line.slice(line.indexOf(' ') + 1));
            } catch (e) {
                data = { success: false, error: `无法解析设备响应: ${line}` };
            }
            // a reply to a request that already timed out is not the answer
            // to the next one: each timeout owes one late reply (for 30 s)
            const now = Date.now();
            this._late = (this._late || []).filter(t => t > now);
            if (this._late.length) {
                this._late.shift();
                return;
            }
            if (this._pending) {
                const p = this._pending;
                this._pending = null;
                clearTimeout(p.timer);
                p.resolve(data);
            }
            return;
        }
        if (line.startsWith('@READY')) {
            if (this.onReady) this.onReady(line);
            return;
        }
        const text = line.replace(/^(minischeme>\s*)+/, '');
        if (text.trim() && this.onLog) this.onLog(text);
    }

    /* One command at a time; resolves with the device's JSON reply */
    _request(line, timeoutMs = 20000) {
        const run = () => new Promise((resolve, reject) => {
            if (!this.writer) {
                reject(new Error('串口未连接'));
                return;
            }
            const timer = setTimeout(() => {
                this._pending = null;
                (this._late = this._late || []).push(Date.now() + 30000);
                reject(new Error('设备响应超时'));
            }, timeoutMs);
            this._pending = { resolve, reject, timer };
            this.writer.write(new TextEncoder().encode(line + '\n')).catch((e) => {
                clearTimeout(timer);
                this._pending = null;
                reject(e);
            });
        });
        const p = this._queue.then(run, run);
        this._queue = p.catch(() => {});
        return p;
    }

    async info(timeoutMs = 5000) { return this._request('@INFO', timeoutMs); }

    async exec(bytes, timeoutMs = 20000) {
        const b64 = bytesToBase64(bytes);
        if (b64.length <= SERIAL_EXEC_INLINE_MAX) return this._request('@EXEC ' + b64, timeoutMs);
        return this.upload(bytes, '/spiffs/upload.tmp', true);
    }

    async evalSource(source) { return this._request('@EVAL ' + utf8ToBase64(source)); }

    async upload(bytes, path, run, onProgress) {
        let r = await this._request(`@BEGIN ${bytes.length} ${path}`);
        if (!r.success) return r;
        for (let off = 0; off < bytes.length; off += SERIAL_CHUNK_BYTES) {
            r = await this._request('@DATA ' + bytesToBase64(bytes.subarray(off, off + SERIAL_CHUNK_BYTES)));
            if (!r.success) return r;
            if (onProgress) onProgress(Math.min(bytes.length, off + SERIAL_CHUNK_BYTES), bytes.length);
        }
        return this._request(run ? '@END run' : '@END save', 60000);
    }

    /* File manager (paths never contain spaces: the protocol splits on them) */
    async fsList() { return expectSuccess(await this._request('@LS', 10000), '读取文件列表'); }
    /* the installed apps with their metadata, as GET /api/apps */
    async apps() { return expectSuccess(await this._request('@APPS', 15000), '读取应用列表'); }

    async fsRead(path, onProgress) {
        const parts = [];
        let offset = 0, size = 0;
        do {
            const r = expectSuccess(await this._request(`@READ ${offset} ${path}`), '读取文件');
            const chunk = base64ToBytes(r.data);
            size = r.size;
            if (chunk.length === 0) break;
            parts.push(chunk);
            offset += chunk.length;
            if (onProgress) onProgress(offset, size);
        } while (offset < size);
        const out = new Uint8Array(offset);
        let at = 0;
        for (const p of parts) { out.set(p, at); at += p.length; }
        return out;
    }

    async fsWrite(path, bytes, onProgress) {
        return expectSuccess(await this.upload(bytes, path, false, onProgress), '保存文件');
    }

    async fsRemove(path) { return expectSuccess(await this._request('@RM ' + path), '删除'); }
    async fsRename(from, to) { return expectSuccess(await this._request(`@MV ${from} ${to}`), '重命名'); }
    async reset() { return expectSuccess(await this._request('@RESET', 5000), '重启'); }

    /* KEY 18 and the light sensor, as HttpDeviceLink.input (firmware 1.0.62+);
     * the requests queue one after another, so a release never overtakes its press */
    async input(params) {
        const parts = [];
        if (params.button !== undefined) parts.push('button=' + (params.button ? '1' : '0'));
        if (params.light !== undefined) parts.push('light=' + String(params.light));
        return expectSuccess(await this._request('@INPUT ' + parts.join(' '), 5000), '发送输入');
    }

    /* One screenshot (firmware 1.0.62+): the whole screen as /api/screen
     * replies (minischeme_mirror.h), a few rows per request; onProgress(rows, height) */
    async screenshot(onProgress) {
        const replies = [];
        let from = 0;
        for (;;) {
            const r = await this._request('@SCREEN ' + from, 10000);
            if (!r || !r.success) {
                const msg = (r && r.error) || '截图失败';
                throw new Error(/unknown command/.test(msg) ? '固件不支持串口截图，请更新到 v1.0.62 以上' : msg);
            }
            const buf = base64ToBytes(r.data);
            if (buf.length < 16 || String.fromCharCode(buf[0], buf[1], buf[2], buf[3]) !== 'MSCR') {
                throw new Error('无法解析的截图数据');
            }
            replies.push(buf);
            const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
            const h = dv.getUint16(8, true), nrows = dv.getUint16(10, true);
            let at = 16, last = -1;
            for (let i = 0; i < nrows; i++) {
                last = dv.getUint16(at, true);
                at += 4 + dv.getUint16(at + 2, true);
            }
            if (onProgress) onProgress(last + 1, h);
            if (!(buf[5] & 1) || last < 0) return replies;   // no MORE: the screen is complete
            from = last + 1;
        }
    }
}

class SimDeviceLink {
    constructor() {
        this.kind = 'sim';
        this.onLog = null;
    }

    get label() { return '本地模拟进程 (server.py)'; }
    async connect() { return { success: true, compiler: false }; }
    async disconnect() {}
    async info() { return { success: true, compiler: false }; }

    async exec(bytes) {
        let hex = '';
        for (let i = 0; i < bytes.length; i++) hex += bytes[i].toString(16).padStart(2, '0');
        const base = window.LOCAL_SERVER_BASE || '';
        const res = await fetch(base + '/api/execute_bytecode', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ bytecode_hex: hex, byte_len: bytes.length })
        });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        return res.json();
    }

    async evalSource() { return { success: false, error: '模拟进程不含编译器' }; }
    async upload(bytes) { return this.exec(bytes); }
}
