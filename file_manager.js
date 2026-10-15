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

const FM_SPECIAL = {
    'app.msbc': '开机应用 · 字节码，开机时构建 Flash ROM 镜像',
    'app.fasl': '开机应用 · 堆快照',
    'config.ini': '系统配置 · 重启后生效',
    'app.romsig': '内嵌应用签名',
    'upload.tmp': '上传暂存文件',
};

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

function fmBaseName(path) {
    return path.startsWith(FM_ROOT) ? path.slice(FM_ROOT.length) : path;
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
                        <button class="pill-btn" data-act="reset" title="重启后 config.ini 与开机应用的修改才会生效">⏻ 重启设备</button>
                        <button class="pill-btn" data-act="wipe" title="清除浏览器中保存的模拟文件系统与系统字库，恢复初始状态" hidden>清空模拟 Flash</button>
                        <input type="file" class="fm-file-input" multiple hidden>
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

    _renderList() {
        const tbody = this.el.tbody;
        tbody.textContent = '';
        for (const f of this.files) {
            const name = fmBaseName(f.path);
            const tr = document.createElement('tr');

            const nameTd = document.createElement('td');
            const nameSpan = document.createElement('span');
            nameSpan.className = 'fm-name';
            nameSpan.textContent = name;
            nameSpan.title = f.path;
            nameTd.appendChild(nameSpan);
            if (FM_SPECIAL[name]) {
                const tag = document.createElement('span');
                tag.className = 'fm-tag';
                tag.textContent = FM_SPECIAL[name];
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
        this.el.empty.hidden = this.files.length > 0;
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
        if (name === 'app.msbc' || name === 'app.fasl') warn = '\n删除后，下次开机会重新安装固件内嵌的应用。';
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
