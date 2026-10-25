/*
 * 合并应用: several apps' pages in one app (apps/lib/combo.scm), built here.
 *
 * The chosen apps' code (apps/<id>/<id>.scm, as the market ships it; their
 * meta.ini from the image's trailer, apps/<id>.msbc) goes
 * after applib and combo.scm, each followed by (combo-member! id page-ids
 * defaults) (its meta.ini page_ids and [config] defaults), then
 * (combo-start! name); the WASM compiler makes the image, a meta.ini trailer
 * names the members ([combo] members: the firmware lets the app read their
 * own config.ini) and the pages to show (config entries; empty: every page).
 * The image goes to the target (WASM device or board) as
 * /spiffs/apps/combo/app.msbc; an existing combo's config.ini gets the new
 * entries. Each member keeps its settings in its own config.ini.
 */

const CB_LIBS = ['apps/lib/gui.scm', 'apps/lib/infopages.scm', 'apps/lib/applib.scm'];
const CB_WEB_LIB = 'apps/lib/appweb.scm';
const CB_COMBO_LIB = 'apps/lib/combo.scm';
const CB_COMBO_PAGE = 'apps/lib/combo_web.html';   // its own web page: pages, carousel, alerts
const CB_EXCLUDE = new Set(['settings', 'pcmonitor', 'combo']);   // not built on applib's app-define!
const CB_ID = 'combo';
const CB_PATH = `/spiffs/apps/${CB_ID}/app.msbc`;
const CB_INI = `/spiffs/apps/${CB_ID}/config.ini`;

function cbEsc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function cbSchemeString(s) {
    return '"' + String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
}

/* {section: [lines]} of an ini text */
function cbIniSections(text) {
    const out = {};
    let section = '';
    for (const line of String(text || '').replace(/\r\n/g, '\n').split('\n')) {
        const m = line.match(/^\s*\[([^\]]+)\]/);
        if (m) { section = m[1].trim().toLowerCase(); out[section] = out[section] || []; continue; }
        (out[section] = out[section] || []).push(line);
    }
    return out;
}

function cbIniValue(lines, key) {
    for (const line of lines || []) {
        const m = line.match(/^\s*([A-Za-z0-9_]+)\s*=\s*([^;#]*?)\s*(?:[;#].*)?$/);
        if (m && m[1] === key) return m[2];
    }
    return null;
}

/* text with key set in [config] (replaced in place, else added there) */
function cbIniSet(text, key, value) {
    const lines = String(text || '').replace(/\r\n/g, '\n').split('\n');
    const re = new RegExp(`^\\s*${key}\\s*=`);
    for (let i = 0; i < lines.length; i++) {
        if (re.test(lines[i])) { lines[i] = `${key} = ${value}`; return lines.join('\n'); }
    }
    const at = lines.findIndex(l => /^\s*\[config\]/i.test(l));
    if (at >= 0) lines.splice(at + 1, 0, `${key} = ${value}`);
    else lines.push('[config]', `${key} = ${value}`);
    return lines.join('\n');
}

/* The meta.ini text of an image's MSMD trailer, or '' */
function cbImageMeta(bytes) {
    const n = bytes.length;
    if (n < 20 || String.fromCharCode(...bytes.subarray(n - 4)) !== 'MSMD') return '';
    const dv = new DataView(bytes.buffer, bytes.byteOffset, n);
    const len = dv.getUint32(n - 12, true);
    if (len === 0 || len > n - 20) return '';
    return new TextDecoder().decode(bytes.subarray(n - 12 - len, n - 12));
}

function cbVersion(v) { return String(v || '1.0').split('.').map(x => parseInt(x, 10) || 0); }
function cbNewer(a, b) {
    const x = cbVersion(a), y = cbVersion(b);
    for (let i = 0; i < Math.max(x.length, y.length); i++) {
        if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) > (y[i] || 0);
    }
    return false;
}

class ComboBuilder {
    constructor(opts) {
        this.opts = opts;
        this.apps = [];      // [{id, name, ids, pages, views, web, api, defaults, source}]
        this.el = null;
    }

    log(kind, text) { if (this.opts.log) this.opts.log(kind, text); }

    _status(text, kind) {
        const s = this.el.status;
        s.textContent = text || '';
        s.className = 'fm-status' + (kind ? ` ${kind}` : '');
    }

    _build() {
        const root = document.createElement('div');
        root.className = 'fm-overlay';
        root.hidden = true;
        root.innerHTML = `
            <div class="fm-dialog" role="dialog" aria-modal="true" aria-labelledby="cb-title" style="max-width: 760px;">
                <div class="fm-head">
                    <span class="fm-title" id="cb-title">🧩 合并应用</span>
                    <span class="fm-target cb-target"></span>
                    <button class="fm-close" data-act="close" title="关闭 (Esc)">&times;</button>
                </div>
                <div style="padding: 14px 20px; overflow-y: auto; overflow-x: hidden; max-height: 70vh; font-size: 13px;">
                    <div style="color: var(--text-secondary); margin-bottom: 10px; line-height: 1.5;">
                        勾选要合并的应用，生成一个“${CB_ID}”应用装到当前目标：自动轮播时依次显示各应用的页面，标题显示所属应用和序号。
                        默认显示勾选应用的全部页面；也可以只勾选部分页面，或直接编辑下面的“显示的页面”（之后也能在设备的应用配置 entries 里改）。
                        各应用的设置仍在它自己的配置里。
                    </div>
                    <div style="display: grid; grid-template-columns: 110px 1fr 110px 90px; gap: 8px; align-items: center; margin-bottom: 10px;">
                        <label for="cb-name">合集名称:</label>
                        <input id="cb-name" class="device-host-input" value="合集" maxlength="20">
                        <label for="cb-seconds">每页秒数:</label>
                        <input id="cb-seconds" class="device-host-input" value="10" maxlength="40" title="一个数，或每页一个：15,10,10">
                    </div>
                    <div class="cb-apps" style="border: 1px solid var(--border-color); border-radius: 8px; padding: 8px 12px;"></div>
                    <div style="display: grid; grid-template-columns: 110px 1fr; gap: 8px; align-items: center; margin-top: 10px;">
                        <label for="cb-entries">显示的页面:</label>
                        <input id="cb-entries" class="device-host-input" spellcheck="false" placeholder="留空：勾选应用的全部页面" title="应用.英文页名，逗号分开，按顺序轮播；如 weather.front, calendar.today, wxpusher.news[0]">
                    </div>
                </div>
                <div class="fm-toolbar" style="padding: 12px 20px; border-top: 1px solid var(--border-color); display: flex; gap: 10px; justify-content: flex-end; flex-wrap: wrap;">
                    <button class="pill-btn" data-act="read" title="读取当前目标上已装的合集：成员与显示的页面">⟳ 读取已装的合集</button>
                    <button class="pill-btn" data-act="download" title="下载生成的 combo.msbc">⬇ 下载 .msbc</button>
                    <button class="action-btn highlight" data-act="install" style="background: var(--accent-blue); color: #fff; font-weight: 600;">🧩 生成并安装到当前目标</button>
                </div>
                <div class="fm-status" role="status" aria-live="polite"></div>
            </div>`;
        document.body.appendChild(root);
        const q = (s) => root.querySelector(s);
        this.el = {
            root, target: q('.cb-target'), apps: q('.cb-apps'), name: q('#cb-name'), seconds: q('#cb-seconds'),
            entries: q('#cb-entries'), status: q('.fm-status'),
        };
        root.addEventListener('click', (e) => {
            if (e.target === root) { this.close(); return; }
            const b = e.target.closest('[data-act]');
            if (!b) return;
            const act = b.dataset.act;
            if (act === 'close') this.close();
            else if (act === 'read') this._readInstalled();
            else if (act === 'download') this._download();
            else if (act === 'install') this._install();
        });
        root.addEventListener('change', (e) => {
            if (e.target.matches('.cb-app-check')) this._renderApps();
            if (e.target.matches('.cb-app-check, .cb-page-check')) this._syncEntries();
        });
        document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !root.hidden) this.close(); });
    }

    async open() {
        if (!this.el) this._build();
        this.el.root.hidden = false;
        try {
            const b = this.opts.getBackend();
            this.el.target.textContent = b.label;
        } catch (e) {
            this.el.target.textContent = '';
        }
        if (!this.apps.length) {
            this._status('正在读取应用列表…');
            try {
                await this._loadApps();
                this._status('');
            } catch (e) {
                this._status(`读取应用失败: ${e.message}`, 'error');
            }
        }
        this._renderApps();
    }

    close() { if (this.el) this.el.root.hidden = true; }

    async _fetchText(path) {
        const r = await fetch(path, { cache: 'no-store' });
        if (!r.ok) throw new Error(`${path}: HTTP ${r.status}`);
        return r.text();
    }

    /* The apps the market ships with their code: name, English page names,
     * page names (from the code's app-page calls), views, defaults */
    async _loadApps() {
        const index = JSON.parse(await this._fetchText('apps/index.json'));
        const out = [];
        for (const a of index) {
            if (CB_EXCLUDE.has(a.id)) continue;
            let source, meta;
            try {
                // the meta.ini the image carries (local servers do not serve .ini files)
                const image = await fetch(`apps/${a.file || a.id + '.msbc'}`, { cache: 'no-store' });
                if (!image.ok) continue;
                meta = cbImageMeta(new Uint8Array(await image.arrayBuffer()));
                source = await this._fetchText(`apps/${a.id}/${a.id}.scm`);
            } catch (e) { continue; }
            if (!/\(app-define!/.test(source)) continue;
            const secs = cbIniSections(meta);
            const ids = (cbIniValue(secs.app, 'page_ids') || '').split(',').map(s => s.trim()).filter(Boolean);
            const pages = [...source.matchAll(/\(app-(?:local-)?page\s+"([^"]+)"/g)].map(m => m[1]);
            const views = [...source.matchAll(/\(app-view!\s+"([^"]+)"\s+(\d+)/g)].map(m => ({ name: m[1], page: +m[2] }));
            const defaults = [];
            for (const line of secs.config || []) {
                const m = line.match(/^\s*([A-Za-z0-9_]+)\s*=\s*([^;#]*?)\s*(?:[;#].*)?$/);
                if (m) defaults.push([m[1], m[2]]);
            }
            out.push({ id: a.id, name: cbIniValue(secs.app, 'name') || a.name || a.id, ids, pages, views,
                       web: !!a.web, api: cbIniValue(secs.app, 'api') || a.api || '1.0', defaults, source });
        }
        this.apps = out;
    }

    _pageId(app, k) { return app.ids[k] || String(k + 1); }

    _renderApps() {
        const box = this.el.apps;
        const checked = new Set([...box.querySelectorAll('.cb-app-check:checked')].map(c => c.value));
        const pagesOff = new Set([...box.querySelectorAll('.cb-page-check:not(:checked)')].map(c => c.value));
        const viewsOn = new Set([...box.querySelectorAll('.cb-page-check.cb-view:checked')].map(c => c.value));
        if (this._preset) {   // from the installed combo
            checked.clear();
            this._preset.members.forEach(m => checked.add(m));
        }
        box.innerHTML = this.apps.map(app => {
            const on = checked.has(app.id);
            const pages = app.pages.map((name, k) => {
                const v = `${app.id}.${this._pageId(app, k)}`;
                const sel = this._preset ? (this._preset.entries.length === 0 || this._preset.entries.includes(v)) : !pagesOff.has(v);
                return `<label style="margin-right: 12px; white-space: nowrap;"><input type="checkbox" class="cb-page-check" value="${cbEsc(v)}" ${sel ? 'checked' : ''}> ${cbEsc(this._pageId(app, k))} <span style="color: var(--text-secondary);">${cbEsc(name)}</span></label>`;
            }).join('');
            const views = app.views.map(vw => {
                const v = `${app.id}.${vw.name}[0]`;
                const sel = this._preset ? this._preset.entries.includes(v) : viewsOn.has(v);
                return `<label style="margin-right: 12px; white-space: nowrap;" title="视图：${cbEsc(vw.name)}[0] 为最新一条，[1] 为第二条…"><input type="checkbox" class="cb-page-check cb-view" value="${cbEsc(v)}" ${sel ? 'checked' : ''}> ${cbEsc(vw.name)}[0] <span style="color: var(--text-secondary);">最新一条</span></label>`;
            }).join('');
            return `<div style="padding: 6px 0; border-bottom: 1px solid var(--border-color);">
                <label style="font-weight: 600;"><input type="checkbox" class="cb-app-check" value="${cbEsc(app.id)}" ${on ? 'checked' : ''}> ${cbEsc(app.name)} <span style="color: var(--text-secondary); font-weight: 400;">(${cbEsc(app.id)}，${app.pages.length} 页)</span></label>
                ${on ? `<div style="margin: 4px 0 0 22px; line-height: 1.9;">${pages}${views}</div>` : ''}
            </div>`;
        }).join('');
        if (this._preset) {
            this.el.entries.value = this._preset.entries.join(', ');
            this._preset = null;
        }
    }

    _members() {
        return this.apps.filter(a => this.el.apps.querySelector(`.cb-app-check[value="${a.id}"]`)?.checked);
    }

    /* The entries field from the checked pages: empty while every page of
     * every chosen app (and no view) is checked */
    _syncEntries() {
        const members = this._members();
        const pages = [...this.el.apps.querySelectorAll('.cb-page-check')];
        const all = pages.every(c => c.classList.contains('cb-view') ? !c.checked : c.checked);
        this.el.entries.value = all ? '' : pages.filter(c => c.checked).map(c => c.value).join(', ');
        if (!members.length) this.el.entries.value = '';
    }

    _source(members, name) {
        return Promise.all([...CB_LIBS, CB_WEB_LIB, CB_COMBO_LIB]
            .map(p => this._fetchText(p))).then(libs => {
            const parts = libs.slice();
            for (const m of members) {
                parts.push(`(combo-loading! ${cbSchemeString(m.id)})`);   // its folder and settings while it loads
                parts.push(m.source);
                parts.push(`(combo-member! ${cbSchemeString(m.id)} (list ${m.ids.map(cbSchemeString).join(' ')})\n` +
                           `               (list ${m.defaults.map(([k, v]) => `(cons ${cbSchemeString(k)} ${cbSchemeString(v)})`).join(' ')}))`);
            }
            parts.push(`(combo-start! ${cbSchemeString(name)})`);
            return parts.join('\n\n');
        });
    }

    _meta(members, name, entries, seconds) {
        const api = members.reduce((a, m) => (cbNewer(m.api, a) ? m.api : a), '1.0');
        const pages = entries ? entries.split(',').filter(s => s.trim()).length : members.reduce((n, m) => n + m.pages.length, 0);
        return `[app]
id = ${CB_ID}
name = ${name}
description = 合并应用：${members.map(m => m.name).join('、')} 的页面轮流显示；各应用的设置在它自己的配置里
version = 1
pages = ${pages}
api = ${api}

[combo]
members = ${members.map(m => m.id).join(', ')}

[fields]
entries = text | 显示的页面 | 逗号分开，按顺序轮播。应用.英文页名（如 weather.sevendays、calendar.today，front 为第一页），或应用提供的视图，如 wxpusher.news[0]（最新一条）。留空：全部页面
carousel = select:=跟随系统,1=自动轮播,0=手动翻页 | 自动轮播 | 留空跟随 config.ini
carousel_seconds = text | 每页秒数 | 一个数，或每页一个：15,10,10
alerts = text | 成员的强提醒 | 覆盖成员自己的提醒设置，逗号分开：应用:优先级[:结束方式[:秒数]]，如 wxpusher:7:both:60；优先级 0 关闭该应用的提醒

[config]
entries = ${entries}
carousel = 1
carousel_seconds = ${seconds}
alerts =
`;
    }

    /* The page section of the image (as tools/build_apps.py web_section): the
     * combined app's page with appweb.css and appweb.js inlined, gzip'd */
    async _pageSection() {
        const [html, css, js] = await Promise.all([CB_COMBO_PAGE, 'apps/lib/appweb.css', 'apps/lib/appweb.js']
            .map(p => this._fetchText(p)));
        const page = html.replace('<!-- appweb -->', `<style>\n${css}</style>\n<script>\n${js}</script>`);
        const gz = new Uint8Array(await new Response(new Blob([new TextEncoder().encode(page)])
            .stream().pipeThrough(new CompressionStream('gzip'))).arrayBuffer());
        const out = new Uint8Array(gz.length + 12);
        out.set(gz, 0);
        const dv = new DataView(out.buffer, gz.length);
        dv.setUint32(0, gz.length, true);
        dv.setUint32(4, fnv1a32(gz), true);
        out.set([0x4D, 0x53, 0x57, 0x50], gz.length + 8);   // "MSWP"
        return out;
    }

    /* {bytes, entries, seconds, members, name} of the combined app */
    async _make() {
        const members = this._members();
        if (!members.length) throw new Error('请至少勾选一个应用');
        if (typeof compileWithWasm !== 'function') throw new Error('编译器未就绪');
        const name = (this.el.name.value.trim() || '合集').replace(/[\r\n;#"\\]/g, '');
        const seconds = (this.el.seconds.value.trim() || '10').replace(/[^0-9,]/g, '') || '10';
        const entries = this.el.entries.value.trim().replace(/[\r\n;#]/g, '');
        const source = await this._source(members, name);
        const comp = compileWithWasm(source);
        if (!comp.success) throw new Error(`编译失败: ${comp.error}`);
        const code0 = comp.bytes;
        const pageBytes = await this._pageSection();
        const code = new Uint8Array(code0.length + pageBytes.length);   // code, its page, the meta trailer
        code.set(code0, 0);
        code.set(pageBytes, code0.length);
        const metaBytes = new TextEncoder().encode(this._meta(members, name, entries, seconds));
        const out = new Uint8Array(code.length + metaBytes.length + 12);
        out.set(code, 0);
        out.set(metaBytes, code.length);
        const dv = new DataView(out.buffer, code.length + metaBytes.length);
        dv.setUint32(0, metaBytes.length, true);
        dv.setUint32(4, fnv1a32(metaBytes), true);
        out.set([0x4D, 0x53, 0x4D, 0x44], code.length + metaBytes.length + 8);   // "MSMD"
        return { bytes: out, entries, seconds, members, name };
    }

    async _download() {
        try {
            const r = await this._make();
            const url = URL.createObjectURL(new Blob([r.bytes], { type: 'application/octet-stream' }));
            const a = document.createElement('a');
            a.href = url;
            a.download = `${CB_ID}.msbc`;
            a.click();
            setTimeout(() => URL.revokeObjectURL(url), 2000);
            this._status(`已生成 ${CB_ID}.msbc (${r.bytes.length} 字节)`, 'ok');
        } catch (e) {
            this._status(e.message, 'error');
        }
    }

    async _install() {
        let backend;
        try {
            backend = this.opts.getBackend();
        } catch (e) {
            this._status(e.message, 'error');
            return;
        }
        try {
            this._status('正在生成…');
            const r = await this._make();
            this._status(`正在安装到 ${backend.label}…`);
            await backend.fsWrite(CB_PATH, r.bytes);
            // an installed combo keeps its config.ini: the new pages and seconds go there too
            let ini = null;
            try { ini = new TextDecoder().decode(await backend.fsRead(CB_INI)); } catch (e) { ini = null; }
            if (ini && ini.trim()) {
                ini = cbIniSet(cbIniSet(ini, 'entries', r.entries), 'carousel_seconds', r.seconds);
                await backend.fsWrite(CB_INI, new TextEncoder().encode(ini));
            }
            this.log('info', `🧩 已安装合并应用 ${r.name} (${r.members.map(m => m.id).join(', ')}) 到 ${CB_PATH}，${r.bytes.length} 字节`);
            if (!confirm(`已安装 ${r.name}（${r.bytes.length} 字节）。设为启动应用并重启？`)) {
                this._status(`已安装到 ${CB_PATH}`, 'ok');
                return;
            }
            const set = await backend.run(`(config-set! "system" "boot_app" "apps/${CB_ID}/app.msbc")`);
            if (String(set).trim() !== '#t') throw new Error(`设置启动应用失败（${set}）`);
            if (backend.reset) await backend.reset();
            this._status(`${r.name} 已设为启动应用，正在重启`, 'ok');
        } catch (e) {
            this._status(`安装失败: ${e.message}`, 'error');
        }
    }

    /* The combo already on the target: its members and pages */
    async _readInstalled() {
        try {
            const backend = this.opts.getBackend();
            const meta = cbImageMeta(new Uint8Array(await backend.fsRead(CB_PATH)));
            if (!meta) throw new Error('当前目标上没有合并应用');
            const secs = cbIniSections(meta);
            let ini = '';
            try { ini = new TextDecoder().decode(await backend.fsRead(CB_INI)); } catch (e) { ini = ''; }
            const isecs = cbIniSections(ini);
            const entries = (cbIniValue(isecs.config, 'entries') ?? cbIniValue(secs.config, 'entries') ?? '')
                .split(',').map(s => s.trim()).filter(Boolean);
            this._preset = { members: (cbIniValue(secs.combo, 'members') || '').split(',').map(s => s.trim()).filter(Boolean), entries };
            this.el.name.value = cbIniValue(secs.app, 'name') || '合集';
            this.el.seconds.value = cbIniValue(isecs.config, 'carousel_seconds') || cbIniValue(secs.config, 'carousel_seconds') || '10';
            if (!this.apps.length) await this._loadApps();
            this._renderApps();
            this._status(`已读取 ${backend.label} 上的合并应用`, 'ok');
        } catch (e) {
            this._status(e.message, 'error');
        }
    }
}

window.ComboBuilder = ComboBuilder;
