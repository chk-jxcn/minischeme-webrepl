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

    static isSupportedProxyUrl(url) {
        if (!url || typeof url !== 'string') return false;
        if (DeviceSetupWizard.isLocalProxyUrl(url)) return true;
        if (url.includes('124.222.231.186')) return true;
        return false;
    }

    /**
     * Dedicated public proxy & protocol converter address.
     */
    static getPublicProxyServer() {
        return 'http://124.222.231.186:8087';
    }

    /**
     * Resolves currently configured service URL from settings input fields,
     * localStorage, or window.LOCAL_SERVER_BASE.
     */
    static getConfiguredServiceUrl() {
        const hostEl = typeof document !== 'undefined' ? document.getElementById('server-host-input') : null;
        const portEl = typeof document !== 'undefined' ? document.getElementById('server-port-input') : null;
        let host = hostEl ? hostEl.value.trim() : '';
        let port = portEl ? portEl.value.trim() : '';

        if (!host && typeof localStorage !== 'undefined') {
            try { host = (localStorage.getItem('webrepl_server_host') || '').trim(); } catch (e) {}
        }
        if (!port && typeof localStorage !== 'undefined') {
            try { port = (localStorage.getItem('webrepl_server_port') || '').trim(); } catch (e) {}
        }

        if (!host && typeof window !== 'undefined' && window.LOCAL_SERVER_BASE) {
            return window.LOCAL_SERVER_BASE;
        }
        if (!host && typeof window !== 'undefined' && window.LOCAL_SERVER_INFO && window.LOCAL_SERVER_INFO.baseUrl) {
            return window.LOCAL_SERVER_INFO.baseUrl;
        }

        if (!host && typeof window !== 'undefined' && window.location) {
            host = (window.location.hostname && window.location.hostname !== 'localhost') ? window.location.hostname : '127.0.0.1';
        }
        if (!host) host = '127.0.0.1';
        if (!port) port = '8087';

        host = host.replace(/^https?:\/\//i, '').replace(/\/+$/, '');
        return `http://${host}:${port}`;
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
     * A server address from config.ini: the firmware keeps the device's key
     * for that server in the same value, "<64 hex digits>@http://host:port".
     */
    static splitKeyedUrl(value) {
        const m = String(value || '').trim().match(/^\[?([0-9a-fA-F]{64})\]?@(.*)$/);
        return m ? { key: m[1], url: m[2].trim() } : { key: '', url: String(value || '').trim() };
    }

    static urlOrigin(url) {
        const m = String(url || '').trim().match(/^([a-z][a-z0-9+.-]*:\/\/[^\/?#]*)/i);
        return m ? m[1].toLowerCase() : '';
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
                        <div id="ds-interface-select-row" style="display: grid; grid-template-columns: 120px 1fr; gap: 10px; align-items: center; margin-bottom: 8px;">
                            <label for="ds-interface-select" style="font-size: 13px;">选择代理接口:</label>
                            <div style="display: flex; gap: 8px; align-items: center; width: 100%;">
                                <select id="ds-interface-select" class="compact-select" style="flex: 1; height: 32px; font-family: monospace; font-size: 12px; background: rgba(0,0,0,0.25); border: 1px solid var(--border-color); color: var(--text-primary); border-radius: 4px; padding: 2px 8px;">
                                    <option value="">正在检测本地服务网络接口...</option>
                                </select>
                                <button type="button" class="pill-btn highlight" id="ds-apply-interface-btn" style="white-space: nowrap; font-size: 11.5px; padding: 4px 10px;">填入此接口</button>
                            </div>
                        </div>
                        <div style="display: grid; grid-template-columns: 120px 1fr; gap: 10px; align-items: center; margin-bottom: 8px;">
                            <label for="ds-proxy-url" style="font-size: 13px;">应用代理地址:</label>
                            <input type="text" id="ds-proxy-url" placeholder="http://127.0.0.1:8087" value="http://127.0.0.1:8087" class="device-host-input" style="width: 100%;">
                        </div>
                        <div style="display: grid; grid-template-columns: 120px 1fr; gap: 10px; align-items: center; margin-bottom: 8px;">
                            <label for="ds-converter-url" style="font-size: 13px;">协议转换器:</label>
                            <input type="text" id="ds-converter-url" placeholder="http://127.0.0.1:8087" value="http://127.0.0.1:8087" class="device-host-input" style="width: 100%;">
                        </div>
                        <div style="display: flex; gap: 8px; margin-left: 130px; margin-bottom: 10px; flex-wrap: wrap;">
                            <button type="button" class="pill-btn" id="ds-fill-public-proxy" style="font-size: 11.5px; padding: 3px 8px;">🌐 快捷填入公网服务器 (124.222.231.186:8087)</button>
                            <button type="button" class="pill-btn" id="ds-fill-local-proxy" style="font-size: 11.5px; padding: 3px 8px;">🏠 快捷填入当前服务 IP</button>
                        </div>
                        <div id="ds-hw-password-row" style="display: grid; grid-template-columns: 120px 1fr; gap: 10px; align-items: center; margin-bottom: 6px;">
                            <label for="ds-hw-password" style="font-size: 13px;">硬件安全密码:</label>
                            <input type="text" id="ds-hw-password" placeholder="设置硬件密码 (已设置后将明文显示且不可修改)" class="device-host-input" style="width: 100%;" autocomplete="off" spellcheck="false">
                        </div>
                        <div id="ds-hw-password-hint" style="font-size: 11px; color: #eab308; margin-left: 130px;">
                            ⚠️ 提示：固件连接服务器时用硬件密码在本地算出 hash 密钥并自动注册加密通道（密码不发给服务器）；它同时也是设备网页和 HTTP API 的访问密码；一旦设置将以明文显示且禁止修改。
                        </div>
                        <div id="ds-panel-row" style="display: grid; grid-template-columns: 120px 1fr; gap: 10px; align-items: center; margin-top: 10px;">
                            <label for="ds-panel" style="font-size: 13px;">屏幕类型:</label>
                            <select id="ds-panel" class="compact-select" style="height: 32px; background: rgba(0,0,0,0.25); border: 1px solid var(--border-color); color: var(--text-primary); border-radius: 4px; padding: 2px 8px;">
                                <option value="ips">IPS（默认，驱动中设置反色）</option>
                                <option value="tft">TFT（不反色）</option>
                            </select>
                        </div>
                        <div style="font-size: 11px; color: var(--text-secondary); margin-left: 130px; margin-top: 4px;">颜色像底片一样反了就选另一种；之后也可以在设备网页的"常用设置"里改，立即生效。</div>
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
            wifiSection: q('#ds-wifi-section'),
            wifiEnable: q('#ds-wifi-enable'),
            wifiSsid: q('#ds-wifi-ssid'),
            wifiPass: q('#ds-wifi-password'),
            interfaceSelectRow: q('#ds-interface-select-row'),
            interfaceSelect: q('#ds-interface-select'),
            applyInterfaceBtn: q('#ds-apply-interface-btn'),
            proxyUrl: q('#ds-proxy-url'),
            converterUrl: q('#ds-converter-url'),
            hwPassRow: q('#ds-hw-password-row'),
            hwPass: q('#ds-hw-password'),
            hwPassHint: q('#ds-hw-password-hint'),
            panel: q('#ds-panel'),
            fillPublicBtn: q('#ds-fill-public-proxy'),
            fillLocalBtn: q('#ds-fill-local-proxy'),
        };

        if (this.el.interfaceSelect) {
            this.el.interfaceSelect.addEventListener('change', () => {
                const val = (this.el.interfaceSelect.value || '').trim();
                if (val) {
                    this.el.proxyUrl.value = val;
                    this.el.converterUrl.value = val;
                    this._status(`已选择并填入代理接口: ${val}`, 'ok');
                }
            });
        }

        if (this.el.applyInterfaceBtn) {
            this.el.applyInterfaceBtn.addEventListener('click', () => {
                const val = (this.el.interfaceSelect.value || '').trim();
                if (val) {
                    this.el.proxyUrl.value = val;
                    this.el.converterUrl.value = val;
                    this._status(`已填入选中的代理接口: ${val}`, 'ok');
                } else {
                    this._status('请先从列表中选择一个网络接口', 'error');
                }
            });
        }

        if (this.el.fillPublicBtn) {
            this.el.fillPublicBtn.addEventListener('click', () => {
                const pub = DeviceSetupWizard.getPublicProxyServer();
                this.el.proxyUrl.value = pub;
                this.el.converterUrl.value = pub;
                if (this.el.interfaceSelect) this.el.interfaceSelect.value = pub;
                this._status('已填入公网服务器地址 (124.222.231.186:8087)', 'ok');
            });
        }

        if (this.el.fillLocalBtn) {
            this.el.fillLocalBtn.addEventListener('click', () => {
                const loc = DeviceSetupWizard.getConfiguredServiceUrl();
                this.el.proxyUrl.value = loc;
                this.el.converterUrl.value = loc;
                if (this.el.interfaceSelect) this.el.interfaceSelect.value = loc;
                this._status(`已读取并填入当前设置的服务地址 (${loc})`, 'ok');
            });
        }

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
                this.el.hwPassHint.textContent = '⚠️ 必填项：固件用硬件密码自动注册加密通道（密码不发给服务器），它同时也是设备网页和 HTTP API 的访问密码（长度不小于 6 位字符）；一旦设置将以明文显示且禁止修改。';
            }
        }
    }

    _updateModeUi() {
        const isSim = this._isSimulator();
        if (this.el.wifiSection) this.el.wifiSection.hidden = isSim;
        if (this.el.hwPassRow) this.el.hwPassRow.style.display = isSim ? 'none' : 'grid';
        if (this.el.hwPassHint) this.el.hwPassHint.hidden = isSim;
        if (this.el.title) {
            this.el.title.textContent = isSim ? '⚙️ 本地模拟设备初始化配置' : '⚙️ ESP32 设备初始化配置';
        }
        const defaultLocalProxy = DeviceSetupWizard.getConfiguredServiceUrl();
        if (this.el.fillLocalBtn) {
            this.el.fillLocalBtn.textContent = `🏠 快捷填入当前服务 IP (${defaultLocalProxy.replace(/^https?:\/\//i, '')})`;
        }
        if (isSim) {
            this.el.proxyUrl.placeholder = `${defaultLocalProxy} (本地/局域网代理或公网代理，模拟设备不加密)`;
            this.el.converterUrl.placeholder = `${defaultLocalProxy} (本地/局域网代理或公网代理，模拟设备不加密)`;
            this._applyHwPasswordLockState('');
        } else {
            if (DeviceSetupWizard.isPublicWebRepl()) {
                const pubProxy = DeviceSetupWizard.getPublicProxyServer();
                this.el.proxyUrl.placeholder = `${pubProxy} (公网加密代理)`;
                this.el.converterUrl.placeholder = `${pubProxy} (公网加密代理)`;
            } else {
                this.el.proxyUrl.placeholder = defaultLocalProxy;
                this.el.converterUrl.placeholder = defaultLocalProxy;
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

    /**
     * Dynamically populate the interface selection dropdown (#ds-interface-select)
     * using network interfaces detected by the local/public server (/api/server_info).
     * Categorizes interfaces into physical LAN (ESP32 accessible), virtual/VPN,
     * public proxy server, and loopback.
     */
    async populateInterfaceList() {
        if (!this.el || !this.el.interfaceSelect) return;
        const select = this.el.interfaceSelect;
        const currentProxy = (this.el.proxyUrl ? this.el.proxyUrl.value : '').trim();

        let info = (window.LocalServerManager && window.LocalServerManager.info) ? window.LocalServerManager.info : null;
        // only a page served by the local server has /api/server_info at its own origin
        // (GitHub Pages answers 404, which the browser logs as an error)
        if (!info && !DeviceSetupWizard.isPublicWebRepl()) {
            try {
                const res = await fetch('/api/server_info', { cache: 'no-store' });
                if (res.ok) {
                    info = await res.json();
                    if (window.LocalServerManager) window.LocalServerManager.info = info;
                }
            } catch (e) {
                /* ignore fetch error if server is offline */
            }
        }

        const activePort = (info && info.port) || (window.location.port || '8087');
        const rawIps = (info && Array.isArray(info.ips)) ? info.ips.slice() : [];
        if (info && info.ip && !rawIps.includes(info.ip)) {
            rawIps.unshift(info.ip);
        }

        const isPublicWebRepl = DeviceSetupWizard.isPublicWebRepl() || (info && Boolean(info.is_public));

        // Filter and collect candidate interface URLs
        const candidates = [];
        const seenUrls = new Set();

        const addCandidate = (url, label, isPhysical = false, isPublic = false, isLoopback = false) => {
            if (!url || seenUrls.has(url)) return;
            seenUrls.add(url);
            candidates.push({ url, label, isPhysical, isPublic, isLoopback });
        };

        // 1. Process IPs from server_info
        for (const ip of rawIps) {
            if (!ip) continue;
            // Filter cloud VPC private IP (e.g. 10.0.0.4) on public server
            if (isPublicWebRepl && ip.startsWith('10.')) continue;

            const url = `http://${ip}:${activePort}`;
            if (ip === '127.0.0.1' || ip === 'localhost') {
                addCandidate(url, `${url} (本机回环 / 仅限 WASM 模拟器)`, false, false, true);
            } else if (ip === '124.222.231.186') {
                addCandidate(url, `${url} (公网测试服务器 / 推荐外网环境)`, false, true, false);
            } else if (ip.startsWith('192.168.')) {
                const parts = ip.split('.');
                const third = parseInt(parts[2], 10);
                // Common router physical LAN subnets (0..32, 50, 68, 88, 100, 123) vs virtual/VPN subnets (195, 137, 200+)
                const isPhysical = (third <= 32 || third === 50 || third === 68 || third === 88 || third === 100 || third === 123);
                if (isPhysical) {
                    addCandidate(url, `${url} (物理局域网 / 推荐: ESP32可访问)`, true, false, false);
                } else {
                    addCandidate(url, `${url} (虚拟网卡/VPN: ESP32通常无法直连)`, false, false, false);
                }
            } else if (ip.startsWith('172.')) {
                // 172.16..31 usually Docker/WSL2/Hyper-V virtual switch
                addCandidate(url, `${url} (虚拟网卡/WSL: ESP32通常无法直连)`, false, false, false);
            } else if (ip.startsWith('10.')) {
                addCandidate(url, `${url} (私有网络/内网地址)`, false, false, false);
            } else {
                addCandidate(url, `${url} (公网服务地址)`, false, true, false);
            }
        }

        // 2. Always ensure public proxy is available in list
        const pubUrl = DeviceSetupWizard.getPublicProxyServer();
        if (!seenUrls.has(pubUrl)) {
            addCandidate(pubUrl, `${pubUrl} (公网测试服务器 / 推荐外网环境)`, false, true, false);
        }

        // 3. Ensure 127.0.0.1 is available in list
        const loopbackUrl = `http://127.0.0.1:${activePort}`;
        if (!seenUrls.has(loopbackUrl)) {
            addCandidate(loopbackUrl, `${loopbackUrl} (本机回环 / 仅限 WASM 模拟器)`, false, false, true);
        }

        // Build option elements
        select.innerHTML = '';
        const defaultPromptOpt = document.createElement('option');
        defaultPromptOpt.value = '';
        defaultPromptOpt.textContent = '-- 请选择代理服务器接口 --';
        select.appendChild(defaultPromptOpt);

        let matchFound = false;
        let recommendedUrl = '';

        for (const item of candidates) {
            const opt = document.createElement('option');
            opt.value = item.url;
            opt.textContent = item.label;
            if (item.isPhysical && !recommendedUrl && !isPublicWebRepl) {
                recommendedUrl = item.url;
            } else if (item.isPublic && !recommendedUrl && isPublicWebRepl) {
                recommendedUrl = item.url;
            }
            if (currentProxy && (item.url === currentProxy || item.url.replace(/\/+$/, '') === currentProxy.replace(/\/+$/, ''))) {
                opt.selected = true;
                matchFound = true;
            }
            select.appendChild(opt);
        }

        // If existing proxy URL isn't in list but is non-empty, add custom option
        if (currentProxy && !matchFound) {
            const customOpt = document.createElement('option');
            customOpt.value = currentProxy;
            customOpt.textContent = `${currentProxy} (当前已配置自定义地址)`;
            customOpt.selected = true;
            select.insertBefore(customOpt, select.firstChild.nextSibling);
        } else if (!matchFound && recommendedUrl && (!currentProxy || currentProxy.includes('10.0.0.'))) {
            select.value = recommendedUrl;
        }
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
        await this.populateInterfaceList();
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
        const configuredSrv = DeviceSetupWizard.getConfiguredServiceUrl();
        let defaultProxy;
        if (this._isSimulator()) {
            defaultProxy = configuredSrv;
        } else if (DeviceSetupWizard.isPublicWebRepl()) {
            defaultProxy = DeviceSetupWizard.getPublicProxyServer();
        } else {
            defaultProxy = configuredSrv;
        }
        if (this.el.wifiEnable) {
            this.el.wifiEnable.checked = true;
        }
        if (this.el.panel) this.el.panel.value = 'ips';
        this.el.wifiSsid.value = '';
        this.el.wifiPass.value = '';
        this.el.proxyUrl.value = defaultProxy;
        this.el.converterUrl.value = defaultProxy;
        if (!this._isSimulator() && !this.lockedHwPassword) {
            this.el.hwPass.value = '';
        }
        this.populateInterfaceList();
        this._status('已填入推荐默认设置', 'ok');
    }

    async _readFromDevice(autoTriggered = false) {
        this._status('正在读取设备 /spiffs/config.ini…');
        this._applyHwPasswordLockState('');
        this.existingIniText = '';
        this.existingBootApp = '';
        // true until the device's config.ini was read: a board always has one,
        // so saving without it would replace every setting with defaults
        this.readFailed = !this._isSimulator();
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
                this.existingIniText = '';
                if (!this._isSimulator()) {
                    this._status('读取设备 config.ini 失败（无响应或超时）。为避免覆盖设备现有配置，请点击“读取设备配置”重试后再保存。', 'error');
                    return;
                }
                this.readFailed = false;
                this._setDefault();
                if (autoTriggered) {
                    this._status('⚠️ 检测到串口设备尚未配置 WiFi，请填写下方初始配置并保存重启', 'ok');
                } else {
                    this._status('设备尚无配置文件，已填入初始默认值', 'ok');
                }
                return;
            }

            const text = new TextDecoder().decode(bytes);
            this.existingIniText = text;
            this.readFailed = false;
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
            let pUrl = DeviceSetupWizard.splitKeyedUrl(kv['server.proxy_url']).url;
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
            let cUrl = DeviceSetupWizard.splitKeyedUrl(kv['server.converter_url']).url;
            if (this._isSimulator() && (cUrl === 'http://converter.local:8087' || !DeviceSetupWizard.isLocalProxyUrl(cUrl))) {
                cUrl = window.LOCAL_SERVER_BASE || 'http://127.0.0.1:8087';
            } else if (!this._isSimulator() && DeviceSetupWizard.isPublicWebRepl() && (!cUrl || cUrl === 'http://converter.local:8087')) {
                cUrl = DeviceSetupWizard.getPublicProxyServer();
            }
            this.el.converterUrl.value = cUrl;
        } else if (!this._isSimulator() && DeviceSetupWizard.isPublicWebRepl()) {
            this.el.converterUrl.value = DeviceSetupWizard.getPublicProxyServer();
        }

        const existingHwPass = kv['server.hardware_password'] || kv['http.http_password'] || '';
        this._applyHwPasswordLockState(existingHwPass);

        if (this.el.panel) this.el.panel.value = /^tft$/i.test(kv['display.panel'] || '') ? 'tft' : 'ips';

        if (kv['system.boot_app']) {
            this.existingBootApp = kv['system.boot_app'];
        }
        this.populateInterfaceList();
    }

    async _saveAndReboot() {
        const isSim = this._isSimulator();
        const ssid = isSim ? '' : this.el.wifiSsid.value.trim();
        const pass = isSim ? '' : this.el.wifiPass.value.trim();
        const proxy = this.el.proxyUrl.value.trim();
        const conv = this.el.converterUrl.value.trim() || proxy;

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

        // the router's WiFi password is the router's: no weak-password rule here
        if (!isSim && this.readFailed) {
            const msg = '尚未成功读取设备当前的 config.ini，为避免覆盖设备上的配置，已取消保存。请先点击“读取设备配置”。';
            this._status(msg, 'error');
            this.log('error', `⚙️ ${msg}`);
            return;
        }

        if (isSim) {
            if (!DeviceSetupWizard.isSupportedProxyUrl(proxy) || !DeviceSetupWizard.isSupportedProxyUrl(conv)) {
                const msg = '本地模拟设备 (WASM) 仅支持非加密协议，请连接本地代理服务器 (127.0.0.1 / 局域网 IP) 或已部署的公网服务器 (124.222.231.186:8087)';
                this._status(msg, 'error');
                this.log('error', `⚙️ ${msg}`);
                return;
            }
        }

        this._status('正在写入配置到设备…');
        try {
            // Only the server addresses and the hardware password: the firmware
            // registers with each server by itself (its MAC as the id, a hash
            // of the password; the password is never sent) and keeps the key
            // it gets next to the address
            const configContent = this.buildConfigIni({
                wifiSsid: ssid,
                wifiPassword: pass,
                proxyUrl: proxy,
                converterUrl: conv,
                hwPassword: hwPass,
                panel: this.el.panel ? this.el.panel.value : 'ips',
                bootApp: this.existingBootApp || 'settings',
                isSimulator: isSim,
                existingIni: this.existingIniText || '',
            });

            const configBytes = new TextEncoder().encode(configContent);
            await this.backend.fsWrite('/spiffs/config.ini', configBytes);
            this.log('info', '⚙️ 已保存新配置到 /spiffs/config.ini');

            if (!isSim && hwPass) {
                this._applyHwPasswordLockState(hwPass);
                // the board asks for this password ([http] http_password) after the restart
                try { localStorage.setItem('minischeme_http_password', hwPass); } catch (_) {}
                if (this.backend) this.backend.password = hwPass;
            }

            // Reboot device
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
            panel = 'ips',
            bootApp = 'settings',
            existingIni = ''
        } = opts;

        if (isSim && (!DeviceSetupWizard.isSupportedProxyUrl(proxyUrl) || !DeviceSetupWizard.isSupportedProxyUrl(converterUrl))) {
            throw new Error('本地模拟设备 (WASM) 仅支持非加密协议，请连接本地代理服务器 (127.0.0.1 / 局域网 IP) 或已部署的公网服务器 (124.222.231.186:8087)');
        }

        const effectiveSsid = isSim ? '' : wifiSsid;
        const effectivePass = isSim ? '' : wifiPassword;
        const effectiveHwPass = isSim ? '' : hwPassword;
        const panelType = panel === 'tft' ? 'tft' : 'ips';   // [display] panel: IPS needs the driver's inversion

        // If existing INI text is provided and non-empty, merge into it
        if (existingIni && existingIni.trim().length > 0) {
            let lines = existingIni.split(/\r?\n/);
            // Ensure config_version = 3 is at the top
            let hasVersion = false;
            for (let i = 0; i < lines.length; i++) {
                if (/^\s*config_version\s*=/i.test(lines[i])) {
                    lines[i] = 'config_version = 3';
                    hasVersion = true;
                    break;
                }
            }
            if (!hasVersion) {
                lines.unshift('config_version = 3');
            }

            function setSectionKey(sectionName, key, value) {
                let secHeaderIdx = -1;
                let nextSecIdx = -1;
                const secRegex = new RegExp(`^\\s*\\[${sectionName}\\]`, 'i');
                for (let i = 0; i < lines.length; i++) {
                    if (secRegex.test(lines[i])) {
                        secHeaderIdx = i;
                        break;
                    }
                }
                if (secHeaderIdx === -1) {
                    lines.push('', `[${sectionName}]`, `${key} = ${value}`);
                    return;
                }
                for (let i = secHeaderIdx + 1; i < lines.length; i++) {
                    if (/^\s*\[.+\]/.test(lines[i])) {
                        nextSecIdx = i;
                        break;
                    }
                }
                const endIdx = nextSecIdx !== -1 ? nextSecIdx : lines.length;
                const keyRegex = new RegExp(`^\\s*${key}\\s*=`, 'i');
                for (let i = secHeaderIdx + 1; i < endIdx; i++) {
                    if (keyRegex.test(lines[i])) {
                        lines[i] = `${key} = ${value}`;
                        return;
                    }
                }
                lines.splice(endIdx, 0, `${key} = ${value}`);
            }

            setSectionKey('wifi', 'wifi_ssid', effectiveSsid);
            setSectionKey('wifi', 'wifi_password', effectivePass);
            setSectionKey('wifi', 'ssid', effectiveSsid);
            setSectionKey('wifi', 'password', effectivePass);

            if (effectiveHwPass) {
                setSectionKey('http', 'http_password', effectiveHwPass);
            }
            // an address that names the same server keeps the device's key for it
            const oldKv = DeviceSetupWizard.parseIniMap(existingIni);
            const keepKey = (sectionKey, url) => {
                const old = DeviceSetupWizard.splitKeyedUrl(oldKv[sectionKey]);
                return old.key && url && DeviceSetupWizard.urlOrigin(old.url) === DeviceSetupWizard.urlOrigin(url)
                    ? `${old.key}@${url}` : url;
            };
            setSectionKey('server', 'proxy_url', keepKey('server.proxy_url', proxyUrl));
            setSectionKey('server', 'converter_url', keepKey('server.converter_url', converterUrl));
            if (effectiveHwPass) {
                setSectionKey('server', 'hardware_password', effectiveHwPass);
            }

            setSectionKey('app', 'proxy', keepKey('app.proxy', proxyUrl));
            setSectionKey('app', 'https_proxy', keepKey('app.https_proxy', converterUrl));
            setSectionKey('display', 'panel', panelType);

            setSectionKey('system', 'boot_app', bootApp || 'settings');

            return lines.join('\n');
        }

        return [
            '; Device configuration (read at boot)',
            '; \';\' or \'#\' starts a comment; unknown keys are ignored.',
            'config_version = 3',
            '',
            '[system]',
            `boot_app = ${bootApp || 'settings'}`,
            'device_name = 桌面屏',
            'app_storage_kb = 256',
            'button_long_ms = 800',
            'button_mid_ms = 3500',
            'button_hold_ms = 8000',
            'web_in_app = 1',
            'factory_reset_key = 1',
            '',
            '[wifi]',
            `wifi_ssid = ${effectiveSsid}`,
            `wifi_password = ${effectivePass}`,
            `ssid = ${effectiveSsid}`,
            `password = ${effectivePass}`,
            '',
            '[http]',
            `http_password = ${effectiveHwPass}`,
            '',
            '[server]',
            `proxy_url = ${proxyUrl}`,
            `converter_url = ${converterUrl}`,
            `hardware_password = ${effectiveHwPass}`,
            '',
            '[app]',
            `proxy = ${proxyUrl}`,
            `https_proxy = ${converterUrl}`,
            'carousel = 1',
            'carousel_seconds = 10',
            '',
            '[display]',
            'mode = band',
            'band_lines = 13',
            'color_bits = 16',
            'palette = color',
            `panel = ${panelType}`,
            'auto_backlight = 1',
            'backlight = 220',
            'color_format = rgb565',
            'width = 320',
            'height = 480',
            'lcd_dma = 1',
            'lcd_dma_lines = 0',
            'lcd_clock_hz = 20000000',
            '',
            '[memory]',
            'reserved_heap = 65536',
            'max_heap = 131072',
            'vm_eden = 4096',
            'vm_stack = 1024',
            'vm_frames = 256',
            'app_xip = 1',
            'http_stack = 6144',
            '',
            '[text]',
            'marquee = pixel',
            'marquee_fps = 20',
            'marquee_step = 1',
            'marquee_hold = 1',
            'wrap_marquee = line',
            'wrap_marquee_fps = 0.5',
            'wrap_marquee_step = 1',
            'wrap_marquee_hold = 1',
            '',
            '[fonts]',
            'font_order = app, fontrom, spiffs',
            'font_override = ',
            ''
        ].join('\n');
    }

    buildConfigIni(opts = {}) {
        return DeviceSetupWizard.buildConfigIni(opts);
    }
}

window.DeviceSetupWizard = DeviceSetupWizard;
window.MiniSchemeDeviceSetup = new DeviceSetupWizard();


