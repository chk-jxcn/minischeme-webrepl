/**
 * @file device_setup.js
 * @brief Initial Device Setup Wizard for MiniScheme WebREPL.
 *
 * Rules:
 * 1. Auto-triggers ONLY when connecting via Web Serial and the device is detected
 *    as unconfigured (missing config.ini or empty WiFi SSID), or when writing to
 *    the local WASM simulated device.
 * 2. Local simulated device (WASM) does NOT require a password and is restricted
 *    exclusively to local proxy connections (127.0.0.1 / localhost / private LAN IP)
 *    to prevent load on external servers.
 * 3. When connected to a Serial or WiFi hardware device, users can configure WiFi,
 *    App Proxy URL, and Hardware Password. If the hardware password is already set
 *    on the device, it is displayed in plaintext and locked against modification.
 */

class DeviceSetupWizard {
    /**
     * @param {object} [opts]
     * @param {() => object} [opts.getBackend]
     * @param {(kind: string, text: string) => void} [opts.log]
     */
    constructor(opts = {}) {
        this.getBackend = (opts && opts.getBackend) || (() => null);
        this.log = (opts && opts.log) || (() => {});
        this.backend = null;
        this.busy = false;
        this.lockedHwPassword = '';
        this._build();
    }

    /**
     * Validate whether a proxy/converter URL points strictly to a local or private LAN address.
     * Empty string is allowed (falls back to local default).
     */
    static isLocalProxyUrl(urlStr) {
        const s = String(urlStr || '').trim();
        if (!s) return true;
        let parsed;
        try {
            parsed = new URL(s);
        } catch (e) {
            return false;
        }
        if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return false;
        const host = (parsed.hostname || '').toLowerCase().replace(/^\[|\]$/g, '');
        if (!host) return false;
        if (host === 'localhost' || host === '::1' || host === '0.0.0.0') return true;
        if (/^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(host)) return true;
        if (/^10\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(host)) return true;
        if (/^192\.168\.\d{1,3}\.\d{1,3}$/.test(host)) return true;
        const m172 = /^172\.(\d{1,3})\.\d{1,3}\.\d{1,3}$/.exec(host);
        if (m172) {
            const second = parseInt(m172[1], 10);
            if (second >= 16 && second <= 31) return true;
        }
        if (window.LOCAL_SERVER_BASE) {
            try {
                const cfgHost = new URL(window.LOCAL_SERVER_BASE).hostname.toLowerCase().replace(/^\[|\]$/g, '');
                if (host === cfgHost) return true;
            } catch (e) {}
        }
        return false;
    }

    /**
     * Check if WebREPL is hosted on a public domain/IP (e.g. GitHub Pages).
     */
    static isPublicWebRepl() {
        if (typeof window === 'undefined' || !window.location) return false;
        const h = (window.location.hostname || '').toLowerCase().trim();
        if (!h) return false;
        if (h === 'localhost' || h === '127.0.0.1' || h === '::1' || h === '0.0.0.0') return false;
        if (/^10\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(h)) return false;
        if (/^192\.168\.\d{1,3}\.\d{1,3}$/.test(h)) return false;
        const m172 = /^172\.(\d{1,3})\.\d{1,3}\.\d{1,3}$/.exec(h);
        if (m172 && parseInt(m172[1], 10) >= 16 && parseInt(m172[1], 10) <= 31) return false;
        return true;
    }

    /**
     * Dedicated public proxy & protocol converter address.
     */
    static getPublicProxyServer() {
        return 'http://124.222.231.186:8087';
    }

    /**
     * Built-in password security filter:
     * - Minimum length of 6 characters
     * - Blocks all-identical characters (e.g. 88888888, 00000000)
     * - Blocks ascending sequential numbers (e.g. 12345678, 1234, 2345)
     * - Blocks descending sequential numbers (e.g. 87654321, 4321, 6543)
     * - Blocks repeated digits in a row (e.g. 8888, 0000)
     * - Blocks common weak passwords
     */
    static validatePasswordSecurity(pwd) {
        if (!pwd || typeof pwd !== 'string') {
            return { valid: false, message: '密码不能为空' };
        }
        const val = pwd.trim();
        if (val.length < 6) {
            return { valid: false, message: '密码长度不能小于 6 位字符' };
        }

        // 1. All identical characters
        let allSame = true;
        for (let i = 1; i < val.length; i++) {
            if (val[i] !== val[0]) {
                allSame = false;
                break;
            }
        }
        if (allSame) {
            return { valid: false, message: '密码过于简单，不能使用全重复字符（如 88888888、00000000）' };
        }

        // 2. Common weak passwords blacklist
        const commonWeak = new Set([
            '123456', '1234567', '12345678', '123456789', '01234567',
            '88888888', '00000000', '11111111', '66666666',
            '87654321', '76543210', '654321', '987654321',
            'password', 'admin123', 'qwertyui'
        ]);
        if (commonWeak.has(val.toLowerCase())) {
            return { valid: false, message: '该密码属于常见弱密码，请设置更安全的密码' };
        }

        // 3. 4+ consecutive ascending, descending, or repeated digits
        let ascRun = 1, descRun = 1, repRun = 1;
        for (let i = 1; i < val.length; i++) {
            const prev = val.charCodeAt(i - 1);
            const curr = val.charCodeAt(i);
            const isDigitPrev = (prev >= 48 && prev <= 57);
            const isDigitCurr = (curr >= 48 && curr <= 57);

            if (isDigitPrev && isDigitCurr) {
                const diff = curr - prev;
                if (diff === 1) {
                    ascRun++;
                    if (ascRun >= 4) {
                        return { valid: false, message: '密码过于简单，不能包含正序连续数字（如 12345678、1234）' };
                    }
                } else {
                    ascRun = 1;
                }

                if (diff === -1) {
                    descRun++;
                    if (descRun >= 4) {
                        return { valid: false, message: '密码过于简单，不能包含倒序连续数字（如 87654321、4321）' };
                    }
                } else {
                    descRun = 1;
                }

                if (diff === 0) {
                    repRun++;
                    if (repRun >= 4) {
                        return { valid: false, message: '密码过于简单，不能包含连续重复数字（如 88888888、00000000）' };
                    }
                } else {
                    repRun = 1;
                }
            } else {
                ascRun = 1;
                descRun = 1;
                repRun = 1;
            }
        }

        return { valid: true };
    }

    /**
     * Parse INI text into section.key map.
     */
    static parseIniMap(iniText) {
        const lines = String(iniText || '').split('\n');
        let sec = '';
        const kv = {};
        for (let line of lines) {
            line = line.trim();
            if (!line || line.startsWith(';') || line.startsWith('#')) continue;
            const m = line.match(/^\[(.*)\]$/);
            if (m) { sec = m[1].trim().toLowerCase(); continue; }
            const eq = line.indexOf('=');
            if (eq > 0) {
                const k = line.substring(0, eq).trim();
                let v = line.substring(eq + 1).trim();
                const cIdx = v.search(/[;#]/);
                if (cIdx >= 0) v = v.substring(0, cIdx).trim();
                kv[`${sec}.${k}`] = v;
            }
        }
        return kv;
    }

    /**
     * Check if a config.ini text represents an unconfigured device (no WiFi SSID set).
     */
    static isConfigUnconfigured(iniText) {
        if (!iniText || !String(iniText).trim()) return true;
        const kv = DeviceSetupWizard.parseIniMap(iniText);
        const ssid = (kv['wifi.ssid'] || kv['wifi.wifi_ssid'] || '').trim();
        return ssid.length === 0;
    }

    _build() {
        const root = document.createElement('div');
        root.className = 'fm-overlay ds-overlay';
        root.hidden = true;
        root.innerHTML = `
            <div class="fm-dialog ds-dialog" role="dialog" aria-modal="true" aria-labelledby="ds-title" style="max-width: 680px;">
                <div class="fm-head">
                    <span class="fm-title" id="ds-title">⚙️ 初始设备配置向导</span>
                    <span class="fm-target ds-target"></span>
                    <button class="fm-close" data-act="close" title="关闭 (Esc)">&times;</button>
                </div>
                <div class="am-body ds-body" style="padding: 16px 24px; max-height: 70vh; overflow-y: auto;">
                    <div id="ds-intro-banner" style="margin-bottom: 14px; font-size: 13px; color: var(--text-secondary); line-height: 1.5;">
                        在此设置 WiFi 网络、应用代理服务器地址以及硬件密码。点击<b>“保存并重启”</b>将配置写入目标设备。
                    </div>

                    <!-- Simulator Notice Banner -->
                    <div id="ds-sim-notice" hidden style="margin-bottom: 14px; padding: 10px 14px; border-radius: 8px; background: rgba(56, 189, 248, 0.1); border: 1px solid rgba(56, 189, 248, 0.3); color: #7dd3fc; font-size: 12.5px; line-height: 1.5;">
                        💻 <b>本地模拟设备模式</b>：模拟设备无需设置 WiFi 与硬件密码，并且<b>只能使用本地代理连接</b>（<code>127.0.0.1</code> / <code>localhost</code> / 局域网 IP），避免对外部服务器造成压力。
                    </div>

                    <!-- WiFi Section -->
                    <div id="ds-wifi-section" class="ds-section" style="margin-bottom: 16px; border: 1px solid var(--border-color); border-radius: 8px; padding: 14px 18px; background: rgba(255,255,255,0.02);">
                        <h4 style="margin-bottom: 12px; font-size: 14px; color: var(--accent-cyan);">📶 1. WiFi 无线网络设置 [wifi]</h4>
                        <div style="display: flex; align-items: center; gap: 8px; margin-bottom: 10px;">
                            <label style="font-size: 13px; display: inline-flex; align-items: center; gap: 6px; cursor: pointer;">
                                <input type="checkbox" id="ds-wifi-enable" checked style="width: 16px; height: 16px; accent-color: var(--accent-cyan); cursor: pointer;">
                                <span style="font-weight: 500;">WiFi 连网状态 (默认开启)</span>
                            </label>
                        </div>
                        <div style="display: grid; grid-template-columns: 120px 1fr; gap: 10px; align-items: center; margin-bottom: 8px;">
                            <label for="ds-wifi-ssid" style="font-size: 13px;">WiFi 名称:</label>
                            <input type="text" id="ds-wifi-ssid" placeholder="例如: MyHome-WiFi" class="device-host-input" style="width: 100%;">
                        </div>
                        <div style="display: grid; grid-template-columns: 120px 1fr; gap: 10px; align-items: center;">
                            <label for="ds-wifi-password" style="font-size: 13px;">WiFi 密码:</label>
                            <input type="password" id="ds-wifi-password" placeholder="WiFi 密码" class="device-host-input" style="width: 100%;">
                        </div>
                    </div>

                    <!-- Server & Security Section -->
                    <div class="ds-section" style="margin-bottom: 16px; border: 1px solid var(--border-color); border-radius: 8px; padding: 14px 18px; background: rgba(255,255,255,0.02);">
                        <h4 style="margin-bottom: 12px; font-size: 14px; color: var(--accent-blue);">🛡️ 2. 应用代理与安全密码 [server]</h4>
                        <div style="display: grid; grid-template-columns: 120px 1fr; gap: 10px; align-items: center; margin-bottom: 8px;">
                            <label for="ds-proxy-url" style="font-size: 13px;">应用代理地址:</label>
                            <input type="text" id="ds-proxy-url" placeholder="http://127.0.0.1:8087" value="http://127.0.0.1:8087" class="device-host-input" style="width: 100%;">
                        </div>
                        <div style="display: grid; grid-template-columns: 120px 1fr; gap: 10px; align-items: center; margin-bottom: 8px;">
                            <label for="ds-converter-url" style="font-size: 13px;">协议转换器:</label>
                            <input type="text" id="ds-converter-url" placeholder="http://127.0.0.1:8087" value="http://127.0.0.1:8087" class="device-host-input" style="width: 100%;">
                        </div>
                        <div id="ds-hw-password-row" style="display: grid; grid-template-columns: 120px 1fr; gap: 10px; align-items: center; margin-bottom: 6px;">
                            <label for="ds-hw-password" style="font-size: 13px;">硬件安全密码:</label>
                            <input type="text" id="ds-hw-password" placeholder="设置硬件密码 (已设置后将明文显示且不可修改)" class="device-host-input" style="width: 100%;" autocomplete="off" spellcheck="false">
                        </div>
                        <div id="ds-hw-password-hint" style="font-size: 11px; color: #eab308; margin-left: 130px;">
                            ⚠️ 提示：硬件密码用于 HKDF 派生端到端加密密钥与身份验证；一旦设置将以明文显示且禁止修改。
                        </div>
                    </div>

                    <!-- System Boot App Section -->
                    <div class="ds-section" style="margin-bottom: 16px; border: 1px solid var(--border-color); border-radius: 8px; padding: 14px 18px; background: rgba(255,255,255,0.02);">
                        <h4 style="margin-bottom: 12px; font-size: 14px; color: var(--accent-green);">🚀 3. 开机默认启动应用 [system]</h4>
                        <div style="display: grid; grid-template-columns: 120px 1fr; gap: 10px; align-items: center;">
                            <label for="ds-boot-app" style="font-size: 13px;">启动应用:</label>
                            <select id="ds-boot-app" class="mode-dropdown" style="width: 100%; padding: 6px 10px;">
                                <option value="" selected>内置系统设置 (Settings - 默认)</option>
                                <option value="apps/calendar/app.msbc">万年历 (Calendar)</option>
                                <option value="apps/weather/app.msbc">天气预报 (Weather)</option>
                                <option value="apps/stocks/app.msbc">股票行情 (Stocks)</option>
                                <option value="apps/news/app.msbc">热点新闻 (News)</option>
                                <option value="apps/crypto/app.msbc">加密货币 (Crypto)</option>
                                <option value="apps/futures/app.msbc">大宗期货 (Futures)</option>
                                <option value="apps/memo/app.msbc">电子备忘录 (Memo)</option>
                                <option value="apps/notifier/app.msbc">消息提示 (Notifier)</option>
                                <option value="apps/album/app.msbc">电子相册 (Album)</option>
                                <option value="apps/usage/app.msbc">Token 用量 (Usage)</option>
                                <option value="apps/pcmonitor/app.msbc">PC 监视器 (PC Monitor)</option>
                                <option value="apps/settings/app.msbc">系统设置独立版 (Settings)</option>
                            </select>
                        </div>
                    </div>
                </div>
                <div class="fm-toolbar" style="padding: 12px 24px; border-top: 1px solid var(--border-color); display: flex; gap: 10px; justify-content: flex-end;">
                    <button class="pill-btn" data-act="read">⟳ 读取设备配置</button>
                    <button class="pill-btn" data-act="default">恢复推荐默认</button>
                    <button class="action-btn highlight" data-act="save" style="background: var(--accent-blue); color: #fff; font-weight: 600;">💾 保存配置并重启设备</button>
                </div>
                <div class="fm-status ds-status" role="status" aria-live="polite"></div>
            </div>`;

        if (document.body) {
            document.body.appendChild(root);
        } else {
            window.addEventListener('DOMContentLoaded', () => {
                if (!root.parentElement && document.body) document.body.appendChild(root);
            });
        }

        const q = (sel) => root.querySelector(sel);
        this.el = {
            root,
            title: q('#ds-title'),
            target: q('.ds-target'),
            status: q('.ds-status'),
            introBanner: q('#ds-intro-banner'),
            simNotice: q('#ds-sim-notice'),
            wifiSection: q('#ds-wifi-section'),
            wifiEnable: q('#ds-wifi-enable'),
            wifiSsid: q('#ds-wifi-ssid'),
            wifiPass: q('#ds-wifi-password'),
            proxyUrl: q('#ds-proxy-url'),
            converterUrl: q('#ds-converter-url'),
            hwPassRow: q('#ds-hw-password-row'),
            hwPass: q('#ds-hw-password'),
            hwPassHint: q('#ds-hw-password-hint'),
            bootApp: q('#ds-boot-app'),
        };

        if (this.el.wifiEnable) {
            this.el.wifiEnable.addEventListener('change', (e) => {
                if (typeof window.setSimWifiOnline === 'function') {
                    window.setSimWifiOnline(e.target.checked, e.target);
                }
            });
        }

        root.addEventListener('click', (e) => {
            if (e.target === root) { this.close(); return; }
            const btn = e.target.closest('[data-act]');
            if (btn && !btn.disabled) this._action(btn.dataset.act);
        });

        root.addEventListener('keydown', (e) => {
            if (e.key === 'Escape') { e.preventDefault(); this.close(); }
        });
    }

    _status(text, kind) {
        this.el.status.textContent = text || '';
        this.el.status.className = 'fm-status ds-status' + (kind ? ` fm-status-${kind}` : '');
    }

    _isSimulator() {
        return !!(this.backend && this.backend.kind === 'wasm');
    }

    _applyHwPasswordLockState(existingPassword) {
        const pwd = String(existingPassword || '').trim();
        this.el.hwPass.type = 'text'; // Always plaintext when shown
        if (this._isSimulator()) {
            this.lockedHwPassword = '';
            this.el.hwPass.value = '';
            this.el.hwPass.readOnly = true;
            this.el.hwPass.disabled = true;
            return;
        }
        if (pwd.length > 0) {
            this.lockedHwPassword = pwd;
            this.el.hwPass.value = pwd;
            this.el.hwPass.readOnly = true;
            this.el.hwPass.disabled = true;
            this.el.hwPass.style.opacity = '0.85';
            this.el.hwPass.style.cursor = 'not-allowed';
            if (this.el.hwPassHint) {
                this.el.hwPassHint.style.color = '#4ade80';
                this.el.hwPassHint.textContent = '🔒 硬件密码已设置（明文显示），已设置的硬件密码禁止修改。';
            }
        } else {
            this.lockedHwPassword = '';
            this.el.hwPass.value = '';
            this.el.hwPass.readOnly = false;
            this.el.hwPass.disabled = false;
            this.el.hwPass.style.opacity = '1';
            this.el.hwPass.style.cursor = '';
            this.el.hwPass.placeholder = '必填项：请输入不小于 6 位字符的硬件密码';
            if (this.el.hwPassHint) {
                this.el.hwPassHint.style.color = '#eab308';
                this.el.hwPassHint.textContent = '⚠️ 必填项：硬件密码用于 HKDF 派生端到端加密密钥与身份验证（长度不小于 6 位字符）；一旦设置将以明文显示且禁止修改。';
            }
        }
    }

    _updateModeUi() {
        const isSim = this._isSimulator();
        if (this.el.simNotice) this.el.simNotice.hidden = !isSim;
        if (this.el.wifiSection) this.el.wifiSection.hidden = isSim;
        if (this.el.hwPassRow) this.el.hwPassRow.style.display = isSim ? 'none' : 'grid';
        if (this.el.hwPassHint) this.el.hwPassHint.hidden = isSim;
        if (this.el.title) {
            this.el.title.textContent = isSim ? '⚙️ 本地模拟设备初始化配置' : '⚙️ ESP32 设备初始化配置';
        }
        const defaultLocalProxy = window.LOCAL_SERVER_BASE || 'http://127.0.0.1:8087';
        if (isSim) {
            this.el.proxyUrl.placeholder = `${defaultLocalProxy} (仅限本地/局域网代理，非加密协议)`;
            this.el.converterUrl.placeholder = `${defaultLocalProxy} (仅限本地/局域网代理，非加密协议)`;
            this._applyHwPasswordLockState('');
        } else {
            if (DeviceSetupWizard.isPublicWebRepl()) {
                const pubProxy = DeviceSetupWizard.getPublicProxyServer();
                this.el.proxyUrl.placeholder = `${pubProxy} (公网加密代理)`;
                this.el.converterUrl.placeholder = `${pubProxy} (公网加密代理)`;
            } else {
                this.el.proxyUrl.placeholder = 'http://192.168.1.100:8087';
                this.el.converterUrl.placeholder = 'http://192.168.1.100:8087';
            }
        }
    }

    /**
     * Called automatically ONLY after connecting via Web Serial.
     * Checks if the device is unconfigured (no WiFi SSID in /spiffs/config.ini),
     * and if so, opens the Initial Device Setup Wizard automatically.
     */
    async checkSerialAndOpenIfUnconfigured(serialLink) {
        if (!serialLink || serialLink.kind !== 'serial') return false;
        try {
            let iniText = '';
            try {
                const bytes = await serialLink.fsRead('/spiffs/config.ini');
                if (bytes && bytes.length) iniText = new TextDecoder().decode(bytes);
            } catch (e) {
                try {
                    const bytes = await serialLink.fsRead('config.ini');
                    if (bytes && bytes.length) iniText = new TextDecoder().decode(bytes);
                } catch (err) { /* no config.ini yet */ }
            }
            if (DeviceSetupWizard.isConfigUnconfigured(iniText)) {
                this.log('info', '⚙️ 检测到串口设备尚未配置 WiFi 网络，已自动弹出初始化配置界面。');
                await this.open({ autoTriggered: true });
                return true;
            }
        } catch (e) {
            /* ignore probe errors */
        }
        return false;
    }

    async open(opts = {}) {
        try {
            this.backend = this.getBackend();
        } catch (e) {
            this.log('error', `⚙️ 设备配置: ${e.message || e}`);
            return;
        }
        if (!this.backend) {
            this.log('error', '⚙️ 设备配置: 请先连接串口/WiFi 设备，或切换到本地 WASM 模拟设备');
            return;
        }
        this.el.target.textContent = this.backend.label || '';
        this._updateModeUi();
        this.el.root.hidden = false;
        await this._readFromDevice(opts && opts.autoTriggered);
    }

    close() {
        this.el.root.hidden = true;
    }

    async _action(act) {
        if (act === 'close') this.close();
        else if (act === 'read') await this._readFromDevice(false);
        else if (act === 'default') this._setDefault();
        else if (act === 'save') await this._saveAndReboot();
    }

    _setDefault() {
        let defaultProxy;
        if (this._isSimulator()) {
            defaultProxy = window.LOCAL_SERVER_BASE || 'http://127.0.0.1:8087';
        } else if (DeviceSetupWizard.isPublicWebRepl()) {
            defaultProxy = DeviceSetupWizard.getPublicProxyServer();
        } else {
            defaultProxy = window.LOCAL_SERVER_BASE || 'http://192.168.1.100:8087';
        }
        if (this.el.wifiEnable) {
            this.el.wifiEnable.checked = true;
        }
        this.el.wifiSsid.value = '';
        this.el.wifiPass.value = '';
        this.el.proxyUrl.value = defaultProxy;
        this.el.converterUrl.value = defaultProxy;
        if (!this._isSimulator() && !this.lockedHwPassword) {
            this.el.hwPass.value = '';
        }
        this.el.bootApp.value = '';
        this._status('已填入推荐默认设置', 'ok');
    }

    async _readFromDevice(autoTriggered = false) {
        this._status('正在读取设备 /spiffs/config.ini…');
        this._applyHwPasswordLockState('');
        if (this.el.wifiEnable) {
            this.el.wifiEnable.checked = typeof window.isSimWifiOnline === 'function' ? window.isSimWifiOnline() : true;
        }
        try {
            let bytes = null;
            try {
                bytes = await this.backend.fsRead('/spiffs/config.ini');
            } catch (e) {
                try { bytes = await this.backend.fsRead('config.ini'); } catch (err) {}
            }

            if (!bytes || !bytes.length) {
                this._setDefault();
                if (autoTriggered) {
                    this._status('⚠️ 检测到串口设备尚未配置 WiFi，请填写下方初始配置并保存重启', 'ok');
                } else {
                    this._status('设备尚无配置文件，已填入初始默认值', 'ok');
                }
                return;
            }

            const text = new TextDecoder().decode(bytes);
            this._parseToForm(text);
            if (autoTriggered) {
                this._status('⚠️ 检测到串口设备尚未配置 WiFi 网络，请完成初始配置并保存重启', 'ok');
            } else {
                this._status('成功读取设备当前配置', 'ok');
            }
        } catch (e) {
            this._status(`读取配置失败: ${e.message || e}`, 'error');
        }
    }

    _parseToForm(iniText) {
        const kv = DeviceSetupWizard.parseIniMap(iniText);

        if (kv['wifi.ssid'] !== undefined) this.el.wifiSsid.value = kv['wifi.ssid'];
        else if (kv['wifi.wifi_ssid'] !== undefined) this.el.wifiSsid.value = kv['wifi.wifi_ssid'];

        if (kv['wifi.password'] !== undefined) this.el.wifiPass.value = kv['wifi.password'];
        else if (kv['wifi.wifi_password'] !== undefined) this.el.wifiPass.value = kv['wifi.wifi_password'];

        if (kv['server.proxy_url'] !== undefined) {
            let pUrl = kv['server.proxy_url'];
            if (this._isSimulator() && (pUrl === 'http://proxy.local:8087' || !DeviceSetupWizard.isLocalProxyUrl(pUrl))) {
                pUrl = window.LOCAL_SERVER_BASE || 'http://127.0.0.1:8087';
            } else if (!this._isSimulator() && DeviceSetupWizard.isPublicWebRepl() && (!pUrl || pUrl === 'http://proxy.local:8087')) {
                pUrl = DeviceSetupWizard.getPublicProxyServer();
            }
            this.el.proxyUrl.value = pUrl;
        } else if (!this._isSimulator() && DeviceSetupWizard.isPublicWebRepl()) {
            this.el.proxyUrl.value = DeviceSetupWizard.getPublicProxyServer();
        }

        if (kv['server.converter_url'] !== undefined) {
            let cUrl = kv['server.converter_url'];
            if (this._isSimulator() && (cUrl === 'http://converter.local:8087' || !DeviceSetupWizard.isLocalProxyUrl(cUrl))) {
                cUrl = window.LOCAL_SERVER_BASE || 'http://127.0.0.1:8087';
            } else if (!this._isSimulator() && DeviceSetupWizard.isPublicWebRepl() && (!cUrl || cUrl === 'http://converter.local:8087')) {
                cUrl = DeviceSetupWizard.getPublicProxyServer();
            }
            this.el.converterUrl.value = cUrl;
        } else if (!this._isSimulator() && DeviceSetupWizard.isPublicWebRepl()) {
            this.el.converterUrl.value = DeviceSetupWizard.getPublicProxyServer();
        }

        const existingHwPass = kv['server.hardware_password'] || '';
        this._applyHwPasswordLockState(existingHwPass);

        if (kv['system.boot_app']) {
            let b = kv['system.boot_app'].replace(/^\/spiffs\//, '');
            for (let opt of this.el.bootApp.options) {
                if (opt.value === b || opt.value.includes(b)) {
                    this.el.bootApp.value = opt.value;
                    break;
                }
            }
        }
    }

    async _saveAndReboot() {
        const isSim = this._isSimulator();
        const ssid = isSim ? '' : this.el.wifiSsid.value.trim();
        const pass = isSim ? '' : this.el.wifiPass.value.trim();
        const proxy = this.el.proxyUrl.value.trim();
        const conv = this.el.converterUrl.value.trim() || proxy;
        const bootApp = this.el.bootApp.value.trim();

        let hwPass = '';
        if (!isSim) {
            hwPass = this.lockedHwPassword || (this.el.hwPass ? this.el.hwPass.value.trim() : '');
            if (!this.lockedHwPassword) {
                if (!hwPass) {
                    const msg = '硬件密码为必填项，请输入不小于 6 位字符的硬件密码';
                    this._status(msg, 'error');
                    this.log('error', `⚙️ ${msg}`);
                    if (this.el.hwPass) this.el.hwPass.focus();
                    return;
                }
                const chk = DeviceSetupWizard.validatePasswordSecurity(hwPass);
                if (!chk.valid) {
                    this._status(chk.message, 'error');
                    this.log('error', `⚙️ 硬件密码校验失败: ${chk.message}`);
                    if (this.el.hwPass) this.el.hwPass.focus();
                    return;
                }
            }
        }

        if (!isSim && pass) {
            const chk = DeviceSetupWizard.validatePasswordSecurity(pass);
            if (!chk.valid) {
                this._status(`WiFi ${chk.message}`, 'error');
                this.log('error', `⚙️ WiFi 密码校验失败: ${chk.message}`);
                if (this.el.wifiPass) this.el.wifiPass.focus();
                return;
            }
        }

        if (isSim) {
            if (!DeviceSetupWizard.isLocalProxyUrl(proxy) || !DeviceSetupWizard.isLocalProxyUrl(conv)) {
                const msg = '本地模拟设备 (WASM) 仅支持非加密协议，只能连接本地代理服务器 (127.0.0.1 / localhost / 局域网 IP)';
                this._status(msg, 'error');
                this.log('error', `⚙️ ${msg}`);
                return;
            }
        }

        this._status('正在写入配置并上传基础应用…');
        try {
            // 1. Ensure default calendar app is present on the board
            if (bootApp.includes('calendar')) {
                try {
                    const check = await this.backend.fsRead(`/spiffs/${bootApp}`);
                    if (!check || !check.length) throw new Error('not found');
                } catch (e) {
                    this._status('正在部署万年历默认应用到设备…');
                    try {
                        const res = await fetch('apps/calendar.msbc');
                        if (res.ok) {
                            const calBytes = new Uint8Array(await res.arrayBuffer());
                            await this.backend.fsWrite(`/spiffs/${bootApp}`, calBytes);
                            this.log('info', `📦 已安装默认应用: ${bootApp}`);
                        }
                    } catch (calErr) {
                        this.log('warn', `无法自动部署 calendar.msbc: ${calErr.message}`);
                    }
                }
            }

            // 2. Generate config.ini
            const configContent = this.buildConfigIni({
                wifiSsid: ssid,
                wifiPassword: pass,
                proxyUrl: proxy,
                converterUrl: conv,
                hwPassword: hwPass,
                bootApp: bootApp,
                isSimulator: isSim,
            });

            const configBytes = new TextEncoder().encode(configContent);
            await this.backend.fsWrite('/spiffs/config.ini', configBytes);
            this.log('info', '⚙️ 已保存新配置到 /spiffs/config.ini');

            if (!isSim && hwPass) {
                this._applyHwPasswordLockState(hwPass);
            }

            // 3. Reboot device
            if (typeof this.backend.reset === 'function') {
                this._status('配置保存成功！设备正在重启…', 'ok');
                this.log('info', '⏻ 正在重启设备以应用新设置…');
                await this.backend.reset();
            } else {
                this._status('配置保存成功！请手动重启设备', 'ok');
            }

            setTimeout(() => this.close(), 2500);
        } catch (e) {
            this._status(`保存失败: ${e.message || e}`, 'error');
            this.log('error', `⚙️ 配置写入错误: ${e.message || e}`);
        }
    }

    static buildConfigIni(opts = {}) {
        const isSim = !!opts.isSimulator;
        const isPublic = DeviceSetupWizard.isPublicWebRepl();
        const defaultHardwareProxy = isPublic ? DeviceSetupWizard.getPublicProxyServer() : 'http://proxy.local:8087';
        const defaultProxy = isSim ? 'http://127.0.0.1:8087' : defaultHardwareProxy;
        const defaultConv = isSim ? 'http://127.0.0.1:8087' : defaultHardwareProxy;
        const {
            wifiSsid = '',
            wifiPassword = '',
            proxyUrl = defaultProxy,
            converterUrl = defaultConv,
            hwPassword = '',
            bootApp = ''
        } = opts;

        if (isSim && (!DeviceSetupWizard.isLocalProxyUrl(proxyUrl) || !DeviceSetupWizard.isLocalProxyUrl(converterUrl))) {
            throw new Error('本地模拟设备 (WASM) 仅支持非加密协议，只能连接本地代理服务器 (127.0.0.1 / localhost / 局域网 IP)');
        }

        return [
            '; MiniScheme Hardware Initial Configuration',
            '[wifi]',
            `ssid = ${isSim ? '' : wifiSsid}`,
            `password = ${isSim ? '' : wifiPassword}`,
            '',
            '[server]',
            `proxy_url = ${proxyUrl}`,
            `converter_url = ${converterUrl}`,
            `hardware_password = ${isSim ? '' : hwPassword}`,
            '',
            '[app]',
            `proxy = ${proxyUrl}`,
            `https_proxy = ${converterUrl}`,
            '',
            '[system]',
            `boot_app = ${bootApp}`,
            'button_long_ms = 800',
            'button_mid_ms = 3500',
            'button_hold_ms = 8000',
            ''
        ].join('\n');
    }

    buildConfigIni(opts = {}) {
        return DeviceSetupWizard.buildConfigIni(opts);
    }
}

window.DeviceSetupWizard = DeviceSetupWizard;
window.MiniSchemeDeviceSetup = new DeviceSetupWizard();


