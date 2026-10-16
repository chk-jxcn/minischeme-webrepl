/**
 * @file device_setup.js
 * @brief Initial Device Setup Wizard for MiniScheme WebREPL.
 *
 * Allows users connecting over Web Serial or HTTP to view/edit the initial
 * hardware configuration (/spiffs/config.ini): WiFi credentials, proxy URL,
 * hardware security password, and the default boot application (万年历/Calendar).
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
        this._build();
    }

    _build() {
        const root = document.createElement('div');
        root.className = 'fm-overlay ds-overlay';
        root.hidden = true;
        root.innerHTML = `
            <div class="fm-dialog ds-dialog" role="dialog" aria-modal="true" aria-labelledby="ds-title" style="max-width: 680px;">
                <div class="fm-head">
                    <span class="fm-title" id="ds-title">⚙️ ESP32 初始设备配置向导</span>
                    <span class="fm-target ds-target"></span>
                    <button class="fm-close" data-act="close" title="关闭 (Esc)">&times;</button>
                </div>
                <div class="am-body ds-body" style="padding: 16px 24px; max-height: 70vh; overflow-y: auto;">
                    <div style="margin-bottom: 14px; font-size: 13px; color: var(--text-secondary); line-height: 1.5;">
                        在初次开机或恢复出厂后，在此设置网络与服务器凭据。点击<b>“保存并重启”</b>将配置写入硬件并自动启动默认应用。
                    </div>

                    <!-- WiFi Section -->
                    <div class="ds-section" style="margin-bottom: 16px; border: 1px solid var(--border-color); border-radius: 8px; padding: 14px 18px; background: rgba(255,255,255,0.02);">
                        <h4 style="margin-bottom: 12px; font-size: 14px; color: var(--accent-cyan);">📶 1. WiFi 无线网络设置 [wifi]</h4>
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
                            <input type="text" id="ds-proxy-url" placeholder="http://192.168.1.100:8087" value="http://192.168.1.100:8087" class="device-host-input" style="width: 100%;">
                        </div>
                        <div style="display: grid; grid-template-columns: 120px 1fr; gap: 10px; align-items: center; margin-bottom: 8px;">
                            <label for="ds-converter-url" style="font-size: 13px;">协议转换器:</label>
                            <input type="text" id="ds-converter-url" placeholder="http://192.168.1.100:8087" value="http://192.168.1.100:8087" class="device-host-input" style="width: 100%;">
                        </div>
                        <div style="display: grid; grid-template-columns: 120px 1fr; gap: 10px; align-items: center; margin-bottom: 6px;">
                            <label for="ds-hw-password" style="font-size: 13px;">硬件安全密码:</label>
                            <input type="password" id="ds-hw-password" placeholder="设置硬件密码 (丢失将无法出厂恢复)" class="device-host-input" style="width: 100%;">
                        </div>
                        <div style="font-size: 11px; color: #eab308; margin-left: 130px;">
                            ⚠️ 提示：硬件密码用于 HKDF 派生端到端加密密钥与出厂重置身份验证，请妥善保存。
                        </div>
                    </div>

                    <!-- System Boot App Section -->
                    <div class="ds-section" style="margin-bottom: 16px; border: 1px solid var(--border-color); border-radius: 8px; padding: 14px 18px; background: rgba(255,255,255,0.02);">
                        <h4 style="margin-bottom: 12px; font-size: 14px; color: var(--accent-green);">🚀 3. 开机默认启动应用 [system]</h4>
                        <div style="display: grid; grid-template-columns: 120px 1fr; gap: 10px; align-items: center;">
                            <label for="ds-boot-app" style="font-size: 13px;">启动应用:</label>
                            <select id="ds-boot-app" class="mode-dropdown" style="width: 100%; padding: 6px 10px;">
                                <option value="apps/calendar/app.msbc" selected>万年历 (Calendar - 默认自带)</option>
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
                                <option value="apps/settings/app.msbc">系统设置 (Settings)</option>
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
            target: q('.ds-target'),
            status: q('.ds-status'),
            wifiSsid: q('#ds-wifi-ssid'),
            wifiPass: q('#ds-wifi-password'),
            proxyUrl: q('#ds-proxy-url'),
            converterUrl: q('#ds-converter-url'),
            hwPass: q('#ds-hw-password'),
            bootApp: q('#ds-boot-app'),
        };

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

    async open() {
        try {
            this.backend = this.getBackend();
        } catch (e) {
            this.log('error', `⚙️ 设备配置: ${e.message || e}`);
            return;
        }
        this.el.target.textContent = this.backend.label || '';
        this.el.root.hidden = false;
        await this._readFromDevice();
    }

    close() {
        this.el.root.hidden = true;
    }

    async _action(act) {
        if (act === 'close') this.close();
        else if (act === 'read') await this._readFromDevice();
        else if (act === 'default') this._setDefault();
        else if (act === 'save') await this._saveAndReboot();
    }

    _setDefault() {
        this.el.wifiSsid.value = '';
        this.el.wifiPass.value = '';
        this.el.proxyUrl.value = 'http://192.168.1.100:8087';
        this.el.converterUrl.value = 'http://192.168.1.100:8087';
        this.el.hwPass.value = '';
        this.el.bootApp.value = 'apps/calendar/app.msbc';
        this._status('已填入推荐默认设置', 'ok');
    }

    async _readFromDevice() {
        this._status('正在读取设备 /spiffs/config.ini…');
        try {
            let bytes = null;
            try {
                bytes = await this.backend.fsRead('/spiffs/config.ini');
            } catch (e) {
                try { bytes = await this.backend.fsRead('config.ini'); } catch (err) {}
            }

            if (!bytes || !bytes.length) {
                this._status('设备尚无配置文件，已填入初始默认值', 'ok');
                return;
            }

            const text = new TextDecoder().decode(bytes);
            this._parseToForm(text);
            this._status('成功读取设备当前配置', 'ok');
        } catch (e) {
            this._status(`读取配置失败: ${e.message || e}`, 'error');
        }
    }

    _parseToForm(iniText) {
        const lines = iniText.split('\n');
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

        if (kv['wifi.ssid'] !== undefined) this.el.wifiSsid.value = kv['wifi.ssid'];
        else if (kv['wifi.wifi_ssid'] !== undefined) this.el.wifiSsid.value = kv['wifi.wifi_ssid'];

        if (kv['wifi.password'] !== undefined) this.el.wifiPass.value = kv['wifi.password'];
        else if (kv['wifi.wifi_password'] !== undefined) this.el.wifiPass.value = kv['wifi.wifi_password'];

        if (kv['server.proxy_url'] !== undefined) this.el.proxyUrl.value = kv['server.proxy_url'];
        if (kv['server.converter_url'] !== undefined) this.el.converterUrl.value = kv['server.converter_url'];
        if (kv['server.hardware_password'] !== undefined) this.el.hwPass.value = kv['server.hardware_password'];

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
        const ssid = this.el.wifiSsid.value.trim();
        const pass = this.el.wifiPass.value.trim();
        const proxy = this.el.proxyUrl.value.trim();
        const conv = this.el.converterUrl.value.trim() || proxy;
        const hwPass = this.el.hwPass.value.trim();
        const bootApp = this.el.bootApp.value.trim();

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
                bootApp: bootApp
            });

            const configBytes = new TextEncoder().encode(configContent);
            await this.backend.fsWrite('/spiffs/config.ini', configBytes);
            this.log('info', '⚙️ 已保存新配置到 /spiffs/config.ini');

            // 3. Reboot device
            if (typeof this.backend.reset === 'function') {
                this._status('配置保存成功！设备正在重启并连网…', 'ok');
                this.log('info', '⏻ 正在重启 ESP32 设备以应用新设置…');
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
        const {
            wifiSsid = '',
            wifiPassword = '',
            proxyUrl = 'http://proxy.local:8087',
            converterUrl = 'http://converter.local:8087',
            hwPassword = '',
            bootApp = 'apps/calendar/app.msbc'
        } = opts;

        return [
            '; MiniScheme Hardware Initial Configuration',
            '[wifi]',
            `ssid = ${wifiSsid}`,
            `password = ${wifiPassword}`,
            '',
            '[server]',
            `proxy_url = ${proxyUrl}`,
            `converter_url = ${converterUrl}`,
            `hardware_password = ${hwPassword}`,
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

