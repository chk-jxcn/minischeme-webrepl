/**
 * @file file_manager.js
 * @brief File manager for the WebREPL: list, upload, download, rename,
 *        delete and edit text files on the board (HTTP or serial link) or in
 *        the WASM device's simulated file system (LittleFS on the board,
 *        mounted at /spiffs).
 *
 * A backend provides label, fsList() -> {total, used, files: [{path, size}]},
 * fsRead(path[, onProgress]) -> Uint8Array, fsWrite(path, bytes[, onProgress]),
 * fsRemove(path), fsRename(from, to) and optionally reset(); failures throw.
 * HttpDeviceLink and SerialDeviceLink (device_link.js) are backends as they
 * are; WasmFsBackend below wraps the wasm_fs_* exports.
 */

const FM_ROOT = '/spiffs/';
/* Paths below /spiffs/ (the board's mount point): the firmware takes paths
 * shorter than 64 bytes without "..", so names up to 55 characters, with
 * subdirectories ("fonts/x.mfnt"); no spaces, since the serial protocol
 * splits its arguments on them */
const FM_NAME_MAX = 55;
const FM_SEGMENT_RE = /^[A-Za-z0-9._-]+$/;

function fmValidName(name) {
    return name.length > 0 && name.length <= FM_NAME_MAX && !name.includes('..') &&
        name.split('/').every((seg) => FM_SEGMENT_RE.test(seg) && seg !== '.');
}
const FM_TEXT_EXT = /\.(ini|cfg|conf|txt|scm|ss|json|csv|md|log|html?|js|css|xml|ya?ml|py|sh)$/i;
const FM_EDIT_MAX = 64 * 1024;

/* What a file is, by folder: the root holds the system's files, apps/<id>/ and
 * user/<id>/ an app's (market and uploaded ones) */
const FM_SPECIAL = {
    'app.msbc': '旧式开机应用 · 字节码',
    'app.fasl': '旧式开机应用 · 堆快照',
    'config.ini': '系统配置 · 重启后生效',
    'theme.css': '系统配色（所有应用）',
    'app.romsig': '内嵌应用签名',
    'upload.tmp': '上传暂存文件',
};
const FM_APP_SPECIAL = {
    'app.msbc': '应用镜像 · 字节码，启动时映射为 Flash ROM',
    'app.fasl': '应用镜像 · 堆快照',
    'config.ini': '应用配置',
    'schedule.ini': '定时启动',
    'theme.css': '应用配色',
};

function fmTag(dir, name) {
    if (!dir) return FM_SPECIAL[name] || '';
    return /^(apps|user)\/[^/]+\/$/.test(dir) ? (FM_APP_SPECIAL[name] || '') : '';
}

const FM_ERRORS = {
    'no such file': '文件不存在',
    'target exists': '目标文件已存在',
    'file system full': '文件系统空间不足',
    'path must be under /spiffs/': '路径必须位于 /spiffs/ 下',
    'remove failed': '删除失败',
    'rename failed': '重命名失败',
};

function fmErrorText(e) {
    const msg = (e && e.message) || String(e);
    return FM_ERRORS[msg] || msg;
}

function fmFormatSize(n) {
    if (n < 0) return '?';
    if (n < 1024) return `${n} B`;
    if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
    return `${(n / 1048576).toFixed(2)} MB`;
}

const FM_FOLD_AT = 10;   // a folder of more files starts folded (an app's picture cache)

function fmBaseName(path) {
    return path.startsWith(FM_ROOT) ? path.slice(FM_ROOT.length) : path;
}

/* ---- Backup and restore: every file in one standard ZIP ---------------- */

/* Not backed up or restored: records of the board's App ROM slots and its
 * staging file (rebuilt by the firmware; wrong after a reflash) */
const FM_BACKUP_SKIP = new Set(['.approm', 'app.romsig', 'upload.tmp']);

const FM_CRC_TABLE = (() => {
    const t = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
        let c = n;
        for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
        t[n] = c >>> 0;
    }
    return t;
})();

function fmCrc32(bytes) {
    let c = 0xFFFFFFFF;
    for (let i = 0; i < bytes.length; i++) c = FM_CRC_TABLE[(c ^ bytes[i]) & 0xFF] ^ (c >>> 8);
    return (c ^ 0xFFFFFFFF) >>> 0;
}

/* entries [{name, data: Uint8Array}] -> a ZIP Blob (stored, UTF-8 names) */
function fmZip(entries) {
    const enc = new TextEncoder();
    const d = new Date();
    const time = (d.getHours() << 11) | (d.getMinutes() << 5) | (d.getSeconds() >> 1);
    const date = ((d.getFullYear() - 1980) << 9) | ((d.getMonth() + 1) << 5) | d.getDate();
    const parts = [], central = [];
    let offset = 0;
    for (const e of entries) {
        const name = enc.encode(e.name), crc = fmCrc32(e.data), n = e.data.length;
        const h = new DataView(new ArrayBuffer(30));
        h.setUint32(0, 0x04034b50, true); h.setUint16(4, 20, true); h.setUint16(6, 0x0800, true);
        h.setUint16(10, time, true); h.setUint16(12, date, true); h.setUint32(14, crc, true);
        h.setUint32(18, n, true); h.setUint32(22, n, true); h.setUint16(26, name.length, true);
        parts.push(new Uint8Array(h.buffer), name, e.data);
        const c = new DataView(new ArrayBuffer(46));
        c.setUint32(0, 0x02014b50, true); c.setUint16(4, 20, true); c.setUint16(6, 20, true);
        c.setUint16(8, 0x0800, true); c.setUint16(12, time, true); c.setUint16(14, date, true);
        c.setUint32(16, crc, true); c.setUint32(20, n, true); c.setUint32(24, n, true);
        c.setUint16(28, name.length, true); c.setUint32(42, offset, true);
        central.push(new Uint8Array(c.buffer), name);
        offset += 30 + name.length + n;
    }
    const size = central.reduce((s, p) => s + p.length, 0);
    const end = new DataView(new ArrayBuffer(22));
    end.setUint32(0, 0x06054b50, true); end.setUint16(8, entries.length, true);
    end.setUint16(10, entries.length, true); end.setUint32(12, size, true); end.setUint32(16, offset, true);
    return new Blob([...parts, ...central, new Uint8Array(end.buffer)], { type: 'application/zip' });
}

/* A ZIP (ours, or stored / deflated by another tool) -> [{name, data}] */
async function fmUnzip(buf) {
    const v = new DataView(buf), u8 = new Uint8Array(buf);
    let eocd = -1;
    for (let i = buf.byteLength - 22; i >= Math.max(0, buf.byteLength - 65557); i--) {
        if (v.getUint32(i, true) === 0x06054b50) { eocd = i; break; }
    }
    if (eocd < 0) throw new Error('不是 zip 文件');
    const count = v.getUint16(eocd + 10, true);
    let p = v.getUint32(eocd + 16, true);
    const dec = new TextDecoder(), out = [];
    for (let i = 0; i < count; i++) {
        if (v.getUint32(p, true) !== 0x02014b50) throw new Error('zip 文件的目录损坏');
        const method = v.getUint16(p + 10, true), crc = v.getUint32(p + 16, true);
        const csize = v.getUint32(p + 20, true), nlen = v.getUint16(p + 28, true);
        const local = v.getUint32(p + 42, true);
        const name = dec.decode(u8.subarray(p + 46, p + 46 + nlen));
        p += 46 + nlen + v.getUint16(p + 30, true) + v.getUint16(p + 32, true);
        if (name.endsWith('/')) continue;
        const start = local + 30 + v.getUint16(local + 26, true) + v.getUint16(local + 28, true);
        let data = u8.slice(start, start + csize);
        if (method === 8) {
            const stream = new Blob([data]).stream().pipeThrough(new DecompressionStream('deflate-raw'));
            data = new Uint8Array(await new Response(stream).arrayBuffer());
        } else if (method !== 0) {
            throw new Error(`${name}: 不支持的压缩方式 (${method})`);
        }
        if (fmCrc32(data) !== crc) throw new Error(`${name}: 校验失败，备份文件已损坏`);
        out.push({ name, data });
    }
    return out;
}

/* The WASM device's simulated file system (wasm_fs_* exports in wasm_bridge.c) */
class WasmFsBackend {
    constructor(getExports, getMemory) {
        this.getExports = getExports;
        this.getMemory = getMemory;
        this.kind = 'wasm';
    }

    get label() { return `WASM 设备仿真 (模拟文件系统${this.persistent ? '，保存在浏览器中' : ''})`; }

    _ex() {
        const ex = this.getExports();
        if (!ex || !ex.wasm_fs_list) throw new Error('WASM 引擎未就绪');
        return ex;
    }

    _str(text) {
        const bytes = new TextEncoder().encode(text + '\0');
        const ex = this._ex();
        const ptr = ex.wasm_alloc_buffer(bytes.length);
        new Uint8Array(this.getMemory().buffer, ptr, bytes.length).set(bytes);
        return ptr;
    }

    _readStr(ptr) {
        const mem = new Uint8Array(this.getMemory().buffer);
        let end = ptr;
        while (mem[end] !== 0) end++;
        return new TextDecoder().decode(mem.subarray(ptr, end));
    }

    /* Calls an export taking string arguments; a non-NULL result is an error */
    _call(name, ...texts) {
        const ex = this._ex();
        const ptrs = texts.map((t) => this._str(t));
        const err = ex[name](...ptrs);
        ptrs.forEach((p) => ex.wasm_free_buffer(p));
        if (err) throw new Error(this._readStr(err));
    }

    async fsList() { return JSON.parse(this._readStr(this._ex().wasm_fs_list())); }

    async fsRead(path) {
        const ex = this._ex();
        const p = this._str(path);
        const size = ex.wasm_fs_size(p);
        const data = size >= 0 ? ex.wasm_fs_data(p) : 0;
        ex.wasm_free_buffer(p);
        if (size < 0) throw new Error('no such file');
        return new Uint8Array(this.getMemory().buffer, data, size).slice();
    }

    async fsWrite(path, bytes) {
        const ex = this._ex();
        const p = this._str(path);
        const buf = ex.wasm_alloc_buffer(bytes.length || 1);
        new Uint8Array(this.getMemory().buffer, buf, bytes.length).set(bytes);
        const err = ex.wasm_fs_write(p, buf, bytes.length);
        ex.wasm_free_buffer(buf);
        ex.wasm_free_buffer(p);
        if (err) throw new Error(this._readStr(err));
    }

    async fsRemove(path) { this._call('wasm_fs_remove', path); }
    async fsRename(from, to) { this._call('wasm_fs_rename', from, to); }
}

class FileManager {
    /**
     * @param {object} opts
     * @param {() => object} opts.getBackend returns the backend or throws a message
     * @param {(kind: string, text: string) => void} [opts.log] terminal output
     */
    constructor({ getBackend, log }) {
        this.getBackend = getBackend;
        this.log = log || (() => {});
        this.backend = null;
        this.files = [];
        this.busy = false;
        this.editPath = null;
        this.editSaved = '';
        this._build();
    }

    /* ------------------------------------------------------------------ */
    /* DOM                                                                */
    /* ------------------------------------------------------------------ */

    _build() {
        const root = document.createElement('div');
        root.className = 'fm-overlay';
        root.hidden = true;
        root.innerHTML = `
            <div class="fm-dialog" role="dialog" aria-modal="true" aria-labelledby="fm-title">
                <div class="fm-head">
                    <span class="fm-title" id="fm-title">🗂️ 文件管理</span>
                    <span class="fm-target"></span>
                    <button class="fm-close" data-act="close" title="关闭 (Esc)" aria-label="关闭">&times;</button>
                </div>
                <div class="fm-list-view">
                    <div class="fm-toolbar">
                        <div class="fm-usage" title="文件系统已用 / 总容量">
                            <div class="fm-usage-bar"><span></span></div>
                            <span class="fm-usage-text">—</span>
                        </div>
                        <span class="fm-spacer"></span>
                        <button class="pill-btn" data-act="refresh">⟳ 刷新</button>
                        <button class="pill-btn" data-act="upload">⬆ 上传文件</button>
                        <button class="pill-btn" data-act="new">＋ 新建文本</button>
                        <button class="pill-btn" data-act="backup" title="把文件系统里的所有文件下载成一个 zip（刷机、换分区前先备份）">⬇ 备份全部</button>
                        <button class="pill-btn" data-act="restore" title="把备份 zip 里的文件写回文件系统，同名覆盖">⬆ 恢复备份</button>
                        <button class="pill-btn" data-act="reset" title="重启后 config.ini 与开机应用的修改才会生效">⏻ 重启设备</button>
                        <button class="pill-btn" data-act="wipe" title="清除浏览器中保存的模拟文件系统与系统字库，恢复初始状态" hidden>清空模拟 Flash</button>
                        <input type="file" class="fm-file-input" multiple hidden>
                        <input type="file" class="fm-restore-input" accept=".zip,application/zip" hidden>
                    </div>
                    <div class="fm-table-wrap">
                        <table class="fm-table">
                            <thead><tr><th>文件</th><th class="fm-num">大小</th><th class="fm-actions-col">操作</th></tr></thead>
                            <tbody></tbody>
                        </table>
                        <div class="fm-empty" hidden>没有文件</div>
                        <div class="fm-drop-hint">也可以把文件拖到这里上传</div>
                    </div>
                </div>
                <div class="fm-edit-view" hidden>
                    <div class="fm-toolbar">
                        <button class="pill-btn" data-act="back">← 返回列表</button>
                        <span class="fm-edit-path"></span>
                        <span class="fm-dirty" hidden>● 未保存</span>
                        <span class="fm-spacer"></span>
                        <span class="fm-edit-info"></span>
                        <button class="action-btn fm-save" data-act="save">保存 (Ctrl+S)</button>
                    </div>
                    <textarea class="fm-editor" spellcheck="false" autocomplete="off" aria-label="文件内容"></textarea>
                </div>
                <div class="fm-status" role="status" aria-live="polite"></div>
            </div>`;
        document.body.appendChild(root);

        const q = (sel) => root.querySelector(sel);
        this.el = {
            root,
            dialog: q('.fm-dialog'),
            target: q('.fm-target'),
            listView: q('.fm-list-view'),
            editView: q('.fm-edit-view'),
            usageBar: q('.fm-usage-bar span'),
            usageText: q('.fm-usage-text'),
            tbody: q('tbody'),
            empty: q('.fm-empty'),
            tableWrap: q('.fm-table-wrap'),
            fileInput: q('.fm-file-input'),
            restoreInput: q('.fm-restore-input'),
            resetBtn: q('[data-act="reset"]'),
            wipeBtn: q('[data-act="wipe"]'),
            editPath: q('.fm-edit-path'),
            dirty: q('.fm-dirty'),
            editInfo: q('.fm-edit-info'),
            editor: q('.fm-editor'),
            status: q('.fm-status'),
        };

        root.addEventListener('click', (e) => {
            if (e.target === root) { this.close(); return; }
            const btn = e.target.closest('[data-act]');
            if (btn && !btn.disabled) this._action(btn.dataset.act, btn.dataset.path);
        });
        root.addEventListener('keydown', (e) => {
            if (e.key === 'Escape') { e.preventDefault(); this._escape(); }
            if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's' && this.editPath) {
                e.preventDefault();
                this._save();
            }
        });
        this.el.restoreInput.addEventListener('change', () => {
            const file = this.el.restoreInput.files && this.el.restoreInput.files[0];
            this.el.restoreInput.value = '';
            if (file) this._restore(file);
        });
        this.el.fileInput.addEventListener('change', () => {
            const list = Array.from(this.el.fileInput.files || []);
            this.el.fileInput.value = '';
            if (list.length) this._upload(list);
        });
        // Drops here upload to the file system instead of reaching the page's run-file drop handler
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
            if (list.length) this._upload(list);
        });
        root.addEventListener('dragover', (e) => { e.preventDefault(); e.stopPropagation(); });
        root.addEventListener('drop', (e) => { e.preventDefault(); e.stopPropagation(); });

        this.el.editor.addEventListener('input', () => this._updateDirty());
        this.el.editor.addEventListener('keydown', (e) => {
            if (e.key === 'Tab' && !e.shiftKey && !e.ctrlKey) {
                e.preventDefault();
                this.el.editor.setRangeText('  ', this.el.editor.selectionStart, this.el.editor.selectionEnd, 'end');
                this._updateDirty();
            }
        });
    }

    /* ------------------------------------------------------------------ */
    /* Open / close                                                       */
    /* ------------------------------------------------------------------ */

    async open() {
        try {
            this.backend = this.getBackend();
        } catch (e) {
            this.log('error', `文件管理不可用: ${fmErrorText(e)}`);
            return;
        }
        this.el.target.textContent = this.backend.label || '';
        this.el.resetBtn.hidden = typeof this.backend.reset !== 'function';
        this.el.wipeBtn.hidden = typeof this.backend.wipe !== 'function';
        this._showList();
        this.el.root.hidden = false;
        this._lastFocus = document.activeElement;
        this.el.dialog.querySelector('[data-act="refresh"]').focus();
        await this.refresh();
    }

    close() {
        if (this.editPath && this._isDirty() && !confirm('有未保存的修改，确定关闭吗？')) return;
        this.editPath = null;
        this.el.root.hidden = true;
        if (this._lastFocus && this._lastFocus.focus) this._lastFocus.focus();
    }

    _escape() {
        if (this.editPath) this._backToList();
        else this.close();
    }

    /* ------------------------------------------------------------------ */
    /* Busy state and status                                              */
    /* ------------------------------------------------------------------ */

    _status(text, kind = 'info') {
        this.el.status.textContent = text || '';
        this.el.status.dataset.kind = kind;
    }

    async _run(label, fn) {
        if (this.busy) return undefined;
        this.busy = true;
        this.el.dialog.classList.add('fm-busy');
        this.el.dialog.querySelectorAll('button').forEach((b) => {
            if (b.dataset.act !== 'close') b.disabled = true;
        });
        if (label) this._status(label);
        try {
            return await fn();
        } catch (e) {
            this._status(fmErrorText(e), 'error');
            return undefined;
        } finally {
            this.busy = false;
            this.el.dialog.classList.remove('fm-busy');
            this.el.dialog.querySelectorAll('button').forEach((b) => { b.disabled = b.dataset.locked === '1'; });
        }
    }

    _progress(verb, name) {
        return (done, total) => {
            if (total > 0) this._status(`${verb} ${name}… ${Math.round(done * 100 / total)}%`);
        };
    }

    /* ------------------------------------------------------------------ */
    /* List view                                                          */
    /* ------------------------------------------------------------------ */

    async refresh() {
        await this._run('读取文件列表…', async () => {
            const r = await this.backend.fsList();
            this.files = (r.files || []).slice().sort((a, b) => a.path.localeCompare(b.path));
            this._renderUsage(r.used || 0, r.total || 0);
            this._renderList();
            this._status(`${this.files.length} 个文件`);
        });
    }

    _renderUsage(used, total) {
        const pct = total > 0 ? Math.min(100, used * 100 / total) : 0;
        this.el.usageBar.style.width = `${pct.toFixed(1)}%`;
        this.el.usageBar.classList.toggle('fm-usage-high', pct > 85);
        this.el.usageText.textContent = total > 0
            ? `${fmFormatSize(used)} / ${fmFormatSize(total)} (${pct.toFixed(0)}%)`
            : fmFormatSize(used);
    }

    /* The files grouped by folder: a header row per folder (its files and their size),
     * a click folds it; a folder of more than FM_FOLD_AT files starts folded */
    _renderList() {
        const tbody = this.el.tbody;
        tbody.textContent = '';
        if (!this.folded) this.folded = new Map();   // folder -> folded?
        const groups = new Map();
        for (const f of this.files) {
            const rel = fmBaseName(f.path);
            const cut = rel.lastIndexOf('/');
            const dir = cut >= 0 ? rel.slice(0, cut + 1) : '';
            if (!groups.has(dir)) groups.set(dir, []);
            groups.get(dir).push(f);
        }
        for (const [dir, files] of [...groups.entries()].sort((a, b) => a[0].localeCompare(b[0]))) {
            if (!this.folded.has(dir)) this.folded.set(dir, files.length > FM_FOLD_AT);
            const folded = this.folded.get(dir);
            const head = document.createElement('tr');
            head.className = 'fm-dir-row';
            const td = document.createElement('td');
            td.colSpan = 3;
            const total = files.reduce((n, f) => n + (f.size || 0), 0);
            td.textContent = `${folded ? '▸' : '▾'} ${dir || '/'}  ·  ${files.length} 个文件，${fmFormatSize(total)}`;
            td.title = folded ? '点击展开' : '点击折叠';
            head.appendChild(td);
            head.addEventListener('click', () => { this.folded.set(dir, !folded); this._renderList(); });
            tbody.appendChild(head);
            if (!folded) for (const f of files) this._renderFile(tbody, f, dir);
        }
        this.el.empty.hidden = this.files.length > 0;
    }

    _renderFile(tbody, f, dir) {
        {
            const name = fmBaseName(f.path).slice(dir.length);
            const tr = document.createElement('tr');

            const nameTd = document.createElement('td');
            const nameSpan = document.createElement('span');
            nameSpan.className = 'fm-name';
            nameSpan.textContent = name;
            nameSpan.title = f.path;
            nameTd.appendChild(nameSpan);
            if (fmTag(dir, name)) {
                const tag = document.createElement('span');
                tag.className = 'fm-tag';
                tag.textContent = fmTag(dir, name);
                nameTd.appendChild(tag);
            }

            const sizeTd = document.createElement('td');
            sizeTd.className = 'fm-num';
            sizeTd.textContent = fmFormatSize(f.size);
            sizeTd.title = `${f.size} 字节`;

            const actTd = document.createElement('td');
            actTd.className = 'fm-actions';
            const editable = this._looksText(f);
            actTd.append(
                this._rowButton('edit', f.path, '编辑', editable ? '' : '只能编辑文本文件', !editable),
                this._rowButton('download', f.path, '下载'),
                this._rowButton('rename', f.path, '重命名'),
                this._rowButton('delete', f.path, '删除', '', false, true),
            );
            tr.append(nameTd, sizeTd, actTd);
            tbody.appendChild(tr);
        }
    }

    _rowButton(act, path, text, title = '', disabled = false, danger = false) {
        const b = document.createElement('button');
        b.className = 'fm-row-btn' + (danger ? ' fm-danger' : '');
        b.dataset.act = act;
        b.dataset.path = path;
        b.textContent = text;
        if (title) b.title = title;
        if (disabled) b.dataset.locked = '1';
        b.disabled = disabled;
        return b;
    }

    _looksText(f) {
        return FM_TEXT_EXT.test(f.path) && f.size <= FM_EDIT_MAX;
    }

    _exists(path) {
        return this.files.some((f) => f.path === path);
    }

    /* Asks for a file name; returns a full /spiffs/ path or null */
    _askName(message, initial) {
        let name = initial;
        for (;;) {
            name = prompt(message, name);
            if (name === null) return null;
            name = name.trim().replace(/^\/?spiffs\//, '').replace(/^\//, '');
            if (fmValidName(name)) return FM_ROOT + name;
            message = `文件名只能包含字母、数字、点、下划线和连字符，可用 / 分隔子目录 (最多 ${FM_NAME_MAX} 个字符)，请重新输入:`;
        }
    }

    async _action(act, path) {
        switch (act) {
            case 'close': this.close(); break;
            case 'refresh': await this.refresh(); break;
            case 'upload': this.el.fileInput.click(); break;
            case 'new': await this._newFile(); break;
            case 'reset': await this._reset(); break;
            case 'wipe': await this._wipe(); break;
            case 'backup': await this._backup(); break;
            case 'restore': this.el.restoreInput.click(); break;
            case 'edit': await this._edit(path); break;
            case 'download': await this._download(path); break;
            case 'rename': await this._rename(path); break;
            case 'delete': await this._delete(path); break;
            case 'back': this._backToList(); break;
            case 'save': await this._save(); break;
            default: break;
        }
    }

    async _upload(list) {
        const done = [];
        await this._run(null, async () => {
            for (const file of list) {
                let path = FM_ROOT + file.name;
                if (!fmValidName(file.name)) {
                    const clean = file.name.replace(/[^A-Za-z0-9._-]/g, '_').slice(-FM_NAME_MAX);
                    path = this._askName(`"${file.name}" 不能作为设备上的文件名，请输入新名字:`, clean);
                    if (!path) continue;
                }
                if (this._exists(path) && !confirm(`${fmBaseName(path)} 已存在，覆盖吗？`)) continue;
                const bytes = new Uint8Array(await file.arrayBuffer());
                this._status(`上传 ${fmBaseName(path)}…`);
                await this.backend.fsWrite(path, bytes, this._progress('上传', fmBaseName(path)));
                done.push(path);
                this.log('info', `🗂️ 已上传 ${path} (${bytes.length} 字节)`);
            }
        });
        if (!done.length) return;
        await this.refresh();
        const boot = done.find((p) => /\/app\.(msbc|fasl)$/.test(p));
        this._status(boot && this.backend.reset
            ? `已上传 ${done.length} 个文件。${fmBaseName(boot)} 是开机应用，重启设备后生效`
            : `已上传 ${done.length} 个文件`, 'ok');
    }

    async _download(path) {
        await this._run(`下载 ${fmBaseName(path)}…`, async () => {
            const bytes = await this.backend.fsRead(path, this._progress('下载', fmBaseName(path)));
            const url = URL.createObjectURL(new Blob([bytes], { type: 'application/octet-stream' }));
            const a = document.createElement('a');
            a.href = url;
            a.download = fmBaseName(path);
            document.body.appendChild(a);
            a.click();
            a.remove();
            setTimeout(() => URL.revokeObjectURL(url), 1000);
            this._status(`已下载 ${fmBaseName(path)} (${bytes.length} 字节)`, 'ok');
        });
    }

    async _rename(path) {
        const to = this._askName(`把 ${fmBaseName(path)} 重命名为:`, fmBaseName(path));
        if (!to || to === path) return;
        if (/\/app\.(msbc|fasl)$/.test(to) && !confirm(`${fmBaseName(to)} 会成为开机应用（另一种开机应用文件将被删除），继续吗？`)) return;
        const ok = await this._run('重命名…', async () => {
            await this.backend.fsRename(path, to);
            return true;
        });
        if (!ok) return;
        await this.refresh();
        this._status(`已重命名为 ${fmBaseName(to)}`, 'ok');
    }

    async _delete(path) {
        const name = fmBaseName(path);
        let warn = '';
        if (name === 'app.msbc' || name === 'app.fasl') warn = '\n删除后，下次开机若未安装其他应用将显示内置设置界面。';
        if (name === 'config.ini') warn = '\n删除后，下次开机会按模板重新生成默认配置。';
        if (!confirm(`删除 ${name}？${warn}`)) return;
        const ok = await this._run(`删除 ${name}…`, async () => {
            await this.backend.fsRemove(path);
            return true;
        });
        if (!ok) return;
        await this.refresh();
        this._status(`已删除 ${name}`, 'ok');
    }

    async _reset() {
        if (!confirm('重启设备？')) return;
        const ok = await this._run('发送重启命令…', async () => {
            await this.backend.reset();
            return true;
        });
        if (!ok) return;
        if (this.backend.kind === 'wasm') {
            await this.refresh();
            this._status('模拟设备已重启：重新读取了 config.ini，并启动了开机应用', 'ok');
        } else {
            this._status('设备正在重启，约 10 秒后点击“刷新”', 'ok');
        }
    }

    /* Every file (but FM_BACKUP_SKIP) into minischeme-backup-<kind>-<when>.zip */
    async _backup() {
        const entries = await this._run('读取文件列表…', async () => {
            const files = ((await this.backend.fsList()).files || [])
                .filter((f) => !FM_BACKUP_SKIP.has(fmBaseName(f.path)));
            const out = [];
            for (let i = 0; i < files.length; i++) {
                const f = files[i], name = fmBaseName(f.path);
                this._status(`备份 ${i + 1}/${files.length}: ${name}…`);
                const data = await this.backend.fsRead(f.path);
                if (f.size >= 0 && data.length !== f.size) throw new Error(`${name}: 读到 ${data.length} 字节，应为 ${f.size} 字节`);
                out.push({ name, data });
            }
            return out;
        });
        if (!entries) return;
        const pad = (n) => String(n).padStart(2, '0');
        const d = new Date();
        const fname = `minischeme-backup-${this.backend.kind || 'device'}-${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}.zip`;
        const url = URL.createObjectURL(fmZip(entries));
        const a = document.createElement('a');
        a.href = url;
        a.download = fname;
        document.body.appendChild(a);
        a.click();
        a.remove();
        setTimeout(() => URL.revokeObjectURL(url), 1000);
        const bytes = entries.reduce((s, e) => s + e.data.length, 0);
        this._status(`已备份 ${entries.length} 个文件 (${fmFormatSize(bytes)}) 到 ${fname}`, 'ok');
        this.log('info', `🗂️ 已备份 ${entries.length} 个文件 (${bytes} 字节) 到 ${fname}`);
    }

    /* The files of a backup zip written back (same names replaced, others kept) */
    async _restore(file) {
        let entries;
        try {
            entries = await fmUnzip(await file.arrayBuffer());
        } catch (e) {
            this._status(fmErrorText(e), 'error');
            return;
        }
        entries = entries.filter((e) => !FM_BACKUP_SKIP.has(e.name) && !e.name.startsWith('/') && !e.name.includes('..'));
        if (!entries.length) {
            this._status('备份里没有可以恢复的文件', 'error');
            return;
        }
        const bytes = entries.reduce((s, e) => s + e.data.length, 0);
        if (!confirm(`把 ${file.name} 中的 ${entries.length} 个文件 (${fmFormatSize(bytes)}) 写回 ${this.backend.label}？\n同名文件会被覆盖，其他文件保留。写完后重启设备生效。`)) return;
        // config.ini first: on a freshly flashed board (serial link) the WiFi comes back with it
        entries.sort((a, b) => (b.name === 'config.ini') - (a.name === 'config.ini'));
        const ok = await this._run('恢复…', async () => {
            for (let i = 0; i < entries.length; i++) {
                const e = entries[i];
                this._status(`恢复 ${i + 1}/${entries.length}: ${e.name}…`);
                try {
                    await this.backend.fsWrite(FM_ROOT + e.name, e.data);
                } catch (err) {
                    throw new Error(`${e.name}: ${fmErrorText(err)}（之前的 ${i} 个文件已写入）`);
                }
            }
            return true;
        });
        if (!ok) return;
        await this.refresh();
        this._status(`已恢复 ${entries.length} 个文件 (${fmFormatSize(bytes)})，重启设备后生效`, 'ok');
        this.log('info', `🗂️ 已从 ${file.name} 恢复 ${entries.length} 个文件`);
    }

    async _wipe() {
        if (!confirm('清空模拟 Flash？\n文件系统中的文件 (含 config.ini、开机应用) 和系统字库都会恢复为初始状态，页面将重新载入。')) return;
        await this._run('清空模拟 Flash…', () => this.backend.wipe());
    }

    /* ------------------------------------------------------------------ */
    /* Editor                                                             */
    /* ------------------------------------------------------------------ */

    async _newFile() {
        const path = this._askName('新文件名 (保存在 /spiffs/ 下):', 'notes.txt');
        if (!path) return;
        if (this._exists(path)) {
            if (!confirm(`${fmBaseName(path)} 已存在，打开它吗？`)) return;
            await this._edit(path);
            return;
        }
        this._openEditor(path, '', true);
    }

    async _edit(path) {
        const text = await this._run(`读取 ${fmBaseName(path)}…`, async () => {
            const bytes = await this.backend.fsRead(path, this._progress('读取', fmBaseName(path)));
            if (bytes.includes(0)) throw new Error('这不是文本文件');
            try {
                return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
            } catch (e) {
                throw new Error('文件不是 UTF-8 文本，无法编辑');
            }
        });
        if (text === undefined) return;
        this._openEditor(path, text, false);
    }

    _openEditor(path, text, isNew) {
        this.editPath = path;
        this.editSaved = isNew ? null : text;
        this.el.editor.value = text;
        this.el.editPath.textContent = path;
        this.el.listView.hidden = true;
        this.el.editView.hidden = false;
        this._updateDirty();
        const name = fmBaseName(path);
        // The board reads config.ini at boot; the WASM device's config-get reads it live
        const bootNote = name === 'config.ini' && this.backend.reset ? '修改 config.ini 后需要重启设备才会生效' : '';
        this._status(bootNote || (isNew ? '新文件，保存后写入文件系统' : ''));
        this.el.editor.focus();
        this.el.editor.setSelectionRange(0, 0);
        this.el.editor.scrollTop = 0;
    }

    _isDirty() {
        return this.editSaved === null || this.el.editor.value !== this.editSaved;
    }

    _updateDirty() {
        this.el.dirty.hidden = !this._isDirty();
        const text = this.el.editor.value;
        const lines = text ? text.split('\n').length : 0;
        this.el.editInfo.textContent = `${lines} 行 · ${fmFormatSize(new TextEncoder().encode(text).length)}`;
    }

    async _save() {
        if (!this.editPath || this.busy) return;
        const path = this.editPath;
        const text = this.el.editor.value;
        const bytes = new TextEncoder().encode(text);
        const ok = await this._run(`保存 ${fmBaseName(path)}…`, async () => {
            await this.backend.fsWrite(path, bytes, this._progress('保存', fmBaseName(path)));
            return true;
        });
        if (!ok) return;
        this.editSaved = text;
        this._updateDirty();
        const configNote = fmBaseName(path) === 'config.ini' && this.backend.reset ? '，重启设备后生效' : '';
        this._status(`已保存 ${fmBaseName(path)} (${bytes.length} 字节)${configNote}`, 'ok');
        this.log('info', `🗂️ 已保存 ${path} (${bytes.length} 字节)`);
    }

    _backToList() {
        if (this._isDirty() && !confirm('有未保存的修改，放弃修改吗？')) return;
        this._showList();
        this.refresh();
    }

    _showList() {
        this.editPath = null;
        this.el.editView.hidden = true;
        this.el.listView.hidden = false;
    }
}
