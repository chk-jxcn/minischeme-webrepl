/**
 * @file font_manager.js
 * @brief System font ROM manager for the WebREPL: list, add and remove the
 *        MFNT fonts in the board's "fontrom" flash partition (or the WASM
 *        device's emulated one). Apps get them with (use-font id "face" size).
 *
 * A backend provides label, run(source) -> printed result (throws on error),
 * fsWrite(path, bytes[, onProgress]) and fsRemove(path). A font is added by
 * writing it to the file system and running (fontrom-add path name), so every link
 * (HTTP, serial, WASM) works the same way. Styles: the fm-* classes of the
 * file manager. The "生成字库" view (font_generator.js) makes new fonts.
 *
 * "设为默认" makes a font the system font: font_override system_16:<name>,
 * applied at once with (font-config ...) and kept in config.ini [fonts] with
 * (config-set! ...), so it is used again after a restart.
 */

const FONT_TMP_PATH = '/spiffs/fontrom.tmp';
const FONT_NAME_RE = /^[A-Za-z0-9._-]{1,23}$/;
const FONT_SECTOR = 4096;
const SYSTEM_FONT = 'system_16';   /* the built-in font a default font replaces */
const SYSTEM_FONT_HEIGHT = 16;

/* Name stored in an MFNT header (bytes 16..31), cleaned like the device does */
function fontStoredName(bytes) {
    let name = '';
    for (let i = 16; i < 32 && bytes[i]; i++) {
        const c = String.fromCharCode(bytes[i]);
        name += /[A-Za-z0-9._-]/.test(c) ? c : '_';
    }
    return name || 'font';
}

/* (("name" height glyphs bytes) ...) */
function parseFontList(text) {
    const fonts = [];
    const re = /\("((?:[^"\\]|\\.)*)"\s+(\d+)\s+(\d+)\s+(\d+)\)/g;
    let m;
    while ((m = re.exec(text)) !== null) {
        fonts.push({ name: m[1], height: +m[2], glyphs: +m[3], size: +m[4] });
    }
    return fonts;
}

/* (font-config) => ((app fontrom spiffs) (("system_16" . "simsun-16") ...)) */
function parseFontConfig(text) {
    const order = (/^\(\(([^()]*)\)/.exec(text.trim()) || [, 'app fontrom spiffs'])[1].trim().split(/\s+/).filter(Boolean);
    const overrides = [];
    const re = /\("((?:[^"\\]|\\.)*)"\s*\.\s*"((?:[^"\\]|\\.)*)"\)/g;
    let m;
    while ((m = re.exec(text)) !== null) overrides.push([m[1], m[2]]);
    return { order, overrides };
}

/* "<face>-<size>" suggests (use-font id "face" size) */
function fontUsage(name, id) {
    const m = /^(.+)-(\d+)$/.exec(name);
    return m ? `(use-font ${id} "${m[1]}" ${m[2]})` : `(use-font ${id} "${name}")`;
}

class FontManager {
    /**
     * @param {object} opts
     * @param {() => object} opts.getBackend returns the backend or throws a message
     * @param {(kind: string, text: string) => void} [opts.log] terminal output
     * @param {(code: string) => void} [opts.fillInput] puts code in the REPL input
     */
    constructor({ getBackend, log, fillInput, inputText }) {
        this.getBackend = getBackend;
        this.log = log || (() => {});
        this.fillInput = fillInput || (() => {});
        this.inputText = inputText || (() => '');
        this.backend = null;
        this.fonts = [];
        this.fontConfig = { order: [], overrides: [] };
        this.used = 0;
        this.capacity = 0;
        this.busy = false;
        this._build();
    }

    _build() {
        const root = document.createElement('div');
        root.className = 'fm-overlay';
        root.hidden = true;
        root.innerHTML = `
            <div class="fm-dialog" role="dialog" aria-modal="true" aria-labelledby="fr-title">
                <div class="fm-head">
                    <span class="fm-title" id="fr-title">🔤 系统字库 (Font ROM)</span>
                    <span class="fm-target"></span>
                    <button class="fm-close" data-act="close" title="关闭 (Esc)" aria-label="关闭">&times;</button>
                </div>
                <div class="fm-list-view">
                    <div class="fm-toolbar">
                        <div class="fm-usage" title="字库分区已用 / 总容量">
                            <div class="fm-usage-bar"><span></span></div>
                            <span class="fm-usage-text">—</span>
                        </div>
                        <span class="fm-spacer"></span>
                        <button class="pill-btn" data-act="refresh">⟳ 刷新</button>
                        <button class="pill-btn highlight" data-act="generate" title="选择字体、字号和字符，生成 .mfnt 并安装">✨ 生成字库</button>
                        <button class="pill-btn" data-act="add">⬆ 添加字库 (.mfnt)</button>
                        <input type="file" class="fm-file-input" accept=".mfnt" multiple hidden>
                    </div>
                    <div class="fm-table-wrap">
                        <table class="fm-table">
                            <thead><tr><th>字库名</th><th class="fm-num">字高</th><th class="fm-num">字数</th><th class="fm-num">大小</th><th class="fm-actions-col">操作</th></tr></thead>
                            <tbody></tbody>
                        </table>
                        <div class="fm-empty" hidden>字库分区中没有字库</div>
                        <div class="fm-drop-hint">
                            字库直接从 Flash 映射读取 (XIP)，不占 RAM。应用里写 <code>(use-font 2 "simsun" 16)</code> 就会使用名为 simsun-16 的字库；
                            应用自带字库时优先使用自带的。用 <code>tools/make_font.py</code> 生成 .mfnt，也可以把文件拖到这里。
                        </div>
                    </div>
                </div>
                <div class="fg-view" hidden></div>
                <div class="fm-status" role="status" aria-live="polite"></div>
            </div>`;
        document.body.appendChild(root);

        const q = (sel) => root.querySelector(sel);
        this.el = {
            root,
            listView: q('.fm-list-view'),
            genView: q('.fg-view'),
            dialog: q('.fm-dialog'),
            target: q('.fm-target'),
            usageBar: q('.fm-usage-bar span'),
            usageText: q('.fm-usage-text'),
            tbody: q('tbody'),
            empty: q('.fm-empty'),
            tableWrap: q('.fm-table-wrap'),
            fileInput: q('.fm-file-input'),
            status: q('.fm-status'),
        };

        root.addEventListener('click', (e) => {
            if (e.target === root) { this.close(); return; }
            const btn = e.target.closest('[data-act]');
            if (btn && !btn.disabled) this._action(btn.dataset.act, btn.dataset.name);
        });
        root.addEventListener('keydown', (e) => {
            if (e.key !== 'Escape') return;
            e.preventDefault();
            if (!this.el.genView.hidden) this._showList();
            else this.close();
        });
        this.generator = new FontGenerator(this.el.genView, {
            backend: () => this.backend,
            run: (label, fn) => this._run(label, fn),
            status: (text, kind) => this._status(text, kind),
            installRom: (bytes, name) => this._installRom(bytes, name),
            space: () => ({ used: this.used, capacity: this.capacity }),
            inputText: this.inputText || (() => ''),
            back: () => this._showList(),
            log: (kind, text) => this.log(kind, text),
        });
        this.el.fileInput.addEventListener('change', () => {
            const list = Array.from(this.el.fileInput.files || []);
            this.el.fileInput.value = '';
            if (list.length) this._add(list);
        });
        this.el.tableWrap.addEventListener('dragover', (e) => {
            e.preventDefault();
            e.stopPropagation();
            this.el.tableWrap.classList.add('fm-drop');
        });
        this.el.tableWrap.addEventListener('dragleave', () => this.el.tableWrap.classList.remove('fm-drop'));
        this.el.tableWrap.addEventListener('drop', (e) => {
            e.preventDefault();
            e.stopPropagation();
            this.el.tableWrap.classList.remove('fm-drop');
            const list = Array.from((e.dataTransfer && e.dataTransfer.files) || []);
            if (list.length) this._add(list);
        });
        root.addEventListener('dragover', (e) => { e.preventDefault(); e.stopPropagation(); });
        root.addEventListener('drop', (e) => { e.preventDefault(); e.stopPropagation(); });
    }

    async open() {
        try {
            this.backend = this.getBackend();
        } catch (e) {
            this.log('error', `字库管理不可用: ${e.message || e}`);
            return;
        }
        this.el.target.textContent = this.backend.label || '';
        this._showList(false);
        this.el.root.hidden = false;
        this._lastFocus = document.activeElement;
        this.el.dialog.querySelector('[data-act="refresh"]').focus();
        await this.refresh();
    }

    close() {
        if (this.busy) return;
        this.el.root.hidden = true;
        if (this._lastFocus && this._lastFocus.focus) this._lastFocus.focus();
    }

    _status(text, kind = 'info') {
        this.el.status.textContent = text || '';
        this.el.status.dataset.kind = kind;
    }

    async _run(label, fn) {
        if (this.busy) return undefined;
        this.busy = true;
        this.el.dialog.classList.add('fm-busy');
        this.el.dialog.querySelectorAll('button').forEach((b) => { b.disabled = true; });
        if (label) this._status(label);
        try {
            return await fn();
        } catch (e) {
            this._status(e.message || String(e), 'error');
            return undefined;
        } finally {
            this.busy = false;
            this.el.dialog.classList.remove('fm-busy');
            this.el.dialog.querySelectorAll('button').forEach((b) => { b.disabled = false; });
        }
    }

    _showList(reload = true) {
        this.el.genView.hidden = true;
        this.el.listView.hidden = false;
        if (reload && !this.el.root.hidden) this.refresh();
    }

    async _showGenerator() {
        this.el.listView.hidden = true;
        this.el.genView.hidden = false;
        await this.generator.show();
    }

    async refresh() {
        await this._run('读取字库列表…', () => this._load());
    }

    async _load() {
        const info = (await this.backend.run('(fontrom-info)')).trim();
        if (info === '#f') {
            this.fonts = [];
            this.capacity = 0;
            this._renderUsage();
            this._renderList();
            throw new Error('设备没有 fontrom 分区：需要烧录带新分区表的固件');
        }
        const nums = (info.match(/\d+/g) || []).map(Number);
        this.used = nums[0] || 0;
        this.capacity = nums[1] || 0;
        this.fonts = parseFontList(await this.backend.run('(fontrom-list)'));
        this.fontConfig = parseFontConfig(await this.backend.run('(font-config)'));
        this._renderUsage();
        this._renderList();
        this._status(`${this.fonts.length} 个字库，剩余 ${fmFormatSize(this.capacity - this.used)}`);
    }

    /* Writes bytes to the file system, copies them into the font ROM, removes the copy */
    async _installRom(bytes, name) {
        if (!this.capacity) await this._load();
        const old = this.fonts.find((f) => f.name === name);
        if (old && !confirm(`系统字库里已有 ${name}，替换吗？`)) throw new Error('已取消');
        const need = Math.ceil(bytes.length / FONT_SECTOR) * FONT_SECTOR;
        if (this.used + need > this.capacity) {
            throw new Error(`空间不足：需要 ${fmFormatSize(need)}，剩余 ${fmFormatSize(this.capacity - this.used)}`);
        }
        this._status(`上传 ${name}…`);
        await this.backend.fsWrite(FONT_TMP_PATH, bytes, (done, total) => {
            if (total > 0) this._status(`上传 ${name}… ${Math.round(done * 100 / total)}%`);
        });
        this._status(`写入 Flash 字库分区 ${name} (${fmFormatSize(bytes.length)})…`);
        try {
            await this.backend.run(`(fontrom-add "${FONT_TMP_PATH}" "${name}")`);
        } finally {
            try { await this.backend.fsRemove(FONT_TMP_PATH); } catch (e) { /* already gone */ }
        }
        this.log('info', `🔤 已写入系统字库 ${name} (${bytes.length} 字节)`);
        await this._load();
    }

    _renderUsage() {
        const pct = this.capacity > 0 ? Math.min(100, this.used * 100 / this.capacity) : 0;
        this.el.usageBar.style.width = `${pct.toFixed(1)}%`;
        this.el.usageBar.classList.toggle('fm-usage-high', pct > 85);
        this.el.usageText.textContent = this.capacity > 0
            ? `${fmFormatSize(this.used)} / ${fmFormatSize(this.capacity)} (${pct.toFixed(0)}%)`
            : '—';
    }

    _renderList() {
        const tbody = this.el.tbody;
        tbody.textContent = '';
        for (const f of this.fonts) {
            const tr = document.createElement('tr');
            const nameTd = document.createElement('td');
            const nameSpan = document.createElement('span');
            nameSpan.className = 'fm-name';
            nameSpan.textContent = f.name;
            nameTd.appendChild(nameSpan);
            const isDefault = f.name === this._defaultFont();
            if (isDefault) {
                const badge = document.createElement('span');
                badge.className = 'fm-badge';
                badge.textContent = '默认';
                badge.title = '系统默认字体 (config.ini [fonts] font_override = system_16:' + f.name + ')';
                nameTd.appendChild(badge);
            }
            const cells = [f.height, f.glyphs, fmFormatSize(f.size)].map((v) => {
                const td = document.createElement('td');
                td.className = 'fm-num';
                td.textContent = String(v);
                return td;
            });
            const actTd = document.createElement('td');
            actTd.className = 'fm-actions';
            actTd.append(
                isDefault
                    ? this._rowButton('undefault', f.name, '恢复内置', '系统文字改回固件内置的 16 px 字体')
                    : this._rowButton('default', f.name, '设为默认', `系统文字 (0 号字体) 改用 ${f.name}，并保存到 config.ini`),
                this._rowButton('use', f.name, '填入用法', `把 ${fontUsage(f.name, 2)} 填入输入框`),
                this._rowButton('remove', f.name, '删除', '', true),
            );
            tr.append(nameTd, ...cells, actTd);
            tbody.appendChild(tr);
        }
        this.el.empty.hidden = this.fonts.length > 0;
    }

    _rowButton(act, name, text, title = '', danger = false) {
        const b = document.createElement('button');
        b.className = 'fm-row-btn' + (danger ? ' fm-danger' : '');
        b.dataset.act = act;
        b.dataset.name = name;
        b.textContent = text;
        if (title) b.title = title;
        return b;
    }

    async _action(act, name) {
        switch (act) {
            case 'close': this.close(); break;
            case 'refresh': await this.refresh(); break;
            case 'add': this.el.fileInput.click(); break;
            case 'generate': await this._showGenerator(); break;
            case 'remove': await this._remove(name); break;
            case 'default': await this._setDefault(name); break;
            case 'undefault': await this._setDefault(null); break;
            case 'use':
                this.fillInput(fontUsage(name, 2));
                this.close();
                break;
            default: break;
        }
    }

    async _add(list) {
        const added = [];
        await this._run(null, async () => {
            for (const file of list) {
                const bytes = new Uint8Array(await file.arrayBuffer());
                if (bytes.length < 32 || String.fromCharCode(...bytes.subarray(0, 4)) !== 'MFNT') {
                    throw new Error(`${file.name} 不是 MFNT 字库 (请用 tools/make_font.py 生成)`);
                }
                let name = fontStoredName(bytes);
                for (;;) {
                    name = prompt(`字库名 (应用用 "名称-字号" 引用，例如 simsun-16):`, name);
                    if (name === null) break;
                    name = name.trim();
                    if (FONT_NAME_RE.test(name)) break;
                    alert('字库名只能包含字母、数字、点、下划线和连字符，最多 23 个字符');
                }
                if (name === null) continue;
                await this._installRom(bytes, name);
                added.push(name);
            }
        });
        if (!added.length) return;
        await this.refresh();
        this._status(`已添加 ${added.join(', ')}。应用里用 ${fontUsage(added[0], 2)} 引用`, 'ok');
    }

    /** Font ROM font that replaces the built-in system font, or null */
    _defaultFont() {
        const o = this.fontConfig.overrides.find(([from]) => from === SYSTEM_FONT);
        return o ? o[1] : null;
    }

    /** Makes name the system font (null: back to the built-in one), now and after a restart */
    async _setDefault(name) {
        const font = name && this.fonts.find((f) => f.name === name);
        if (font && font.height !== SYSTEM_FONT_HEIGHT &&
            !confirm(`${name} 字高 ${font.height} px，内置系统字体是 ${SYSTEM_FONT_HEIGHT} px。` +
                     '系统文字会变大或变小，应用的布局可能错位。仍然设为默认字体？')) return;
        const overrides = this.fontConfig.overrides.filter(([from]) => from !== SYSTEM_FONT);
        if (name) overrides.unshift([SYSTEM_FONT, name]);
        const order = (this.fontConfig.order.length ? this.fontConfig.order : ['app', 'fontrom', 'spiffs']).join(', ');
        const text = overrides.map(([from, to]) => `${from}:${to}`).join(', ');
        let why = '';
        const saved = await this._run(name ? `设置默认字体 ${name}…` : '恢复内置字体…', async () => {
            // apps on applib draw their text with the default font too (app-refresh-fonts!)
            await this.backend.run(`(begin (font-config "${order}" "${text}") ` +
                `(if (defined? 'app-refresh-fonts!) (app-refresh-fonts!)) (gui-invalidate) #t)`);
            try {
                return (await this.backend.run(`(config-set! "fonts" "font_override" "${text}")`)).trim() === '#t';
            } catch (e) {
                why = /config-set!/.test(e.message || '') ? '固件没有 config-set!，请更新固件' : (e.message || String(e));
                return false;
            }
        });
        if (saved === undefined) return;
        await this.refresh();
        const what = name ? `默认字体改为 ${name}` : '已恢复内置字体';
        this._status(saved ? `${what}，已生效并保存到 config.ini，重启后仍然有效`
            : `${what}，已生效；但没有保存到 config.ini (${why || '写入失败'})，重启后恢复原设置`, saved ? 'ok' : 'error');
        this.log('info', `🔤 ${what}${saved ? ' (config.ini [fonts] font_override 已保存)' : ` (未保存 config.ini: ${why || '写入失败'})`}`);
    }

    async _remove(name) {
        const isDefault = name === this._defaultFont();
        if (!confirm(`从字库分区删除 ${name}？使用它的应用会改用系统字体。` +
                     (isDefault ? '它是当前的默认字体，系统文字会改回内置字体。' : ''))) return;
        const ok = await this._run(`删除 ${name}…`, async () => {
            const r = (await this.backend.run(`(fontrom-remove "${name}")`)).trim();
            if (r !== '#t') throw new Error(`没有名为 ${name} 的字库`);
            return true;
        });
        if (!ok) return;
        this.log('info', `🔤 已删除字库 ${name}`);
        await this.refresh();
        this._status(`已删除 ${name}`, 'ok');
    }
}
