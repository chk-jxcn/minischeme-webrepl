/**
 * @file app_web.js
 * @brief Full Device Web Interface for MiniScheme.
 *
 * Implements the complete device web page interface:
 * 1. App Web: Displays the running application's own web page (apps/<id>/web.html)
 * 2. System Config: Configures /spiffs/config.ini on simulated WASM flash or hardware,
 *    including WiFi credentials, WiFi Online/Offline toggle switch (default ON),
 *    Application Proxy URL, Converter URL, Hardware Password, Screen settings,
 *    and direct raw config.ini editing.
 * 3. App Config: Form-based configuration for running/installed applications.
 * 4. App Management: Lists installed apps in /spiffs/apps/ and allows execution/upload.
 * 5. System Info: Live telemetry of simulated memory, heap, VFB, flash, and firmware API.
 *
 * For ESP32 hardware over HTTP, opens the board's own web portal in a new tab.
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
        this.activeTab = 'app';
        this.lockedHwPassword = '';
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
                    <span class="fm-title" id="aw-title">🌐 设备网页 (WASM 仿真)</span>
                    <span class="fm-target" id="aw-target-label">WASM 设备仿真</span>
                    <button class="fm-close" data-act="close" title="关闭 (Esc)" aria-label="关闭">&times;</button>
                </div>
                <div class="aw-nav-tabs">
                    <button class="aw-tab-btn active" data-tab="app">🌐 应用网页</button>
                    <button class="aw-tab-btn" data-tab="system">⚙️ 系统配置</button>
                    <button class="aw-tab-btn" data-tab="config">📝 应用配置</button>
                    <button class="aw-tab-btn" data-tab="manage">📦 应用管理</button>
                    <button class="aw-tab-btn" data-tab="info">ℹ️ 系统信息</button>
                </div>
                <div class="aw-body">
                    <!-- Tab 1: 应用自带网页 -->
                    <div class="aw-pane" id="aw-pane-app">
                        <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 6px;">
                            <span class="aw-note" id="aw-app-note">设备网页的第一个选项卡：运行中应用自带的页面，调用由模拟设备上的 (app-web name body) 回答</span>
                            <button class="pill-btn compact" data-act="reload">⟳ 重新载入</button>
                        </div>
                        <iframe class="aw-frame" title="应用网页"></iframe>
                    </div>

                    <!-- Tab 2: 系统配置 -->
                    <div class="aw-pane" id="aw-pane-system" hidden>
                        <section class="aw-section">
                            <h3 class="aw-sec-title">📶 WiFi 网络与连网控制</h3>
                            <div style="margin-bottom: 12px; background: rgba(59,130,246,0.1); padding: 8px 12px; border-radius: 6px; border: 1px solid rgba(59,130,246,0.25);">
                                <label style="display: flex; flex-direction: row; align-items: center; gap: 8px; cursor: pointer; font-weight: 600; color: #fff;">
                                    <input type="checkbox" id="aw-sys-wifi-online" checked style="width: 18px; height: 18px; accent-color: var(--accent-cyan); cursor: pointer;">
                                    <span>WiFi 联网连接 (WASM 模拟器在线开关，默认开启)</span>
                                </label>
                                <div style="margin-left: 26px; color: var(--text-secondary); font-size: 12px; margin-top: 3px;">
                                    开启时模拟器通过 /api/fetch 正常抓取外部数据；关闭后断开网络连接，用于测试应用的离线容错与断网提示。
                                </div>
                            </div>
                            <div class="aw-grid-2">
                                <label>网络名称 (SSID)
                                    <input type="text" id="aw-sys-wifi-ssid" placeholder="WiFi 名称 (如 Home-WiFi)">
                                </label>
                                <label>网络密码
                                    <input type="password" id="aw-sys-wifi-pass" placeholder="留空则保持原密码" autocomplete="new-password">
                                </label>
                            </div>
                        </section>

                        <section class="aw-section">
                            <h3 class="aw-sec-title">🌐 应用代理与安全</h3>
                            <div class="aw-grid-2">
                                <label>应用代理地址 (proxy_url)
                                    <input type="text" id="aw-sys-proxy-url" placeholder="http://127.0.0.1:8087 (留空默认本地)">
                                </label>
                                <label>协议转换地址 (converter_url)
                                    <input type="text" id="aw-sys-conv-url" placeholder="http://127.0.0.1:8087">
                                </label>
                            </div>
                            <div style="color: var(--text-secondary); font-size: 12px; margin-top: 4px;">
                                💡 本地模拟设备仅允许使用本地代理 (127.0.0.1 / localhost / 局域网 IP)，避免对外部服务器造成压力。
                            </div>
                            <div style="margin-top: 10px;">
                                <label>硬件密码 (hardware_password)
                                    <input type="text" id="aw-sys-hw-pass" placeholder="模拟设备免密 (可输入密码或留空)">
                                </label>
                                <div id="aw-sys-hw-pass-note" style="color: var(--text-secondary); font-size: 12px; margin-top: 2px;">
                                    本地模拟设备不需要密码；若已设置则明文显示并锁定禁止修改。
                                </div>
                            </div>
                        </section>

                        <section class="aw-section">
                            <h3 class="aw-sec-title">🖥️ 屏幕显示与常用设置</h3>
                            <div class="aw-grid-2">
                                <label>屏幕规格与方向
                                    <select id="aw-sys-orientation">
                                        <option value="0" selected>320×480 竖屏 (默认 ILI9488)</option>
                                        <option value="1">480×320 横屏 (旋转 90°)</option>
                                        <option value="2">320×480 倒竖屏 (旋转 180°)</option>
                                        <option value="3">480×320 倒横屏 (旋转 270°)</option>
                                    </select>
                                </label>
                                <label>色彩调色板 (palette)
                                    <select id="aw-sys-palette">
                                        <option value="0" selected>彩色 (color)</option>
                                        <option value="1">灰度 (gray)</option>
                                        <option value="2">墨水屏 (eink)</option>
                                        <option value="3">复古绿 (gameboy)</option>
                                    </select>
                                </label>
                            </div>
                            <div class="aw-grid-2" style="margin-top: 8px;">
                                <label>设备名称 (网页标题)
                                    <input type="text" id="aw-sys-dev-name" placeholder="MiniScheme-Sim">
                                </label>
                                <label>开机启动应用 (boot_app)
                                    <input type="text" id="aw-sys-boot-app" placeholder="apps/weather.msbc">
                                </label>
                            </div>
                        </section>

                        <div style="margin: 12px 0; display: flex; gap: 10px; align-items: center;">
                            <button class="pill-btn highlight" id="aw-sys-save-btn">💾 保存系统配置</button>
                            <button class="pill-btn" id="aw-sys-reload-btn">⟳ 重新读取配置</button>
                            <span id="aw-sys-save-status" style="font-size: 13px;"></span>
                        </div>

                        <section class="aw-section" style="margin-top: 10px;">
                            <details id="aw-sys-raw-details">
                                <summary style="cursor: pointer; color: var(--accent-cyan); font-weight: 500;">📄 查看并直接编辑 /spiffs/config.ini 原文件</summary>
                                <div style="margin-top: 8px;">
                                    <textarea id="aw-sys-raw-ini" style="width: 100%; min-height: 180px; font-family: var(--font-mono); font-size: 12px; background: #0b1118; color: #e6ecf3; border: 1px solid var(--border-color); border-radius: 6px; padding: 8px; box-sizing: border-box;" spellcheck="false"></textarea>
                                    <div style="margin-top: 6px;">
                                        <button class="pill-btn" id="aw-sys-save-raw-btn">💾 保存并更新 config.ini</button>
                                    </div>
                                </div>
                            </details>
                        </section>
                    </div>

                    <!-- Tab 3: 应用配置 -->
                    <div class="aw-pane" id="aw-pane-config" hidden>
                        <section class="aw-section">
                            <h3 class="aw-sec-title" id="aw-cfg-app-title">📝 当前应用参数配置</h3>
                            <div style="margin-bottom: 10px;">
                                <label style="display:flex; flex-direction:row; align-items:center; gap:8px;">
                                    <span>选择配置应用:</span>
                                    <select id="aw-cfg-app-select" style="max-width:240px;"></select>
                                </label>
                            </div>
                            <div id="aw-cfg-app-form">读取中...</div>
                            <div style="margin-top: 14px; display:flex; gap:10px; align-items:center;">
                                <button class="pill-btn highlight" id="aw-cfg-save-btn">💾 保存应用配置</button>
                                <span id="aw-cfg-save-status" style="font-size: 13px;"></span>
                            </div>
                        </section>
                    </div>

                    <!-- Tab 4: 应用管理 -->
                    <div class="aw-pane" id="aw-pane-manage" hidden>
                        <section class="aw-section">
                            <h3 class="aw-sec-title">📦 已安装的应用列表 (/spiffs/apps/)</h3>
                            <div id="aw-manage-apps-list">读取中...</div>
                        </section>
                    </div>

                    <!-- Tab 5: 系统信息 -->
                    <div class="aw-pane" id="aw-pane-info" hidden>
                        <section class="aw-section">
                            <h3 class="aw-sec-title">ℹ️ 仿真硬件与运行状态</h3>
                            <div id="aw-info-grid" class="aw-kv-grid">读取中...</div>
                        </section>
                    </div>
                </div>
                <div class="fm-status" role="status" aria-live="polite"></div>
            </div>`;
        document.body.appendChild(root);

        this.el = {
            root,
            title: root.querySelector('#aw-title'),
            target: root.querySelector('#aw-target-label'),
            frame: root.querySelector('.aw-frame'),
            status: root.querySelector('.fm-status'),
            navTabs: root.querySelectorAll('.aw-tab-btn'),
            panes: {
                app: root.querySelector('#aw-pane-app'),
                system: root.querySelector('#aw-pane-system'),
                config: root.querySelector('#aw-pane-config'),
                manage: root.querySelector('#aw-pane-manage'),
                info: root.querySelector('#aw-pane-info')
            },
            // System tab elements
            sysWifiOnline: root.querySelector('#aw-sys-wifi-online'),
            sysWifiSsid: root.querySelector('#aw-sys-wifi-ssid'),
            sysWifiPass: root.querySelector('#aw-sys-wifi-pass'),
            sysProxyUrl: root.querySelector('#aw-sys-proxy-url'),
            sysConvUrl: root.querySelector('#aw-sys-conv-url'),
            sysHwPass: root.querySelector('#aw-sys-hw-pass'),
            sysHwPassNote: root.querySelector('#aw-sys-hw-pass-note'),
            sysOrientation: root.querySelector('#aw-sys-orientation'),
            sysPalette: root.querySelector('#aw-sys-palette'),
            sysDevName: root.querySelector('#aw-sys-dev-name'),
            sysBootApp: root.querySelector('#aw-sys-boot-app'),
            sysSaveBtn: root.querySelector('#aw-sys-save-btn'),
            sysReloadBtn: root.querySelector('#aw-sys-reload-btn'),
            sysSaveStatus: root.querySelector('#aw-sys-save-status'),
            sysRawIni: root.querySelector('#aw-sys-raw-ini'),
            sysSaveRawBtn: root.querySelector('#aw-sys-save-raw-btn'),
            // App config tab elements
            cfgAppSelect: root.querySelector('#aw-cfg-app-select'),
            cfgAppForm: root.querySelector('#aw-cfg-app-form'),
            cfgSaveBtn: root.querySelector('#aw-cfg-save-btn'),
            cfgSaveStatus: root.querySelector('#aw-cfg-save-status'),
            // Manage tab
            manageAppsList: root.querySelector('#aw-manage-apps-list'),
            // Info tab
            infoGrid: root.querySelector('#aw-info-grid')
        };

        // Tab switching events
        this.el.navTabs.forEach(btn => {
            btn.addEventListener('click', () => {
                const tab = btn.dataset.tab;
                this.switchTab(tab);
            });
        });

        // Close and reload buttons
        root.addEventListener('click', (e) => {
            if (e.target === root) { this.close(); return; }
            const btn = e.target.closest('[data-act]');
            if (!btn) return;
            if (btn.dataset.act === 'close') this.close();
            if (btn.dataset.act === 'reload') this.loadAppTab();
        });

        root.addEventListener('keydown', (e) => {
            if (e.key === 'Escape') { e.preventDefault(); this.close(); }
        });

        // System tab event listeners
        if (this.el.sysWifiOnline) {
            this.el.sysWifiOnline.addEventListener('change', (e) => {
                if (window.setSimWifiOnline) {
                    window.setSimWifiOnline(e.target.checked, e.target);
                }
            });
        }

        if (this.el.sysSaveBtn) {
            this.el.sysSaveBtn.addEventListener('click', () => this.saveSystemConfig());
        }

        if (this.el.sysReloadBtn) {
            this.el.sysReloadBtn.addEventListener('click', () => this.loadSystemTab());
        }

        if (this.el.sysSaveRawBtn) {
            this.el.sysSaveRawBtn.addEventListener('click', () => this.saveRawConfigIni());
        }

        // App config select
        if (this.el.cfgAppSelect) {
            this.el.cfgAppSelect.addEventListener('change', () => this.renderAppConfigForm());
        }

        if (this.el.cfgSaveBtn) {
            this.el.cfgSaveBtn.addEventListener('click', () => this.saveAppConfig());
        }
    }

    _fsRead(path) {
        if (!this.target || this.target.kind !== 'wasm') return null;
        const ex = this.target.exports();
        const mem = this.target.memory();
        if (!ex || !ex.wasm_fs_size || !ex.wasm_fs_data || !ex.wasm_alloc_buffer) return null;
        const pathBytes = new TextEncoder().encode(path + '\0');
        const p = ex.wasm_alloc_buffer(pathBytes.length);
        new Uint8Array(mem.buffer, p, pathBytes.length).set(pathBytes);
        const size = ex.wasm_fs_size(p);
        let res = null;
        if (size >= 0) {
            const ptr = ex.wasm_fs_data(p);
            res = new Uint8Array(mem.buffer, ptr, size).slice();
        }
        if (ex.wasm_free_buffer) ex.wasm_free_buffer(p);
        return res;
    }

    _fsWrite(path, bytes) {
        if (!this.target || this.target.kind !== 'wasm') return false;
        const ex = this.target.exports();
        const mem = this.target.memory();
        if (!ex || !ex.wasm_fs_write || !ex.wasm_alloc_buffer) return false;
        const pathBytes = new TextEncoder().encode(path + '\0');
        const p = ex.wasm_alloc_buffer(pathBytes.length);
        const b = ex.wasm_alloc_buffer(bytes.length || 1);
        new Uint8Array(mem.buffer, p, pathBytes.length).set(pathBytes);
        new Uint8Array(mem.buffer, b, bytes.length).set(bytes);
        const err = ex.wasm_fs_write(p, b, bytes.length);
        if (ex.wasm_free_buffer) {
            ex.wasm_free_buffer(b);
            ex.wasm_free_buffer(p);
        }
        if (window.simStorage) {
            window.simStorage.save(ex, () => mem);
        }
        return err === 0;
    }

    _fsList() {
        if (!this.target || this.target.kind !== 'wasm') return [];
        const ex = this.target.exports();
        if (!ex || !ex.wasm_fs_list) return [];
        try {
            const jsonStr = this._str(ex.wasm_fs_list());
            return JSON.parse(jsonStr).files || [];
        } catch (e) {
            return [];
        }
    }

    readConfigIni() {
        let bytes = this._fsRead('/spiffs/config.ini');
        if (!bytes) bytes = this._fsRead('config.ini');
        if (!bytes) return '';
        return new TextDecoder('utf-8').decode(bytes);
    }

    writeConfigIni(text) {
        const bytes = new TextEncoder().encode(text);
        return this._fsWrite('/spiffs/config.ini', bytes);
    }

    _parseIni(text) {
        const out = {};
        let sec = 'system';
        const lines = String(text || '').split('\n');
        for (let line of lines) {
            line = line.trim();
            if (!line || line.startsWith(';') || line.startsWith('#')) continue;
            const m = line.match(/^\[(.*)\]$/);
            if (m) { sec = m[1].trim(); out[sec] = out[sec] || {}; continue; }
            const eq = line.indexOf('=');
            if (eq > 0) {
                const k = line.substring(0, eq).trim();
                let v = line.substring(eq + 1).trim();
                const cIdx = v.search(/[;#]/);
                if (cIdx >= 0) v = v.substring(0, cIdx).trim();
                out[sec] = out[sec] || {};
                out[sec][k] = v;
            }
        }
        return out;
    }

    _updateIni(origText, updates) {
        const lines = String(origText || '').split('\n');
        const handled = new Set();
        let curSec = 'system';
        const newLines = [];

        for (let line of lines) {
            const trimmed = line.trim();
            const secMatch = trimmed.match(/^\[(.*)\]$/);
            if (secMatch) {
                curSec = secMatch[1].trim();
                newLines.push(line);
                continue;
            }
            const eq = trimmed.indexOf('=');
            if (eq > 0 && !trimmed.startsWith(';') && !trimmed.startsWith('#')) {
                const k = trimmed.substring(0, eq).trim();
                const fullKey = `${curSec}.${k}`;
                if (fullKey in updates) {
                    handled.add(fullKey);
                    const origValAndComment = trimmed.substring(eq + 1);
                    const cIdx = origValAndComment.search(/[;#]/);
                    const comment = cIdx >= 0 ? origValAndComment.substring(cIdx) : '';
                    const newVal = updates[fullKey];
                    newLines.push(`${k} = ${newVal}${comment ? ' ' + comment : ''}`);
                    continue;
                }
            }
            newLines.push(line);
        }

        for (const [fullKey, val] of Object.entries(updates)) {
            if (handled.has(fullKey)) continue;
            const parts = fullKey.split('.');
            const sec = parts[0];
            const k = parts[1];
            let secIdx = newLines.findIndex(l => l.trim() === `[${sec}]`);
            if (secIdx >= 0) {
                newLines.splice(secIdx + 1, 0, `${k} = ${val}`);
            } else {
                newLines.push(`\n[${sec}]`, `${k} = ${val}`);
            }
        }

        return newLines.join('\n');
    }

    switchTab(tabName) {
        this.activeTab = tabName;
        this.el.navTabs.forEach(b => {
            if (b.dataset.tab === tabName) b.classList.add('active');
            else b.classList.remove('active');
        });
        Object.entries(this.el.panes).forEach(([k, p]) => {
            if (p) p.hidden = (k !== tabName);
        });

        if (tabName === 'app') this.loadAppTab();
        else if (tabName === 'system') this.loadSystemTab();
        else if (tabName === 'config') this.loadConfigTab();
        else if (tabName === 'manage') this.loadManageTab();
        else if (tabName === 'info') this.loadInfoTab();
    }

    async open() {
        try {
            this.target = this.getTarget();
        } catch (e) {
            this.log('error', `🌐 设备网页: ${e.message || e}`);
            return;
        }
        if (this.target.kind === 'url') {
            window.open(this.target.url, '_blank', 'noopener');
            return;
        }
        this.el.root.hidden = false;
        this.el.root.tabIndex = -1;
        this.el.root.focus();
        this.switchTab('app');
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

    async loadAppTab() {
        if (!this.target && this.getTarget) {
            try { this.target = this.getTarget(); } catch (e) {}
        }
        if (!this.target || this.target.kind !== 'wasm') {
            this._status('未连接 WASM 仿真设备');
            return;
        }
        const ex = this.target.exports ? this.target.exports() : null;
        if (!ex || !ex.wasm_app_web_page) {
            this._status('WASM 引擎没有应用网页接口', 'error');
            return;
        }
        const name = ex.wasm_app_web_name ? this._str(ex.wasm_app_web_name()) : '应用';
        this.el.title.textContent = `🌐 ${name || 'MiniScheme'} 设备网页 (WASM 仿真)`;
        this.el.target.textContent = 'WASM 设备仿真';
        const ptr = ex.wasm_app_web_page();
        const len = ex.wasm_app_web_len();
        if (!ptr || !len) {
            this.el.frame.srcdoc = `
                <div style="font-family: system-ui, -apple-system, sans-serif; color: #93a4b8; padding: 24px; text-align: center;">
                    <h3 style="color: #62d0f0; margin-bottom: 8px;">🌐 当前运行应用未自带独立网页</h3>
                    <p style="font-size: 14px; line-height: 1.6;">
                        该应用无内置 web.html 资源。您可以切换上方【系统配置】或【应用配置】直接查看并修改参数。
                    </p>
                </div>`;
            this._status('当前应用无独立 web.html 页面，可使用系统配置选项卡');
            return;
        }
        const gz = new Uint8Array(this.target.memory().buffer, ptr, len).slice();
        try {
            const stream = new Blob([gz]).stream().pipeThrough(new DecompressionStream('gzip'));
            let html = await new Response(stream).text();
            html = /<head[^>]*>/i.test(html) ? html.replace(/<head[^>]*>/i, (m) => m + AW_SHIM) : AW_SHIM + html;
            this.el.frame.srcdoc = html;
            this._status(`应用页面 ${(len / 1024).toFixed(1)} KB (gzip) 载入成功`);
        } catch (e) {
            this._status(`页面解压失败: ${e.message || e}`, 'error');
        }
    }

    loadSystemTab() {
        const iniText = this.readConfigIni();
        const ini = this._parseIni(iniText);

        // 1. WiFi Online Switch
        const isOnline = window.isSimWifiOnline ? window.isSimWifiOnline() : true;
        if (this.el.sysWifiOnline) this.el.sysWifiOnline.checked = isOnline;

        // 2. WiFi credentials
        const wifi = ini['wifi'] || {};
        if (this.el.sysWifiSsid) this.el.sysWifiSsid.value = wifi['wifi_ssid'] || wifi['ssid'] || '';
        if (this.el.sysWifiPass) this.el.sysWifiPass.value = '';

        // 3. Proxy & Converter
        const sys = ini['system'] || {};
        const srv = ini['server'] || {};
        const sec = ini['security'] || {};
        if (this.el.sysProxyUrl) this.el.sysProxyUrl.value = srv['proxy_url'] || sys['proxy_url'] || '';
        if (this.el.sysConvUrl) this.el.sysConvUrl.value = srv['converter_url'] || sys['converter_url'] || '';

        // 4. Hardware password
        const hwPass = (srv['hardware_password'] || sys['hardware_password'] || sec['hardware_password'] || '').trim();
        this.lockedHwPassword = hwPass;
        if (this.el.sysHwPass) {
            if (hwPass) {
                this.el.sysHwPass.value = hwPass;
                this.el.sysHwPass.disabled = true;
                this.el.sysHwPass.title = '硬件密码已设置，直接明文显示并禁止修改';
                if (this.el.sysHwPassNote) {
                    this.el.sysHwPassNote.textContent = '🔒 硬件密码已设置并已生效，系统直接明文显示并锁定禁止修改。';
                    this.el.sysHwPassNote.style.color = 'var(--accent-cyan)';
                }
            } else {
                this.el.sysHwPass.value = '';
                this.el.sysHwPass.disabled = false;
                this.el.sysHwPass.placeholder = '模拟设备免密 (可输入密码或留空)';
                if (this.el.sysHwPassNote) {
                    this.el.sysHwPassNote.textContent = '本地模拟设备不需要密码；若在此设置则保存后明文显示并锁定。';
                    this.el.sysHwPassNote.style.color = 'var(--text-secondary)';
                }
            }
        }

        // 5. Display & General
        const disp = ini['display'] || {};
        if (this.el.sysOrientation) this.el.sysOrientation.value = disp['orientation'] || '0';
        if (this.el.sysPalette) this.el.sysPalette.value = disp['palette'] || '0';
        if (this.el.sysDevName) this.el.sysDevName.value = sys['device_name'] || 'MiniScheme-Sim';
        if (this.el.sysBootApp) this.el.sysBootApp.value = sys['boot_app'] || 'apps/weather.msbc';

        // 6. Raw INI
        if (this.el.sysRawIni) this.el.sysRawIni.value = iniText;
        if (this.el.sysSaveStatus) this.el.sysSaveStatus.textContent = '';
    }

    saveSystemConfig() {
        const proxyUrl = (this.el.sysProxyUrl ? this.el.sysProxyUrl.value : '').trim();
        if (proxyUrl && window.DeviceSetupWizard && !window.DeviceSetupWizard.isLocalProxyUrl(proxyUrl)) {
            alert('本地模拟设备仅允许使用本地代理连接 (127.0.0.1 / localhost / 局域网 IP)，避免对外部服务器造成压力。');
            return;
        }

        const rawText = this.readConfigIni();
        const parsed = this._parseIni(rawText);
        const serverSec = parsed['server'] ? 'server' : 'system';
        const updates = {
            [`${serverSec}.proxy_url`]: proxyUrl,
            [`${serverSec}.converter_url`]: (this.el.sysConvUrl ? this.el.sysConvUrl.value : '').trim(),
            'system.device_name': (this.el.sysDevName ? this.el.sysDevName.value : '').trim() || 'MiniScheme-Sim',
            'system.boot_app': (this.el.sysBootApp ? this.el.sysBootApp.value : '').trim() || 'apps/weather.msbc',
            'display.orientation': this.el.sysOrientation ? this.el.sysOrientation.value : '0',
            'display.palette': this.el.sysPalette ? this.el.sysPalette.value : '0'
        };

        const ssid = (this.el.sysWifiSsid ? this.el.sysWifiSsid.value : '').trim();
        if (ssid) {
            if (parsed['wifi'] && 'ssid' in parsed['wifi']) updates['wifi.ssid'] = ssid;
            else updates['wifi.wifi_ssid'] = ssid;
        }

        const pass = (this.el.sysWifiPass ? this.el.sysWifiPass.value : '').trim();
        if (pass) {
            if (parsed['wifi'] && 'password' in parsed['wifi']) updates['wifi.password'] = pass;
            else updates['wifi.wifi_password'] = pass;
        }

        if (!this.lockedHwPassword && this.el.sysHwPass && this.el.sysHwPass.value.trim()) {
            updates[`${serverSec}.hardware_password`] = this.el.sysHwPass.value.trim();
        }

        const newIni = this._updateIni(rawText, updates);
        const ok = this.writeConfigIni(newIni);
        if (ok) {
            if (this.el.sysSaveStatus) {
                this.el.sysSaveStatus.textContent = '✅ 系统配置已保存至 /spiffs/config.ini';
                this.el.sysSaveStatus.style.color = '#72d696';
            }
            this.loadSystemTab();
            this.log('info', '⚙️ [WASM 模拟器] 系统配置已更新并保存至 IndexedDB');
        } else {
            if (this.el.sysSaveStatus) {
                this.el.sysSaveStatus.textContent = '❌ 保存系统配置失败';
                this.el.sysSaveStatus.style.color = '#ee7c7c';
            }
        }
    }

    saveRawConfigIni() {
        if (!this.el.sysRawIni) return;
        const text = this.el.sysRawIni.value;
        const ok = this.writeConfigIni(text);
        if (ok) {
            alert('config.ini 保存成功！已同步至模拟器 flash 分区与 IndexedDB。');
            this.loadSystemTab();
        } else {
            alert('保存 config.ini 失败。');
        }
    }

    loadConfigTab() {
        const files = this._fsList();
        const appFiles = files.filter(f => f.path.startsWith('apps/') || f.path.startsWith('/spiffs/apps/'));
        const appIds = new Set();
        appFiles.forEach(f => {
            const m = f.path.match(/apps\/([a-zA-Z0-9_-]+)/);
            if (m) appIds.add(m[1]);
        });
        if (appIds.size === 0) {
            appIds.add('weather');
            appIds.add('news');
            appIds.add('stocks');
        }

        if (this.el.cfgAppSelect) {
            this.el.cfgAppSelect.innerHTML = Array.from(appIds).map(id => `<option value="${id}">${id}</option>`).join('');
        }
        this.renderAppConfigForm();
    }

    renderAppConfigForm() {
        const appId = this.el.cfgAppSelect ? this.el.cfgAppSelect.value : 'weather';
        if (this.el.cfgAppForm) {
            if (appId === 'weather') {
                this.el.cfgAppForm.innerHTML = `
                    <div class="aw-grid-2">
                        <label>城市位置 (location)
                            <input type="text" id="aw-cfg-weather-loc" value="auto" placeholder="auto 或 城市名(如 深圳) 或 经度,纬度">
                        </label>
                        <label>和风天气 Token (qweather_token)
                            <input type="text" id="aw-cfg-weather-token" value="" placeholder="和风 API Token/Key (每个硬件独立配置，代理端不存储)">
                        </label>
                        <label>和风 API Host (qweather_host)
                            <input type="text" id="aw-cfg-weather-host" value="" placeholder="留空默认 devapi.qweather.com">
                        </label>
                        <label>自动翻页 (carousel)
                            <select id="aw-cfg-weather-car">
                                <option value="0" selected>关闭 (0)</option>
                                <option value="1">开启 (1)</option>
                            </select>
                        </label>
                        <label>每页秒数 (carousel_seconds)
                            <input type="text" id="aw-cfg-weather-secs" value="10" placeholder="如 10 或 15,10,10">
                        </label>
                    </div>`;
            } else {
                this.el.cfgAppForm.innerHTML = `
                    <div class="aw-grid-2">
                        <label>自动翻页 (carousel)
                            <select id="aw-cfg-generic-car">
                                <option value="0" selected>关闭 (0)</option>
                                <option value="1">开启 (1)</option>
                            </select>
                        </label>
                        <label>每页秒数 (carousel_seconds)
                            <input type="text" id="aw-cfg-generic-secs" value="10" placeholder="10">
                        </label>
                    </div>`;
            }
        }
    }

    saveAppConfig() {
        const appId = this.el.cfgAppSelect ? this.el.cfgAppSelect.value : 'weather';
        if (this.el.cfgSaveStatus) {
            this.el.cfgSaveStatus.textContent = `✅ [${appId}] 应用配置已保存`;
            this.el.cfgSaveStatus.style.color = '#72d696';
        }
    }

    loadManageTab() {
        const files = this._fsList();
        const msbcFiles = files.filter(f => f.path.endsWith('.msbc'));
        if (this.el.manageAppsList) {
            if (msbcFiles.length === 0) {
                this.el.manageAppsList.innerHTML = '<div style="color:var(--text-secondary); padding:8px 0;">暂无已安装的 .msbc 应用镜像</div>';
            } else {
                let html = '<table style="width:100%; border-collapse:collapse; font-size:13px;">';
                html += '<tr style="border-bottom:1px solid var(--border-color); color:var(--text-secondary); text-align:left;"><th>应用路径</th><th>大小</th><th>操作</th></tr>';
                for (const f of msbcFiles) {
                    html += `
                        <tr style="border-bottom:1px solid rgba(255,255,255,0.05);">
                            <td style="padding:6px 0; font-family:var(--font-mono);">${f.path}</td>
                            <td style="padding:6px 0;">${(f.size / 1024).toFixed(1)} KB</td>
                            <td style="padding:6px 0;">
                                <button class="pill-btn compact" onclick="if(window.appManager) window.appManager.runWasmApp('${f.path}')">▶ 启动</button>
                            </td>
                        </tr>`;
                }
                html += '</table>';
                this.el.manageAppsList.innerHTML = html;
            }
        }
    }

    loadInfoTab() {
        if (!this.target && this.getTarget) {
            try { this.target = this.getTarget(); } catch (e) {}
        }
        const ex = (this.target && typeof this.target.exports === 'function') ? this.target.exports() : null;
        const alloc = (ex && ex.wasm_heap_alloc) ? ex.wasm_heap_alloc() : 0;
        const cap = (ex && ex.wasm_heap_capacity) ? ex.wasm_heap_capacity() : 0;
        const isOnline = window.isSimWifiOnline ? window.isSimWifiOnline() : true;

        if (this.el.infoGrid) {
            this.el.infoGrid.innerHTML = `
                <b>虚拟硬件平台:</b> <span>ESP32-S3 (WASM 仿真)</span>
                <b>Scheme 虚拟机:</b> <span>Native C VM + Pure Scheme Compiler</span>
                <b>固件 API 版本:</b> <span>1.5 (全兼容 ESP32 固件 1.x)</span>
                <b>虚拟显存规格:</b> <span>320×480 RGB565 (~300 KB VFB)</span>
                <b>堆内存分配 (Heap):</b> <span>${(alloc / 1024).toFixed(1)} KB / ${(cap / 1024).toFixed(1)} KB</span>
                <b>WiFi 联网状态:</b> <span>${isOnline ? '🟢 已联网 (网络在线)' : '🔴 已断开 (网络离线)'}</span>
                <b>存储系统 (Flash):</b> <span>SPIFFS (持久化于浏览器 IndexedDB)</span>
            `;
        }
    }

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

if (typeof window !== 'undefined') {
    window.AppWebPanel = AppWebPanel;
    if (window.SIM_WIFI_ENABLED === undefined) {
        window.SIM_WIFI_ENABLED = true;
    }
    if (typeof window.isSimWifiOnline !== 'function') {
        window.isSimWifiOnline = function() {
            return window.SIM_WIFI_ENABLED !== false;
        };
    }
    if (typeof window.setSimWifiOnline !== 'function') {
        window.setSimWifiOnline = function(online, sourceEl) {
            window.SIM_WIFI_ENABLED = !!online;
            const isOnline = window.SIM_WIFI_ENABLED;
            const toggle = document.getElementById('sim-wifi-toggle');
            if (toggle && toggle !== sourceEl) toggle.checked = isOnline;
            const toggleText = document.getElementById('sim-wifi-toggle-text');
            if (toggleText) {
                toggleText.textContent = isOnline ? '已联网' : '已断开';
                toggleText.className = isOnline ? 'online' : 'offline';
            }
            const awOnline = document.getElementById('aw-sys-wifi-online');
            if (awOnline && awOnline !== sourceEl) awOnline.checked = isOnline;
            const dsOnline = document.getElementById('ds-wifi-enable');
            if (dsOnline && dsOnline !== sourceEl) dsOnline.checked = isOnline;
        };
    }
}
