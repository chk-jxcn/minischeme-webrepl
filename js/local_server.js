/**
 * @file local_server.js
 * @brief Local Server (MiniScheme-WebREPL.exe / server.py) detector,
 *        dynamic latest GitHub Release resolver, and status panel for WebREPL.
 */

const GITHUB_REPO_LATEST_API = 'https://api.github.com/repos/chk-jxcn/minischeme-webrepl/releases/latest';
const GITHUB_EXE_RELEASE_URL = 'https://github.com/chk-jxcn/minischeme-webrepl/releases/latest/download/MiniScheme-WebREPL.exe';
const GITHUB_INSTALL_PS1_CMD = 'irm https://raw.githubusercontent.com/chk-jxcn/minischeme-webrepl/main/install.ps1 | iex';
const GITHUB_INSTALL_SH_CMD = 'curl -fsSL https://raw.githubusercontent.com/chk-jxcn/minischeme-webrepl/main/install.sh | bash';

window.LOCAL_SERVER_BASE = '';
window.LOCAL_SERVER_INFO = null;

class LocalServerManager {
    constructor() {
        this.info = null;
        this.dialog = null;
        this.probing = false;
        this.latestRelease = {
            tag: 'latest',
            exeUrl: GITHUB_EXE_RELEASE_URL,
            htmlUrl: 'https://github.com/chk-jxcn/minischeme-webrepl/releases/latest',
            size: null
        };
    }

    init() {
        this.dialog = document.getElementById('local-server-dialog');
        const btnOpen = document.getElementById('btn-local-server');
        if (btnOpen) {
            btnOpen.addEventListener('click', () => this.open());
        }

        const btnClose = document.getElementById('local-server-close-btn');
        if (btnClose) {
            btnClose.addEventListener('click', () => this.close());
        }

        const btnProbe = document.getElementById('local-server-probe-btn');
        if (btnProbe) {
            btnProbe.addEventListener('click', () => this.probeLocalServer(true));
        }

        const btnTest = document.getElementById('server-cfg-test-btn');
        if (btnTest) {
            btnTest.addEventListener('click', () => this.testConnection());
        }

        const btnSave = document.getElementById('server-cfg-save-btn');
        if (btnSave) {
            btnSave.addEventListener('click', () => this.saveConfig());
        }

        const btnReset = document.getElementById('server-cfg-reset-btn');
        if (btnReset) {
            btnReset.addEventListener('click', () => this.resetConfig());
        }

        const hostInput = document.getElementById('server-host-input');
        const portInput = document.getElementById('server-port-input');
        const savedHost = localStorage.getItem('webrepl_server_host');
        const savedPort = localStorage.getItem('webrepl_server_port');
        if (hostInput) {
            hostInput.value = savedHost || (window.location.hostname || '127.0.0.1');
        }
        if (portInput) {
            portInput.value = savedPort || (window.location.port || '8087');
        }

        const btnOpenLocalUrl = document.getElementById('local-server-jump-btn');
        if (btnOpenLocalUrl) {
            btnOpenLocalUrl.addEventListener('click', () => {
                const targetUrl = (this.info && this.info.local_url) || (window.LOCAL_SERVER_BASE || 'http://127.0.0.1:8087');
                window.location.href = targetUrl;
            });
        }

        const btnCopyPs1 = document.getElementById('local-server-copy-ps1-btn');
        if (btnCopyPs1) {
            btnCopyPs1.addEventListener('click', () => {
                navigator.clipboard.writeText(GITHUB_INSTALL_PS1_CMD).catch(() => {});
                btnCopyPs1.textContent = '✔ 已复制 PowerShell 命令';
                setTimeout(() => { btnCopyPs1.textContent = '📋 复制 PowerShell 命令'; }, 2000);
            });
        }

        const btnCopySh = document.getElementById('local-server-copy-sh-btn');
        if (btnCopySh) {
            btnCopySh.addEventListener('click', () => {
                navigator.clipboard.writeText(GITHUB_INSTALL_SH_CMD).catch(() => {});
                btnCopySh.textContent = '✔ 已复制 Bash 命令';
                setTimeout(() => { btnCopySh.textContent = '📋 复制 Bash 命令'; }, 2000);
            });
        }

        if (this.dialog) {
            this.dialog.addEventListener('click', (e) => {
                if (e.target === this.dialog) this.close();
            });
        }

        // Initialize WASM Simulator UUID Card
        this.initSimulatorUUID();

        // Probe local server and resolve latest GitHub Release on load
        this.probeLocalServer(false);
        this.resolveLatestRelease();
    }

    initSimulatorUUID() {
        let simUuid = localStorage.getItem('minischeme_sim_uuid');
        if (!simUuid || !simUuid.startsWith('SIM-')) {
            const hex = () => Math.random().toString(16).substring(2, 6).toUpperCase();
            simUuid = `SIM-${hex()}-${hex()}-${hex()}`;
            localStorage.setItem('minischeme_sim_uuid', simUuid);
        }

        const inputDisplay = document.getElementById('sim-uuid-display');
        if (inputDisplay) {
            inputDisplay.value = simUuid;
        }

        const btnCopy = document.getElementById('sim-uuid-copy-btn');
        if (btnCopy) {
            btnCopy.addEventListener('click', () => {
                const val = inputDisplay ? inputDisplay.value : simUuid;
                navigator.clipboard.writeText(val).catch(() => {});
                btnCopy.textContent = '✔ 已复制 UUID';
                setTimeout(() => { btnCopy.textContent = '📋 复制 UUID'; }, 2000);
            });
        }

        const btnRegen = document.getElementById('sim-uuid-regen-btn');
        if (btnRegen) {
            btnRegen.addEventListener('click', () => {
                if (!confirm('确定重新生成模拟器 UUID 吗？这将在代理端作为一个全新的模拟器实例。')) return;
                const hex = () => Math.random().toString(16).substring(2, 6).toUpperCase();
                const newUuid = `SIM-${hex()}-${hex()}-${hex()}`;
                localStorage.setItem('minischeme_sim_uuid', newUuid);
                if (inputDisplay) inputDisplay.value = newUuid;
                this.registerSimulator(newUuid);
            });
        }

        const btnJump = document.getElementById('sim-portal-jump-btn');
        if (btnJump) {
            btnJump.addEventListener('click', () => {
                const targetBase = window.LOCAL_SERVER_BASE || 'http://127.0.0.1:8087';
                const curUuid = (inputDisplay && inputDisplay.value) || simUuid;
                window.open(`${targetBase}/user?uuid=${encodeURIComponent(curUuid)}`, '_blank');
            });
        }

        this.registerSimulator(simUuid);
    }

    async registerSimulator(uuid) {
        if (!uuid) return;
        const targetBase = window.LOCAL_SERVER_BASE || (window.location.origin && window.location.origin.startsWith('http') ? window.location.origin : 'http://127.0.0.1:8087');
        try {
            await fetch(`${targetBase}/api/user/sim_register`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ uuid: uuid })
            });
        } catch (e) {
            // Server offline or not reachable yet
        }
    }

    async resolveLatestRelease() {
        try {
            const res = await fetch(GITHUB_REPO_LATEST_API, {
                headers: { 'Accept': 'application/vnd.github+json' },
                cache: 'no-store'
            });
            if (res.ok) {
                const data = await res.json();
                const tag = data.tag_name || 'latest';
                const assets = Array.isArray(data.assets) ? data.assets : [];
                const exeAsset = assets.find((a) => a.name && a.name.toLowerCase().endsWith('.exe'));
                this.latestRelease = {
                    tag,
                    exeUrl: (exeAsset && exeAsset.browser_download_url) || GITHUB_EXE_RELEASE_URL,
                    htmlUrl: data.html_url || 'https://github.com/chk-jxcn/minischeme-webrepl/releases/latest',
                    size: exeAsset ? exeAsset.size : null
                };
            }
        } catch (e) {
            // Keep /releases/latest/download/MiniScheme-WebREPL.exe redirect URL
        }
        this._updateReleaseUI();
        return this.latestRelease;
    }

    _updateReleaseUI() {
        const dlBtn = document.getElementById('local-server-download-exe');
        if (dlBtn && this.latestRelease) {
            dlBtn.href = this.latestRelease.exeUrl;
            const sizeMb = this.latestRelease.size ? ` (${(this.latestRelease.size / 1048576).toFixed(1)} MB)` : '';
            const tagLabel = this.latestRelease.tag !== 'latest' ? ` [${this.latestRelease.tag}]` : ' [Latest]';
            dlBtn.textContent = `⬇️ 从 GitHub 一键下载 MiniScheme-WebREPL.exe${tagLabel}${sizeMb}`;
        }
    }

    open() {
        if (!this.dialog) return;
        this.dialog.hidden = false;
        if (typeof this.dialog.showModal === 'function') {
            try { this.dialog.showModal(); } catch (e) {}
        }
        this.probeLocalServer(true);
        this.resolveLatestRelease();
    }

    close() {
        if (!this.dialog) return;
        this.dialog.hidden = true;
        if (typeof this.dialog.close === 'function') {
            try { this.dialog.close(); } catch (e) {}
        }
    }

    async _tryEndpoint(baseUrl) {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 1200);
        try {
            const res = await fetch(`${baseUrl}/api/server_info`, {
                cache: 'no-store',
                signal: controller.signal
            });
            if (!res.ok) return null;
            const data = await res.json();
            if (data && data.success && data.port) {
                return { ...data, baseUrl };
            }
        } catch (e) {
            return null;
        } finally {
            clearTimeout(timer);
        }
        return null;
    }

    async testConnection() {
        const hostInput = document.getElementById('server-host-input');
        const portInput = document.getElementById('server-port-input');
        const fb = document.getElementById('server-cfg-feedback');
        if (!hostInput || !portInput) return null;

        let host = hostInput.value.trim() || '127.0.0.1';
        host = host.replace(/^https?:\/\//i, '').replace(/\/+$/, '');
        let port = portInput.value.trim() || '8087';

        const targetUrl = `http://${host}:${port}`;
        if (fb) {
            fb.hidden = false;
            fb.style.display = 'block';
            fb.innerHTML = `<span style="color:var(--accent-cyan);">⏳ 正在连接测试 ${targetUrl}/api/server_info ...</span>`;
        }

        const t0 = performance.now();
        const res = await this._tryEndpoint(targetUrl);
        const elapsed = Math.round(performance.now() - t0);

        if (fb) {
            if (res) {
                fb.innerHTML = `<span style="color:#4ade80; font-weight:600;">✔ 连接成功 (${elapsed} ms)！MiniScheme 服务已就绪</span><br>` +
                    `<span style="font-size:11.5px; color:var(--text-secondary);">服务地址: ${targetUrl} &nbsp;|&nbsp; 局域网代理: ${res.lan_url || targetUrl}</span>`;
            } else {
                fb.innerHTML = `<span style="color:#ef4444; font-weight:600;">✖ 连接失败 (${elapsed} ms)</span><br>` +
                    `<span style="font-size:11.5px; color:var(--text-secondary);">未能连接到 ${targetUrl}。请检查 IP/端口是否正确，或者 server.py / MiniScheme-WebREPL.exe 是否正在运行。</span>`;
            }
        }
        return res;
    }

    async saveConfig() {
        const hostInput = document.getElementById('server-host-input');
        const portInput = document.getElementById('server-port-input');
        const fb = document.getElementById('server-cfg-feedback');
        if (!hostInput || !portInput) return;

        let host = hostInput.value.trim() || '127.0.0.1';
        host = host.replace(/^https?:\/\//i, '').replace(/\/+$/, '');
        let port = portInput.value.trim() || '8087';

        localStorage.setItem('webrepl_server_host', host);
        localStorage.setItem('webrepl_server_port', port);

        const targetUrl = `http://${host}:${port}`;
        window.LOCAL_SERVER_BASE = targetUrl;
        if (typeof window.syncWasmProxyUrl === 'function') {
            window.syncWasmProxyUrl(targetUrl);
        }

        if (fb) {
            fb.hidden = false;
            fb.style.display = 'block';
            fb.innerHTML = `<span style="color:#4ade80;">✔ 配置已保存并生效！当前服务地址：<b>${targetUrl}</b></span>`;
        }

        await this.probeLocalServer(true);
    }

    async resetConfig() {
        localStorage.removeItem('webrepl_server_host');
        localStorage.removeItem('webrepl_server_port');
        const hostInput = document.getElementById('server-host-input');
        const portInput = document.getElementById('server-port-input');
        const fb = document.getElementById('server-cfg-feedback');
        if (hostInput) hostInput.value = window.location.hostname || '127.0.0.1';
        if (portInput) portInput.value = window.location.port || '8087';
        if (fb) {
            fb.hidden = false;
            fb.style.display = 'block';
            fb.innerHTML = `<span style="color:var(--text-secondary);">已清除自定义配置，恢复自动检测 (默认 127.0.0.1:8087)</span>`;
        }
        await this.probeLocalServer(true);
    }

    async probeLocalServer(manual = false) {
        if (this.probing) return this.info;
        this.probing = true;
        const statusEl = document.getElementById('local-server-status-box');
        if (manual && statusEl) {
            statusEl.textContent = '🔍 正在检测 MiniScheme 后端服务状态...';
        }

        try {
            const candidates = [];
            const savedHost = (localStorage.getItem('webrepl_server_host') || '').trim();
            const savedPort = (localStorage.getItem('webrepl_server_port') || '').trim();

            if (savedHost) {
                const cleanHost = savedHost.replace(/^https?:\/\//i, '').replace(/\/+$/, '');
                const cleanPort = savedPort || '8087';
                candidates.push(`http://${cleanHost}:${cleanPort}`);
            } else {
                if (window.location.protocol.startsWith('http')) {
                    candidates.push(''); // Same origin first
                }

                for (const p of [8087, 8088, 8089, 8090, 8091, 8080]) {
                    const origin = `http://127.0.0.1:${p}`;
                    if (!candidates.includes(origin) && window.location.origin !== origin) {
                        candidates.push(origin);
                    }
                }
            }

            let found = null;
            for (const base of candidates) {
                const res = await this._tryEndpoint(base);
                if (res) {
                    found = res;
                    break;
                }
            }

            this.info = found;
            window.LOCAL_SERVER_INFO = found;
            if (found) {
                window.LOCAL_SERVER_BASE = found.baseUrl;
            } else if (savedHost) {
                const cleanHost = savedHost.replace(/^https?:\/\//i, '').replace(/\/+$/, '');
                window.LOCAL_SERVER_BASE = `http://${cleanHost}:${savedPort || '8087'}`;
            } else {
                window.LOCAL_SERVER_BASE = '';
            }

            if (typeof window.syncWasmProxyUrl === 'function') {
                window.syncWasmProxyUrl(window.LOCAL_SERVER_BASE || 'http://127.0.0.1:8087');
            }

            this._updateUI();
            return found;
        } finally {
            this.probing = false;
        }
    }

    _updateUI() {
        const btnHeader = document.getElementById('btn-local-server');
        const statusBox = document.getElementById('local-server-status-box');
        const btnJump = document.getElementById('local-server-jump-btn');
        const hostInput = document.getElementById('server-host-input');
        const portInput = document.getElementById('server-port-input');
        const savedHost = (localStorage.getItem('webrepl_server_host') || '').trim();
        const savedPort = (localStorage.getItem('webrepl_server_port') || '').trim();

        if (hostInput && !hostInput.matches(':focus')) {
            hostInput.value = savedHost || (this.info ? (this.info.ip || '127.0.0.1') : '127.0.0.1');
        }
        if (portInput && !portInput.matches(':focus')) {
            portInput.value = savedPort || (this.info ? String(this.info.port || '8087') : '8087');
        }

        if (this.info) {
            const { ip, port, lan_url, local_url } = this.info;
            const isSameOrigin = this.info.baseUrl === '' || (window.location.origin && this.info.baseUrl === window.location.origin);
            const activeHost = savedHost || ip || '127.0.0.1';
            const activePort = savedPort || port || '8087';

            if (btnHeader) {
                btnHeader.textContent = `🟢 服务 ${activeHost}:${activePort}`;
                btnHeader.title = `MiniScheme 后端服务运行中 | 地址: ${this.info.baseUrl || local_url} (点击查看或修改 IP/端口)`;
            }

            if (statusBox) {
                statusBox.innerHTML =
                    `<div style="color:#4ade80; font-weight:600; margin-bottom:4px;">` +
                    `🟢 已连接 MiniScheme 服务端 ${isSameOrigin ? '(当前页面由本地服务承载)' : `(${this.info.baseUrl})`}` +
                    `</div>` +
                    `<div style="font-size:12px; color:var(--text-secondary);">` +
                    `服务 IP: <b style="color:var(--text-primary);">${activeHost}</b> &nbsp;|&nbsp; ` +
                    `端口: <b style="color:var(--accent-cyan);">${activePort}</b> &nbsp;|&nbsp; ` +
                    `ESP32 代理地址: <code style="color:#38bdf8;">${lan_url || `http://${activeHost}:${activePort}`}</code>` +
                    `</div>`;
            }

            if (btnJump) {
                btnJump.hidden = isSameOrigin;
                btnJump.textContent = `🚀 切换到服务运行页面 (${local_url || this.info.baseUrl})`;
            }

            // Sync detected LAN proxy URL to DeviceSetupWizard defaults
            if (window.MiniSchemeDeviceSetup && window.MiniSchemeDeviceSetup.el) {
                const ds = window.MiniSchemeDeviceSetup.el;
                const effectiveProxy = window.LOCAL_SERVER_BASE || lan_url || `http://${activeHost}:${activePort}`;
                if (ds.proxyUrl && (!ds.proxyUrl.value || ds.proxyUrl.value === 'http://192.168.1.100:8087' || ds.proxyUrl.value === 'http://127.0.0.1:8087')) {
                    ds.proxyUrl.value = effectiveProxy;
                }
                if (ds.converterUrl && (!ds.converterUrl.value || ds.converterUrl.value === 'http://192.168.1.100:8087' || ds.converterUrl.value === 'http://127.0.0.1:8087')) {
                    ds.converterUrl.value = effectiveProxy;
                }
            }
        } else if (savedHost) {
            const customUrl = `http://${savedHost}:${savedPort || '8087'}`;
            if (btnHeader) {
                btnHeader.textContent = `🔴 服务未连上 (${savedHost}:${savedPort || '8087'})`;
                btnHeader.title = `未能连接到指定服务 ${customUrl}，点击检查或重新配置`;
            }
            if (statusBox) {
                statusBox.innerHTML =
                    `<div style="color:#ef4444; font-weight:600; margin-bottom:4px;">` +
                    `🔴 无法连接到配置的后端服务 (${customUrl})` +
                    `</div>` +
                    `<div style="font-size:12px; color:var(--text-secondary);">` +
                    `请检查 IP 与端口是否填写正确，并确保该机器上的 server.py 或 MiniScheme-WebREPL.exe 正在运行。` +
                    `</div>`;
            }
            if (btnJump) {
                btnJump.hidden = true;
            }
        } else {
            if (btnHeader) {
                btnHeader.textContent = '🖥️ 本地服务端 (Exe)';
                btnHeader.title = '一键下载安装并运行本地服务端 (MiniScheme-WebREPL.exe)';
            }
            if (statusBox) {
                statusBox.innerHTML =
                    `<div style="color:#fbbf24; font-weight:600; margin-bottom:4px;">` +
                    `⚪ 当前运行在纯浏览器离线/远端模式（未检测到本机 8087 端口服务）` +
                    `</div>` +
                    `<div style="font-size:12px; color:var(--text-secondary);">` +
                    `可点击下方按钮一键下载并运行最新 Release <b>MiniScheme-WebREPL.exe</b>，或在上方配置已有的服务 IP 和端口。` +
                    `</div>`;
            }
            if (btnJump) {
                btnJump.hidden = true;
            }
        }

        if (window.proxyAdminManager && typeof window.proxyAdminManager.refreshLinks === 'function') {
            window.proxyAdminManager.refreshLinks();
        }
    }
}

window.MiniSchemeLocalServer = new LocalServerManager();
document.addEventListener('DOMContentLoaded', () => {
    window.MiniSchemeLocalServer.init();
});
