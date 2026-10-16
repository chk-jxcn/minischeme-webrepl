/**
 * @file local_server.js
 * @brief Local Server (MiniScheme-WebREPL.exe / server.py) detector,
 *        one-click GitHub downloader, and status panel for WebREPL.
 */

const GITHUB_EXE_RELEASE_URL = 'https://github.com/chk-jxcn/minischeme-webrepl/releases/download/v1.0.0/MiniScheme-WebREPL.exe';
const GITHUB_INSTALL_PS1_CMD = 'irm https://raw.githubusercontent.com/chk-jxcn/minischeme-webrepl/main/install.ps1 | iex';
const GITHUB_INSTALL_SH_CMD = 'curl -fsSL https://raw.githubusercontent.com/chk-jxcn/minischeme-webrepl/main/install.sh | bash';

window.LOCAL_SERVER_BASE = '';
window.LOCAL_SERVER_INFO = null;

class LocalServerManager {
    constructor() {
        this.info = null;
        this.dialog = null;
        this.probing = false;
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

        const btnOpenLocalUrl = document.getElementById('local-server-jump-btn');
        if (btnOpenLocalUrl) {
            btnOpenLocalUrl.addEventListener('click', () => {
                const targetUrl = (this.info && this.info.local_url) || 'http://127.0.0.1:8087';
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

        // Probe immediately on page load
        this.probeLocalServer(false);
    }

    open() {
        if (!this.dialog) return;
        this.dialog.hidden = false;
        if (typeof this.dialog.showModal === 'function') {
            try { this.dialog.showModal(); } catch (e) {}
        }
        this.probeLocalServer(true);
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

    async probeLocalServer(manual = false) {
        if (this.probing) return this.info;
        this.probing = true;
        const statusEl = document.getElementById('local-server-status-box');
        if (manual && statusEl) {
            statusEl.textContent = '🔍 正在检测本地 MiniScheme 服务 (端口 8087 ~ 8092)...';
        }

        try {
            const candidates = [];
            if (window.location.protocol.startsWith('http')) {
                candidates.push(''); // Same origin first
            }
            for (const p of [8087, 8088, 8089, 8090, 8091, 8080]) {
                const origin = `http://127.0.0.1:${p}`;
                if (window.location.origin !== origin) {
                    candidates.push(origin);
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
            window.LOCAL_SERVER_BASE = found ? found.baseUrl : '';

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

        if (this.info) {
            const { ip, port, lan_url, local_url } = this.info;
            const isSameOrigin = this.info.baseUrl === '';

            if (btnHeader) {
                btnHeader.textContent = `🟢 本地服务 ${ip}:${port}`;
                btnHeader.title = `本地服务运行中 | 本机 IP: ${ip} | 端口: ${port} (点击查看详情)`;
            }

            if (statusBox) {
                statusBox.innerHTML =
                    `<div style="color:#4ade80; font-weight:600; margin-bottom:4px;">` +
                    `🟢 已连接本地服务端 ${isSameOrigin ? '(当前页面即由本地服务承载)' : '(已自动关联本地服务 API)'}` +
                    `</div>` +
                    `<div style="font-size:12px; color:var(--text-secondary);">` +
                    `本机局域网 IP: <b style="color:var(--text-primary);">${ip}</b> &nbsp;|&nbsp; ` +
                    `监听端口: <b style="color:var(--accent-cyan);">${port}</b> &nbsp;|&nbsp; ` +
                    `ESP32 代理地址: <code style="color:#38bdf8;">${lan_url}</code>` +
                    `</div>`;
            }

            if (btnJump) {
                btnJump.hidden = isSameOrigin;
                btnJump.textContent = `🚀 切换到本地运行页面 (${local_url})`;
            }

            // Sync detected LAN proxy URL to DeviceSetupWizard defaults
            if (window.MiniSchemeDeviceSetup && window.MiniSchemeDeviceSetup.el) {
                const ds = window.MiniSchemeDeviceSetup.el;
                if (ds.proxyUrl && (!ds.proxyUrl.value || ds.proxyUrl.value === 'http://192.168.1.100:8087')) {
                    ds.proxyUrl.value = lan_url;
                }
                if (ds.converterUrl && (!ds.converterUrl.value || ds.converterUrl.value === 'http://192.168.1.100:8087')) {
                    ds.converterUrl.value = lan_url;
                }
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
                    `可点击下方按钮一键下载并运行 <b>MiniScheme-WebREPL.exe</b>，自动启动本地 WebREPL + 应用代理并在系统托盘显示本机 IP 与端口。` +
                    `</div>`;
            }
            if (btnJump) {
                btnJump.hidden = true;
            }
        }
    }
}

window.MiniSchemeLocalServer = new LocalServerManager();
document.addEventListener('DOMContentLoaded', () => {
    window.MiniSchemeLocalServer.init();
});
