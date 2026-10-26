/**
 * @file app_source.js
 * @brief Where the WebREPL takes the apps, the app library (applib) and the API
 *        reference from: minischeme-apps on GitHub, at its newest release tag.
 *
 * The WebREPL carries no app of its own. The newest tag is looked up when the
 * user asks for it (refresh(): the app manager's ⟳ 刷新) or the first time, and
 * kept in localStorage; every file comes from that tag (its dist/ is the CI's
 * build: index.json, the images, dist/lib/<applib version>/, dist/api.json; the
 * apps' own code under apps/<id>/) through jsDelivr (reachable from mainland
 * China) or raw.githubusercontent.com. A file of a tag never changes, so it is
 * kept in the browser's Cache Storage and read from there next time; offline,
 * the copy of an earlier tag is used. Served by a local server.py, the page's
 * own apps/ comes first: build_apps.py --sync puts the PC's builds there.
 */

const AS_REPO = 'chk-jxcn/minischeme-apps';
const AS_CACHE = 'minischeme-apps';
const AS_TAG_KEY = 'minischeme-apps-tag';
const AS_CACHE_HOST = 'https://minischeme-apps.cache/';   // Cache Storage keys: <host><tag>/<path>

class AppSource {
    constructor() {
        this.tag = '';
        try { this.tag = localStorage.getItem(AS_TAG_KEY) || ''; } catch (e) { /* private window */ }
        this.memory = new Map();            // without Cache Storage (an http:// LAN address)
        this.lastSource = '';               // where the last file came from: 'local', 'cache', 'jsdelivr', 'github'
    }

    /* Served by the PC's own server (not the published WebREPL): its apps/ may hold local builds */
    _local() {
        const pub = window.DeviceSetupWizard && window.DeviceSetupWizard.isPublicWebRepl();
        return !pub && window.location.protocol.startsWith('http');
    }

    async _fetch(url, timeoutMs) {
        const ctl = typeof AbortController === 'function' ? new AbortController() : null;
        const t = ctl ? setTimeout(() => ctl.abort(), timeoutMs || 20000) : 0;
        try {
            return await fetch(url, { cache: 'no-store', signal: ctl ? ctl.signal : undefined });
        } finally {
            if (t) clearTimeout(t);
        }
    }

    /* The newest release tag: the GitHub API, else jsDelivr's list of the repository's versions */
    async latestTag() {
        try {
            const r = await this._fetch(`https://api.github.com/repos/${AS_REPO}/releases/latest`, 10000);
            if (r.ok) {
                const d = await r.json();
                if (d && d.tag_name) return d.tag_name;
            }
        } catch (e) { /* the next source */ }
        const r = await this._fetch(`https://data.jsdelivr.com/v1/packages/gh/${AS_REPO}`, 10000);
        if (!r.ok) throw new Error(`读取应用仓库版本失败 (HTTP ${r.status})`);
        const vs = ((await r.json()).versions || []).map((v) => String(v.version || ''))
            .filter((v) => /^\d+(\.\d+)*$/.test(v));
        if (!vs.length) throw new Error('应用仓库没有发布版本');
        vs.sort((a, b) => AppSource.compare(b, a));
        return 'v' + vs[0];
    }

    /* Looks the newest tag up again (the user's 刷新); keeps the old one when offline */
    async refresh() {
        try {
            this.tag = await this.latestTag();
            try { localStorage.setItem(AS_TAG_KEY, this.tag); } catch (e) { /* not kept */ }
        } catch (e) {
            if (!this.tag) throw e;
        }
        return this.tag;
    }

    async ensureTag() {
        if (!this.tag) await this.refresh();
        return this.tag;
    }

    static compare(a, b) {
        const x = String(a).replace(/^v/, '').split('.').map(Number), y = String(b).replace(/^v/, '').split('.').map(Number);
        for (let i = 0; i < Math.max(x.length, y.length); i++) {
            if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) - (y[i] || 0);
        }
        return 0;
    }

    async _cache() {
        try { return (typeof caches !== 'undefined') ? await caches.open(AS_CACHE) : null; } catch (e) { return null; }
    }

    /* The page's own apps/ for a path of the repository: dist/<x> -> apps/<x>, apps/<id>/<x> -> apps/<id>/<x> */
    _localPath(path) {
        return path.startsWith('dist/') ? 'apps/' + path.slice(5) : path;
    }

    /* A Response for path (relative to the repository root) at the current tag */
    async _get(path, opts = {}) {
        if (this._local() && !opts.remoteOnly) {
            try {
                const r = await this._fetch(this._localPath(path), 5000);
                if (r.ok) { this.lastSource = 'local'; return r; }
            } catch (e) { /* GitHub */ }
        }
        const tag = await this.ensureTag();
        const key = `${AS_CACHE_HOST}${tag}/${path}`;
        const cache = await this._cache();
        const kept = cache ? await cache.match(key) : (this.memory.get(key) || null);
        if (kept) { this.lastSource = 'cache'; return cache ? kept : kept.clone(); }
        let err = null;
        for (const [url, from] of [[`https://cdn.jsdelivr.net/gh/${AS_REPO}@${tag}/${path}`, 'jsdelivr'],
                                   [`https://raw.githubusercontent.com/${AS_REPO}/${tag}/${path}`, 'github']]) {
            try {
                const r = await this._fetch(url, 30000);
                if (!r.ok) { err = new Error(`${path}: HTTP ${r.status}`); continue; }
                const body = await r.arrayBuffer();
                const resp = new Response(body, { headers: { 'Content-Type': r.headers.get('Content-Type') || '' } });
                if (cache) await cache.put(key, resp.clone()).catch(() => {});
                else this.memory.set(key, resp.clone());
                this.lastSource = from;
                return resp;
            } catch (e) { err = e; }
        }
        // offline: the copy of an earlier tag
        if (cache) {
            const old = (await cache.keys()).map((q) => q.url).filter((u) => u.endsWith('/' + path))
                .sort((a, b) => AppSource.compare(b.slice(AS_CACHE_HOST.length).split('/')[0],
                                                  a.slice(AS_CACHE_HOST.length).split('/')[0]));
            if (old.length) { this.lastSource = 'cache'; return cache.match(old[0]); }
        }
        throw new Error(`下载 ${path} 失败（${err ? err.message || err : '无网络'}）`);
    }

    async text(path, opts) { return (await this._get(path, opts)).text(); }
    async json(path, opts) { return JSON.parse(await this.text(path, opts)); }
    async bytes(path, opts) { return new Uint8Array(await (await this._get(path, opts)).arrayBuffer()); }

    /* The market: [{id, name, file, size, version, api, applib, libs, source, meta, web_page, ...}] */
    async index(opts) {
        const list = await this.json('dist/index.json', opts);
        return Array.isArray(list) ? list : [];
    }
    image(file, opts) { return this.bytes(`dist/${file}`, opts); }
    appFile(path, opts) { return this.text(path, opts); }

    /* {current, versions: [{version, api, files}]}, newest first */
    libIndex() { return this.json('dist/lib/index.json'); }
    libFile(version, name) { return this.text(`dist/lib/${version}/${name}`); }
    libApi(version) { return this.json(`dist/lib/${version}/api.json`); }
    apiReference() { return this.json('dist/api.json'); }

    /* The library version that serves an app needing `need` ("1.2"): the newest of the
     * same MAJOR with an equal or higher MINOR; '' when none */
    static pickLib(need, versions) {
        const [nm, nn] = String(need || '').split('.').map(Number);
        const ok = (versions || []).map((v) => v.version || v).filter((v) => {
            const [m, n] = String(v).split('.').map(Number);
            return Number.isFinite(nm) ? m === nm && n >= (nn || 0) : true;
        });
        ok.sort((a, b) => AppSource.compare(b, a));
        return ok[0] || '';
    }

    static serves(need, have) {
        const [nm, nn] = String(need || '').split('.').map(Number);
        const [hm, hn] = String(have || '').split('.').map(Number);
        return nm === hm && (nn || 0) <= (hn || 0);
    }
}

window.AppSource = AppSource;
window.appSource = new AppSource();
