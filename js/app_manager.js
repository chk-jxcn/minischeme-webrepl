/**
 * @file app_manager.js
 * @brief App manager for the WebREPL: the apps installed on the target (the
 *        board over HTTP or serial, or the WASM device), with their metadata,
 *        a settings form built from each app's [fields], the raw ini, the
 *        boot app, and installing the apps built into web_repl/apps/.
 *
 * A backend provides label, kind ('wasm' | 'device'), apps() -> the JSON of
 * the firmware's GET /api/apps (serial: "@APPS"; simulator: wasm_apps_json) ({boot, apps: [{path, id, name, description,
 * version, pages, size, ini, boot, meta}]}), run(source) -> printed result,
 * fsRead(path) -> Uint8Array, fsWrite(path, bytes), fsRemove(path) and
 * reset(). The form logic matches the board's settings page
 * (examples/esp_idf/main/setup_page.html); keep the two in step.
 */

const AM_GITHUB_APPS_INDEX = 'https://raw.githubusercontent.com/chk-jxcn/minischeme-apps/main/apps/index.json';
const AM_GITHUB_RELEASE_BASE = 'https://github.com/chk-jxcn/minischeme-apps/releases/latest/download/';
const AM_LOCAL_INDEX = 'apps/index.json';

function amEsc(s) {
    return String(s == null ? '' : s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
}

function amRel(p) { return p.startsWith('/spiffs/') ? p.slice(8) : p; }

function amSize(n) {
    if (n == null || n < 0) return '?';
    return n < 1024 ? `${n} B` : n < 1048576 ? `${(n / 1024).toFixed(1)} KB` : `${(n / 1048576).toFixed(2)} MB`;
}

/* INI as the firmware reads it (mini_device_config_value): the value ends at
 * the first ; or #. Returns {section: [{key, value, comment}]} */
function amParseIni(text) {
    const out = {};
    let sec = '';
    for (const raw of String(text || '').split('\n')) {
        const t = raw.replace(/\r$/, '').trim();
        if (!t || t[0] === ';' || t[0] === '#') continue;
        const m = t.match(/^\[(.+)\]$/);
        if (m) { sec = m[1].trim(); out[sec] = out[sec] || []; continue; }
        const eq = t.indexOf('=');
        if (eq < 0) continue;
        const rest = t.slice(eq + 1);
        const c = rest.search(/[;#]/);
        (out[sec] = out[sec] || []).push({
            key: t.slice(0, eq).trim(),
            value: (c >= 0 ? rest.slice(0, c) : rest).trim(),
            comment: c >= 0 ? rest.slice(c + 1).trim() : '',
        });
    }
    return out;
}

function amIniValues(text) {
    const v = {};
    for (const items of Object.values(amParseIni(text))) for (const it of items) if (!(it.key in v)) v[it.key] = it.value;
    return v;
}

/* key = value in [section], the comment kept (column 23, as the firmware
 * writes it); a missing key goes to the end of its section */
function amIniSet(text, section, key, value) {
    const lines = String(text || '').split('\n');
    let sec = '', last = -1, found = false;
    for (let i = 0; i < lines.length; i++) {
        const t = lines[i].trim();
        const m = t.match(/^\[(.+)\]$/);
        if (m) { sec = m[1].trim(); continue; }
        if (sec === section && t) last = i;
        if (!t || t[0] === ';' || t[0] === '#') continue;
        const eq = lines[i].indexOf('=');
        if (eq < 0 || lines[i].slice(0, eq).trim() !== key) continue;
        const rest = lines[i].slice(eq + 1);
        const c = rest.search(/[;#]/);
        const head = `${key} = ${value}`;
        lines[i] = c < 0 ? head : (head.length < 23 ? head.padEnd(23) : head + ' ') + rest.slice(c).trim();
        found = true;
        break;
    }
    if (!found) {
        if (last >= 0) lines.splice(last + 1, 0, `${key} = ${value}`);
        else lines.push(`[${section}]`, `${key} = ${value}`);
    }
    return lines.join('\n');
}

/* [config] keys in order, described by [fields] ("type | label | help") */
function amAppFields(meta) {
    const ini = amParseIni(meta);
    const desc = {
        proxy_url: { type: 'text', label: '应用代理地址', help: '留空默认使用系统配置 (config.ini)' },
        converter_url: { type: 'text', label: '协议转换器地址', help: '留空默认使用系统配置 (config.ini)' },
    };
    for (const f of ini.fields || []) {
        const [type, label, help] = `${f.value}||`.split('|').map((x) => x.trim());
        desc[f.key] = { type: type || 'text', label, help };
    }
    return (ini.config || []).map((c) => {
        let defVal = c.value;
        if ((c.key === 'proxy_url' && defVal === 'http://proxy.local:8087') ||
            (c.key === 'converter_url' && defVal === 'http://converter.local:8087')) {
            defVal = '';
        }
        return Object.assign(
            { key: c.key, def: defVal, type: 'text', label: c.key, help: c.comment }, desc[c.key] || {});
    });
}

/* The ini the app's first start writes from its metadata */
function amDefaultIni(app) {
    let meta = app.meta || '';
    meta = meta.replace(/^(\s*proxy_url\s*=\s*)http:\/\/proxy\.local:8087/gm, '$1')
               .replace(/^(\s*converter_url\s*=\s*)http:\/\/converter\.local:8087/gm, '$1');
    const at = meta.search(/^[ \t]*\[config\]/m);
    return '; settings of this app; they override config.ini\n' + (at >= 0 ? meta.slice(at) : '[config]\n');
}

class AppManager {
    /**
     * @param {object} opts
     * @param {() => object} opts.getBackend the backend, or throws a message
     * @param {(kind: string, text: string) => void} [opts.log] terminal output
     */
    constructor({ getBackend, log }) {
        this.getBackend = getBackend;
        this.log = log || (() => {});
        this.backend = null;
        this.apps = [];
        this.bundled = [];
        this.open_ = {};      // index -> 'form' | 'file'
        this.busy = false;
        this._build();
    }

    _build() {
        const root = document.createElement('div');
        root.className = 'fm-overlay am-overlay';
        root.hidden = true;
        root.innerHTML = `
            <div class="fm-dialog" role="dialog" aria-modal="true" aria-labelledby="am-title">
                <div class="fm-head">
                    <span class="fm-title" id="am-title">📦 App 管理</span>
                    <span class="fm-target"></span>
                    <button class="fm-close" data-act="close" title="关闭 (Esc)" aria-label="关闭">&times;</button>
                </div>
                <div class="fm-toolbar">
                    <span class="am-boot"></span>
                    <span class="fm-spacer"></span>
                    <button class="pill-btn" data-act="refresh">⟳ 刷新</button>
                    <button class="pill-btn" data-act="reset" title="重启设备，运行启动应用">⏻ 重启并运行启动应用</button>
                </div>
                <div class="am-body">
                    <h4 class="am-h">设备上的应用</h4>
                    <div class="am-installed">—</div>
                    <h4 class="am-h">可安装的应用 <span class="am-note am-market-note">（读取自 GitHub 官方应用仓库）</span></h4>
                    <div class="am-bundled">—</div>
                </div>
                <div class="fm-status" role="status" aria-live="polite"></div>
            </div>`;
        document.body.appendChild(root);
        const q = (sel) => root.querySelector(sel);
        this.el = {
            root, target: q('.fm-target'), boot: q('.am-boot'), installed: q('.am-installed'),
            bundled: q('.am-bundled'), status: q('.fm-status'), resetBtn: q('[data-act="reset"]'),
            marketNote: q('.am-market-note'),
        };
        root.addEventListener('click', (e) => {
            if (e.target === root) { this.close(); return; }
            const btn = e.target.closest('[data-act]');
            if (btn && !btn.disabled) this._action(btn.dataset.act, btn.dataset.i);
        });
        root.addEventListener('keydown', (e) => {
            if (e.key === 'Escape') { e.preventDefault(); this.close(); }
        });
    }

    async open() {
        try {
            this.backend = this.getBackend();
        } catch (e) {
            this.log('error', `📦 App 管理: ${e.message || e}`);
            return;
        }
        this.el.target.textContent = this.backend.label || '';
        this.el.resetBtn.hidden = typeof this.backend.reset !== 'function';
        this.el.root.hidden = false;
        this.el.root.tabIndex = -1;
        this.el.root.focus();
        await this.refresh();
    }

    close() { this.el.root.hidden = true; }

    _status(text, kind) {
        this.el.status.textContent = text || '';
        this.el.status.className = 'fm-status' + (kind ? ` fm-status-${kind}` : '');
    }

    async _run(label, fn) {
        if (this.busy) return undefined;
        this.busy = true;
        if (label) this._status(label);
        try {
            const r = await fn();
            if (label) this._status('');
            return r;
        } catch (e) {
            this._status(e.message || String(e), 'error');
            return undefined;
        } finally {
            this.busy = false;
        }
    }

    async refresh() {
        await this._run('读取应用列表…', async () => {
            const r = await this.backend.apps();
            if (!r || !r.success) throw new Error((r && r.error) || '读取应用列表失败');
            this.apps = r.apps || [];
            this.bootPath = r.boot || '';
            this.open_ = {};
            try {
                let res = await fetch(AM_GITHUB_APPS_INDEX, { cache: 'no-store' });
                if (!res.ok) res = await fetch(AM_LOCAL_INDEX, { cache: 'no-store' });
                const list = res.ok ? await res.json() : [];
                this.bundled = list.filter((b) => (b.kind || 'app') === 'app');
                this.marketSource = res.url.includes('github') ? 'GitHub 官方市场' : '本地离线包';
            } catch (e) {
                try {
                    const res = await fetch(AM_LOCAL_INDEX, { cache: 'no-store' });
                    this.bundled = (res.ok ? await res.json() : []).filter((b) => (b.kind || 'app') === 'app');
                    this.marketSource = '本地离线包';
                } catch (err) {
                    this.bundled = [];
                    this.marketSource = '离线';
                }
            }
            this._render();
        });
    }

    _render() {
        if (this.el.marketNote) {
            this.el.marketNote.textContent = `（来源: ${this.marketSource || 'GitHub 官方市场'}）`;
        }
        const bootApp = this.apps.find((a) => a.boot);
        this.el.boot.innerHTML = `启动应用：<b>${amEsc(bootApp ? bootApp.name : amRel(this.bootPath))}</b>`;
        this.el.installed.innerHTML = this.apps.map((a, i) => `
            <div class="am-app">
                <div class="am-name">${amEsc(a.name)}${a.boot ? '<span class="am-tag">启动</span>' : ''}</div>
                <div class="am-desc">${amEsc(a.description)}</div>
                <div class="am-desc">${amEsc(amRel(a.path))} · ${amSize(a.size)} · v${amEsc(a.version)} · 配置 ${amEsc(amRel(a.ini))}</div>
                <div class="am-actions">
                    ${a.boot ? '' : `<button class="pill-btn" data-act="boot" data-i="${i}">设为启动应用</button>`}
                    ${this.backend.reset ? `<button class="pill-btn" data-act="run" data-i="${i}">设为启动并重启</button>` : ''}
                    ${amAppFields(a.meta).length ? `<button class="pill-btn" data-act="form" data-i="${i}">配置</button>` : ''}
                    <button class="pill-btn" data-act="file" data-i="${i}">编辑配置文件</button>
                    <button class="pill-btn" data-act="delete" data-i="${i}">删除</button>
                </div>
                <div class="am-box" id="am-box-${i}"></div>
            </div>`).join('') || '<div class="am-desc">设备上没有应用，可以从下面安装</div>';
        const byId = new Map(this.apps.map((a) => [a.id, a]));
        this.el.bundled.innerHTML = this.bundled.map((b, i) => {
            const have = byId.get(b.id);
            const state = !have ? '未安装' : (have.size === b.size && have.version === b.version ? '已安装' : '有更新');
            return `
            <div class="am-app">
                <div class="am-name">${amEsc(b.name)} <span class="am-note">${state}</span></div>
                <div class="am-desc">${amEsc(b.description)}</div>
                <div class="am-desc">${amEsc(b.file)} · ${amSize(b.size)} · v${amEsc(b.version)}</div>
                <div class="am-actions">
                    <button class="pill-btn highlight" data-act="edit" data-i="${i}">📝 编辑源码</button>
                    ${state === '已安装' ? '' : `<button class="pill-btn" data-act="install" data-i="${i}">${have ? '更新' : '安装'}</button>`}
                </div>
            </div>`;
        }).join('') || '<div class="am-desc">没有找到 apps/index.json（运行 tools/build_apps.py 生成）</div>';
    }

    async _action(act, i) {
        const n = Number(i);
        switch (act) {
            case 'close': this.close(); break;
            case 'refresh': await this.refresh(); break;
            case 'reset': await this._reset(); break;
            case 'boot': await this._setBoot(n, false); break;
            case 'run': await this._setBoot(n, true); break;
            case 'form': await this._toggleForm(n); break;
            case 'file': await this._toggleFile(n); break;
            case 'save-form': await this._saveForm(n); break;
            case 'reset-form': await this._resetForm(n); break;
            case 'save-file': await this._saveFile(n); break;
            case 'delete': await this._delete(n); break;
            case 'install': await this._install(n); break;
            case 'edit': {
                this.close();
                if (window.SchemeEditor) {
                    window.SchemeEditor.openWithApp(this.bundled[n]);
                }
                break;
            }
            default: break;
        }
    }

    async _readIni(app) {
        try {
            const bytes = await this.backend.fsRead(app.ini);
            return new TextDecoder('utf-8').decode(bytes);
        } catch (e) {
            return null;  // no ini yet: the app writes its defaults on the first start
        }
    }

    async _writeText(path, text) {
        await this.backend.fsWrite(path, new TextEncoder().encode(text));
    }

    /* An app's server addresses: shown without the device's key, each with its
     * app service password below it (real boards: the device registers there) */
    static get SERVER_KEYS() { return ['proxy_url', 'proxy', 'converter_url']; }

    _serverPwHtml(i, key, password, relay) {
        const id = `am-f${i}-${key}_password`;
        return `<label class="am-label" for="${id}">${amEsc(key)} 的应用服务密码</label>
            <input type="text" id="${id}" value="${amEsc(password)}" autocomplete="off" spellcheck="false" maxlength="64"
                placeholder="留空：系统配置里同一服务器的密码">
            <div class="am-help">明文显示；设备用它在这台服务器注册加密通道，注册后与服务器绑定：改了服务器地址才能修改。留空：不加密，明文 HTTP，请求头带设备 ID</div>
            <label class="am-check"><input type="checkbox" id="am-f${i}-${key}_relay"${relay ? ' checked' : ''}>
                没有密码时经系统协议转换器转发（有密码时只用这台服务器自己的转换器）</label>`;
    }

    /* bound (the device registered there) and the address unchanged: read-only */
    _applyServerPwLock(i) {
        const st = (this.formState_ || {})[i];
        if (!st) return;
        const W = window.DeviceSetupWizard;
        for (const k of AppManager.SERVER_KEYS) {
            const srv = document.getElementById(`am-f${i}-${k}`), pw = document.getElementById(`am-f${i}-${k}_password`);
            if (!srv || !pw) continue;
            const sv = st.servers[k] || {};
            const bound = !!sv.key && !!W && W.urlOrigin(srv.value.trim()) === W.urlOrigin(sv.url);
            if (bound) pw.value = st.passwords[k] || '';
            pw.readOnly = bound;
            pw.style.opacity = bound ? '0.85' : '1';
            pw.title = bound ? '已在这台服务器注册：密码与服务器绑定，改了服务器地址才能修改' : '';
            const relay = document.getElementById(`am-f${i}-${k}_relay`);
            if (relay) relay.disabled = !!pw.value.trim();   // a password: its own converter only
        }
    }

    _fieldHtml(i, f, value) {
        if ((f.key === 'proxy_url' && value === 'http://proxy.local:8087') ||
            (f.key === 'converter_url' && value === 'http://converter.local:8087')) {
            value = '';
        }
        const id = `am-f${i}-${f.key}`;
        const help = f.help ? `<div class="am-help">${amEsc(f.help)}</div>` : '';
        if (f.type === 'bool') {
            const on = value === '1' || value === 'true' || value === 'on';
            return `<label class="am-check"><input type="checkbox" id="${id}"${on ? ' checked' : ''}> ${amEsc(f.label)}</label>${help}`;
        }
        let input;
        if (f.type.startsWith('select:')) {
            const opts = f.type.slice(7).split(',').map((o) => o.split('='));
            if (!opts.some(([v]) => v === value)) opts.unshift([value, value]);
            input = `<select id="${id}">${opts.map(([v, l]) =>
                `<option value="${amEsc(v)}"${v === value ? ' selected' : ''}>${amEsc(l || v)}</option>`).join('')}</select>`;
        } else if (f.type.startsWith('number')) {
            const [lo, hi] = (f.type.split(':')[1] || '').split('-');
            input = `<input type="number" id="${id}" value="${amEsc(value)}"${lo ? ` min="${lo}"` : ''}${hi ? ` max="${hi}"` : ''}>`;
        } else {
            const ph = (f.key === 'proxy_url' || f.key === 'converter_url' || f.def === '') ? ' placeholder="留空默认使用系统配置"' : '';
            input = `<input type="text" id="${id}" value="${amEsc(value)}"${ph}>`;
        }
        const st = (this.formState_ || {})[i];
        const pw = st && st.withPasswords && AppManager.SERVER_KEYS.includes(f.key)
            ? this._serverPwHtml(i, f.key, st.passwords[f.key] || '', st.relay[f.key]) : '';
        return `<label class="am-label" for="${id}">${amEsc(f.label)}</label>${input}${help}${pw}`;
    }

    async _toggleForm(i) {
        const box = document.getElementById(`am-box-${i}`);
        if (this.open_[i] === 'form') { box.innerHTML = ''; delete this.open_[i]; return; }
        const app = this.apps[i];
        const text = await this._run(`读取 ${amRel(app.ini)}…`, () => this._readIni(app));
        const values = amIniValues(text || amDefaultIni(app));
        // the server addresses without the device's key; their passwords (a
        // value registered before per-server passwords used the hardware password)
        const W = window.DeviceSetupWizard;
        const st = { servers: {}, passwords: {}, relay: {}, withPasswords: this.backend.kind !== 'wasm' && !!W };
        let legacy = null;
        for (const k of AppManager.SERVER_KEYS) {
            if (!(k in values) || !W) continue;
            st.servers[k] = W.splitKeyedUrl(values[k]);
            values[k] = st.servers[k].url;
            st.relay[k] = values[k + '_relay'] === '1';
            if ((k + '_password') in values) st.passwords[k] = values[k + '_password'];
            else if (st.servers[k].key && st.withPasswords) {
                if (legacy === null) {
                    try {
                        const sys = new TextDecoder('utf-8').decode(await this.backend.fsRead('/spiffs/config.ini'));
                        legacy = (W.parseIniMap(sys)['server.hardware_password'] || '').trim();
                    } catch (e) { legacy = ''; }
                }
                st.passwords[k] = legacy;
            }
        }
        (this.formState_ = this.formState_ || {})[i] = st;
        this.open_[i] = 'form';
        box.innerHTML = `<div class="am-form">
            ${amAppFields(app.meta).map((f) => this._fieldHtml(i, f, f.key in values ? values[f.key] : f.def)).join('')}
            <div class="am-actions">
                <button class="action-btn" data-act="save-form" data-i="${i}">保存配置</button>
                <button class="pill-btn" data-act="reset-form" data-i="${i}">恢复默认</button>
            </div>
            <div class="am-help">${text == null ? '还没有配置文件，显示的是默认值；保存后写入 ' : '保存到 '}${amEsc(app.ini)}，应用重启后生效</div>
        </div>`;
        for (const k of AppManager.SERVER_KEYS) {
            for (const id of [`am-f${i}-${k}`, `am-f${i}-${k}_password`]) {
                const el = document.getElementById(id);
                if (el) el.addEventListener('input', () => this._applyServerPwLock(i));
            }
        }
        this._applyServerPwLock(i);
    }

    async _saveForm(i) {
        const app = this.apps[i];
        const ok = await this._run(`保存 ${amRel(app.ini)}…`, async () => {
            let text = (await this._readIni(app)) || amDefaultIni(app);
            const values = amIniValues(text);
            const st = (this.formState_ || {})[i] || { servers: {}, passwords: {} };
            const W = window.DeviceSetupWizard;
            for (const f of amAppFields(app.meta)) {
                const el = document.getElementById(`am-f${i}-${f.key}`);
                let v = f.type === 'bool' ? (el.checked ? '1' : '0') : el.value.trim();
                if (/[;#\n]/.test(v)) throw new Error(`${f.label}：不能含有 ; 或 #`);
                const sv = st.servers[f.key];
                if (sv && sv.key && v && W && W.urlOrigin(v) === W.urlOrigin(sv.url)) v = `${sv.key}@${v}`;   // the same server keeps its key
                if (values[f.key] !== v) text = amIniSet(text, 'config', f.key, v);
                const pw = document.getElementById(`am-f${i}-${f.key}_password`);
                if (pw && !pw.readOnly) {
                    const pv = pw.value.trim();
                    if (/[;#\s]/.test(pv)) throw new Error(`${f.key} 的应用服务密码：不能含有空格、; 或 #`);
                    if ((values[f.key + '_password'] || '') !== pv) text = amIniSet(text, 'config', f.key + '_password', pv);
                }
                const relay = document.getElementById(`am-f${i}-${f.key}_relay`);
                if (relay) {
                    const rv = relay.checked ? '1' : '0';
                    if ((values[f.key + '_relay'] || '0') !== rv) text = amIniSet(text, 'config', f.key + '_relay', rv);
                }
            }
            await this._writeText(app.ini, text);
            return true;
        });
        if (!ok) return;
        this._status(`${app.name} 的配置已保存，应用重启后生效`, 'ok');
        this.log('info', `📦 ${app.name}: 配置已保存到 ${app.ini}`);
    }

    async _resetForm(i) {
        const app = this.apps[i];
        if (!confirm(`把 ${app.name} 的配置恢复为默认值？`)) return;
        const ok = await this._run('写入默认配置…', async () => { await this._writeText(app.ini, amDefaultIni(app)); return true; });
        if (!ok) return;
        delete this.open_[i];
        await this._toggleForm(i);
        this._status('已恢复默认配置', 'ok');
    }

    async _toggleFile(i) {
        const box = document.getElementById(`am-box-${i}`);
        if (this.open_[i] === 'file') { box.innerHTML = ''; delete this.open_[i]; return; }
        const app = this.apps[i];
        const text = await this._run(`读取 ${amRel(app.ini)}…`, () => this._readIni(app));
        this.open_[i] = 'file';
        box.innerHTML = `<div class="am-form">
            <textarea class="fm-editor am-editor" id="am-t${i}" spellcheck="false"></textarea>
            <div class="am-actions"><button class="action-btn" data-act="save-file" data-i="${i}">保存文件</button></div>
            <div class="am-help">${amEsc(app.ini)}：覆盖 config.ini 中的同名项${text == null ? '（还没有这个文件，已填入默认值）' : ''}</div>
        </div>`;
        document.getElementById(`am-t${i}`).value = text == null ? amDefaultIni(app) : text;
    }

    async _saveFile(i) {
        const app = this.apps[i];
        const text = document.getElementById(`am-t${i}`).value;
        const ok = await this._run(`保存 ${amRel(app.ini)}…`, async () => { await this._writeText(app.ini, text); return true; });
        if (ok) this._status(`已保存 ${app.ini}，应用重启后生效`, 'ok');
    }

    async _setBoot(i, andRestart) {
        const app = this.apps[i];
        const ok = await this._run('设置启动应用…', async () => {
            const r = await this.backend.run(`(config-set! "system" "boot_app" "${amRel(app.path)}")`);
            if (String(r).trim() !== '#t') throw new Error(`没有写入 config.ini（${r}）`);
            return true;
        });
        if (!ok) return;
        this.log('info', `📦 启动应用改为 ${app.name} (${amRel(app.path)})`);
        if (andRestart) { await this._reset(); return; }
        await this.refresh();
        this._status(`${app.name} 已设为启动应用，重启后运行`, 'ok');
    }

    async _reset() {
        const ok = await this._run('重启设备…', async () => { await this.backend.reset(); return true; });
        if (!ok) return;
        if (this.backend.kind === 'wasm') await this.refresh();
        this._status(this.backend.kind === 'wasm' ? '模拟设备已重启，正在运行启动应用' : '设备正在重启，稍后点“刷新”', 'ok');
    }

    async _delete(i) {
        const app = this.apps[i];
        if (app.source === 'builtin') { this._status('内置应用不能删除', 'error'); return; }
        if (!confirm(`从设备删除 ${app.name}（${amRel(app.dir || app.path)} 中的镜像和配置）？`)) return;
        const ok = await this._run(`删除 ${app.name}…`, async () => {
            await this.backend.fsRemove(app.path);
            try { await this.backend.fsRemove(app.ini); } catch (e) { /* no ini */ }
            return true;
        });
        if (!ok) return;
        this.log('info', `📦 已删除 ${app.name}`);
        await this.refresh();
        this._status(`已删除 ${app.name}${app.boot ? '；它是启动应用，重启后会运行 app.msbc' : ''}`, 'ok');
    }

    async _install(i) {
        const b = this.bundled[i];
        const ok = await this._run(`安装 ${b.name}…`, async () => {
            let bytes = null;
            const urls = [
                `/api/release_asset?repo=minischeme-apps&asset=${encodeURIComponent(b.file)}`,
                `https://raw.githubusercontent.com/chk-jxcn/minischeme-apps/main/apps/${b.file}`,
                `https://raw.githubusercontent.com/chk-jxcn/minischeme-apps/main/dist/${b.file}`,
                `apps/${b.file}`,
                `${AM_GITHUB_RELEASE_BASE}${b.file}`
            ];
            for (const url of urls) {
                try {
                    const res = await fetch(url, { cache: 'no-store' });
                    if (res.ok) {
                        const buf = await res.arrayBuffer();
                        if (buf.byteLength > 100) {
                            bytes = new Uint8Array(buf);
                            break;
                        }
                    }
                } catch (e) { /* try next */ }
            }
            if (!bytes) {
                throw new Error(`读取 ${b.file} 失败 (GitHub 与本地均未获取到)`);
            }

            await this.backend.fsWrite(`/spiffs/apps/${b.id}/app.msbc`, bytes);   /* the app's folder, as the market */
            return true;
        });
        if (!ok) return;
        this.log('info', `📦 已安装 ${b.name} 到 /spiffs/apps/${b.id}/app.msbc`);
        await this.refresh();
        this._status(`已安装 ${b.name}，可以“设为启动并重启”运行它`, 'ok');
    }
}
