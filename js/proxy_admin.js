/**
 * @file proxy_admin.js
 * @brief Proxy Management & Audit Portal Integration for MiniScheme WebREPL
 */

class ProxyAdminManager {
    constructor() {
        this.dialog = null;
        this.iframe = null;
        this.externalBtn = null;
        this.closeBtn = null;
    }

    init() {
        this.dialog = document.getElementById('proxy-admin-dialog');
        this.iframe = document.getElementById('proxy-admin-iframe');
        this.externalBtn = document.getElementById('proxy-admin-external-btn');
        this.closeBtn = document.getElementById('proxy-admin-close-btn');

        const btnHeader = document.getElementById('btn-proxy-admin');
        if (btnHeader) {
            btnHeader.addEventListener('click', () => this.open());
        }

        const btnQuick = document.getElementById('btn-quick-proxy-admin');
        if (btnQuick) {
            btnQuick.addEventListener('click', () => this.open());
        }

        if (this.closeBtn) {
            this.closeBtn.addEventListener('click', () => this.close());
        }

        if (this.dialog) {
            this.dialog.addEventListener('click', (e) => {
                if (e.target === this.dialog) this.close();
            });
            this.dialog.addEventListener('keydown', (e) => {
                if (e.key === 'Escape') this.close();
            });
        }
    }

    getAdminUrl() {
        if (window.LOCAL_SERVER_BASE) {
            return `${window.LOCAL_SERVER_BASE.replace(/\/+$/, '')}/admin`;
        }
        if (window.location.protocol.startsWith('http')) {
            return `${window.location.origin}/admin`;
        }
        return 'http://127.0.0.1:8087/admin';
    }

    open(external = false) {
        const url = this.getAdminUrl();
        if (external) {
            window.open(url, '_blank');
            return;
        }

        if (!this.dialog) {
            this.init();
        }

        if (this.externalBtn) {
            this.externalBtn.href = url;
        }

        if (this.iframe) {
            if (!this.iframe.src || !this.iframe.src.includes('/admin')) {
                this.iframe.src = url;
            }
        }

        if (this.dialog) {
            this.dialog.removeAttribute('hidden');
            if (typeof this.dialog.showModal === 'function') {
                try {
                    this.dialog.showModal();
                } catch (e) {
                    this.dialog.setAttribute('open', '');
                }
            } else {
                this.dialog.setAttribute('open', '');
            }
        } else {
            window.open(url, '_blank');
        }
    }

    close() {
        if (this.dialog) {
            if (typeof this.dialog.close === 'function') {
                try {
                    this.dialog.close();
                } catch (e) {}
            }
            this.dialog.removeAttribute('open');
            this.dialog.setAttribute('hidden', '');
        }
    }
}

window.ProxyAdminManager = ProxyAdminManager;
window.proxyAdminManager = new ProxyAdminManager();

if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => window.proxyAdminManager.init());
} else {
    window.proxyAdminManager.init();
}
