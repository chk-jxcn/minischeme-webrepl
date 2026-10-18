/**
 * @file hw_mirror.js
 * @brief Shows the board's real screen and figures in the WebREPL while it is
 *        connected over HTTP: /api/screen sends the rows that changed on the
 *        panel (packed RGB565, see minischeme_mirror.h), /api/stats the
 *        memory, display and load figures.
 *
 * The screen loop asks again right away while the board reports more rows,
 * else every SCREEN_IDLE_MS; a still screen costs a 16-byte reply. The first
 * request (and the one after a reboot) asks for the whole screen.
 *
 * Each mirror keeps its own cursor: the rows newer than `since`, from row
 * `from` on. A pass over the screen may take several replies; when it ends,
 * `since` becomes the clock of its first reply, so rows that changed during
 * the pass come in the next one. Another viewer (a second tab, a script)
 * takes nothing away from this one.
 */

const MIRROR_SCREEN_IDLE_MS = 120;
const MIRROR_STATS_MS = 1000;
const MIRROR_RETRY_MS = 2000;

class HardwareMirror {
    /**
     * @param {object} opts
     * @param {HTMLCanvasElement} opts.canvas the LCD canvas
     * @param {(stats: object) => void} opts.onStats real figures, once a second
     * @param {(state: string, detail: string) => void} opts.onState
     *        'sync' | 'live' | 'nopixels' | 'error' | 'unsupported' | 'stopped'
     */
    constructor({ canvas, onStats, onState }) {
        this.canvas = canvas;
        this.onStats = onStats || (() => {});
        this.onState = onState || (() => {});
        this.link = null;
        this.gen = 0;          // bumps on stop: old loops end
        this.image = null;
        this.needFull = true;
        this.since = 0;        // the rows newer than this are asked for
        this.from = 0;         // the row the current pass goes on at
        this.passClock = null; // the board's clock when this pass began
        this.lastRow = -1;     // the last row of the latest reply
        this.lastUptime = 0;
        this.bytes = 0;
        this.ws = null;
        this.state = 'stopped';
    }

    get active() { return this.link !== null; }

    start(link) {
        this.stop();
        if (!link || typeof link.screen !== 'function') return;
        this.link = link;
        this.needFull = true;
        this.lastUptime = 0;
        const gen = ++this.gen;
        this._setState('sync', '同步硬件画面…');
        this._startStreamOrPolling(gen);
        this._statsLoop(gen);
    }

    stop() {
        this.gen++;
        if (this.ws) {
            try { this.ws.close(); } catch (_) {}
            this.ws = null;
        }
        this.link = null;
        this.image = null;
        if (this.state !== 'stopped') this._setState('stopped', '');
    }

    async _startStreamOrPolling(gen) {
        let streamOk = false;
        if (typeof WebSocket !== 'undefined' && this.link && this.link.base) {
            try {
                let host = '';
                try {
                    const u = new URL(this.link.base);
                    host = u.hostname;
                } catch (_) {
                    host = this.link.base.replace(/^https?:\/\//, '').split(':')[0].split('/')[0];
                }
                if (host) {
                    streamOk = await this._tryWebSocketStream(gen, host);
                }
            } catch (err) {
                console.warn('[HardwareMirror] WebSocket stream init failed, falling back to HTTP polling:', err);
            }
        }
        if (!streamOk && this._alive(gen)) {
            this._screenLoop(gen);
        }
    }

    _tryWebSocketStream(gen, host) {
        return new Promise((resolve) => {
            if (!this._alive(gen)) return resolve(false);
            if (typeof window !== 'undefined' && window.location && window.location.protocol === 'https:') {
                // Browsers strictly block unencrypted ws:// connections from an HTTPS page (Mixed Content).
                // Skip direct ws:// to avoid browser error noise and fall back directly to HTTP polling.
                return resolve(false);
            }
            const pwd = this.link.password || (typeof getHttpAuthPassword === 'function' ? getHttpAuthPassword() : localStorage.getItem("minischeme_http_password") || '');
            const wsUrl = `ws://${host}:8088/?auth=${encodeURIComponent(pwd)}`;
            let ws = null;
            let connected = false;
            let timer = null;

            const cleanup = () => {
                if (timer) { clearTimeout(timer); timer = null; }
                if (ws) {
                    ws.onopen = null;
                    ws.onerror = null;
                    ws.onclose = null;
                    ws.onmessage = null;
                }
            };

            try {
                ws = new WebSocket(wsUrl);
                ws.binaryType = 'arraybuffer';
                this.ws = ws;
            } catch (e) {
                return resolve(false);
            }

            timer = setTimeout(() => {
                if (!connected) {
                    cleanup();
                    try { ws.close(); } catch (_) {}
                    if (this.ws === ws) this.ws = null;
                    resolve(false);
                }
            }, 1500);

            ws.onopen = () => {
                if (!this._alive(gen)) {
                    cleanup();
                    try { ws.close(); } catch (_) {}
                    if (this.ws === ws) this.ws = null;
                    return resolve(false);
                }
                connected = true;
                if (timer) { clearTimeout(timer); timer = null; }
                this._setState('live', '实时传输 (TCP/WS)');
                resolve(true);
            };

            ws.onmessage = (evt) => {
                if (!this._alive(gen)) return;
                const buf = new Uint8Array(evt.data);
                if (buf.length < 16 || String.fromCharCode(buf[0], buf[1], buf[2], buf[3]) !== 'MSCR') {
                    return;
                }
                const flags = this._apply(buf);
                if (flags & 2) {
                    this._setState('nopixels', 'direct 模式不保存像素，无法镜像 (config.ini 中改用 band 或 full)');
                } else if (this.state !== 'live') {
                    this._setState('live', '实时传输 (TCP/WS)');
                }
            };

            ws.onerror = () => {
                if (!connected) {
                    cleanup();
                    if (this.ws === ws) this.ws = null;
                    resolve(false);
                }
            };

            ws.onclose = () => {
                if (connected && this._alive(gen)) {
                    if (this.ws === ws) this.ws = null;
                    this._setState('sync', '流中断，切换为 HTTP 轮询…');
                    this._screenLoop(gen);
                }
            };
        });
    }

    _setState(state, detail) {
        this.state = state;
        this.onState(state, detail);
    }

    _alive(gen) { return gen === this.gen && this.link !== null; }

    async _screenLoop(gen) {
        while (this._alive(gen)) {
            let delay = MIRROR_SCREEN_IDLE_MS;
            try {
                const full = this.needFull;
                if (full) {
                    this.since = 0;
                    this.from = 0;
                    this.passClock = null;
                }
                const buf = new Uint8Array(await this.link.screen({ since: this.since, from: this.from, full }));
                if (!this._alive(gen)) return;
                if (buf.length < 16 || String.fromCharCode(buf[0], buf[1], buf[2], buf[3]) !== 'MSCR') {
                    // a JSON error from the firmware (out of memory and the like)
                    let msg = '';
                    try { msg = JSON.parse(new TextDecoder().decode(buf)).error; } catch (e) { msg = '无法解析的回复'; }
                    throw new Error(msg);
                }
                if (full) this.needFull = false;
                const flags = this._apply(buf);
                this._advance(buf, flags);
                if (flags & 2) {
                    this._setState('nopixels', 'direct 模式不保存像素，无法镜像 (config.ini 中改用 band 或 full)');
                    delay = MIRROR_RETRY_MS;
                    this.needFull = true;
                } else {
                    if (this.state !== 'live') this._setState('live', '');
                    if (flags & 1) delay = 0;
                }
            } catch (e) {
                if (!this._alive(gen)) return;
                const msg = (e && e.message) || String(e);
                if (/HTTP 404/.test(msg)) {
                    this._setState('unsupported', '固件没有 /api/screen，请更新固件后再连接');
                    return;
                }
                this._setState('error', `画面同步中断: ${msg}，稍后重试`);
                this.needFull = true;
                delay = MIRROR_RETRY_MS;
            }
            if (delay) await new Promise((r) => setTimeout(r, delay));
        }
    }

    async _statsLoop(gen) {
        while (this._alive(gen)) {
            try {
                const st = await this.link.stats();
                if (!this._alive(gen)) return;
                if (st && st.success) {
                    // uptime going backwards: the board rebooted, fetch the whole screen
                    if (st.uptime_ms < this.lastUptime) this.needFull = true;
                    this.lastUptime = st.uptime_ms;
                    st.mirror_bytes = this.bytes;
                    this.bytes = 0;
                    this.onStats(st);
                }
            } catch (e) { /* the screen loop reports connection problems */ }
            await new Promise((r) => setTimeout(r, MIRROR_STATS_MS));
        }
    }

    /** Moves this viewer's cursor past a reply (version 2: the board keeps
     *  row versions; version 1 firmware keeps one cursor for everyone) */
    _advance(buf, flags) {
        if (buf[4] < 2) return;
        const clock = new DataView(buf.buffer, buf.byteOffset, buf.byteLength).getUint32(12, true);
        if (this.passClock === null) this.passClock = clock;
        if ((flags & 1) && this.lastRow >= 0) {
            this.from = this.lastRow + 1;
        } else {
            this.since = this.passClock;
            this.from = 0;
            this.passClock = null;
        }
    }

    /** Applies one /api/screen reply to the canvas; returns its flags */
    _apply(buf) {
        const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
        const flags = buf[5];
        const w = dv.getUint16(6, true), h = dv.getUint16(8, true), nrows = dv.getUint16(10, true);
        this.bytes += buf.length;
        if (!w || !h) return flags;
        const ctx = this.canvas.getContext('2d');
        if (this.canvas.width !== w || this.canvas.height !== h) {
            this.canvas.width = w;
            this.canvas.height = h;
            this.image = null;
        }
        if (!this.image) {
            this.image = ctx.createImageData(w, h);
            this.pixels = new Uint32Array(this.image.data.buffer);
            this.pixels.fill(0xFF000000);
        }
        const px = this.pixels;
        let at = 16, y0 = h, y1 = -1;
        this.lastRow = -1;
        for (let r = 0; r < nrows; r++) {
            const y = dv.getUint16(at, true), n = dv.getUint16(at + 2, true);
            at += 4;
            const end = at + n;
            let i = y * w;
            const rowEnd = i + w;
            while (at < end && i < rowEnd) {
                const c = buf[at++];
                if (c < 128) {
                    for (let k = 0; k <= c && i < rowEnd; k++, at += 2) px[i++] = rgb565ToAbgr(buf[at] | (buf[at + 1] << 8));
                } else {
                    const v = rgb565ToAbgr(buf[at] | (buf[at + 1] << 8));
                    at += 2;
                    for (let k = 0; k < c - 126 && i < rowEnd; k++) px[i++] = v;
                }
            }
            at = end;
            if (y < y0) y0 = y;
            if (y > y1) y1 = y;
            this.lastRow = y;
        }
        if (y1 >= y0) ctx.putImageData(this.image, 0, 0, 0, y0, w, y1 - y0 + 1);
        return flags;
    }
}

/* RGB565 -> canvas pixel (little-endian RGBA as one Uint32) */
function rgb565ToAbgr(v) {
    const r = (v >> 11) & 0x1F, g = (v >> 5) & 0x3F, b = v & 0x1F;
    return 0xFF000000 | (((b << 3) | (b >> 2)) << 16) | (((g << 2) | (g >> 4)) << 8) | ((r << 3) | (r >> 2));
}
