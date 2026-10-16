/**
 * @file font_generator.js
 * @brief MFNT font generator for the WebREPL font manager: pick a face, a
 *        pixel size and the characters (presets, text, strings of .scm
 *        sources), preview the result as the device draws it, then install
 *        it into the system font ROM, save it to the file system or download it.
 *
 * Two engines produce the font:
 * - PC engine: web_repl/server.py runs tools/make_font.py (Pillow/FreeType),
 *   the same code as the command line, so both give identical fonts. It
 *   lists the installed font files and leaves out characters a face lacks.
 * - Browser engine (fallback, or for a font file chosen here): canvas text,
 *   thresholded to 1 bit or kept as 2/4-bit coverage. Faces are the
 *   browser's; missing characters come from its fallback fonts.
 *
 * MFNT layout (version 2, version 1 is read too): tools/make_font.py.
 */

const FG_ASCII = Array.from({ length: 95 }, (_, i) => String.fromCharCode(32 + i)).join('');
const FG_NAME_RE = /^[A-Za-z0-9._-]{1,23}$/;
const FG_MIN_SIZE = 6;
const FG_MAX_SIZE = 128;
const FG_MAX_WIDTH = 128;      // pixels of one glyph
const FG_PATH_NAME_MAX = 55; // "/fonts/<name>.mfnt" under /spiffs (firmware paths < 64 bytes)
const FG_SAMPLE = '温度 23.5℃ 湿度 45%\n2026年10月8日 星期四 农历八月十七\nThe quick brown fox 0123456789';
const FG_STRING_RE = /"((?:\\.|[^"\\])*)"/g;

/* ------------------------------------------------------------------------ */
/* MFNT                                                                     */
/* ------------------------------------------------------------------------ */

/**
 * Baseline row that puts the glyphs' ink in the cell, as tools/make_font.py
 * auto_offset: all of the characters' ink, centered, when it fits; else that
 * of 98 % of them, the tops kept first. (Centering the font's ascent +
 * descent cut the top row off most 16 px SimSun / SimHei characters.)
 * ctx.font must be set.
 */
function fgInkBaseline(ctx, cps, size) {
    const ups = [], downs = [];
    for (const cp of cps) {
        const m = ctx.measureText(String.fromCharCode(cp));
        const up = Math.ceil(m.actualBoundingBoxAscent || 0), down = Math.ceil(m.actualBoundingBoxDescent || 0);
        if (up + down > 0) { ups.push(up); downs.push(down); }
    }
    if (!ups.length) return Math.round(size * 0.88);
    ups.sort((a, b) => a - b);
    downs.sort((a, b) => a - b);
    let up = ups[ups.length - 1], down = downs[downs.length - 1];
    if (up + down > size) {
        const k = Math.floor(ups.length / 100);
        up = ups[ups.length - 1 - k];
        down = downs[downs.length - 1 - k];
    }
    return up + down > size ? up : up + Math.floor((size - up - down) / 2);
}

/**
 * glyphs: [{cp, advance, bpr, rows: Uint8Array}] sorted or not; rows hold bpp
 * bits a pixel, MSB first. ascent: baseline row (0: unknown).
 */
function mfntEncode(height, name, glyphs, { bpp = 1, ascent = 0, descent = 0 } = {}) {
    const list = glyphs.slice().sort((a, b) => a.cp - b.cp);
    const seen = new Map();
    const chunks = [];
    let bitmapLen = 0, maxBpr = 1;
    const index = new Uint8Array(list.length * 8);
    const iv = new DataView(index.buffer);
    list.forEach((g, i) => {
        const key = g.rows.join(',');
        let off = seen.get(key);
        if (off === undefined) { // identical bitmaps (blank glyphs) are stored once
            off = bitmapLen;
            seen.set(key, off);
            chunks.push(g.rows);
            bitmapLen += g.rows.length;
        }
        iv.setUint16(i * 8, g.cp, true);
        iv.setUint8(i * 8 + 2, g.advance);
        iv.setUint8(i * 8 + 3, g.bpr);
        iv.setUint32(i * 8 + 4, off, true);
        maxBpr = Math.max(maxBpr, g.bpr);
    });
    const out = new Uint8Array(48 + index.length + bitmapLen);
    const dv = new DataView(out.buffer);
    out.set([0x4D, 0x46, 0x4E, 0x54]);
    dv.setUint16(4, 2, true);
    out[6] = height;
    out[7] = maxBpr;
    dv.setUint32(8, list.length, true);
    dv.setUint32(12, 48 + index.length, true);
    out.set(new TextEncoder().encode(name).subarray(0, 16), 16);
    out[32] = bpp;
    out[33] = Math.max(0, Math.min(255, ascent));
    out[34] = Math.max(0, Math.min(255, descent));
    out.set(index, 48);
    let at = 48 + index.length;
    for (const c of chunks) { out.set(c, at); at += c.length; }
    return out;
}

function mfntDecode(bytes) {
    if (bytes.length < 32 || String.fromCharCode(...bytes.subarray(0, 4)) !== 'MFNT') throw new Error('不是 MFNT 字库');
    const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const version = dv.getUint16(4, true);
    const head = version >= 2 ? 48 : 32;
    if (bytes.length < head) throw new Error('MFNT 字库不完整');
    const height = bytes[6];
    const count = dv.getUint32(8, true);
    const boff = dv.getUint32(12, true);
    const bpp = version >= 2 && [1, 2, 4].includes(bytes[32]) ? bytes[32] : 1;
    const ascent = version >= 2 ? bytes[33] : 0;
    const map = new Map();
    for (let i = 0; i < count; i++) {
        const e = head + i * 8;
        if (bytes[e + 3] === 0 && bytes[e + 2] === 0) continue; // absent glyph
        map.set(dv.getUint16(e, true), { advance: bytes[e + 2], bpr: bytes[e + 3], off: boff + dv.getUint32(e + 4, true) });
    }
    let name = '';
    for (let i = 16; i < 32 && bytes[i]; i++) name += String.fromCharCode(bytes[i]);
    return { bytes, version, height, count, map, name, bpp, ascent };
}

/** Draws text with the font as the device would (missing glyphs: red box) */
function mfntDrawPreview(canvas, font, text, width = 320, scale = 2) {
    const h = font.height, lineH = h + 2;
    const lines = [[]];
    let x = 0;
    for (const ch of text) {
        if (ch === '\n') { lines.push([]); x = 0; continue; }
        const cp = ch.codePointAt(0);
        const g = cp <= 0xFFFF ? font.map.get(cp) : undefined;
        const adv = g ? g.advance : (cp < 128 ? Math.ceil(h / 2) : h);
        if (x + adv > width && x > 0) { lines.push([]); x = 0; }
        lines[lines.length - 1].push({ x, g, adv });
        x += adv;
    }
    canvas.width = width;
    canvas.height = Math.max(1, lines.length) * lineH;
    canvas.style.width = `${width * scale}px`;
    canvas.style.height = `${canvas.height * scale}px`;
    const ctx = canvas.getContext('2d');
    const img = ctx.createImageData(canvas.width, canvas.height);
    const put = (px, py, r, gr, b) => {
        if (px < 0 || px >= canvas.width || py < 0 || py >= canvas.height) return;
        const o = (py * canvas.width + px) * 4;
        img.data[o] = r; img.data[o + 1] = gr; img.data[o + 2] = b; img.data[o + 3] = 255;
    };
    for (let i = 0; i < img.data.length; i += 4) { img.data[i + 3] = 255; }
    lines.forEach((items, ln) => {
        const top = ln * lineH;
        for (const it of items) {
            if (!it.g) {
                for (let k = 1; k < h - 1; k++) {
                    put(it.x + 1, top + k, 200, 60, 60); put(it.x + it.adv - 2, top + k, 200, 60, 60);
                }
                for (let k = 1; k < it.adv - 1; k++) {
                    put(it.x + k, top + 1, 200, 60, 60); put(it.x + k, top + h - 2, 200, 60, 60);
                }
                continue;
            }
            const { bpr, off } = it.g;
            const bpp = font.bpp || 1, levels = (1 << bpp) - 1;
            for (let y = 0; y < h; y++) {
                for (let x = 0; x < bpr * 8 / bpp; x++) {
                    const bit = x * bpp;
                    const v = (font.bytes[off + y * bpr + (bit >> 3)] >> (8 - bpp - (bit & 7))) & levels;
                    if (v) { const c = Math.round(v * 255 / levels); put(it.x + x, top + y, c, c, c); }
                }
            }
        }
    });
    ctx.putImageData(img, 0, 0);
}

/** Characters of the string literals in Scheme source (all of it if none) */
function fgSourceChars(text) {
    let out = '';
    for (const m of text.matchAll(FG_STRING_RE)) out += m[1];
    return out || text;
}

function fgUnique(text) {
    return Array.from(new Set(Array.from(text).filter((c) => {
        const cp = c.codePointAt(0);
        return cp >= 32 && cp <= 0xFFFF;
    })));
}

/** Rough MFNT size before generating */
function fgEstimate(chars, size, bpp = 1) {
    let bytes = 48;
    for (const c of chars) {
        const cp = c.codePointAt(0);
        const w = cp < 0x2000 ? Math.ceil(size / 2) : size;
        bytes += 8 + Math.ceil(w * bpp / 8) * size;
    }
    return bytes;
}

/* ------------------------------------------------------------------------ */
/* Engines                                                                  */
/* ------------------------------------------------------------------------ */

class ServerFontEngine {
    get label() { return 'PC 字体引擎 (server.py，与 tools/make_font.py 输出一致)'; }

    static async probe() {
        try {
            const res = await fetch('/api/font/faces');
            if (!res.ok) return null;
            const r = await res.json();
            if (!r.success) return null;
            const engine = new ServerFontEngine();
            engine.faceList = r.faces.map((f) => ({ ...f, key: f.file }));
            return engine;
        } catch (e) {
            return null;
        }
    }

    async faces() { return this.faceList; }

    async make({ face, size, chars, presets, name, yOffset, spacing, bpp }) {
        const res = await fetch('/api/font/make', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ face: face.key, size, chars, presets, name, y_offset: yOffset, spacing, bpp }),
        });
        if (!res.ok) throw new Error(`字体服务 HTTP ${res.status}`);
        const r = await res.json();
        if (!r.success) throw new Error(r.error || '生成失败');
        const data = Uint8Array.from(atob(r.mfnt), (c) => c.charCodeAt(0));
        return { data, name: r.name, glyphs: r.glyphs, bytes: r.bytes, missing: r.missing || '' };
    }
}

const FG_BROWSER_FACES = [
    { id: 'simsun', family: 'SimSun', family_zh: '宋体', cjk: true },
    { id: 'simhei', family: 'SimHei', family_zh: '黑体', cjk: true },
    { id: 'msyh', family: 'Microsoft YaHei', family_zh: '微软雅黑', cjk: true },
    { id: 'kaiti', family: 'KaiTi', family_zh: '楷体', cjk: true },
    { id: 'fangsong', family: 'FangSong', family_zh: '仿宋', cjk: true },
    { id: 'dengxian', family: 'DengXian', family_zh: '等线', cjk: true },
    { id: 'pingfang', family: 'PingFang SC', family_zh: '苹方', cjk: true },
    { id: 'notosanssc', family: 'Noto Sans SC', family_zh: '思源黑体', cjk: true },
    { id: 'notoserifsc', family: 'Noto Serif SC', family_zh: '思源宋体', cjk: true },
    { id: 'wqy', family: 'WenQuanYi Micro Hei', family_zh: '文泉驿微米黑', cjk: true },
    { id: 'arial', family: 'Arial', cjk: false },
    { id: 'verdana', family: 'Verdana', cjk: false },
    { id: 'consolas', family: 'Consolas', cjk: false },
    { id: 'courier', family: 'Courier New', cjk: false },
    { id: 'sans', family: 'sans-serif', cjk: true, generic: true },
    { id: 'serif', family: 'serif', cjk: true, generic: true },
    { id: 'mono', family: 'monospace', cjk: false, generic: true },
];

class BrowserFontEngine {
    constructor() {
        this.custom = [];
        this.canvas = document.createElement('canvas');
        this.ctx = this.canvas.getContext('2d', { willReadFrequently: true });
    }

    get label() { return '浏览器渲染 (未连接 server.py 字体服务；缺字由浏览器的后备字体补上)'; }

    _available(family) {
        const ctx = this.ctx;
        const probe = '中文字体测试 ABCabc 0123';
        // a face may itself be a default (SimSun is the serif and monospace font
        // of Chinese Windows), so it only has to differ from one of them
        for (const fallback of ['monospace', 'serif', 'sans-serif']) {
            ctx.font = `48px ${fallback}`;
            const base = ctx.measureText(probe).width;
            ctx.font = `48px "${family}", ${fallback}`;
            if (ctx.measureText(probe).width !== base) return true;
        }
        return false;
    }

    async faces() {
        const list = FG_BROWSER_FACES.filter((f) => f.generic || this._available(f.family));
        return [...this.custom, ...list].map((f) => ({ ...f, key: f.family, file: f.generic ? '浏览器默认' : '浏览器字体' }));
    }

    /** A font file chosen by the user, loaded with the FontFace API */
    async addFile(file) {
        const family = `fg-${this.custom.length}-${file.name.replace(/[^A-Za-z0-9]/g, '')}`;
        const face = new FontFace(family, await file.arrayBuffer());
        await face.load();
        document.fonts.add(face);
        const stem = file.name.replace(/\.[^.]+$/, '').toLowerCase().replace(/[^a-z0-9._-]/g, '');
        const entry = { id: stem || 'custom', family, family_zh: file.name, cjk: true, custom: true };
        this.custom.unshift(entry);
        return { ...entry, key: family, file: file.name };
    }

    async make({ face, size, chars, presets, name, yOffset, spacing, bpp = 1 }) {
        const set = new Set([...FG_ASCII, ...chars, ...presets.flatMap((p) => Array.from(p))]);
        const cps = Array.from(set).map((c) => c.codePointAt(0))
            .filter((cp) => cp >= 32 && cp <= 0xFFFF && cp !== 0x0A && cp !== 0x0D && cp !== 0x09);
        const ctx = this.ctx;
        const font = face.generic ? `${size}px ${face.key}` : `${size}px "${face.key}", sans-serif`;
        ctx.font = font;
        const m0 = ctx.measureText('中Agj');
        const asc = m0.fontBoundingBoxAscent ?? size * 0.88;
        const baseline = yOffset === null || yOffset === undefined ? fgInkBaseline(ctx, cps, size) : yOffset + asc;
        this.canvas.width = FG_MAX_WIDTH;
        this.canvas.height = size;
        const levels = (1 << bpp) - 1;
        const maxW = FG_MAX_WIDTH; // as tools/make_font.py: 128 px, whatever the bits per pixel
        const glyphs = [];
        for (let i = 0; i < cps.length; i++) {
            const ch = String.fromCharCode(cps[i]);
            ctx.font = font;
            const m = ctx.measureText(ch);
            const left = -(m.actualBoundingBoxLeft || 0);
            const right = m.actualBoundingBoxRight || 0;
            const inkW = Math.round(right - left);
            const minAdv = cps[i] < 128 ? Math.floor(size / 2) : size;
            const own = Math.max(1, Math.round(m.width)); // the face's advance width
            if (inkW <= 0 || ch.trim() === '') {
                const advance = Math.min(spacing === 'cell' ? minAdv : own, maxW);
                const bpr = Math.ceil(advance * bpp / 8);
                glyphs.push({ cp: cps[i], advance, bpr, rows: new Uint8Array(bpr * size) });
                continue;
            }
            const advance = Math.min(spacing === 'cell' ? Math.max(inkW, minAdv) : own, maxW);
            const width = Math.min(Math.max(advance, Math.ceil(right)), maxW);
            const bpr = Math.ceil(width * bpp / 8);
            const cols = Math.floor(bpr * 8 / bpp);
            ctx.clearRect(0, 0, this.canvas.width, size);
            ctx.fillStyle = '#fff';
            ctx.textBaseline = 'alphabetic';
            ctx.fillText(ch, 0, baseline);
            const px = ctx.getImageData(0, 0, cols, size).data;
            const rows = new Uint8Array(bpr * size);
            for (let y = 0; y < size; y++) {
                for (let x = 0; x < cols; x++) {
                    const a = px[(y * cols + x) * 4 + 3];
                    const v = bpp === 1 ? (a >= 128 ? 1 : 0) : Math.round(a * levels / 255);
                    if (v) { const bit = x * bpp; rows[y * bpr + (bit >> 3)] |= v << (8 - bpp - (bit & 7)); }
                }
            }
            glyphs.push({ cp: cps[i], advance, bpr, rows });
            if (i % 400 === 399) await new Promise((r) => setTimeout(r, 0)); // keep the page responsive
        }
        const ascent = Math.round(baseline);
        const data = mfntEncode(size, name, glyphs, { bpp, ascent, descent: Math.max(0, size - ascent) });
        return { data, name, glyphs: glyphs.length, bytes: data.length, missing: '' };
    }
}

/* ------------------------------------------------------------------------ */
/* Generator view                                                           */
/* ------------------------------------------------------------------------ */

class FontGenerator {
    /**
     * @param {HTMLElement} container element the view is built in
     * @param {object} host callbacks of the font manager:
     *   backend() current backend, run(label, fn) busy wrapper, status(text, kind),
     *   installRom(bytes, name), space() {used, capacity}, inputText() REPL input,
     *   back() return to the list, log(kind, text)
     */
    constructor(container, host) {
        this.host = host;
        this.engine = null;
        this.faceList = [];
        this.presets = [];
        this.result = null;      // last generated font
        this.resultKey = '';
        this.nameEdited = false;
        this._build(container);
    }

    _build(container) {
        container.innerHTML = `
            <div class="fm-toolbar">
                <button class="pill-btn" data-fg="back">← 返回字库列表</button>
                <span class="fg-engine"></span>
                <span class="fm-spacer"></span>
            </div>
            <div class="fg-body">
                <div class="fg-form">
                    <label class="fg-row"><span>字体</span>
                        <select class="fg-face"></select>
                        <button class="fm-row-btn" data-fg="font-file" title="选择 .ttf / .otf / .woff 字体文件 (浏览器渲染)">字体文件…</button>
                        <input type="file" class="fg-font-file" accept=".ttf,.otf,.ttc,.woff,.woff2" hidden>
                    </label>
                    <div class="fg-row">
                        <label><span>字号</span> <input type="number" class="fg-size" min="${FG_MIN_SIZE}" max="${FG_MAX_SIZE}" value="16"> px</label>
                        <label title="字形在格子里的纵向位置，留空为自动居中"><span>纵向偏移</span> <input type="number" class="fg-yoff" placeholder="自动" min="-32" max="32"></label>
                        <label title="按字体：比例字体 (雅黑、等线) 保持原有字距；固定格：ASCII 至少半格宽，与内置字体一致"><span>字宽</span>
                            <select class="fg-spacing"><option value="font">按字体</option><option value="cell">固定格</option></select></label>
                        <label title="每个像素的灰度级数：1 位为黑白点阵；2 / 4 位保留边缘覆盖率，笔画边缘平滑，字库大 2 / 4 倍"><span>抗锯齿</span>
                            <select class="fg-bpp"><option value="1">1 位 (黑白)</option><option value="2">2 位</option><option value="4">4 位</option></select></label>
                    </div>
                    <label class="fg-row"><span>名称</span>
                        <input type="text" class="fg-name" maxlength="23" spellcheck="false">
                        <code class="fg-usage"></code>
                    </label>
                    <div class="fg-section">预设字符集 <small>(ASCII 始终包含)</small></div>
                    <div class="fg-presets"></div>
                    <div class="fg-section">要包含的字
                        <span class="fm-spacer"></span>
                        <button class="fm-row-btn" data-fg="from-input" title="提取 REPL 输入框里代码的字符串">从输入框提取</button>
                        <button class="fm-row-btn" data-fg="from-file" title="提取 .scm 源码里所有字符串用到的字">从 .scm 提取…</button>
                        <button class="fm-row-btn" data-fg="clear">清空</button>
                        <input type="file" class="fg-src-file" accept=".scm,.ss,.txt,.json" multiple hidden>
                    </div>
                    <textarea class="fg-chars" spellcheck="false" placeholder="直接输入或粘贴需要的字，例如：温度湿度光照亮度"></textarea>
                    <div class="fg-stats"></div>
                </div>
                <div class="fg-side">
                    <div class="fg-section">预览 <small class="fg-zoom">(设备上的实际效果)</small></div>
                    <textarea class="fg-sample" spellcheck="false" rows="3"></textarea>
                    <div class="fg-preview-wrap"><canvas class="fg-preview"></canvas><div class="fg-preview-hint">点击“生成预览”</div></div>
                    <div class="fg-result"></div>
                </div>
            </div>
            <div class="fg-actions">
                <button class="pill-btn" data-fg="preview">⟳ 生成预览</button>
                <span class="fm-spacer"></span>
                <button class="pill-btn" data-fg="download">⬇ 下载 .mfnt</button>
                <button class="pill-btn" data-fg="save-fs" title="保存为 /spiffs/fonts/&lt;名称&gt;.mfnt，可用 font-load 或 use-font 加载">保存到文件系统</button>
                <button class="action-btn" data-fg="rom">写入系统字库 ROM</button>
            </div>`;
        const q = (s) => container.querySelector(s);
        this.el = {
            engine: q('.fg-engine'), face: q('.fg-face'), fontFile: q('.fg-font-file'), size: q('.fg-size'),
            yoff: q('.fg-yoff'), spacing: q('.fg-spacing'), bpp: q('.fg-bpp'), name: q('.fg-name'), usage: q('.fg-usage'), presets: q('.fg-presets'),
            chars: q('.fg-chars'), stats: q('.fg-stats'), srcFile: q('.fg-src-file'), sample: q('.fg-sample'),
            preview: q('.fg-preview'), previewHint: q('.fg-preview-hint'), result: q('.fg-result'),
            fontFileBtn: q('[data-fg="font-file"]'), zoom: q('.fg-zoom'), previewWrap: q('.fg-preview-wrap'),
        };
        this.el.sample.value = FG_SAMPLE;
        container.addEventListener('click', (e) => {
            const b = e.target.closest('[data-fg]');
            if (b && !b.disabled) this._action(b.dataset.fg);
        });
        const changed = () => this._update();
        this.el.face.addEventListener('change', () => { this._autoName(); changed(); });
        this.el.size.addEventListener('input', () => { this._autoName(); changed(); });
        this.el.yoff.addEventListener('input', changed);
        this.el.spacing.addEventListener('change', changed);
        this.el.bpp.addEventListener('change', changed);
        this.el.chars.addEventListener('input', changed);
        this.el.name.addEventListener('input', () => { this.nameEdited = true; changed(); });
        this.el.sample.addEventListener('input', () => this._drawPreview());
        this.el.presets.addEventListener('change', changed);
        this.el.srcFile.addEventListener('change', async () => {
            const files = Array.from(this.el.srcFile.files || []);
            this.el.srcFile.value = '';
            let text = '';
            for (const f of files) text += fgSourceChars(await f.text());
            this._appendChars(text, `从 ${files.map((f) => f.name).join(', ')} 提取`);
        });
        this.el.fontFile.addEventListener('change', async () => {
            const file = this.el.fontFile.files && this.el.fontFile.files[0];
            this.el.fontFile.value = '';
            if (file) await this._useFontFile(file);
        });
    }

    /** Called each time the view is shown */
    async show() {
        if (!this.engine) {
            this.host.status('加载字体列表…');
            this.engine = (await ServerFontEngine.probe()) || new BrowserFontEngine();
            this.browserEngine = this.engine instanceof BrowserFontEngine ? this.engine : null;
            try {
                let r = await fetch('data/font_charsets.json');
                if (!r.ok) r = await fetch('font_charsets.json');
                const data = await r.json();
                const byId = new Map(data.presets.map((p) => [p.id, p]));
                this.presets = data.presets.map((p) => ({
                    id: p.id, label: p.label,
                    chars: p.parts ? p.parts.map((id) => byId.get(id).chars).join('') : p.chars,
                }));
            } catch (e) {
                this.presets = [{ id: 'ascii', label: 'ASCII 可打印字符', chars: FG_ASCII }];
            }
            this._renderPresets();
            await this._loadFaces();
            this._autoName();
        }
        this.el.engine.textContent = this.engine.label;
        this._update();
        this.host.status('选择字体、字号和要包含的字，然后生成预览');
    }

    async _loadFaces(selectKey) {
        this.faceList = await this.engine.faces();
        const sel = this.el.face;
        sel.textContent = '';
        const groups = [['中文字体', this.faceList.filter((f) => f.cjk)], ['其他字体', this.faceList.filter((f) => !f.cjk)]];
        for (const [label, list] of groups) {
            if (!list.length) continue;
            const og = document.createElement('optgroup');
            og.label = label;
            for (const f of list) {
                const o = document.createElement('option');
                o.value = f.key;
                o.textContent = `${f.family_zh ? f.family_zh + ' · ' : ''}${f.family}${f.file ? ' (' + f.file + ')' : ''}`;
                og.appendChild(o);
            }
            sel.appendChild(og);
        }
        const preferred = selectKey || (this.faceList.find((f) => f.id === 'simsun') || this.faceList[0] || {}).key;
        if (preferred) sel.value = preferred;
    }

    _renderPresets() {
        this.el.presets.textContent = '';
        for (const p of this.presets) {
            const label = document.createElement('label');
            label.className = 'fg-preset';
            const cb = document.createElement('input');
            cb.type = 'checkbox';
            cb.value = p.id;
            if (p.id === 'ascii') { cb.checked = true; cb.disabled = true; }
            label.append(cb, ` ${p.label} `);
            const n = document.createElement('small');
            n.textContent = `${new Set(Array.from(p.chars)).size}`;
            label.appendChild(n);
            this.el.presets.appendChild(label);
        }
    }

    _face() { return this.faceList.find((f) => f.key === this.el.face.value) || this.faceList[0]; }
    _size() { return Math.max(FG_MIN_SIZE, Math.min(FG_MAX_SIZE, parseInt(this.el.size.value, 10) || 16)); }
    _presetIds() {
        return Array.from(this.el.presets.querySelectorAll('input:checked')).map((c) => c.value).filter((id) => id !== 'ascii');
    }
    _yOffset() { return this.el.yoff.value.trim() === '' ? null : parseInt(this.el.yoff.value, 10); }

    _autoName() {
        if (this.nameEdited) return;
        const f = this._face();
        this.el.name.value = f ? `${f.id}-${this._size()}`.slice(0, 23) : '';
    }

    _allChars() {
        const set = new Set([...FG_ASCII, ...fgUnique(this.el.chars.value)]);
        const ids = new Set(this._presetIds());
        for (const p of this.presets) if (ids.has(p.id)) for (const c of p.chars) set.add(c);
        return set;
    }

    _bpp() {
        const v = Number(this.el.bpp.value);
        return [1, 2, 4].includes(v) ? v : 1;
    }

    _key() {
        const f = this._face();
        return JSON.stringify([f && f.key, this._size(), this._yOffset(), this.el.spacing.value, this._bpp(), this.el.name.value, this._presetIds(),
            fgUnique(this.el.chars.value).sort().join('')]);
    }

    _update() {
        const chars = this._allChars();
        const est = fgEstimate(chars, this._size(), this._bpp());
        const sp = this.host.space();
        const free = sp && sp.capacity ? sp.capacity - sp.used : null;
        const name = this.el.name.value.trim();
        const m = /^(.+)-(\d+)$/.exec(name);
        this.el.usage.textContent = name ? (m ? `(use-font 2 "${m[1]}" ${m[2]})` : `(use-font 2 "${name}")`) : '';
        this.el.name.classList.toggle('fg-bad', !FG_NAME_RE.test(name));
        this.el.stats.textContent = `共 ${chars.size} 个字 · 预计约 ${fmFormatSize(est)}` +
            (free !== null ? ` · 系统字库剩余 ${fmFormatSize(free)}` : '') +
            (free !== null && est > free ? ' (空间不够)' : '');
        this.el.stats.classList.toggle('fg-warn', free !== null && est > free);
        if (this.result && this._key() !== this.resultKey) {
            this.el.result.textContent = '参数已修改，安装前会重新生成';
        }
    }

    _appendChars(text, what) {
        const have = new Set(Array.from(this.el.chars.value));
        const add = fgUnique(text).filter((c) => !have.has(c) && c.codePointAt(0) >= 128);
        this.el.chars.value += add.join('');
        this._update();
        this.host.status(`${what}：新增 ${add.length} 个非 ASCII 字`, 'ok');
    }

    async _useFontFile(file) {
        if (!this.browserEngine) this.browserEngine = new BrowserFontEngine();
        try {
            const entry = await this.browserEngine.addFile(file);
            this.engine = this.browserEngine;
            this.el.engine.textContent = `浏览器渲染 (字体文件 ${file.name})`;
            this.nameEdited = false;
            await this._loadFaces(entry.key);
            this._autoName();
            this._update();
            this.host.status(`已载入字体文件 ${file.name}`, 'ok');
        } catch (e) {
            this.host.status(`无法载入字体文件 ${file.name}: ${e.message || e}`, 'error');
        }
    }

    async _action(act) {
        switch (act) {
            case 'back': this.host.back(); break;
            case 'font-file': this.el.fontFile.click(); break;
            case 'from-file': this.el.srcFile.click(); break;
            case 'from-input': this._appendChars(fgSourceChars(this.host.inputText() || ''), '从输入框提取'); break;
            case 'clear': this.el.chars.value = ''; this._update(); break;
            case 'preview': await this.host.run('生成字库…', () => this._generate()); break;
            case 'download': await this.host.run('生成字库…', async () => this._download(await this._generate())); break;
            case 'save-fs': await this.host.run('生成字库…', async () => this._saveFs(await this._generate())); break;
            case 'rom': await this.host.run('生成字库…', async () => this._installRom(await this._generate())); break;
            default: break;
        }
    }

    /** Generates (or reuses) the font for the current settings */
    async _generate() {
        const name = this.el.name.value.trim();
        if (!FG_NAME_RE.test(name)) throw new Error('名称只能包含字母、数字、点、下划线和连字符，最多 23 个字符');
        const key = this._key();
        if (this.result && key === this.resultKey) return this.result;
        const ids = new Set(this._presetIds());
        const presetText = this.presets.filter((p) => ids.has(p.id));
        const total = this._allChars().size;
        this.host.status(`生成 ${name}：${total} 个字${total > 2000 ? '，需要几秒钟' : ''}…`);
        const t0 = performance.now();
        const r = await this.engine.make({
            face: this._face(),
            size: this._size(),
            yOffset: this._yOffset(),
            spacing: this.el.spacing.value,
            bpp: this._bpp(),
            name,
            chars: fgUnique(this.el.chars.value).join(''),
            presets: this.engine instanceof ServerFontEngine ? Array.from(ids) : presetText.map((p) => p.chars),
        });
        r.font = mfntDecode(r.data);
        r.ms = Math.round(performance.now() - t0);
        this.result = r;
        this.resultKey = key;
        this._drawPreview();
        const miss = r.missing ? `；字体里没有 ${Array.from(r.missing).length} 个字，设备上用内置字体显示: ${Array.from(r.missing).slice(0, 40).join('')}${Array.from(r.missing).length > 40 ? '…' : ''}` : '';
        const aa = r.font.bpp > 1 ? `，${r.font.bpp} 位抗锯齿` : '';
        this.el.result.textContent = `${r.name}: ${r.glyphs} 个字形${aa}，${fmFormatSize(r.bytes)}，用时 ${r.ms} ms${miss}`;
        this.host.status(`已生成 ${r.name} (${fmFormatSize(r.bytes)})`, 'ok');
        return r;
    }

    _drawPreview() {
        if (!this.result) return;
        // whole pixels only: 320 device columns at 1x..3x as the panel allows
        const scale = Math.max(1, Math.min(3, Math.floor((this.el.previewWrap.clientWidth - 14) / 320)));
        mfntDrawPreview(this.el.preview, this.result.font, this.el.sample.value || FG_SAMPLE, 320, scale);
        this.el.zoom.textContent = `(设备上的实际效果，屏宽 320 px，${scale} 倍)`;
        this.el.previewHint.hidden = true;
    }

    _download(r) {
        const url = URL.createObjectURL(new Blob([r.data], { type: 'application/octet-stream' }));
        const a = document.createElement('a');
        a.href = url;
        a.download = `${r.name}.mfnt`;
        document.body.appendChild(a);
        a.click();
        a.remove();
        setTimeout(() => URL.revokeObjectURL(url), 1000);
        this.host.status(`已下载 ${r.name}.mfnt`, 'ok');
    }

    async _saveFs(r) {
        const inner = `/fonts/${r.name}.mfnt`;
        if (inner.length > FG_PATH_NAME_MAX) throw new Error(`设备上的文件名最长 ${FG_PATH_NAME_MAX} 字节，请把名称缩短到 ${FG_PATH_NAME_MAX - 12} 个字符以内`);
        const path = `/spiffs${inner}`;
        const backend = this.host.backend();
        await backend.fsWrite(path, r.data, (done, total) => {
            if (total > 0) this.host.status(`上传 ${path}… ${Math.round(done * 100 / total)}%`);
        });
        this.host.log('info', `🔤 已保存字库 ${path} (${r.bytes} 字节)`);
        this.host.status(`已保存 ${path}，应用里用 ${this.el.usage.textContent} 或 (font-load 2 "${path}") 加载`, 'ok');
    }

    async _installRom(r) {
        await this.host.installRom(r.data, r.name);
        this.host.status(`已写入系统字库 ROM: ${r.name}，应用里用 ${this.el.usage.textContent}`, 'ok');
    }
}
