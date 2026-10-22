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
                        <iframe class="aw-frame" title="应用网页" sandbox="allow-scripts allow-forms allow-modals allow-popups allow-downloads"></iframe>
                    </div>

                    <!-- Tab 2: 系统配置 -->
                    <div class="aw-pane" id="aw-pane-system" hidden>
                        <div style="margin-bottom: 14px; display: flex; align-items: center; justify-content: space-between; background: rgba(56, 189, 248, 0.08); border: 1px solid rgba(56, 189, 248, 0.25); border-radius: 8px; padding: 10px 14px; gap: 12px;">
                            <div>
                                <div style="font-weight: 600; color: #fff; font-size: 13px;">📟 设备运行模式</div>
                                <div style="color: var(--text-secondary); font-size: 12px; margin-top: 2px;">重启设备并进入内置系统设置界面（可查看设备信息、恢复出厂（含清空字库）、使用应用市场）</div>
                            </div>
                            <button class="pill-btn highlight" id="aw-sys-enter-settings-btn" style="white-space: nowrap; cursor: pointer; padding: 6px 14px; font-weight: 500;">⚙️ 进入设置模式</button>
                        </div>
                        <section class="aw-section">
                            <h3 class="aw-sec-title">📶 WiFi 网络与连网控制</h3>
                            <div style="margin-bottom: 12px; background: rgba(59,130,246,0.1); padding: 8px 12px; border-radius: 6px; border: 1px solid rgba(59,130,246,0.25);">
                                <label style="display: flex; flex-direction: row; align-items: center; gap: 8px; cursor: pointer; font-weight: 600; color: #fff;">
                                    <input type="checkbox" id="aw-sys-wifi-online" checked style="width: 18px; height: 18px; accent-color: var(--accent-cyan); cursor: pointer;">
                                    <span>WiFi 联网连接 (WASM 模拟器在线开关，默认开启)</span>
                                </label>
                                <div style="margin-left: 26px; color: var(--text-secondary); font-size: 12px; margin-top: 3px;">
                                    开启时模拟器正常访问应用代理和外部数据（需要时经后端的 /api/fetch 转发）；关闭后断开网络连接，用于测试应用的离线容错与断网提示。
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
                                <label id="aw-sys-proxy-pw-row">应用服务密码 (proxy_url_password)
                                    <input type="text" id="aw-sys-proxy-pw" autocomplete="off" spellcheck="false" maxlength="64">
                                </label>
                                <label id="aw-sys-conv-pw-row">转换器服务密码 (converter_url_password)
                                    <input type="text" id="aw-sys-conv-pw" autocomplete="off" spellcheck="false" maxlength="64" placeholder="与应用代理同一台服务器时留空">
                                </label>
                            </div>
                            <div id="aw-sys-pw-note" style="color: var(--text-secondary); font-size: 12px; margin-top: 2px;">
                                应用服务密码与服务器绑定：设备用它在该服务器注册加密通道（不发送密码），也是该服务器用户门户的登录密码；已注册后不改服务器地址就不能改密码。明文显示。
                            </div>
                            <div style="margin-top: 10px;">
                                <label>硬件密码 (hardware_password) <span style="color: #ef4444;" id="aw-sys-hw-pass-req">*</span>
                                    <input type="text" id="aw-sys-hw-pass" placeholder="必填项：请输入不小于 6 位字符的硬件密码" autocomplete="off" spellcheck="false">
                                </label>
                                <div id="aw-sys-hw-pass-note" style="color: var(--text-secondary); font-size: 12px; margin-top: 2px;">
                                    硬件密码只保护设备网页和 HTTP 接口，可以随时修改；连接服务器用上面的应用服务密码。
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

                        <section class="aw-section">
                            <h3 class="aw-sec-title">💡 屏幕亮度与光感调节</h3>
                            <div style="display: flex; align-items: center; gap: 8px; margin-bottom: 10px;">
                                <label style="font-size: 13px; display: inline-flex; align-items: center; gap: 6px; cursor: pointer;">
                                    <input type="checkbox" id="aw-sys-fixed-bl-enable" style="width: 16px; height: 16px; accent-color: var(--accent-cyan); cursor: pointer;">
                                    <span style="font-weight: 500;">固定亮度模式 (开启则锁定亮度；关闭则启用环境光感动态调节)</span>
                                </label>
                            </div>
                            <div class="aw-grid-2">
                                <label>固定亮度值 (0~255)
                                    <input type="number" id="aw-sys-fixed-bl-val" min="0" max="255" step="1" placeholder="180">
                                </label>
                                <label>亮度偏移指数 (-10~10)
                                    <input type="number" id="aw-sys-bl-offset" min="-10" max="10" step="1" placeholder="0">
                                </label>
                            </div>
                            <div class="aw-grid-2" style="margin-top: 8px;">
                                <label>最低亮度 (0~255, 动态调节下限)
                                    <input type="number" id="aw-sys-bl-min" min="0" max="255" step="1" placeholder="30">
                                </label>
                                <label>最高亮度 (0~255, 动态调节上限)
                                    <input type="number" id="aw-sys-bl-max" min="0" max="255" step="1" placeholder="255">
                                </label>
                            </div>
                            <div style="color: var(--text-secondary); font-size: 12px; margin-top: 6px; line-height: 1.4;">
                                💡 动态算法根据光敏传感器 ADC 读数 (0~4095) 结合亮度偏移指数在最低和最高值之间平滑换算。
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
                            <h3 class="aw-sec-title" id="aw-cfg-runhead">▶ 正在运行的应用</h3>
                            <div id="aw-cfg-runcfg">读取中...</div>
                        </section>
                        <section class="aw-section">
                            <h3 class="aw-sec-title">📦 其他应用配置</h3>
                            <div style="color:var(--text-secondary); font-size:12px; margin-bottom:10px;">
                                点“配置”展开该应用的配置项和配置文件；每个应用拥有独立卡片。保存后，应用下次启动或重启时生效。
                            </div>
                            <div id="aw-cfg-othercfg">读取中...</div>
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
                            <h3 class="aw-sec-title" id="aw-info-title">ℹ️ 仿真硬件与运行状态</h3>
                            <div id="aw-info-grid">读取中...</div>
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
            sysProxyPw: root.querySelector('#aw-sys-proxy-pw'),
            sysConvPw: root.querySelector('#aw-sys-conv-pw'),
            sysProxyPwRow: root.querySelector('#aw-sys-proxy-pw-row'),
            sysConvPwRow: root.querySelector('#aw-sys-conv-pw-row'),
            sysPwNote: root.querySelector('#aw-sys-pw-note'),
            sysHwPass: root.querySelector('#aw-sys-hw-pass'),
            sysHwPassNote: root.querySelector('#aw-sys-hw-pass-note'),
            sysOrientation: root.querySelector('#aw-sys-orientation'),
            sysPalette: root.querySelector('#aw-sys-palette'),
            sysDevName: root.querySelector('#aw-sys-dev-name'),
            sysBootApp: root.querySelector('#aw-sys-boot-app'),
            sysFixedBlEnable: root.querySelector('#aw-sys-fixed-bl-enable'),
            sysFixedBlVal: root.querySelector('#aw-sys-fixed-bl-val'),
            sysBlOffset: root.querySelector('#aw-sys-bl-offset'),
            sysBlMin: root.querySelector('#aw-sys-bl-min'),
            sysBlMax: root.querySelector('#aw-sys-bl-max'),
            sysSaveBtn: root.querySelector('#aw-sys-save-btn'),
            sysReloadBtn: root.querySelector('#aw-sys-reload-btn'),
            sysSaveStatus: root.querySelector('#aw-sys-save-status'),
            sysRawIni: root.querySelector('#aw-sys-raw-ini'),
            sysSaveRawBtn: root.querySelector('#aw-sys-save-raw-btn'),
            sysEnterSettingsBtn: root.querySelector('#aw-sys-enter-settings-btn'),
            // App config tab elements
            cfgRunHead: root.querySelector('#aw-cfg-runhead'),
            cfgRunBox: root.querySelector('#aw-cfg-runcfg'),
            cfgOtherBox: root.querySelector('#aw-cfg-othercfg'),
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

        if (this.el.sysEnterSettingsBtn) {
            this.el.sysEnterSettingsBtn.addEventListener('click', () => this.enterSettingsMode());
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

        if (this.el.sysFixedBlEnable) {
            this.el.sysFixedBlEnable.addEventListener('change', () => this._updateBacklightUI());
        }

        // App config events delegation
        if (this.el.cfgOtherBox) {
            this.el.cfgOtherBox.addEventListener('click', (e) => {
                const btn = e.target.closest('[data-cfg-act="toggle"]');
                if (btn) {
                    const k = btn.dataset.key;
                    const a = this.configApps && this.configApps.find(x => (x.key === k || x.id === k));
                    if (a) this.openAppConfig(a);
                }
            });
        }
    }

    _updateBacklightUI() {
        const fixed = this.el.sysFixedBlEnable ? this.el.sysFixedBlEnable.checked : false;
        if (this.el.sysFixedBlVal) {
            this.el.sysFixedBlVal.disabled = !fixed;
            this.el.sysFixedBlVal.style.opacity = fixed ? '1' : '0.5';
        }
        const dynOpacity = fixed ? '0.6' : '1';
        if (this.el.sysBlOffset) this.el.sysBlOffset.style.opacity = dynOpacity;
        if (this.el.sysBlMin) this.el.sysBlMin.style.opacity = dynOpacity;
        if (this.el.sysBlMax) this.el.sysBlMax.style.opacity = dynOpacity;
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

    /* The device's config.ini text, or null when it could not be read (a
     * serial timeout, a lost link): a save must then stop, since writing a
     * file built from nothing would wipe the device's settings. The board
     * always has a config.ini (the firmware writes one at boot), so an empty
     * answer from a board counts as a failed read too. */
    async _readConfigIniAsync() {
        if (this.target && this.target.kind === 'wasm') {
            return this.readConfigIni();
        }
        const link = (this.target && this.target.link) || window.activeLink;
        if (link && typeof link.fsRead === 'function') {
            try {
                let bytes = await link.fsRead('/spiffs/config.ini');
                if (!bytes || !bytes.length) bytes = await link.fsRead('config.ini');
                if (bytes && bytes.length) return new TextDecoder('utf-8').decode(bytes);
            } catch (e) {
                this.log('error', `⚙️ 读取设备 config.ini 失败: ${e.message || e}`);
            }
        }
        return null;
    }

    async _writeConfigIniAsync(text) {
        if (this.target && this.target.kind === 'wasm') {
            return this.writeConfigIni(text);
        }
        const link = (this.target && this.target.link) || window.activeLink;
        if (link && typeof link.fsWrite === 'function') {
            try {
                await link.fsWrite('/spiffs/config.ini', new TextEncoder().encode(text));
                if (link.kind === 'http' && typeof link._json === 'function') {
                    try {
                        const parsed = this._parseIni(text);
                        const disp = parsed['display'] || {};
                        const params = new URLSearchParams();
                        for (const k of ['auto_backlight', 'backlight', 'backlight_offset', 'backlight_min', 'backlight_max']) {
                            if (disp[k] !== undefined) params.set(`display.${k}`, disp[k]);
                        }
                        if ([...params.keys()].length > 0) {
                            await link._json('/api/settings', {
                                method: 'POST',
                                headers: { 'Content-Type': 'text/plain' },
                                body: params.toString()
                            }, 8000);
                        }
                    } catch (_) {}
                }
                return true;
            } catch (e) {
                return false;
            }
        }
        return false;
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
        if (this.target && this.target.kind === 'device') {
            const link = this.target.link || window.activeLink;
            const label = (link && link.label) || 'ESP32 硬件设备';
            this.el.title.textContent = `🌐 MiniScheme 设备网页 (${label})`;
            this.el.target.textContent = label;
            const nativeBtnHtml = this.target.url
                ? `<p style="margin-top: 14px;"><a href="${this._esc(this.target.url)}" target="_blank" rel="noopener" style="display:inline-block; padding:8px 16px; border-radius:6px; background:#0284c7; color:#fff; text-decoration:none; font-size:13px; font-weight:600;">↗ 在新标签页打开设备原生网页 (${this._esc(link.base)})</a></p>`
                : '';
            this.el.frame.srcdoc = `
                <div style="font-family: system-ui, -apple-system, sans-serif; color: #93a4b8; padding: 24px; text-align: center;">
                    <h3 style="color: #62d0f0; margin-bottom: 8px;">🔌 已连接实体硬件 (${this._esc(label)})</h3>
                    <p style="font-size: 14px; line-height: 1.6;">
                        您可以直接切换上方 <b>【⚙️ 系统配置】</b>、<b>【🛠️ 应用配置】</b>、<b>【📦 应用管理】</b> 或 <b>【ℹ️ 系统信息】</b> 选项卡管理硬件设备。
                    </p>
                    ${nativeBtnHtml}
                </div>`;
            this._status(`已连接 ${label}，可使用上方选项卡直接配置设备`);
            return;
        }
        if (!this.target || this.target.kind !== 'wasm') {
            this._status('未连接设备');
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

    async enterSettingsMode() {
        if (!confirm('确定要重启设备并进入内置系统设置界面吗？')) return;
        this.log('info', '🔄 设备正在重启进入系统设置模式...');
        this.close();

        // 1. WASM simulation mode
        if (this.target && this.target.kind === 'wasm') {
            if (typeof window.bootBundledApp === 'function') {
                await window.bootBundledApp('设置模式: ', 'settings');
            } else {
                this.log('error', '未找到 bootBundledApp 函数');
            }
            return;
        }

        // 2. Hardware device connected via HTTP active link
        if (window.activeLink && window.activeLink.base) {
            try {
                if (typeof window.activeLink._fetch === 'function') {
                    await window.activeLink._fetch('/api/reset?settings=1', { method: 'POST' }, 5000, r => r.text());
                } else {
                    await fetch(`${window.activeLink.base}/api/reset?settings=1`, { method: 'POST' });
                }
                this.log('info', '✅ 重启指令已发送至设备');
            } catch (e) {
                this.log('error', `重启设备失败: ${e.message || e}`);
            }
            return;
        }

        // 3. Hardware device connected via serial or other link
        if (window.activeLink && typeof window.activeLink.reset === 'function') {
            try {
                await window.activeLink.reset(true);
                this.log('info', '✅ 重启指令已发送至设备');
            } catch (e) {
                this.log('error', `重启设备失败: ${e.message || e}`);
            }
            return;
        }

        // 4. Fallback to WASM bundled settings
        if (typeof window.bootBundledApp === 'function') {
            await window.bootBundledApp('设置模式: ', 'settings');
        }
    }

    loadSystemTab() {
        if (this.target && this.target.kind === 'device') {
            return this._readConfigIniAsync().then(t => this._applySystemTabIni(t));
        }
        const iniText = this.readConfigIni();
        this._applySystemTabIni(iniText);
    }

    _applySystemTabIni(iniText) {
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
        const appSec = ini['app'] || {};
        const sec = ini['security'] || {};
        const httpSec = ini['http'] || {};
        if (this.el.sysProxyUrl) this.el.sysProxyUrl.value = srv['proxy_url'] || appSec['proxy'] || sys['proxy_url'] || '';
        if (this.el.sysConvUrl) this.el.sysConvUrl.value = srv['converter_url'] || appSec['https_proxy'] || sys['converter_url'] || '';

        // 4. Hardware password (the HTTP API only, editable) and each server's
        //    app service password (bound to the server once registered there)
        const hwPass = (httpSec['http_password'] || srv['hardware_password'] || sys['hardware_password'] || sec['hardware_password'] || '').trim();
        this.savedHwPassword = hwPass;
        this.lockedHwPassword = '';
        const isWasm = !this.target || this.target.kind === 'wasm';
        if (this.el.sysHwPass) {
            this.el.sysHwPass.type = 'text';
            this.el.sysHwPass.value = hwPass;
            this.el.sysHwPass.disabled = false;
            this.el.sysHwPass.readOnly = false;
        }
        const kv = {};
        for (const [secName, items] of Object.entries(ini)) {
            for (const [k, v] of Object.entries(items || {})) kv[`${secName}.${k}`] = v;
        }
        const serverSec = ini['server'] ? 'server' : 'system';
        this.sysServerState = {
            raw: kv,
            proxy: window.DeviceSetupWizard ? window.DeviceSetupWizard.serverEntry(kv, `${serverSec}.proxy_url`, `${serverSec}.proxy_url_password`) : {},
            conv: window.DeviceSetupWizard ? window.DeviceSetupWizard.serverEntry(kv, `${serverSec}.converter_url`, `${serverSec}.converter_url_password`) : {},
        };
        if (this.el.sysProxyUrl && this.sysServerState.proxy.url) this.el.sysProxyUrl.value = this.sysServerState.proxy.url;
        if (this.el.sysConvUrl && this.sysServerState.conv.url) this.el.sysConvUrl.value = this.sysServerState.conv.url;
        if (this.el.sysProxyPw) this.el.sysProxyPw.value = '';
        if (this.el.sysConvPw) this.el.sysConvPw.value = '';
        if (!this._sysPwListeners) {
            this._sysPwListeners = true;
            for (const el of [this.el.sysProxyUrl, this.el.sysConvUrl]) {
                if (el) el.addEventListener('input', () => this._applySysPwLock());
            }
        }
        this._applySysPwLock(isWasm);

        // 5. Display & General
        const disp = ini['display'] || {};
        if (this.el.sysOrientation) this.el.sysOrientation.value = disp['orientation'] || '0';
        if (this.el.sysPalette) this.el.sysPalette.value = disp['palette'] || '0';
        if (this.el.sysDevName) this.el.sysDevName.value = sys['device_name'] || 'MiniScheme-Sim';
        if (this.el.sysBootApp) this.el.sysBootApp.value = sys['boot_app'] || '';

        // Backlight & Brightness parameters
        const autoBl = disp['auto_backlight'] !== undefined ? (disp['auto_backlight'] !== '0') : true;
        if (this.el.sysFixedBlEnable) this.el.sysFixedBlEnable.checked = !autoBl;
        if (this.el.sysFixedBlVal) this.el.sysFixedBlVal.value = disp['backlight'] !== undefined ? disp['backlight'] : '180';
        if (this.el.sysBlOffset) this.el.sysBlOffset.value = disp['backlight_offset'] !== undefined ? disp['backlight_offset'] : '0';
        if (this.el.sysBlMin) this.el.sysBlMin.value = disp['backlight_min'] !== undefined ? disp['backlight_min'] : '30';
        if (this.el.sysBlMax) this.el.sysBlMax.value = disp['backlight_max'] !== undefined ? disp['backlight_max'] : '255';
        this._updateBacklightUI();

        // 6. Raw INI
        if (this.el.sysRawIni) this.el.sysRawIni.value = iniText;
        if (this.el.sysSaveStatus) this.el.sysSaveStatus.textContent = '';
    }

    /* A bound password (registered there, the address unchanged) is read-only */
    _applySysPwLock(isWasmArg) {
        const isWasm = isWasmArg !== undefined ? isWasmArg : (!this.target || this.target.kind === 'wasm');
        const st = this.sysServerState || {};
        const W = window.DeviceSetupWizard;
        if (!W) return;
        const same = (a, b) => !!a && W.urlOrigin(a) === W.urlOrigin(b);
        const proxyUrl = (this.el.sysProxyUrl ? this.el.sysProxyUrl.value : '').trim();
        const convUrl = (this.el.sysConvUrl ? this.el.sysConvUrl.value : '').trim();
        const shared = !convUrl || same(convUrl, proxyUrl);
        for (const [input, entry, url] of [[this.el.sysProxyPw, st.proxy, proxyUrl], [this.el.sysConvPw, st.conv, convUrl]]) {
            if (!input) continue;
            const bound = !!(entry && entry.key && same(entry.url, url));
            if (bound) input.value = entry.password;
            else if (input.readOnly) input.value = '';
            if (!bound && !input.value && !isWasm) input.value = W.randomPassword();
            input.readOnly = bound;
            input.style.opacity = bound ? '0.85' : '1';
            input.title = bound ? '已在这台服务器注册：密码与服务器绑定，改了服务器地址才能修改' : '';
        }
        if (this.el.sysProxyPwRow) this.el.sysProxyPwRow.style.display = isWasm ? 'none' : '';
        if (this.el.sysConvPwRow) this.el.sysConvPwRow.style.display = isWasm || shared ? 'none' : '';
        if (this.el.sysPwNote) this.el.sysPwNote.style.display = isWasm ? 'none' : '';
    }

    saveSystemConfig() {
        const isWasm = !this.target || this.target.kind === 'wasm';
        const proxyUrl = (this.el.sysProxyUrl ? this.el.sysProxyUrl.value : '').trim();
        if (isWasm && proxyUrl && window.DeviceSetupWizard && !window.DeviceSetupWizard.isSupportedProxyUrl(proxyUrl)) {
            alert('本地模拟设备 (WASM) 仅支持非加密协议，请连接本地代理服务器 (127.0.0.1 / 局域网 IP) 或已部署的公网服务器 (124.222.231.186:8087)');
            return;
        }

        let hwPassToSave = '';
        {
            const rawHwPass = (this.el.sysHwPass ? this.el.sysHwPass.value : '').trim();
            if (!rawHwPass) {
                const msg = '硬件密码为必填项，请输入不小于 6 位字符的硬件密码';
                if (this.el.sysSaveStatus) {
                    this.el.sysSaveStatus.textContent = `❌ ${msg}`;
                    this.el.sysSaveStatus.style.color = '#ee7c7c';
                }
                if (this.el.sysHwPass) this.el.sysHwPass.focus();
                return;
            }
            const chk = rawHwPass === (this.savedHwPassword || '') ? { valid: true } : this._validatePasswordSecurity(rawHwPass);
            if (!chk.valid) {
                if (this.el.sysSaveStatus) {
                    this.el.sysSaveStatus.textContent = `❌ ${chk.message}`;
                    this.el.sysSaveStatus.style.color = '#ee7c7c';
                }
                if (this.el.sysHwPass) this.el.sysHwPass.focus();
                return;
            }
            hwPassToSave = rawHwPass;
        }

        const fixedBl = this.el.sysFixedBlEnable ? this.el.sysFixedBlEnable.checked : false;
        const fixedValRaw = parseInt(this.el.sysFixedBlVal ? this.el.sysFixedBlVal.value : '180', 10);
        const offsetRaw = parseInt(this.el.sysBlOffset ? this.el.sysBlOffset.value : '0', 10);
        let minRaw = parseInt(this.el.sysBlMin ? this.el.sysBlMin.value : '30', 10);
        let maxRaw = parseInt(this.el.sysBlMax ? this.el.sysBlMax.value : '255', 10);

        const fixedVal = Math.max(0, Math.min(255, isNaN(fixedValRaw) ? 180 : fixedValRaw));
        const blOffset = Math.max(-10, Math.min(10, isNaN(offsetRaw) ? 0 : offsetRaw));
        let blMin = Math.max(0, Math.min(255, isNaN(minRaw) ? 30 : minRaw));
        let blMax = Math.max(0, Math.min(255, isNaN(maxRaw) ? 255 : maxRaw));
        if (blMin > blMax) {
            const tmp = blMin;
            blMin = blMax;
            blMax = tmp;
        }

        const applyWithRaw = (rawText) => {
            if (rawText === null || (!isWasm && !String(rawText).trim())) {
                const msg = '读取设备当前 config.ini 失败，为避免覆盖设备上的配置，已取消保存。请检查连接后重试。';
                if (this.el.sysSaveStatus) {
                    this.el.sysSaveStatus.textContent = `❌ ${msg}`;
                    this.el.sysSaveStatus.style.color = '#ee7c7c';
                }
                this.log('error', `⚙️ ${msg}`);
                return null;
            }
            const parsed = this._parseIni(rawText);
            const serverSec = parsed['server'] ? 'server' : 'system';
            const convUrl = (this.el.sysConvUrl ? this.el.sysConvUrl.value : '').trim() || proxyUrl;
            // an address naming the same server keeps the device's key for it
            const W = window.DeviceSetupWizard;
            const flat = {};
            for (const [secName, items] of Object.entries(parsed)) {
                for (const [k, v] of Object.entries(items || {})) flat[`${secName}.${k}`] = v;
            }
            const keepKey = (sk, url) => {
                if (!W) return url;
                const old = W.splitKeyedUrl(flat[sk]);
                return old.key && url && W.urlOrigin(old.url) === W.urlOrigin(url) ? `${old.key}@${url}` : url;
            };
            const updates = {
                [`${serverSec}.proxy_url`]: keepKey(`${serverSec}.proxy_url`, proxyUrl),
                [`${serverSec}.converter_url`]: keepKey(`${serverSec}.converter_url`, convUrl),
                [`${serverSec}.hardware_password`]: hwPassToSave,
                // the firmware guards its web page and API with [http] http_password
                'http.http_password': hwPassToSave,
                'app.proxy': keepKey('app.proxy', proxyUrl),
                'app.https_proxy': keepKey('app.https_proxy', convUrl),
                'system.device_name': (this.el.sysDevName ? this.el.sysDevName.value : '').trim() || 'MiniScheme-Sim',
                'system.boot_app': (this.el.sysBootApp ? this.el.sysBootApp.value : '').trim(),
                'display.orientation': this.el.sysOrientation ? this.el.sysOrientation.value : '0',
                'display.palette': this.el.sysPalette ? this.el.sysPalette.value : '0',
                'display.auto_backlight': fixedBl ? '0' : '1',
                'display.backlight': String(fixedVal),
                'display.backlight_offset': String(blOffset),
                'display.backlight_min': String(blMin),
                'display.backlight_max': String(blMax)
            };

            if (!isWasm) {
                const proxyPw = (this.el.sysProxyPw ? this.el.sysProxyPw.value : '').trim();
                const shared = !W || W.urlOrigin(convUrl) === W.urlOrigin(proxyUrl);
                const convPw = shared ? proxyPw : (this.el.sysConvPw ? this.el.sysConvPw.value : '').trim();
                updates[`${serverSec}.proxy_url_password`] = proxyPw;
                updates[`${serverSec}.converter_url_password`] = convPw;
                updates['app.proxy_password'] = proxyPw;
                updates['app.https_proxy_password'] = convPw;
            }

            if (!parsed['app'] || !('carousel' in parsed['app'])) {
                updates['app.carousel'] = '1';
                updates['app.carousel_seconds'] = '10';
            }

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
            let text = this._updateIni(rawText, updates);
            // a file without config_version is replaced by the firmware's defaults at boot
            if (!/^\s*config_version\s*=/m.test(text)) text = 'config_version = 3\n' + text;
            return text;
        };

        const finishSave = async (ok) => {
            if (ok && !isWasm && hwPassToSave) {
                const link = (this.target && this.target.link) || window.activeLink;
                const newPassword = hwPassToSave !== (this.savedHwPassword || '');
                try { localStorage.setItem('minischeme_http_password', hwPassToSave); } catch (_) {}
                if (link) link.password = hwPassToSave;
                if (newPassword && link && link.kind === 'http' && typeof link._json === 'function') {
                    // firmware since 2026-10-19 guards the API from this request on
                    try {
                        await link._json('/api/settings', {
                            method: 'POST',
                            headers: { 'Content-Type': 'text/plain' },
                            body: new URLSearchParams({ 'http.http_password': hwPassToSave }).toString()
                        }, 8000);
                    } catch (e) {
                        this.log('info', `⚙️ 密码已写入 config.ini，重启设备后生效 (${e.message || e})`);
                    }
                }
            }
            if (ok) {
                this.savedHwPassword = hwPassToSave;
                if (this.el.sysSaveStatus) {
                    this.el.sysSaveStatus.textContent = '✅ 系统配置已保存至 /spiffs/config.ini';
                    this.el.sysSaveStatus.style.color = '#72d696';
                }
                if (isWasm && typeof window.updateSimBrightnessConfig === 'function') {
                    window.updateSimBrightnessConfig({
                        autoBacklight: !fixedBl,
                        backlight: fixedVal,
                        offset: blOffset,
                        min: blMin,
                        max: blMax
                    });
                }
                this.loadSystemTab();
                this.log('info', `⚙️ [${isWasm ? 'WASM 模拟器' : '实体硬件'}] 系统配置已更新并保存至 /spiffs/config.ini`);
            } else if (this.el.sysSaveStatus) {
                this.el.sysSaveStatus.textContent = '❌ 保存系统配置失败';
                this.el.sysSaveStatus.style.color = '#ee7c7c';
            }
        };

        if (isWasm) {
            const newIni = applyWithRaw(this.readConfigIni());
            if (newIni !== null) finishSave(this.writeConfigIni(newIni));
            return;
        }
        return this._readConfigIniAsync().then(rawText => {
            const newIni = applyWithRaw(rawText);
            if (newIni !== null) return this._writeConfigIniAsync(newIni).then(finishSave);
        });
    }

    saveRawConfigIni() {
        if (!this.el.sysRawIni) return;
        const text = this.el.sysRawIni.value;
        if (!this.target || this.target.kind === 'wasm') {
            const ok = this.writeConfigIni(text);
            if (ok) {
                alert('config.ini 保存成功！已同步至模拟器 flash 分区与 IndexedDB。');
                this.loadSystemTab();
            } else {
                alert('保存 config.ini 失败。');
            }
            return;
        }
        return this._writeConfigIniAsync(text).then(ok => {
            if (ok) {
                alert('config.ini 保存成功！');
                this.loadSystemTab();
            } else {
                alert('保存 config.ini 失败。');
            }
        });
    }

    _cfgId(key) {
        return String(key || '').replace(/[^a-zA-Z0-9_-]/g, '_');
    }

    _esc(s) {
        return String(s == null ? '' : s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
    }

    _extractMeta(bytes) {
        if (!bytes || bytes.length < 16) return '';
        const n = bytes.length;
        if (String.fromCharCode(...bytes.subarray(n - 4)) !== 'MSMD') return '';
        const dv = new DataView(bytes.buffer, bytes.byteOffset, n);
        const len = dv.getUint32(n - 12, true);
        if (len === 0 || len > n - 12) return '';
        const metaBytes = bytes.subarray(n - 12 - len, n - 12);
        return new TextDecoder('utf-8').decode(metaBytes);
    }

    _renderFieldHtml(p, f, value) {
        if ((f.key === 'proxy_url' && value === 'http://proxy.local:8087') ||
            (f.key === 'converter_url' && value === 'http://converter.local:8087')) {
            value = '';
        }
        const id = `${p}-${f.key}`;
        const help = f.help ? `<div style="color:var(--text-secondary); font-size:11.5px; margin-top:2px;">${this._esc(f.help)}</div>` : '';
        if (f.type === 'bool') {
            const on = value === '1' || value === 'true' || value === 'on';
            return `<div style="margin:8px 0 4px;">
                <label style="display:flex; flex-direction:row; align-items:center; gap:8px; cursor:pointer;">
                    <input type="checkbox" id="${id}"${on ? ' checked' : ''} style="width:16px; height:16px; accent-color:var(--accent-cyan); cursor:pointer;">
                    <span style="font-size:13px; font-weight:500; color:#fff;">${this._esc(f.label)}</span>
                </label>${help}
            </div>`;
        }
        let input;
        if (f.type.startsWith('select:')) {
            const opts = f.type.slice(7).split(',').map((o) => o.split('='));
            if (!opts.some(([v]) => v === value)) opts.unshift([value, value]);
            input = `<select id="${id}" style="width:100%; max-width:480px; padding:6px 10px; border-radius:5px; background:#0b1118; border:1px solid var(--border-color); color:#fff; font-size:13px;">${opts.map(([v, l]) =>
                `<option value="${this._esc(v)}"${v === value ? ' selected' : ''}>${this._esc(l || v)}</option>`).join('')}</select>`;
        } else if (f.type.startsWith('number')) {
            const [lo, hi] = (f.type.split(':')[1] || '').split('-');
            input = `<input type="number" id="${id}" value="${this._esc(value)}"${lo ? ` min="${lo}"` : ''}${hi ? ` max="${hi}"` : ''} style="width:100%; max-width:480px; padding:6px 10px; border-radius:5px; background:#0b1118; border:1px solid var(--border-color); color:#fff; font-size:13px;">`;
        } else {
            const ph = (f.key === 'proxy_url' || f.key === 'converter_url' || f.def === '') ? ' placeholder="留空默认使用系统配置"' : '';
            input = `<input type="text" id="${id}" value="${this._esc(value)}"${ph} style="width:100%; max-width:480px; padding:6px 10px; border-radius:5px; background:#0b1118; border:1px solid var(--border-color); color:#fff; font-size:13px;">`;
        }
        return `<div style="margin:8px 0 4px;">
            <label style="display:block; color:var(--text-secondary); font-size:12px; margin-bottom:4px;" for="${id}">${this._esc(f.label)}</label>
            ${input}${help}
        </div>`;
    }

    async loadConfigTab() {
        if (!this.target && this.getTarget) {
            try { this.target = this.getTarget(); } catch (e) {}
        }
        const runCfgBox = this.el.cfgRunBox;
        const otherCfgBox = this.el.cfgOtherBox;
        if (!runCfgBox || !otherCfgBox) return;

        runCfgBox.innerHTML = '<div style="color:var(--text-secondary); font-size:13px; padding:6px 0;">正在读取应用列表与状态...</div>';
        otherCfgBox.innerHTML = '<div style="color:var(--text-secondary); font-size:13px; padding:6px 0;">正在读取应用列表与状态...</div>';

        let appList = [];
        let bootKey = '';

        if (this.target && this.target.kind === 'wasm') {
            const ex = this.target.exports();
            if (ex && ex.wasm_apps_json) {
                try {
                    const jsonStr = this._str(ex.wasm_apps_json());
                    const parsed = JSON.parse(jsonStr);
                    if (parsed && Array.isArray(parsed.apps)) {
                        appList = parsed.apps;
                        bootKey = parsed.boot || '';
                    }
                } catch (e) {}
            }
            if (appList.length === 0 && window.appManager && Array.isArray(window.appManager.bundled)) {
                appList = window.appManager.bundled.map(b => ({
                    key: `apps/${b.id}/app.msbc`,
                    id: b.id,
                    name: b.name,
                    description: b.description,
                    path: `/spiffs/apps/${b.id}/app.msbc`,
                    dir: `/spiffs/apps/${b.id}`,
                    ini: `/spiffs/apps/${b.id}/config.ini`,
                    size: b.size,
                    version: b.version,
                    running: false,
                    boot: false,
                    meta: '',
                    source: 'market'
                }));
            }
        } else if (window.activeLink && typeof window.activeLink.apps === 'function') {
            try {
                const res = await window.activeLink.apps();
                if (res && Array.isArray(res.apps)) {
                    appList = res.apps;
                    bootKey = res.boot || '';
                }
            } catch (e) {}
        }

        this.configApps = appList;
        this.cfgOpen = this.cfgOpen || {};

        const run = appList.find(a => a.running || a.boot || (bootKey && a.path && a.path.includes(bootKey)));
        if (this.el.cfgRunHead) {
            this.el.cfgRunHead.textContent = run ? `▶ 正在运行：${run.name}` : '▶ 正在运行的应用';
        }

        if (!run) {
            runCfgBox.innerHTML = `<div style="color:var(--text-secondary); font-size:12.5px; padding:6px 0;">当前没有应用在运行（处于内置系统设置或待机状态）。</div>`;
        } else {
            runCfgBox.innerHTML = `
                <div class="am-app" style="border:1px solid rgba(56, 189, 248, 0.35); border-radius:8px; padding:12px 14px; background:rgba(56, 189, 248, 0.05);">
                    <div class="am-name" style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
                        <span style="color:var(--accent-cyan); font-weight:600; font-size:14px;">${this._esc(run.name)} <span class="am-tag">正在运行</span></span>
                        <span style="font-size:12px; color:var(--text-secondary);">${this._esc(run.dir || run.path || '')}</span>
                    </div>
                    <div class="am-desc" style="margin-bottom:8px;">${this._esc(run.description || '')}</div>
                    <div id="aw-cfg-box-${this._cfgId(run.key || run.id)}"></div>
                </div>
            `;
            await this.openAppConfig(run, true);
        }

        const others = appList.filter(a => !run || (a.key !== run.key && a.id !== run.id));
        if (others.length === 0) {
            otherCfgBox.innerHTML = '<div style="color:var(--text-secondary); font-size:12.5px; padding:6px 0;">没有其他应用。</div>';
        } else {
            otherCfgBox.innerHTML = others.map(a => `
                <div class="am-app" style="margin-bottom:12px; border:1px solid rgba(255,255,255,0.08); border-radius:8px; padding:12px 14px; background:rgba(0,0,0,0.18);">
                    <div class="am-name" style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
                        <span style="font-weight:600; font-size:14px;">${this._esc(a.name)} <span class="am-tag">${a.source === 'builtin' ? '内置' : (a.boot ? '启动应用' : '已安装')}</span></span>
                        <button class="pill-btn compact" data-cfg-act="toggle" data-key="${this._esc(a.key || a.id)}">⚙️ 配置</button>
                    </div>
                    <div class="am-desc" style="margin-bottom:8px;">${this._esc(a.description || a.dir || a.path || '')}</div>
                    <div id="aw-cfg-box-${this._cfgId(a.key || a.id)}"></div>
                </div>
            `).join('');

            for (const o of others) {
                const k = o.key || o.id;
                if (this.cfgOpen[k]) {
                    this.renderAppConfigCard(o);
                }
            }
        }
    }

    async openAppConfig(app, forceOpen = false) {
        const k = app.key || app.id;
        const box = document.getElementById(`aw-cfg-box-${this._cfgId(k)}`);
        if (!box) return;

        if (!forceOpen && this.cfgOpen && this.cfgOpen[k]) {
            delete this.cfgOpen[k];
            box.innerHTML = '';
            return;
        }

        box.innerHTML = '<div style="color:var(--text-secondary); font-size:12px; padding:6px 0;">正在读取应用配置与元数据...</div>';
        this.cfgOpen = this.cfgOpen || {};

        let meta = app.meta || '';
        let ini = '';
        let exists = false;
        const iniPath = app.ini || `/spiffs/apps/${app.id}/config.ini`;

        if (this.target && this.target.kind === 'wasm') {
            const bytes = this._fsRead(iniPath);
            if (bytes && bytes.length > 0) {
                ini = new TextDecoder('utf-8').decode(bytes);
                exists = true;
            }
            if (!meta) {
                const msbcBytes = this._fsRead(app.path || `/spiffs/apps/${app.id}/app.msbc`);
                if (msbcBytes) {
                    meta = this._extractMeta(msbcBytes);
                }
            }
        } else if (window.activeLink && window.activeLink.base) {
            try {
                let r = null;
                if (typeof window.activeLink._json === 'function') {
                    r = await window.activeLink._json(`/api/apps/config?key=${encodeURIComponent(k)}`);
                } else {
                    const res = await fetch(`${window.activeLink.base}/api/apps/config?key=${encodeURIComponent(k)}`);
                    if (res.ok) r = await res.json();
                }
                if (r) {
                    meta = r.meta || meta;
                    ini = r.ini || '';
                    exists = !!r.exists;
                }
            } catch (e) {}
        }

        if (!meta && window.appManager && window.appManager.bundled) {
            const b = window.appManager.bundled.find(x => x.id === app.id);
            if (b && b.meta) meta = b.meta;
        }

        this.cfgOpen[k] = { meta, ini, exists, path: iniPath };
        this.renderAppConfigCard(app);
    }

    renderAppConfigCard(app) {
        const k = app.key || app.id;
        const c = this.cfgOpen && this.cfgOpen[k];
        const box = document.getElementById(`aw-cfg-box-${this._cfgId(k)}`);
        if (!c || !box) return;

        const p = `aw-c-${this._cfgId(k)}`;
        const fields = typeof amAppFields === 'function' ? amAppFields(c.meta) : [];
        const defIni = typeof amDefaultIni === 'function' ? amDefaultIni(app) : (c.meta || '');
        const values = typeof amIniValues === 'function' ? amIniValues(c.exists ? c.ini : defIni) : {};

        let fieldsHtml = '';
        if (fields.length > 0) {
            fieldsHtml = `<div class="am-form" style="border-left:2px solid var(--accent-cyan); padding-left:12px; margin-top:10px;">` +
                fields.map(f => this._renderFieldHtml(p, f, (f.key in values) ? values[f.key] : f.def)).join('') +
                `</div>`;
        } else {
            fieldsHtml = `<div style="color:var(--text-secondary); font-size:12px; margin:8px 0;">该应用暂无可配置的高级项（可在下方直接查看/编辑配置文件）。</div>`;
        }

        box.innerHTML = `
            ${fieldsHtml}
            <div class="am-actions" style="margin-top:10px; display:flex; gap:8px; align-items:center; flex-wrap:wrap;">
                <button class="pill-btn highlight compact" data-cfg-act="save" data-key="${this._esc(k)}">💾 保存配置</button>
                <button class="pill-btn compact" data-cfg-act="reset" data-key="${this._esc(k)}">🔄 恢复默认配置</button>
                <button class="pill-btn compact" data-cfg-act="raw" data-key="${this._esc(k)}">📄 编辑原文件</button>
                <span id="aw-cfg-status-${this._cfgId(k)}" style="font-size:12px;"></span>
            </div>
            <div id="aw-cfg-raw-${this._cfgId(k)}" style="margin-top:8px;"></div>
            <div class="am-help" style="margin-top:8px; font-size:11.5px; color:var(--text-secondary);">
                ${c.exists ? '已配置，配置文件路径：' : '尚未保存独立文件，当前显示默认值；保存后写入：'}<code>${this._esc(c.path)}</code>${app.running ? '，重启或重新载入后生效' : '，应用下次启动时生效'}
            </div>
        `;

        const btnSave = box.querySelector('[data-cfg-act="save"]');
        if (btnSave) btnSave.addEventListener('click', () => this.saveAppConfigItem(app));

        const btnReset = box.querySelector('[data-cfg-act="reset"]');
        if (btnReset) btnReset.addEventListener('click', () => this.resetAppConfigItem(app));

        const btnRaw = box.querySelector('[data-cfg-act="raw"]');
        if (btnRaw) btnRaw.addEventListener('click', () => this.toggleRawAppConfig(app));
    }

    async saveAppConfigItem(app) {
        const k = app.key || app.id;
        const c = this.cfgOpen && this.cfgOpen[k];
        const statusEl = document.getElementById(`aw-cfg-status-${this._cfgId(k)}`);
        if (!c) return;

        const p = `aw-c-${this._cfgId(k)}`;
        let text = c.exists ? c.ini : (typeof amDefaultIni === 'function' ? amDefaultIni(app) : (c.meta || ''));
        const values = typeof amIniValues === 'function' ? amIniValues(text) : {};
        const fields = typeof amAppFields === 'function' ? amAppFields(c.meta) : [];

        for (const f of fields) {
            const el = document.getElementById(`${p}-${f.key}`);
            if (!el) continue;
            const v = f.type === 'bool' ? (el.checked ? '1' : '0') : el.value.trim();
            if (/[;#\n]/.test(v)) {
                if (statusEl) {
                    statusEl.textContent = `❌ ${f.label}：不能含有 ; 或 #`;
                    statusEl.style.color = '#ef4444';
                }
                return;
            }
            if (values[f.key] !== v) {
                if (typeof amIniSet === 'function') {
                    text = amIniSet(text, 'config', f.key, v);
                } else {
                    text += `\n${f.key} = ${v}`;
                }
            }
        }

        let ok = false;
        if (this.target && this.target.kind === 'wasm') {
            const bytes = new TextEncoder().encode(text);
            ok = this._fsWrite(c.path, bytes);
        } else if (window.activeLink && window.activeLink.base) {
            try {
                if (typeof window.activeLink._fetch === 'function') {
                    await window.activeLink._fetch(`/api/apps/config?key=${encodeURIComponent(k)}`, {
                        method: 'POST',
                        headers: { 'Content-Type': 'text/plain;charset=utf-8' },
                        body: text
                    }, 10000, r => r.text());
                    ok = true;
                } else {
                    const res = await fetch(`${window.activeLink.base}/api/apps/config?key=${encodeURIComponent(k)}`, {
                        method: 'POST',
                        headers: { 'Content-Type': 'text/plain;charset=utf-8' },
                        body: text
                    });
                    ok = res.ok;
                }
            } catch (e) {}
        }

        if (ok) {
            c.ini = text;
            c.exists = true;
            if (statusEl) {
                statusEl.textContent = `✅ [${app.name}] 配置已保存`;
                statusEl.style.color = '#72d696';
            }
            this.log('info', `📝 [${app.name}] 应用配置已保存至 ${c.path}`);
        } else {
            if (statusEl) {
                statusEl.textContent = `❌ 保存失败`;
                statusEl.style.color = '#ef4444';
            }
        }
    }

    async resetAppConfigItem(app) {
        if (!confirm(`确定将 ${app.name} 的所有配置恢复为默认值吗？`)) return;
        const k = app.key || app.id;
        const c = this.cfgOpen && this.cfgOpen[k];
        if (!c) return;

        const defIni = typeof amDefaultIni === 'function' ? amDefaultIni(app) : (c.meta || '');
        let ok = false;
        if (this.target && this.target.kind === 'wasm') {
            const bytes = new TextEncoder().encode(defIni);
            ok = this._fsWrite(c.path, bytes);
        } else if (window.activeLink && window.activeLink.base) {
            try {
                if (typeof window.activeLink._fetch === 'function') {
                    await window.activeLink._fetch(`/api/apps/reset?key=${encodeURIComponent(k)}`, { method: 'POST' }, 10000, r => r.text());
                    ok = true;
                } else {
                    const res = await fetch(`${window.activeLink.base}/api/apps/reset?key=${encodeURIComponent(k)}`, { method: 'POST' });
                    ok = res.ok;
                }
            } catch (e) {}
        }

        if (ok) {
            c.ini = defIni;
            c.exists = true;
            this.renderAppConfigCard(app);
            const statusEl = document.getElementById(`aw-cfg-status-${this._cfgId(k)}`);
            if (statusEl) {
                statusEl.textContent = `🔄 [${app.name}] 已恢复默认配置`;
                statusEl.style.color = '#72d696';
            }
        }
    }

    toggleRawAppConfig(app) {
        const k = app.key || app.id;
        const c = this.cfgOpen && this.cfgOpen[k];
        const rawBox = document.getElementById(`aw-cfg-raw-${this._cfgId(k)}`);
        if (!c || !rawBox) return;

        if (rawBox.innerHTML) {
            rawBox.innerHTML = '';
            return;
        }

        const curText = c.exists ? c.ini : (typeof amDefaultIni === 'function' ? amDefaultIni(app) : (c.meta || ''));
        rawBox.innerHTML = `
            <div style="margin-top:8px; background:#0b1118; border:1px solid rgba(255,255,255,0.1); border-radius:6px; padding:10px;">
                <label style="color:var(--text-secondary); font-size:12px; margin-bottom:6px; display:block;">编辑 <code>${this._esc(c.path)}</code> 配置文件：</label>
                <textarea id="aw-cfg-raw-txt-${this._cfgId(k)}" style="width:100%; min-height:140px; font-family:var(--font-mono); font-size:12px; background:#000; color:#e6ecf3; border:1px solid var(--border-color); border-radius:4px; padding:8px; box-sizing:border-box;" spellcheck="false"></textarea>
                <div style="margin-top:8px; display:flex; gap:8px; align-items:center;">
                    <button class="pill-btn compact highlight" id="aw-cfg-raw-save-${this._cfgId(k)}">💾 保存配置文件</button>
                    <span id="aw-cfg-raw-status-${this._cfgId(k)}" style="font-size:12px;"></span>
                </div>
            </div>
        `;

        const txt = document.getElementById(`aw-cfg-raw-txt-${this._cfgId(k)}`);
        if (txt) txt.value = curText;

        const btnSaveRaw = document.getElementById(`aw-cfg-raw-save-${this._cfgId(k)}`);
        if (btnSaveRaw) {
            btnSaveRaw.addEventListener('click', async () => {
                const newText = txt.value;
                let ok = false;
                if (this.target && this.target.kind === 'wasm') {
                    ok = this._fsWrite(c.path, new TextEncoder().encode(newText));
                } else if (window.activeLink && window.activeLink.base) {
                    try {
                        if (typeof window.activeLink._fetch === 'function') {
                            await window.activeLink._fetch(`/api/apps/config?key=${encodeURIComponent(k)}`, {
                                method: 'POST',
                                headers: { 'Content-Type': 'text/plain;charset=utf-8' },
                                body: newText
                            }, 10000, r => r.text());
                            ok = true;
                        } else {
                            const res = await fetch(`${window.activeLink.base}/api/apps/config?key=${encodeURIComponent(k)}`, {
                                method: 'POST',
                                headers: { 'Content-Type': 'text/plain;charset=utf-8' },
                                body: newText
                            });
                            ok = res.ok;
                        }
                    } catch (e) {}
                }
                const rawStatus = document.getElementById(`aw-cfg-raw-status-${this._cfgId(k)}`);
                if (ok) {
                    c.ini = newText;
                    c.exists = true;
                    if (rawStatus) {
                        rawStatus.textContent = '✅ 原文件已保存';
                        rawStatus.style.color = '#72d696';
                    }
                    this.renderAppConfigCard(app);
                } else if (rawStatus) {
                    rawStatus.textContent = '❌ 保存失败';
                    rawStatus.style.color = '#ef4444';
                }
            });
        }
    }

    async loadManageTab() {
        let files = [];
        if (this.target && this.target.kind === 'wasm') {
            files = this._fsList();
        } else {
            const link = (this.target && this.target.link) || window.activeLink;
            if (link && typeof link.fsList === 'function') {
                try {
                    const res = await link.fsList();
                    files = Array.isArray(res) ? res : (res && res.files) || [];
                } catch (e) {}
            }
        }
        const msbcFiles = files.filter(f => f.path && f.path.endsWith('.msbc'));
        if (this.el.manageAppsList) {
            if (msbcFiles.length === 0) {
                this.el.manageAppsList.innerHTML = '<div style="color:var(--text-secondary); padding:8px 0;">暂无已安装的 .msbc 应用镜像</div>';
            } else {
                let html = '<table style="width:100%; border-collapse:collapse; font-size:13px;">';
                html += '<tr style="border-bottom:1px solid var(--border-color); color:var(--text-secondary); text-align:left;"><th>应用路径</th><th>大小</th><th>操作</th></tr>';
                for (const f of msbcFiles) {
                    html += `
                        <tr style="border-bottom:1px solid rgba(255,255,255,0.05);">
                            <td style="padding:6px 0; font-family:var(--font-mono);">${this._esc(f.path)}</td>
                            <td style="padding:6px 0;">${((f.size || 0) / 1024).toFixed(1)} KB</td>
                            <td style="padding:6px 0;">
                                <button class="pill-btn compact" onclick="if(window.appManager) window.appManager.runWasmApp('${this._esc(f.path)}')">▶ 启动</button>
                            </td>
                        </tr>`;
                }
                html += '</table>';
                this.el.manageAppsList.innerHTML = html;
            }
        }
    }

    async loadInfoTab() {
        if (!this.target && this.getTarget) {
            try { this.target = this.getTarget(); } catch (e) {}
        }
        const titleEl = this.el.root.querySelector('#aw-info-title');
        if (this.target && this.target.kind === 'device') {
            const link = this.target.link || window.activeLink;
            if (titleEl) titleEl.textContent = 'ℹ️ 硬件与运行状态';
            // over WiFi: the same report as the board's own web page (/api/hardware)
            if (link && link.kind === 'http' && typeof link._json === 'function') {
                try {
                    const hw = await link._json('/api/hardware', {}, 10000);
                    if (hw && hw.success && this.el.infoGrid) {
                        this.el.infoGrid.innerHTML = this._hardwareHtml(hw);
                        return;
                    }
                } catch (e) {
                    this.log('error', `读取硬件信息失败: ${e.message || e}`);
                }
            }
            let info = {}, stats = {};
            try { if (link && typeof link.info === 'function') info = await link.info(); } catch (e) {}
            try { if (link && typeof link.stats === 'function') stats = await link.stats(); } catch (e) {}
            if (this.el.infoGrid) {
                const vmAlloc = stats.vm_heap_allocated || info.heap_allocated || 0;
                const vmCap = stats.vm_heap_capacity || info.heap_capacity || 0;
                const sysFree = stats.free_heap || info.free_heap || 0;
                const note = link && link.kind === 'serial'
                    ? '<div class="desc" style="margin-top:8px;">串口连接只能读取概要；通过 WiFi (HTTP) 连接设备可查看与设备网页相同的完整硬件信息。</div>' : '';
                this.el.infoGrid.innerHTML = `<div class="aw-kv-grid">
                    <b>实体硬件平台:</b> <span>${this._esc(info.platform || 'ESP32')} (${this._esc(info.version || 'v1.0')})</span>
                    <b>MAC 地址:</b> <span>${this._esc(info.mac || '-')}</span>
                    <b>局域网 IP:</b> <span>${this._esc(info.ip || '-')} (${this._esc(info.ssid || '-')})</span>
                    <b>显示屏规格:</b> <span>${info.width || 320}×${info.height || 480} (${this._esc(info.display_mode || 'band')}, ${info.color_bits || 16}-bit)</span>
                    <b>VM 堆内存 (Heap):</b> <span>${(vmAlloc / 1024).toFixed(1)} KB / ${(vmCap / 1024).toFixed(1)} KB</span>
                    <b>系统剩余内存:</b> <span>${(sysFree / 1024).toFixed(1)} KB Free</span>
                    <b>存储系统 (LittleFS):</b> <span>${((stats.spiffs_used || 0) / 1024).toFixed(1)} KB / ${((stats.spiffs_total || 0) / 1024).toFixed(1)} KB</span>
                </div>${note}`;
            }
            return;
        }
        if (titleEl) titleEl.textContent = 'ℹ️ 仿真硬件与运行状态';
        const ex = (this.target && typeof this.target.exports === 'function') ? this.target.exports() : null;
        const alloc = (ex && ex.wasm_heap_alloc) ? ex.wasm_heap_alloc() : 0;
        const cap = (ex && ex.wasm_heap_capacity) ? ex.wasm_heap_capacity() : 0;
        const isOnline = window.isSimWifiOnline ? window.isSimWifiOnline() : true;

        if (this.el.infoGrid) {
            this.el.infoGrid.innerHTML = `<div class="aw-kv-grid">
                <b>虚拟硬件平台:</b> <span>ESP32 (WASM 仿真)</span>
                <b>Scheme 虚拟机:</b> <span>Native C VM + Pure Scheme Compiler</span>
                <b>固件 API 版本:</b> <span>1.5 (全兼容 ESP32 固件 1.x)</span>
                <b>虚拟显存规格:</b> <span>320×480 RGB565 (~300 KB VFB)</span>
                <b>堆内存分配 (Heap):</b> <span>${(alloc / 1024).toFixed(1)} KB / ${(cap / 1024).toFixed(1)} KB</span>
                <b>WiFi 联网状态:</b> <span>${isOnline ? '🟢 已联网 (网络在线)' : '🔴 已断开 (网络离线)'}</span>
                <b>存储系统 (Flash):</b> <span>/spiffs 文件系统 (持久化于浏览器 IndexedDB)</span>
            </div>`;
        }
    }

    /* /api/hardware as the board's own web page shows it (setup_page.html loadHardware) */
    _hardwareHtml(h) {
        const esc = (v) => this._esc(v == null ? '' : String(v));
        const kb = (n) => `${((Number(n) || 0) / 1024).toFixed(1)} KB`;
        const pct = (a, b) => (b ? ` (${Math.round(a * 100 / b)}%)` : '');
        const dur = (s) => {
            s = Math.floor(Number(s) || 0);
            const d = Math.floor(s / 86400), hh = Math.floor(s % 86400 / 3600), mm = Math.floor(s % 3600 / 60);
            return d ? `${d} 天 ${hh} 小时` : hh ? `${hh} 小时 ${mm} 分` : `${mm} 分 ${s % 60} 秒`;
        };
        const section = (title, rows) => `<h4 style="margin:14px 0 6px;">${title}</h4><div class="aw-kv-grid">` +
            rows.filter(Boolean).map(([k, v]) => `<b>${esc(k)}:</b> <span>${v}</span>`).join('') + '</div>';
        const c = h.chip || {}, f = h.firmware || {}, m = h.memory || {}, v = h.vm || {}, s = h.storage || {};
        const r = h.app_rom || {}, fr = h.font_rom || {}, d = h.display || {}, n = h.network || {}, la = h.last_app;
        let html = section('芯片与固件', [
            ['芯片', `${esc(c.model)} v${((c.revision || 0) / 100).toFixed(2)}，${c.cores} 核 ${c.mhz} MHz${c.bt ? '，WiFi+BT' : ''}`],
            ['MAC', esc(c.mac)],
            ['Flash', kb(c.flash)],
            ['固件', `${esc(f.version)}，${esc(f.built)}`],
            ['ESP-IDF', esc(f.idf)],
            ['固件镜像', `${kb(f.image)} / ${kb(f.partition)} 分区${pct(f.image, f.partition)}`],
            ['运行时间', `${dur((f.uptime_ms || 0) / 1000)}，复位原因 ${esc(f.reset)}，时间${f.time_synced ? '已' : '未'}同步`],
        ]);
        html += section('系统内存', [
            ['空闲', `${kb(m.free)} / ${kb(m.internal_total)}`],
            ['历史最低', kb(m.min_free)],
            ['最大连续块', kb(m.largest)],
            ['DMA 可用', kb(m.dma_free)],
            m.iram_total ? ['IRAM', `已用 ${kb(m.iram_total - m.iram_free)} / ${kb(m.iram_total)}${pct(m.iram_total - m.iram_free, m.iram_total)}，其中 VM ${kb(m.iram_vm)}`] : null,
        ]);
        html += section(`当前程序：${v.settings ? '系统设置' : esc(v.program)}`, [
            ['VM 堆', `${kb(v.used)} / ${kb(v.heap)}${pct(v.used, v.heap)}`],
            v.probe ? ['开机测量', `空闲 ${kb(v.probe.free)}，最大连续块 ${kb(v.probe.largest)}，系统预留 ${kb(v.probe.reserved)}${v.probe.wifi ? '（WiFi 已连上）' : '（WiFi 未连上）'}`] : null,
            ['存活 / 峰值', `${kb(v.live)} / ${kb(v.peak)}`],
            ['累计分配', `${v.alloc_kb} KB，GC ${v.minor_gcs} 次小回收、${v.major_gcs} 次全回收`],
            ['栈', `峰值 ${v.stack_peak} / ${v.stack_slots} 槽`],
            ['代码 ROM', v.rom ? `${kb(v.rom)}（原地运行于 Flash）` : '无（代码在 RAM 中）'],
        ]);
        if (la) {
            html += section(`上次运行的应用：${esc(la.id)}（进入设置前记录）`, [
                ['VM 堆', `${kb(la.live)} / ${kb(la.heap)}`],
                ['堆峰值', kb(la.peak)],
                ['代码 ROM', kb(la.rom)],
                ['系统内存', `空闲 ${kb(la.free)}，最低 ${kb(la.min_free)}`],
                ['运行了', dur(la.uptime_s)],
            ]);
        }
        html += section('存储', [
            ['文件系统', `${kb(s.used)} / ${kb(s.total)}${pct(s.used, s.total)}`],
            ['文件', `${s.files} 个，其中应用目录 ${s.apps} 个`],
            ['应用 ROM 分区', `${kb(r.partition)}，当前程序的代码镜像 ${r.image ? kb(r.image) : '未使用'}`],
        ]);
        const fonts = (fr.fonts || []).map(x => `${esc(x.name)} (${kb(x.bytes)})`).join('，') || '无';
        const slots = (fr.slots || []).filter(x => x.source !== 'built-in' || x.slot < 2)
            .map(x => `${x.slot}: ${esc(x.name || '-')} ${x.height}px ${/^built-?in$/.test(x.source) ? '内置' : esc(x.source)}`).join('；');
        html += section('字库', [
            ['系统字库', `${kb(fr.used)} / ${kb(fr.capacity)}${pct(fr.used, fr.capacity)}`],
            ['字库', fonts],
            ['字体槽', slots || '-'],
        ]);
        html += section('显示', [
            ['屏幕', `${esc(d.model)} ${d.width}x${d.height}`],
            ['模式', `${esc(d.mode)}（${d.band_lines} 行一带），${d.color_bits} 位色，配色 ${esc(d.scheme)}`],
            ['显存', `缓冲 ${kb(d.buffer)}，DMA ${kb(d.dma)}`],
            ['负载', `${d.fps} 帧/秒，主循环 ${d.busy_pct}% 忙，背光 ${d.backlight}`],
            d.dl_cap === undefined ? null : ['显示列表', d.dl_cmds < 0 ? `上一帧超出 ${d.dl_cap} 条，逐带重画` : `上一帧 ${d.dl_cmds} / ${d.dl_cap} 条命令${d.dl_heap ? `，从堆扩容 ${kb(d.dl_heap)}` : ''}`],
        ]);
        html += section('网络', [
            ['WiFi', n.connected ? `${esc(n.ssid)}，${esc(n.ip)}，${n.rssi} dBm` : '未连接'],
            ['热点', n.ap ? `${esc(n.ap_ssid)}，${esc(n.ap_ip)}，${n.clients} 台设备` : '未开启'],
        ]);
        return html;
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

    _validatePasswordSecurity(pwd) {
        if (window.DeviceSetupWizard && typeof window.DeviceSetupWizard.validatePasswordSecurity === 'function') {
            return window.DeviceSetupWizard.validatePasswordSecurity(pwd);
        }
        if (!pwd || typeof pwd !== 'string') return { valid: false, message: '密码不能为空' };
        const val = pwd.trim();
        if (val.length < 6) return { valid: false, message: '密码长度不能小于 6 位字符' };
        let allSame = true;
        for (let i = 1; i < val.length; i++) {
            if (val[i] !== val[0]) { allSame = false; break; }
        }
        if (allSame) return { valid: false, message: '密码过于简单，不能使用全重复字符（如 88888888、00000000）' };
        const commonWeak = new Set([
            '123456', '1234567', '12345678', '123456789', '01234567',
            '88888888', '00000000', '11111111', '66666666',
            '87654321', '76543210', '654321', '987654321',
            'password', 'admin123', 'qwertyui'
        ]);
        if (commonWeak.has(val.toLowerCase())) {
            return { valid: false, message: '该密码属于常见弱密码，请设置更安全的密码' };
        }
        let ascRun = 1, descRun = 1, repRun = 1;
        for (let i = 1; i < val.length; i++) {
            const prev = val.charCodeAt(i - 1), curr = val.charCodeAt(i);
            if (prev >= 48 && prev <= 57 && curr >= 48 && curr <= 57) {
                const diff = curr - prev;
                if (diff === 1) { ascRun++; if (ascRun >= 4) return { valid: false, message: '密码过于简单，不能包含正序连续数字（如 12345678、1234）' }; }
                else ascRun = 1;
                if (diff === -1) { descRun++; if (descRun >= 4) return { valid: false, message: '密码过于简单，不能包含倒序连续数字（如 87654321、4321）' }; }
                else descRun = 1;
                if (diff === 0) { repRun++; if (repRun >= 4) return { valid: false, message: '密码过于简单，不能包含连续重复数字（如 88888888、00000000）' }; }
                else repRun = 1;
            } else {
                ascRun = 1; descRun = 1; repRun = 1;
            }
        }
        return { valid: true };
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
