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
        const btnFooterClose = document.getElementById('local-server-footer-close-btn');
        if (btnFooterClose) {
            btnFooterClose.addEventListener('click', () => this.close());
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

        const btnUsePublic = document.getElementById('btn-use-public-server');
        if (btnUsePublic) {
            btnUsePublic.addEventListener('click', () => {
                const hostInput = document.getElementById('server-host-input');
                const portInput = document.getElementById('server-port-input');
                if (hostInput) hostInput.value = '124.222.231.186';
                if (portInput) portInput.value = '8087';
                this.saveConfig();
            });
        }

        const btnUseLocal = document.getElementById('btn-use-local-server');
        if (btnUseLocal) {
            btnUseLocal.addEventListener('click', () => {
                const hostInput = document.getElementById('server-host-input');
                const portInput = document.getElementById('server-port-input');
                if (hostInput) hostInput.value = '127.0.0.1';
                if (portInput) portInput.value = '8087';
                this.saveConfig();
            });
        }

        const btnReset = document.getElementById('server-cfg-reset-btn');
        if (btnReset) {
            btnReset.addEventListener('click', () => this.fillPublicTestIP());
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
        let targetBase = window.LOCAL_SERVER_BASE;
        if (!targetBase) {
            const savedHost = (localStorage.getItem('webrepl_server_host') || '').trim();
            const savedPort = (localStorage.getItem('webrepl_server_port') || '').trim();
            if (savedHost) {
                const cleanHost = savedHost.replace(/^https?:\/\//i, '').replace(/\/+$/, '');
                targetBase = `http://${cleanHost}:${savedPort || '8087'}`;
            } else if (window.location.hostname && !window.location.hostname.includes('github.io') && window.location.protocol.startsWith('http')) {
                // When hosted directly by local server.py / MiniScheme-WebREPL.exe
                targetBase = window.location.origin;
            }
        }
        if (!targetBase) return; // Avoid POSTing to static hosts like GitHub Pages
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
        const timer = setTimeout(() => controller.abort(), 2500);
        try {
            try {
                const res = await fetch(`${baseUrl}/api/server_info`, {
                    cache: 'no-store',
                    signal: controller.signal
                });
                if (res.ok) {
                    const data = await res.json();
                    if (data && (data.success || data.status === 'ok')) {
                        return { ...data, baseUrl };
                    }
                }
            } catch (e) {
                // fall through to /health
            }

            try {
                const res = await fetch(`${baseUrl}/health`, {
                    cache: 'no-store',
                    signal: controller.signal
                });
                if (res.ok) {
                    const data = await res.json();
                    if (data && (data.status === 'ok' || data.success)) {
                        return { ...data, baseUrl, proxy_server: true };
                    }
                }
            } catch (e2) {
                // both failed
            }
        } finally {
            clearTimeout(timer);
        }
        return null;
    }

    showMixedContentModal(targetUrl) {
        let modal = document.getElementById('mixed-content-modal');
        if (!modal) {
            modal = document.createElement('dialog');
            modal.id = 'mixed-content-modal';
            modal.className = 'modal-dialog flasher-modal';
            modal.style.maxWidth = '580px';
            modal.style.border = '1px solid rgba(245, 158, 11, 0.4)';
            modal.style.boxShadow = '0 20px 50px rgba(0, 0, 0, 0.6)';
            modal.innerHTML = `
                <div class="modal-header" style="border-bottom:1px solid rgba(245,158,11,0.25); padding:12px 16px;">
                    <h3 style="display:flex; align-items:center; gap:8px; color:#fbbf24; font-size:15px; margin:0;">
                        <span>🛡️</span> 浏览器混合内容 (Mixed Content) 拦截提示与解除指引
                    </h3>
                    <button class="modal-close-btn" id="mixed-content-close-btn" style="background:none; border:none; font-size:20px; color:var(--text-secondary); cursor:pointer;">&times;</button>
                </div>
                <div class="modal-body" style="padding:16px 20px; font-size:12.5px; line-height:1.6; color:var(--text-primary);">
                    <div style="background:rgba(245,158,11,0.12); border-left:4px solid #f59e0b; padding:10px 14px; border-radius:4px; margin-bottom:14px;">
                        <b>为什么会提示 (blocked:mixed-content)？</b><br>
                        您当前正通过安全协议 (<b>HTTPS</b>) 访问 WebREPL，而测试的目标服务器 (<code id="mixed-content-target-text">${targetUrl}</code>) 为 <b>HTTP</b> 协议。<br>
                        现代浏览器出于传输安全机制，<b>默认拦截</b> HTTPS 网页向 HTTP 接口发起的所有数据通信。
                    </div>

                    <div style="font-weight:700; color:var(--accent-cyan); margin-bottom:6px; font-size:13.5px;">
                        👉 方案一：在浏览器中允许本站加载不安全内容（仅需开启一次）
                    </div>
                    <div style="margin-bottom:14px; padding-left:4px;">
                        <ol style="margin:4px 0 0 18px; padding:0; line-height:1.8;">
                            <li>点击浏览器顶部地址栏最左侧的 <b>站点控制图标</b>（🔒 锁形图标 或 ⚙️ 调谐设置图标）。</li>
                            <li>在展开的弹出菜单中，点击 <b>「网站设置」(Site settings)</b> 或 <b>「权限」</b>。</li>
                            <li>在权限列表中找到 <b>「不安全内容」(Insecure content)</b>。</li>
                            <li>将右侧状态从 <b>「屏蔽 (默认)」</b> 修改为 <b>「允许」(Allow)</b>。</li>
                            <li>修改后返回本页面，按 <b>F5 刷新页面</b>，即可畅通测试与连接！</li>
                        </ol>
                        <div style="margin-top:6px; font-size:11.5px; color:var(--text-secondary);">
                            💡 提示：在部分 Chrome/Edge 浏览器中，地址栏右侧也会直接出现带有红叉的“已拦截不安全脚本”盾牌图标，点击后可直接选择“允许加载不安全脚本”。
                        </div>
                    </div>

                    <div style="font-weight:700; color:var(--accent-cyan); margin-bottom:6px; font-size:13.5px;">
                        👉 方案二：在新标签页直接验证公网服务是否正常
                    </div>
                    <div style="margin-bottom:14px; padding-left:4px;">
                        浏览器独立新标签页不受混合内容限制。您可以点击下方按钮直接访问公网测试接口：
                        <div style="margin-top:8px;">
                            <a id="mixed-content-link-btn" href="${targetUrl}/health" target="_blank" rel="noopener" class="action-btn highlight" style="display:inline-flex; align-items:center; gap:6px; text-decoration:none; padding:6px 14px; font-size:12.5px;">
                                🌐 在新标签页打开 ${targetUrl}/health
                            </a>
                        </div>
                    </div>

                    <div style="font-weight:700; color:var(--accent-cyan); margin-bottom:6px; font-size:13.5px;">
                        👉 方案三：使用本地桌面客户端 (无任何混合内容限制)
                    </div>
                    <div style="padding-left:4px; font-size:12px; color:var(--text-secondary);">
                        使用下方“方式一”下载的 <b>MiniScheme-WebREPL.exe</b> 桌面客户端，页面本身运行在本地 HTTP (127.0.0.1) 下，连接任何本地或公网 HTTP 服务均开箱即用，无任何拦截。
                    </div>

                    <div style="margin-top:16px; text-align:right;">
                        <button class="pill-btn highlight" id="mixed-content-ok-btn" style="padding:6px 20px;">我知道了</button>
                    </div>
                </div>
            `;
            document.body.appendChild(modal);

            modal.addEventListener('click', (e) => {
                if (e.target === modal) modal.close();
            });
            const closeBtn = modal.querySelector('#mixed-content-close-btn');
            if (closeBtn) closeBtn.addEventListener('click', () => modal.close());
            const okBtn = modal.querySelector('#mixed-content-ok-btn');
            if (okBtn) okBtn.addEventListener('click', () => modal.close());
        } else {
            const linkBtn = modal.querySelector('#mixed-content-link-btn');
            if (linkBtn) {
                linkBtn.href = `${targetUrl}/health`;
                linkBtn.textContent = `🌐 在新标签页打开 ${targetUrl}/health`;
            }
            const targetText = modal.querySelector('#mixed-content-target-text');
            if (targetText) {
                targetText.textContent = targetUrl;
            }
        }

        try {
            if (typeof modal.showModal === 'function') {
                modal.showModal();
            } else {
                modal.hidden = false;
            }
        } catch (e) {
            modal.hidden = false;
        }
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
            fb.innerHTML = `<span style="color:var(--accent-cyan);">⏳ 正在连接测试 ${targetUrl} ...</span>`;
        }

        const isLoopbackTarget = (host === '127.0.0.1' || host === 'localhost');
        const currentHostname = window.location.hostname || '';
        const currentIsNonLoopback = (currentHostname && currentHostname !== '127.0.0.1' && currentHostname !== 'localhost');
        const isHttpsPage = (window.location.protocol === 'https:');
        const isHttpTarget = targetUrl.startsWith('http://');
        const isMixedContentBlocked = isHttpsPage && isHttpTarget;

        const t0 = performance.now();
        const res = await this._tryEndpoint(targetUrl);
        const elapsed = Math.round(performance.now() - t0);

        if (fb) {
            if (res) {
                const typeLabel = res.proxy_server ? ' (代理/转换器服务)' : ' (完整 WebREPL 服务)';
                fb.innerHTML = `<span style="color:#4ade80; font-weight:600;">✔ 连接成功 (${elapsed} ms)！MiniScheme 服务已就绪${typeLabel}</span><br>` +
                    `<span style="font-size:11.5px; color:var(--text-secondary);">服务地址: ${targetUrl} &nbsp;|&nbsp; 协议模式: ${res.protocol_mode || 'both'}</span>`;
            } else {
                let extraHint = '';
                if (isMixedContentBlocked) {
                    extraHint = `
                    <div style="margin-top:10px; padding:10px 12px; border-radius:8px; background:rgba(245,158,11,0.12); border:1px solid rgba(245,158,11,0.3); color:#fef3c7; font-size:12px; text-align:left; line-height:1.6;">
                        <div style="font-weight:700; color:#fbbf24; display:flex; align-items:center; gap:6px; margin-bottom:4px;">
                            <span>🛡️</span> 浏览器阻止了混合内容 (Blocked Mixed Content)
                        </div>
                        <div>当前页面通过 <b>HTTPS</b> 访问，测试的目标服务为 <b>HTTP</b> (<code>${targetUrl}</code>)。现代浏览器默认拦截此类跨协议请求。</div>
                        <div style="margin-top:8px; display:flex; gap:8px; flex-wrap:wrap;">
                            <button type="button" class="pill-btn highlight" id="btn-show-mixed-content-guide" style="padding:4px 10px; font-size:11.5px; cursor:pointer;">
                                📖 允许访问不安全内容指引
                            </button>
                            <a href="${targetUrl}/health" target="_blank" rel="noopener" class="pill-btn" style="padding:4px 10px; font-size:11.5px; text-decoration:none; color:inherit; display:inline-flex; align-items:center; gap:4px;">
                                🔗 在新标签页直接打开测试
                            </a>
                        </div>
                    </div>`;
                } else if (isLoopbackTarget && currentIsNonLoopback) {
                    extraHint = `<div style="margin-top:8px; padding:8px 10px; border-radius:6px; background:rgba(239,68,68,0.12); border:1px solid rgba(239,68,68,0.25); color:#fca5a5; font-size:11.5px; text-align:left; line-height:1.5;">` +
                        `💡 <strong>为什么测试 127.0.0.1 会失败？</strong><br>` +
                        `您当前是从 <code>${currentHostname}</code> 打开 WebREPL 的。浏览器执行的所有网络请求都在<strong>您当前的客户端设备</strong>（如手机、平板或其他电脑）上发起。<br>` +
                        `测试 <code>127.0.0.1</code> 访问的是<strong>该客户端自身</strong>，而不是运行 MiniScheme 服务的主机！<br>` +
                        `👉 <strong>解决方案</strong>：请将主机 IP 改为服务端电脑的局域网 IP（例如：<code>${currentHostname}</code>），或公网服务器 IP <code>124.222.231.186</code>。</div>`;
                }

                fb.innerHTML = `<span style="color:#ef4444; font-weight:600;">✖ 连接失败 (${elapsed} ms)</span><br>` +
                    `<span style="font-size:11.5px; color:var(--text-secondary);">未能连接到 ${targetUrl}。` +
                    (isMixedContentBlocked ? '已受浏览器混合内容安全策略拦截。' : '请检查 IP/端口是否正确，或者 server.py / MiniScheme-WebREPL.exe 是否正在运行。') + `</span>` +
                    extraHint;

                if (isMixedContentBlocked) {
                    const btnGuide = document.getElementById('btn-show-mixed-content-guide');
                    if (btnGuide) {
                        btnGuide.addEventListener('click', () => this.showMixedContentModal(targetUrl));
                    }
                    this.showMixedContentModal(targetUrl);
                }
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

    fillPublicTestIP() {
        const hostInput = document.getElementById('server-host-input');
        const portInput = document.getElementById('server-port-input');
        const fb = document.getElementById('server-cfg-feedback');
        if (hostInput) hostInput.value = '124.222.231.186';
        if (portInput) portInput.value = '8087';
        if (fb) {
            fb.hidden = false;
            fb.style.display = 'block';
            fb.innerHTML = `<span style="color:var(--accent-cyan);">🌐 已填入测试公网 IP (124.222.231.186:8087)，可点击【🔍 测试连接】验证或【💾 保存并应用】生效</span>`;
        }
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

            if (found && found.baseUrl) {
                const simUuid = localStorage.getItem('minischeme_sim_uuid');
                if (simUuid) this.registerSimulator(simUuid);
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
            const { ip, port, lan_url } = this.info;
            const isSameOrigin = this.info.baseUrl === '' || (window.location.origin && this.info.baseUrl === window.location.origin);
            const activeHost = savedHost || ip || '127.0.0.1';
            const activePort = savedPort || port || '8087';

            if (btnHeader) {
                btnHeader.textContent = `🟢 服务 ${activeHost}:${activePort}`;
                btnHeader.title = `MiniScheme 后端服务运行中 | 地址: ${this.info.baseUrl || lan_url} (点击查看或修改 IP/端口)`;
            }

            const btnProxyAdmin = document.getElementById('btn-proxy-admin');
            if (btnProxyAdmin) {
                btnProxyAdmin.href = `http://${activeHost}:${activePort}/admin`;
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
                const isMixedWarning = (window.location.protocol === 'https:' && customUrl.startsWith('http://'));
                statusBox.innerHTML =
                    `<div style="color:#ef4444; font-weight:600; margin-bottom:4px;">` +
                    `🔴 无法连接到配置的后端服务 (${customUrl})` +
                    `</div>` +
                    `<div style="font-size:12px; color:var(--text-secondary);">` +
                    (isMixedWarning
                        ? `当前运行在 HTTPS 安全连接下，该 HTTP 接口可能已被浏览器混合内容安全策略拦截。可点击下方“测试连接”查看解除拦截指引，或在新标签页直接打开。`
                        : `请检查 IP 与端口是否填写正确，并确保该机器上的 server.py 或 MiniScheme-WebREPL.exe 正在运行。`) +
                    `</div>`;
            }
        } else {
            if (btnHeader) {
                btnHeader.textContent = '⚙️ 后端设置';
                btnHeader.title = '设置后端服务连接 (IP / 端口 / 本地 EXE 服务端)';
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
