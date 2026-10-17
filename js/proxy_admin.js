/**
 * @file proxy_admin.js
 * @brief Proxy Management & Audit Portal Integration for MiniScheme WebREPL
 *
 * Opens the standalone Proxy Management & Audit Portal in a separate new browser tab/window.
 * Dynamically resolves the configured server URL (LOCAL_SERVER_BASE or saved server host/port).
 * Does not use modal dialogs or iframes to avoid browser freezing or context trapping.
 */

class ProxyAdminManager {
    constructor() {
        this.btnHeader = null;
        this.btnQuick = null;
    }

    init() {
        this.btnHeader = document.getElementById('btn-proxy-admin');
        this.btnQuick = document.getElementById('btn-quick-proxy-admin');

        if (this.btnHeader) {
            this.btnHeader.addEventListener('click', (e) => {
                e.preventDefault();
                this.open();
            });
        }

        if (this.btnQuick) {
            this.btnQuick.addEventListener('click', (e) => {
                e.preventDefault();
                this.open();
            });
        }

        this.refreshLinks();
    }

    getAdminUrl() {
        if (window.LOCAL_SERVER_BASE) {
            return `${window.LOCAL_SERVER_BASE.replace(/\/+$/, '')}/admin`;
        }
        const savedHost = (localStorage.getItem('webrepl_server_host') || '').trim();
        const savedPort = (localStorage.getItem('webrepl_server_port') || '').trim();
        if (savedHost) {
            const cleanHost = savedHost.replace(/^https?:\/\//i, '').replace(/\/+$/, '');
            return `http://${cleanHost}:${savedPort || '8087'}/admin`;
        }
        if (window.location.protocol.startsWith('http')) {
            return `${window.location.origin}/admin`;
        }
        return 'http://127.0.0.1:8087/admin';
    }

    refreshLinks() {
        const url = this.getAdminUrl();
        if (this.btnHeader) {
            this.btnHeader.href = url;
            this.btnHeader.title = `在独立新页面打开 MiniScheme 代理服务管理后台: ${url}`;
        }
        if (this.btnQuick) {
            this.btnQuick.href = url;
            this.btnQuick.title = `在独立新页面打开 MiniScheme 代理服务管理后台: ${url}`;
        }
    }

    open() {
        const url = this.getAdminUrl();
        this.refreshLinks();
        window.open(url, '_blank', 'noopener,noreferrer');
    }

    close() {
        // No-op retained for backwards compatibility
    }
}

window.ProxyAdminManager = ProxyAdminManager;
window.proxyAdminManager = new ProxyAdminManager();

if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => window.proxyAdminManager.init());
} else {
    window.proxyAdminManager.init();
}
