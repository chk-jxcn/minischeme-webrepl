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
 * kept in the browser (IndexedDB, which also works on an http:// LAN address)
 * and read from there next time; offline, the copy of an earlier tag is used.
 * The files of the current and the previous release are kept. The WebREPL is a
 * static page: no server keeps apps for it. Served by a local server.py, the
 * page's own apps/ (when there is one) comes first: build_apps.py --sync puts
 * the PC's builds there.
 */

const AS_REPO = 'chk-jxcn/minischeme-apps';
const AS_DB = 'minischeme-apps';          // IndexedDB: store "files", key "<tag>/<path>"
const AS_TAG_KEY = 'minischeme-apps-tag';
const AS_KEEP_TAGS = 2;                    // the current release and the one before

class AppSource {
    constructor() {
        this.tag = '';
        try { this.tag = localStorage.getItem(AS_TAG_KEY) || ''; } catch (e) { /* private window */ }
        this.memory = new Map();            // without IndexedDB (a private window may lack it)
        this.dbp = null;
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

    /* Looks the newest tag up again (the user's 刷新); keeps the old one when offline.
     * A new release: the files of releases before the previous one are dropped */
    async refresh() {
        try {
            const tag = await this.latestTag();
            if (tag !== this.tag) {
                this.tag = tag;
                try { localStorage.setItem(AS_TAG_KEY, tag); } catch (e) { /* not kept */ }
                this._prune(tag).catch(() => {});
            }
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

    /* The IndexedDB database, or null (then the files are kept for this page only) */
    _db() {
        if (!this.dbp) {
            this.dbp = new Promise((resolve) => {
                try {
                    const rq = indexedDB.open(AS_DB, 1);
                    rq.onupgradeneeded = () => rq.result.createObjectStore('files');
                    rq.onsuccess = () => resolve(rq.result);
                    rq.onerror = () => resolve(null);
                    rq.onblocked = () => resolve(null);
                } catch (e) { resolve(null); }
            });
        }
        return this.dbp;
    }

    async _store(mode, fn) {
        const db = await this._db();
        if (!db) return null;
        return new Promise((resolve) => {
            try {
                const tx = db.transaction('files', mode);
                const rq = fn(tx.objectStore('files'));
                tx.oncomplete = () => resolve(rq ? rq.result : true);
                tx.onerror = tx.onabort = () => resolve(null);
            } catch (e) { resolve(null); }
        });
    }

    /* {data, type} kept for key, or null */
    async _load(key) {
        if (this.memory.has(key)) return this.memory.get(key);
        return (await this._store('readonly', (s) => s.get(key))) || null;
    }

    async _save(key, value) {
        this.memory.set(key, value);
        await this._store('readwrite', (s) => s.put(value, key));
    }

    async _keys() {
        return (await this._store('readonly', (s) => s.getAllKeys())) || [...this.memory.keys()];
    }

    /* Only the files of the newest AS_KEEP_TAGS releases stay */
    async _prune(current) {
        const keys = await this._keys();
        const tags = [...new Set(keys.map((k) => String(k).split('/')[0]).concat([current]))]
            .sort((a, b) => AppSource.compare(b, a));
        const keep = new Set(tags.slice(0, AS_KEEP_TAGS));
        const drop = keys.filter((k) => !keep.has(String(k).split('/')[0]));
        if (drop.length) await this._store('readwrite', (s) => { drop.forEach((k) => s.delete(k)); return null; });
    }

    _response(v) {
        return new Response(v.data, { headers: { 'Content-Type': v.type || '' } });
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
        const key = `${tag}/${path}`;
        const kept = await this._load(key);
        if (kept) { this.lastSource = 'cache'; return this._response(kept); }
        let err = null;
        for (const [url, from] of [[`https://cdn.jsdelivr.net/gh/${AS_REPO}@${tag}/${path}`, 'jsdelivr'],
                                   [`https://raw.githubusercontent.com/${AS_REPO}/${tag}/${path}`, 'github']]) {
            try {
                const r = await this._fetch(url, 30000);
                if (!r.ok) { err = new Error(`${path}: HTTP ${r.status}`); continue; }
                const value = { data: await r.arrayBuffer(), type: r.headers.get('Content-Type') || '' };
                await this._save(key, value);
                this.lastSource = from;
                return this._response(value);
            } catch (e) { err = e; }
        }
        // offline: the copy of an earlier tag
        const old = (await this._keys()).map(String).filter((k) => k.slice(k.indexOf('/') + 1) === path)
            .sort((a, b) => AppSource.compare(b.split('/')[0], a.split('/')[0]));
        for (const k of old) {
            const v = await this._load(k);
            if (v) { this.lastSource = 'cache'; return this._response(v); }
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
