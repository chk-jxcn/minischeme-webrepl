/**
 * @file editor_flasher.js
 * @brief In-browser Scheme IDE, Web Serial ESP32 Firmware Flasher,
 *        Metadata Extraction, and WASM Compiler integration.
 */

// ---------------------------------------------------------------------------
// 1. Password Protected HTTP Authentication Helper
// ---------------------------------------------------------------------------
function getHttpAuthPassword() {
    return localStorage.getItem("minischeme_http_password") || "";
}

function setHttpAuthPassword(pwd) {
    if (pwd) {
        localStorage.setItem("minischeme_http_password", pwd);
    } else {
        localStorage.removeItem("minischeme_http_password");
    }
}

function getAuthHeaders(headers = {}) {
    const pwd = getHttpAuthPassword();
    if (pwd) {
        headers["X-MiniScheme-Auth"] = pwd;
    }
    return headers;
}

// ---------------------------------------------------------------------------
// 2. Metadata Extraction, INI Generation & FNV-1a Binary Trailer
// ---------------------------------------------------------------------------
function fnv1a32(bytes) {
    let h = 2166136261 >>> 0;
    for (let i = 0; i < bytes.length; i++) {
        h = Math.imul(h ^ bytes[i], 16777619) >>> 0;
    }
    return h >>> 0;
}

function detectApiRequirement(sourceCode) {
    const tokens = new Set(sourceCode.match(/[a-zA-Z0-9_\-+*/<=>!?:%]+/g) || []);
    let maxVer = "1.0";
    
    // v1.5 APIs
    const v15Apis = ['gui-marquee', 'backlight-auto', 'json-feed-status', 'app-carousel-pause', 'app-carousel-resume'];
    for (const api of v15Apis) {
        if (tokens.has(api)) return "1.5";
    }
    // v1.2 APIs
    const v12Apis = ['http-get', 'json-ref', 'font-load', 'use-font', 'gui-polygon', 'gui-round-rect'];
    for (const api of v12Apis) {
        if (tokens.has(api)) maxVer = "1.2";
    }
    return maxVer;
}

function extractSchemeMetadata(code) {
    const meta = {
        id: "custom_app",
        name: "自定义应用",
        description: "在 MiniScheme Web IDE 中创建",
        version: "1.0.0",
        api_version: detectApiRequirement(code),
        proxy_url: "",
        converter_url: ""
    };

    const idMatch = code.match(/(?:;;;|\b|^)\s*id\s*=\s*([a-zA-Z0-9_-]+)/im) ||
                    code.match(/\(define\s+APP-ID\s+"([^"]+)"\)/i) ||
                    code.match(/;;;\s*ID:\s*([a-zA-Z0-9_-]+)/i);
    if (idMatch) meta.id = idMatch[1].trim();

    const nameMatch = code.match(/(?:;;;|\b|^)\s*name\s*=\s*([^\r\n;]+)/im) ||
                      code.match(/\(define\s+APP-NAME\s+"([^"]+)"\)/i) ||
                      code.match(/;;;\s*Name:\s*([^\r\n]+)/i);
    if (nameMatch) meta.name = nameMatch[1].trim();

    const descMatch = code.match(/(?:;;;|\b|^)\s*description\s*=\s*([^\r\n;]+)/im);
    if (descMatch) meta.description = descMatch[1].trim();

    const verMatch = code.match(/(?:;;;|\b|^)\s*version\s*=\s*([^\r\n;]+)/im) ||
                     code.match(/\(define\s+APP-VERSION\s+"([^"]+)"\)/i);
    if (verMatch) meta.version = verMatch[1].trim();

    const apiMatch = code.match(/(?:;;;|\b|^)\s*api(?:_version)?\s*=\s*([0-9.]+)/im);
    if (apiMatch) meta.api_version = apiMatch[1].trim();

    const proxyMatch = code.match(/^(?:;;;\s*)?proxy_url\s*=\s*([^\r\n;#]*)/im);
    if (proxyMatch) meta.proxy_url = proxyMatch[1].trim();

    const convMatch = code.match(/^(?:;;;\s*)?converter_url\s*=\s*([^\r\n;#]*)/im);
    if (convMatch) meta.converter_url = convMatch[1].trim();

    return meta;
}

function generateMetaIniText(meta) {
    return `[app]\nid = ${meta.id}\nname = ${meta.name}\ndescription = ${meta.description}\nversion = ${meta.version}\napi = ${meta.api_version}\n\n[config]\nproxy_url = ${meta.proxy_url || ''}\nconverter_url = ${meta.converter_url || ''}\n`;
}

function generateSchemeHeaderComment(meta) {
    return `;;; [app]\n;;; id = ${meta.id}\n;;; name = ${meta.name}\n;;; description = ${meta.description}\n;;; version = ${meta.version}\n;;; api = ${meta.api_version}\n;;;\n;;; [config]\n;;; proxy_url = ${meta.proxy_url || ''}\n;;; converter_url = ${meta.converter_url || ''}\n\n`;
}

function attachMetaTrailerToMsbc(msbcBytes, meta) {
    const iniText = generateMetaIniText(meta);
    const metaBytes = new TextEncoder().encode(iniText);
    const metaLen = metaBytes.length;
    const hash = fnv1a32(metaBytes);

    // Trailer structure: [meta bytes] + [uint32_le len] + [uint32_le hash] + [4 bytes 'MSMD']
    const trailer = new Uint8Array(metaLen + 4 + 4 + 4);
    trailer.set(metaBytes, 0);

    const dv = new DataView(trailer.buffer, metaLen);
    dv.setUint32(0, metaLen, true);
    dv.setUint32(4, hash, true);
    trailer[metaLen + 8] = 0x4D; // 'M'
    trailer[metaLen + 9] = 0x53; // 'S'
    trailer[metaLen + 10] = 0x4D; // 'M'
    trailer[metaLen + 11] = 0x44; // 'D'

    const combined = new Uint8Array(msbcBytes.length + trailer.length);
    combined.set(msbcBytes, 0);
    combined.set(trailer, msbcBytes.length);

    return {
        combinedBytes: combined,
        metaBytes: metaBytes,
        metaLen: metaLen,
        hash: hash
    };
}

function parseMsbcTrailer(bytes) {
    if (bytes.length < 12) return null;
    const n = bytes.length;
    const magic = String.fromCharCode(bytes[n - 4], bytes[n - 3], bytes[n - 2], bytes[n - 1]);
    if (magic !== 'MSMD') return null;

    const dv = new DataView(bytes.buffer, bytes.byteOffset + n - 12, 8);
    const metaLen = dv.getUint32(0, true);
    const hash = dv.getUint32(4, true);

    if (metaLen <= 0 || metaLen > n - 12) return null;

    const metaOffset = n - 12 - metaLen;
    const metaSlice = bytes.subarray(metaOffset, metaOffset + metaLen);
    const computedHash = fnv1a32(metaSlice);
    if (computedHash !== hash) {
        console.warn('MSMD trailer checksum mismatch', { computedHash, storedHash: hash });
    }

    const iniText = new TextDecoder('utf-8').decode(metaSlice);
    return {
        hasTrailer: true,
        metaLen,
        hash,
        iniText,
        meta: extractSchemeMetadata(iniText),
        bytecodeBytes: bytes.subarray(0, metaOffset)
    };
}

// ---------------------------------------------------------------------------
// 3. Web Serial Firmware Flasher (esptool-js integration)
// ---------------------------------------------------------------------------
const GITHUB_ESP32_RELEASE_BASE = 'https://github.com/chk-jxcn/minischeme-esp32/releases/latest/download/';
const GITHUB_ESP32_LATEST_API = 'https://api.github.com/repos/chk-jxcn/minischeme-esp32/releases/latest';

// Safe base64 decoding helper that never throws on undefined, null, or unpadded input
function safeAtob(val) {
    if (val === undefined || val === null) return '';
    let str = String(val).trim();
    if (!str) return '';
    while (str.length % 4 !== 0) str += '=';
    try {
        return window.atob(str);
    } catch (e1) {
        let cleaned = str.replace(/[^A-Za-z0-9+/=]/g, '');
        while (cleaned.length % 4 !== 0) cleaned += '=';
        try {
            return window.atob(cleaned);
        } catch (e2) {
            return '';
        }
    }
}

// esptool-js bundles may call atob(undefined) for a stub section that is
// absent: that one case decodes to nothing. Any other invalid base64 still
// throws, so a broken transfer (a device file read cut short) is an error,
// never an empty or partial success.
if (typeof window !== 'undefined' && typeof window.atob === 'function') {
    const rawAtob = window.atob.bind(window);
    window.atob = function(val) {
        if (val === undefined || val === null) return '';
        return rawAtob(val);
    };
}

/* SHA-256 of bytes as hex (WebCrypto; on a plain-http page without it, the
 * check is skipped and said so) */
async function sha256Hex(bytes) {
    if (!(window.crypto && crypto.subtle)) return null;
    const d = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
    return Array.from(d, b => b.toString(16).padStart(2, '0')).join('');
}

function binaryStringToBytes(s) {
    const out = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i) & 0xff;
    return out;
}

/* MD5 of bytes as hex: esptool-js compares it with the flash read back */
function md5Hex(bytes) {
    const S = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
               5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
               4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
               6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21];
    const K = new Uint32Array(64);
    for (let i = 0; i < 64; i++) K[i] = Math.floor(Math.abs(Math.sin(i + 1)) * 4294967296) >>> 0;
    const n = bytes.length;
    const total = ((n + 8) >>> 6 << 6) + 64;
    const buf = new Uint8Array(total);
    buf.set(bytes);
    buf[n] = 0x80;
    const bitsLo = (n << 3) >>> 0, bitsHi = Math.floor(n / 0x20000000) >>> 0;
    for (let i = 0; i < 4; i++) {
        buf[total - 8 + i] = (bitsLo >>> (8 * i)) & 0xff;
        buf[total - 4 + i] = (bitsHi >>> (8 * i)) & 0xff;
    }
    let a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;
    const M = new Uint32Array(16);
    for (let off = 0; off < total; off += 64) {
        for (let i = 0; i < 16; i++) {
            const j = off + i * 4;
            M[i] = (buf[j] | (buf[j + 1] << 8) | (buf[j + 2] << 16) | (buf[j + 3] << 24)) >>> 0;
        }
        let A = a0, B = b0, C = c0, D = d0;
        for (let i = 0; i < 64; i++) {
            let F, g;
            if (i < 16) { F = (B & C) | (~B & D); g = i; }
            else if (i < 32) { F = (D & B) | (~D & C); g = (5 * i + 1) % 16; }
            else if (i < 48) { F = B ^ C ^ D; g = (3 * i + 5) % 16; }
            else { F = C ^ (B | ~D); g = (7 * i) % 16; }
            F = (F + A + K[i] + M[g]) >>> 0;
            A = D; D = C; C = B;
            B = (B + ((F << S[i]) | (F >>> (32 - S[i])))) >>> 0;
        }
        a0 = (a0 + A) >>> 0; b0 = (b0 + B) >>> 0; c0 = (c0 + C) >>> 0; d0 = (d0 + D) >>> 0;
    }
    let hex = '';
    for (const w of [a0, b0, c0, d0]) {
        for (let i = 0; i < 4; i++) hex += ((w >>> (8 * i)) & 0xff).toString(16).padStart(2, '0');
    }
    return hex;
}

async function loadEsptoolBundle() {
    if (window.__esptool) return window.__esptool;

    const localCandidates = [
        './js/esptool-bundle.js',
        'js/esptool-bundle.js',
        '/js/esptool-bundle.js',
        './esptool-bundle.js',
        '/esptool-bundle.js'
    ];

    const cdnCandidates = [
        'https://unpkg.com/esptool-js@0.5.6/bundle.js',
        'https://cdn.jsdelivr.net/npm/esptool-js@latest/bundle.js',
        'https://unpkg.com/esptool-js@latest/bundle.js'
    ];

    let mod = null;
    let lastErr = null;

    // 1. Try local bundle paths first (works offline, zero latency, guaranteed stub compatibility)
    for (const url of localCandidates) {
        try {
            mod = await import(url);
            if (mod && mod.ESPLoader) {
                console.log(`[MiniScheme Flasher] Successfully loaded local esptool bundle from: ${url}`);
                break;
            }
        } catch (err) {
            lastErr = err;
        }
    }

    // 2. If local paths fail, fallback to modern CDN versions (>= 0.5.6)
    if (!mod || !mod.ESPLoader) {
        console.warn('[MiniScheme Flasher] Local esptool-bundle.js not found, trying CDN fallback...', lastErr);
        for (const url of cdnCandidates) {
            try {
                mod = await import(url);
                if (mod && mod.ESPLoader) {
                    console.log(`[MiniScheme Flasher] Successfully loaded esptool bundle from CDN: ${url}`);
                    break;
                }
            } catch (err) {
                lastErr = err;
            }
        }
    }

    if (!mod || !mod.ESPLoader) {
        throw new Error(`Failed to load Espressif flasher driver (esptool-js): ${lastErr ? lastErr.message : 'driver not found'}`);
    }

    // 3. Apply defensive unwrap patch for stub decoders across all version variants
    if (mod.getStubJsonByChipName) {
        const originalGetStub = mod.getStubJsonByChipName;
        mod.getStubJsonByChipName = async function(chipName, rev) {
            const res = await originalGetStub(chipName, rev);
            if (res && res.default && (!res.decodedText || res.decodedText.length === 0)) {
                const d = res.default;
                res.entry = res.entry !== undefined ? res.entry : d.entry;
                res.text = res.text || d.text;
                res.text_start = res.text_start !== undefined ? res.text_start : d.text_start;
                res.data = res.data || d.data;
                res.data_start = res.data_start !== undefined ? res.data_start : d.data_start;
                res.bss_start = res.bss_start !== undefined ? res.bss_start : d.bss_start;
                const decodeFn = mod.decodeBase64Data || function(b64) {
                    const decoded = safeAtob(b64);
                    const ui8 = new Uint8Array(decoded.length);
                    for (let i = 0; i < decoded.length; i++) ui8[i] = decoded.charCodeAt(i);
                    return ui8;
                };
                if (!res.decodedText && res.text) res.decodedText = decodeFn(res.text);
                if (!res.decodedData && res.data) res.decodedData = decodeFn(res.data);
            }
            return res;
        };
    }

    window.__esptool = mod;
    return mod;
}

class WebSerialFirmwareFlasher {
    constructor() {
        this.dialog = null;
        this.port = null;
        this.esploader = null;
        this.transport = null;
        this.isFlashing = false;

        this.githubFirmware = {
            bootloader: null,
            partition: null,
            firmware: null,
            status: 'idle'
        };

        this.manualFirmware = {
            bootloader: null,
            partition: null,
            firmware: null
        };
    }

    init() {
        this.dialog = document.getElementById('flasher-dialog');
        if (!this.dialog) return;

        // Mode switch (GitHub vs Manual)
        const radioGh = document.getElementById('flasher-mode-gh');
        const radioManual = document.getElementById('flasher-mode-manual');
        const ghSection = document.getElementById('flasher-gh-section');
        const manualSection = document.getElementById('flasher-manual-section');

        const updateMode = () => {
            if (radioGh && radioGh.checked) {
                if (ghSection) ghSection.style.display = 'block';
                if (manualSection) manualSection.style.display = 'none';
            } else {
                if (ghSection) ghSection.style.display = 'none';
                if (manualSection) manualSection.style.display = 'block';
            }
        };

        if (radioGh) radioGh.addEventListener('change', updateMode);
        if (radioManual) radioManual.addEventListener('change', updateMode);

        // Fetch GitHub release assets
        const btnFetchGh = document.getElementById('flasher-fetch-gh-btn');
        if (btnFetchGh) {
            btnFetchGh.addEventListener('click', () => this.fetchGithubAssets());
        }

        // File pickers for manual mode
        this._bindFileInput('flasher-file-boot', (bytes, name) => {
            this.manualFirmware.bootloader = bytes;
            this._setFileLabel('flasher-label-boot', `${name} (${this._formatSize(bytes.length)})`);
        });
        this._bindFileInput('flasher-file-part', (bytes, name) => {
            this.manualFirmware.partition = bytes;
            this._setFileLabel('flasher-label-part', `${name} (${this._formatSize(bytes.length)})`);
        });
        this._bindFileInput('flasher-file-app', (bytes, name) => {
            this.manualFirmware.firmware = bytes;
            this._setFileLabel('flasher-label-app', `${name} (${this._formatSize(bytes.length)})`);
        });

        // Flash & Reset buttons
        const btnFlashCurrent = document.getElementById('flasher-flash-current-btn');
        if (btnFlashCurrent) {
            btnFlashCurrent.addEventListener('click', () => this.startFlash(true));
        }
        const btnFlashCurrentCard = document.getElementById('flasher-flash-current-card-btn');
        if (btnFlashCurrentCard) {
            btnFlashCurrentCard.addEventListener('click', () => this.startFlash(true));
        }

        const btnFlash = document.getElementById('flasher-start-btn');
        if (btnFlash) {
            btnFlash.addEventListener('click', () => this.startFlash(false));
        }

        const btnReset = document.getElementById('flasher-reset-btn');
        if (btnReset) {
            btnReset.addEventListener('click', () => this.hardReset());
        }

        const btnClose = document.getElementById('flasher-close-btn');
        if (btnClose) {
            btnClose.addEventListener('click', () => this.close());
        }
    }

    updateCurrentDeviceUi() {
        const link = window.activeLink;
        const isSerial = Boolean(link && link.kind === 'serial' && link.port);
        const card = document.getElementById('flasher-current-device-card');
        const cardLabel = document.getElementById('flasher-current-device-label');
        const btnCurrent = document.getElementById('flasher-flash-current-btn');
        const btnStart = document.getElementById('flasher-start-btn');

        if (isSerial) {
            if (card) card.style.display = 'block';
            if (cardLabel) cardLabel.textContent = link.label || 'ESP32 串口';
            if (btnCurrent) btnCurrent.style.display = 'inline-flex';
            if (btnStart) btnStart.textContent = '🔌 选择其他串口烧录...';
        } else {
            if (card) card.style.display = 'none';
            if (btnCurrent) btnCurrent.style.display = 'none';
            if (btnStart) btnStart.textContent = '⚡ 连接串口并开始烧写';
        }
    }

    _setButtonsDisabled(disabled) {
        const btnCurrent = document.getElementById('flasher-flash-current-btn');
        const btnCurrentCard = document.getElementById('flasher-flash-current-card-btn');
        const btnStart = document.getElementById('flasher-start-btn');
        const btnReset = document.getElementById('flasher-reset-btn');
        if (btnCurrent) btnCurrent.disabled = disabled;
        if (btnCurrentCard) btnCurrentCard.disabled = disabled;
        if (btnStart) btnStart.disabled = disabled;
        if (btnReset) btnReset.disabled = disabled;
    }

    _bindFileInput(elemId, callback) {
        const el = document.getElementById(elemId);
        if (!el) return;
        el.addEventListener('change', (ev) => {
            const file = ev.target.files && ev.target.files[0];
            if (!file) return;
            const reader = new FileReader();
            reader.onload = () => {
                callback(new Uint8Array(reader.result), file.name);
            };
            reader.readAsArrayBuffer(file);
        });
    }

    _setFileLabel(elemId, text) {
        const el = document.getElementById(elemId);
        if (el) el.textContent = text;
    }

    _formatSize(n) {
        if (n < 1024) return `${n} B`;
        if (n < 1048576) return `${(n / 1024).toFixed(1)} KB`;
        return `${(n / 1048576).toFixed(2)} MB`;
    }

    open() {
        if (!this.dialog) this.init();
        if (this.dialog) {
            this.updateCurrentDeviceUi();
            this.dialog.showModal();
            const link = window.activeLink;
            if (link && link.kind === 'serial' && link.port) {
                this.log('ok', `✔ 已检测到当前连接的串口设备: ${link.label}。点击【写入当前设备】可直接复用串口进行烧写。`);
            } else {
                this.log('info', 'Web Serial 固件烧录器已打开。请选择固件来源并连接 ESP32 开发板。');
            }
            if (!('serial' in navigator)) {
                this.log('error', '⚠️ 当前浏览器不支持 Web Serial API。请使用 Google Chrome、Microsoft Edge 或 Opera 浏览器。');
            }
        }
    }

    close() {
        if (this.isFlashing) {
            if (!confirm('固件正在烧写中，确定要中断并关闭吗？')) return;
        }
        if (this.dialog) this.dialog.close();
    }

    log(type, msg) {
        const term = document.getElementById('flasher-terminal');
        if (!term) return;
        const line = document.createElement('div');
        line.className = `term-line ${type || 'info'}`;
        const time = new Date().toTimeString().slice(0, 8);
        line.textContent = `[${time}] ${msg}`;
        term.appendChild(line);
        term.scrollTop = term.scrollHeight;
    }

    setProgress(pct, text) {
        const fill = document.getElementById('flasher-progress-fill');
        const label = document.getElementById('flasher-progress-text');
        if (fill) fill.style.width = `${Math.min(100, Math.max(0, pct))}%`;
        if (label) label.textContent = text || `${Math.round(pct)}%`;
    }

    /* The firmware set: firmware-manifest.json and the three images it lists,
     * all from ONE source (never a mix of versions), each checked against the
     * manifest's sha256. Sources in order: the local server (its bundle or the
     * latest Release), the latest Release itself, this site's firmware/ (synced
     * with each Release), the repository's firmware/. */
    async fetchGithubAssets() {
        const statusEl = document.getElementById('flasher-gh-status');
        const btn = document.getElementById('flasher-fetch-gh-btn');
        if (btn) btn.disabled = true;
        if (statusEl) statusEl.textContent = '正在取得最新发布的固件包 (本地服务 / GitHub Release / 本站)...';
        let releaseTag = 'latest';
        let assetMap = {};
        try {
            const relRes = await fetch(GITHUB_ESP32_LATEST_API, {
                headers: { 'Accept': 'application/vnd.github+json' },
                cache: 'no-store'
            });
            if (relRes.ok) {
                const relData = await relRes.json();
                releaseTag = relData.tag_name || 'latest';
                for (const a of (relData.assets || [])) {
                    if (a.name && a.browser_download_url) assetMap[a.name] = a.browser_download_url;
                }
            }
        } catch (e) { /* the other sources follow */ }
        this.log('info', `最新固件 Release: ${releaseTag}`);

        const files = [
            { name: 'bootloader.bin', key: 'bootloader', offset: 0x1000 },
            { name: 'partition-table.bin', key: 'partition', offset: 0x8000 },
            { name: 'minischeme_esp32.bin', key: 'firmware', offset: 0x10000 }
        ];
        const sources = [
            { label: '本地服务 (/api/release_asset)', url: (n) => `/api/release_asset?repo=minischeme-esp32&asset=${encodeURIComponent(n)}` },
            { label: `GitHub Release ${releaseTag}`, url: (n) => assetMap[n] || '' },
            { label: '本站 firmware/', url: (n) => `./firmware/${n}` },
            { label: 'minischeme-esp32 仓库 firmware/', url: (n) => `https://raw.githubusercontent.com/chk-jxcn/minischeme-esp32/main/firmware/${n}` }
        ];
        const get = async (url) => {
            if (!url) return null;
            try {
                const res = await fetch(url, { cache: 'no-store' });
                if (!res.ok) return null;
                const u8 = new Uint8Array(await res.arrayBuffer());
                return u8.length && u8[0] !== 0x3C ? u8 : null;   // '<': an HTML error page
            } catch (e) {
                return null;
            }
        };

        try {
            let done = false;
            for (const src of sources) {
                const manBytes = await get(src.url('firmware-manifest.json'));
                if (!manBytes) continue;
                let manifest;
                try { manifest = JSON.parse(new TextDecoder().decode(manBytes)); } catch (e) { continue; }
                const listed = {};
                for (const f of (manifest.files || [])) listed[f.name] = f;
                const got = {};
                let ok = true;
                for (const item of files) {
                    const entry = listed[item.name];
                    if (!entry || Number(entry.offset) !== item.offset) {
                        this.log('error', `${src.label}: 清单中 ${item.name} 缺失或地址不符，跳过此来源`);
                        ok = false;
                        break;
                    }
                    const data = await get(src.url(item.name));
                    if (!data) { ok = false; break; }
                    if (entry.size && entry.size !== data.length) {
                        this.log('error', `${src.label}: ${item.name} 大小 ${data.length} 与清单 ${entry.size} 不符，跳过此来源`);
                        ok = false;
                        break;
                    }
                    if (entry.sha256) {
                        const digest = await sha256Hex(data);
                        if (digest !== null && digest !== String(entry.sha256).toLowerCase()) {
                            this.log('error', `${src.label}: ${item.name} SHA-256 校验失败，跳过此来源`);
                            ok = false;
                            break;
                        }
                    }
                    got[item.key] = data;
                }
                if (!ok) continue;
                for (const item of files) this.githubFirmware[item.key] = got[item.key];
                // optional: the font ROM image (simsun-16, all of GB2312) of the same release
                this.githubFirmware.fontrom = null;
                const fontEntry = listed['fontrom.bin'];
                if (fontEntry && Number(fontEntry.offset) === 0x190000) {
                    const font = await get(src.url('fontrom.bin'));
                    const digest = font ? await sha256Hex(font) : null;
                    if (font && (!fontEntry.size || fontEntry.size === font.length) &&
                        (!fontEntry.sha256 || digest === null || digest === String(fontEntry.sha256).toLowerCase())) {
                        this.githubFirmware.fontrom = font;
                        this.log('ok', `   fontrom.bin @0x190000 (${this._formatSize(font.length)}) 系统字库: 宋体 16px，GB2312 一、二级汉字`);
                    } else {
                        this.log('error', `${src.label}: fontrom.bin 下载失败或校验不符，本次不写入系统字库`);
                    }
                }
                const checked = files.every(f => listed[f.name].sha256);
                this.log('ok', `✔ 固件 v${manifest.version || '?'} (IDF ${manifest.idf || '?'}) 来自 ${src.label}` +
                    (checked ? '，3 个文件 SHA-256 校验通过' : '，清单无 SHA-256（旧版本），未校验'));
                for (const item of files) {
                    this.log('ok', `   ${item.name} @0x${item.offset.toString(16)} (${this._formatSize(got[item.key].length)})`);
                }
                done = true;
                break;
            }
            if (!done) throw new Error('所有来源都无法取得一套完整且校验通过的固件 (请检查网络或切换手动上传)');

            this.githubFirmware.status = 'ready';
            if (statusEl) {
                statusEl.innerHTML = `<span style="color:#4ade80;">✔ 固件下载完毕: Bootloader (0x1000), 分区表 (0x8000), 主固件 (0x10000)${this.githubFirmware.fontrom ? ', 系统字库 (0x190000)' : ''}</span>`;
            }
        } catch (e) {
            this.log('error', `固件拉取失败: ${e.message}`);
            if (statusEl) statusEl.textContent = `拉取失败: ${e.message}`;
        } finally {
            if (btn) btn.disabled = false;
        }
    }

    async startFlash(useCurrentPort = false) {
        if (this.isFlashing) return;
        if (!('serial' in navigator)) {
            alert('当前浏览器不支持 Web Serial API，请使用 Chrome、Edge 或 Opera 浏览器。');
            return;
        }

        const isGhMode = document.getElementById('flasher-mode-gh').checked;
        const src = isGhMode ? this.githubFirmware : this.manualFirmware;

        const eraseAllCheck = document.getElementById('flasher-erase-all');
        const eraseAll = eraseAllCheck && eraseAllCheck.checked;
        // always all three: a first flash needs the bootloader and partition table
        if (!src.bootloader || !src.partition || !src.firmware) {
            alert('请先准备好全部 3 个固件文件：引导程序 (bootloader)、分区表 (partition-table) 与主固件 (minischeme_esp32)！');
            return;
        }

        const baudSelect = document.getElementById('flasher-baud-select');
        const baudrate = parseInt((baudSelect && baudSelect.value) || '460800', 10);

        this.isFlashing = true;
        this._setButtonsDisabled(true);

        try {
            this.log('info', '正在加载 Espressif 烧录驱动模块 (esptool-js)...');
            const esptool = await loadEsptoolBundle();
            const { ESPLoader, Transport } = esptool;

            let port = null;
            if (useCurrentPort) {
                const link = window.activeLink;
                if (!link || link.kind !== 'serial' || !link.port) {
                    throw new Error('未检测到已连接的串口硬件，请点击“选择其他串口烧录”选择设备。');
                }
                const label = link.label || 'ESP32 串口';
                this.log('info', `正在复用当前硬件串口连接 (${label})...`);
                if (typeof link.releasePort === 'function') {
                    port = await link.releasePort();
                } else {
                    port = link.port;
                    await link.disconnect();
                }
                if (typeof window.disconnectDevice === 'function') {
                    try { await window.disconnectDevice(); } catch (_) {}
                }
                window.activeLink = null;
                this.log('ok', `✔ 成功接管当前串口设备句柄 (${label})`);
            } else {
                this.log('info', '请在弹出窗口中选择 ESP32 开发板的 USB 串口...');
                port = await navigator.serial.requestPort({
                    filters: [
                        { usbVendorId: 0x10c4 }, // CP2102
                        { usbVendorId: 0x1a86 }, // CH340
                        { usbVendorId: 0x0403 }, // FTDI
                        { usbVendorId: 0x303a }  // Espressif USB
                    ]
                });
            }
            this.port = port;

            const transport = new Transport(port);
            this.transport = transport;

            const self = this;
            const term = {
                clean() {},
                write(str) {
                    if (str && str.trim()) self.log('info', str.trim());
                },
                writeLine(str) {
                    if (str && str.trim()) self.log('info', str.trim());
                }
            };

            const resetConstructors = {
                hardReset: (trans) => ({
                    reset: async () => {
                        try {
                            await trans.setSignals(false, true);
                            await new Promise(r => setTimeout(r, 150));
                            await trans.setSignals(false, false);
                            await new Promise(r => setTimeout(r, 200));
                        } catch (e) { /* ignore */ }
                    }
                })
            };

            // romBaudrate: the ROM bootloader's handshake; baudrate: the flashing
            // speed esptool-js switches to after it (it stayed at 115200 before,
            // whatever was selected). A board that cannot keep up falls back.
            const esploader = new ESPLoader({
                transport: transport,
                baudrate: baudrate,
                romBaudrate: 115200,
                terminal: term,
                resetConstructors: resetConstructors
            });
            this.esploader = esploader;

            this.log('info', '正在连接 ESP32 ROM Bootloader (发送硬件 DTR/RTS 复位时序)...');
            this.setProgress(5, '正在握手连接...');
            const chipName = await esploader.main();
            this.log('ok', `✔ 成功连接芯片: ${chipName || 'ESP32'}`);

            if (baudrate !== 115200) {
                this.log('info', `提升烧录波特率至 ${baudrate} baud...`);
            }

            // Build files array and strictly guarantee Uint8Array instances
            const toUint8 = (d) => {
                if (d instanceof Uint8Array) return d;
                if (d instanceof ArrayBuffer) return new Uint8Array(d);
                if (ArrayBuffer.isView(d)) return new Uint8Array(d.buffer, d.byteOffset, d.byteLength);
                return new Uint8Array(d);
            };

            const filesToFlash = [
                { data: toUint8(src.bootloader), address: 0x1000 },
                { data: toUint8(src.partition), address: 0x8000 },
                { data: toUint8(src.firmware), address: 0x10000 }
            ];
            // the release's font ROM (replaces the fontrom partition: fonts installed before are removed)
            const fontCheck = document.getElementById('flasher-write-fontrom');
            if (isGhMode && src.fontrom && fontCheck && fontCheck.checked) {
                filesToFlash.push({ data: toUint8(src.fontrom), address: 0x190000 });
                this.log('info', '同时写入系统字库 (宋体 16px，GB2312 一、二级汉字) 到 0x190000');
            }

            const totalBytes = filesToFlash.reduce((acc, cur) => acc + cur.data.length, 0);
            this.log('info', `准备写入 Flash：共 ${filesToFlash.length} 个分区，总计 ${this._formatSize(totalBytes)}`);

            let writtenBytes = 0;
            const flashOptions = {
                fileArray: filesToFlash,
                flashSize: 'keep',
                flashMode: 'keep',
                flashFreq: 'keep',
                compress: true,
                eraseAll: eraseAll,
                // esptool reads each region back and compares its MD5
                calculateMD5Hash: (image) => md5Hex(typeof image === 'string' ? binaryStringToBytes(image) : image),
                reportProgress: (fileIndex, written, total) => {
                    const filePct = total > 0 ? (written / total) : 0;
                    const overallPct = Math.round(((fileIndex + filePct) / filesToFlash.length) * 100);
                    self.setProgress(overallPct, `${overallPct}% (${self._formatSize(written)} / ${self._formatSize(total)})`);
                }
            };

            this.log('info', `开始写入 Flash (SLIP 压缩传输, ${baudrate} baud)...`);
            await esploader.writeFlash(flashOptions);

            this.setProgress(100, '烧录成功 100%');
            this.log('ok', '🎉 固件烧写完成！正在通过硬件引脚复位芯片重启进入 MiniScheme 系统...');

            try {
                // Assert EN low (RTS=true, DTR=false) to reset ESP32
                await transport.setSignals(false, true);
                await new Promise(r => setTimeout(r, 150));
                // Release EN high with IO0 high (RTS=false, DTR=false) so ESP32 reboots from Flash
                await transport.setSignals(false, false);
                await new Promise(r => setTimeout(r, 200));
            } catch (e) {
                this.log('info', '发送硬件复位信号: ' + e.message);
            }

            try {
                await esploader.after('hard_reset');
            } catch (e) {
                // Ignore fallback error
            }

            await transport.disconnect();
            this.port = null;
            this.transport = null;
            this.esploader = null;

            this.log('ok', '✔ 串口已关闭。MiniScheme 固件正在启动，你可以在 WebREPL 中连接 WiFi HTTP 或串口终端进行控制！');
            this.log('info', '💡 提示：如果开发板未自动亮屏，可轻按板上的 RST / EN 按键手动复位。');
        } catch (err) {
            this.log('error', `❌ 烧录失败: ${err.message}`);
            // release the serial port so a retry can open it again
            try {
                if (this.transport) await this.transport.disconnect();
                else if (this.port && this.port.readable) await this.port.close();
            } catch (_) { /* already closed */ }
            this.port = null;
            this.transport = null;
            this.esploader = null;
            alert(`烧录失败: ${err.message}`);
        } finally {
            this.isFlashing = false;
            this._setButtonsDisabled(false);
            this.updateCurrentDeviceUi();
        }
    }

    async hardReset() {
        if (!('serial' in navigator)) return;
        try {
            const link = window.activeLink;
            if (link && link.kind === 'serial' && link.port) {
                this.log('info', `正在复用当前串口 (${link.label}) 发送硬件复位指令...`);
                if (typeof link.reset === 'function') {
                    await link.reset();
                    this.log('ok', '✔ 已通过串口发送系统复位重启指令 (@RESET)');
                    return;
                }
            }

            let port = null;
            if (link && link.kind === 'serial' && link.port) {
                if (typeof link.releasePort === 'function') {
                    port = await link.releasePort();
                } else {
                    port = link.port;
                    await link.disconnect();
                }
                if (typeof window.disconnectDevice === 'function') {
                    try { await window.disconnectDevice(); } catch (_) {}
                }
                window.activeLink = null;
            } else {
                port = await navigator.serial.requestPort();
            }
            await port.open({ baudRate: 115200 });
            // Pull EN low while keeping IO0 high (DTR=false, RTS=true)
            await port.setSignals({ dataTerminalReady: false, requestToSend: true });
            await new Promise(r => setTimeout(r, 150));
            // Release EN high while keeping IO0 high (DTR=false, RTS=false) so chip boots into user app
            await port.setSignals({ dataTerminalReady: false, requestToSend: false });
            await new Promise(r => setTimeout(r, 200));
            await port.close();
            this.log('ok', '✔ 已发送硬件复位重启信号 (ESP32 Run / Reboot)');
            this.updateCurrentDeviceUi();
        } catch (e) {
            this.log('error', `复位失败: ${e.message}`);
        }
    }
}

// ---------------------------------------------------------------------------
// 4. Scheme In-Browser IDE & Online Compiler
// ---------------------------------------------------------------------------
const DEFAULT_SCHEME_TEMPLATE = `;;; [app]
;;; id = my_app
;;; name = 我的自定义应用
;;; description = 使用 MiniScheme Web IDE 开发的轻量桌面应用
;;; version = 1.0.0
;;; api = 1.5
;;;
;;; [config]
;;; proxy_url = 
;;; converter_url = 

;; 最小应用：固件需要重绘时调用 gui-render-proc；app-tick 每秒调用一次。
;; 状态变化后用 gui-invalidate 标出要重绘的区域 (x y w h)。
(define seconds 0)
(define clock "--:--")

(define (render)
  (let ((w (gui-width)) (h (gui-height)))
    (gui-rect 0 0 w h (gui-rgb 16 24 40) #t)
    (gui-rect 0 0 w 48 (gui-rgb 30 60 110) #t)
    (gui-text 16 16 "Hello, MiniScheme!" (gui-rgb 255 255 255))
    (gui-text 16 72 "毫秒级 WASM 预编译，零显存条带渲染" (gui-rgb 150 200 255))
    (gui-text 16 112 (string-append "时间: " clock) (gui-rgb 230 230 230))
    (gui-text 16 144 (string-append "已运行 " (number->string seconds) " 秒") (gui-rgb 180 180 180))))

(define gui-render-proc render)

;; hm 为 "20:29" 这样的时间 (未对时为 "--:--")
(define (app-tick hm sec week date lux backlight tick lunar)
  (set! seconds (+ seconds 1))
  (set! clock (string-append hm sec))
  (gui-invalidate 0 104 (gui-width) 64))

(gui-invalidate 0 0 (gui-width) (gui-height))
`;

class SchemeIdeModal {
    constructor() {
        this.dialog = null;
        this.codeArea = null;
        this.lastCompiled = null;
        this.bundledApps = [];
    }

    init() {
        this.dialog = document.getElementById('editor-dialog');
        this.codeArea = document.getElementById('editor-code');
        if (!this.dialog) return;

        // Workspace tab buttons
        const tabRepl = document.getElementById('tab-btn-repl');
        const tabEditor = document.getElementById('tab-btn-editor');
        if (tabRepl) {
            tabRepl.addEventListener('click', () => this.close());
        }
        if (tabEditor) {
            tabEditor.addEventListener('click', () => this.open());
        }

        // Toggle metadata drawer
        const btnToggleMeta = document.getElementById('editor-toggle-meta-btn');
        const metaDrawer = document.getElementById('editor-meta-drawer');
        if (btnToggleMeta && metaDrawer) {
            btnToggleMeta.addEventListener('click', () => {
                metaDrawer.hidden = !metaDrawer.hidden;
                btnToggleMeta.textContent = metaDrawer.hidden ? '📋 应用元数据 ▸' : '📋 应用元数据 ▾';
            });
        }

        // Sync metadata buttons
        const btnSyncFromCode = document.getElementById('editor-sync-from-code-btn');
        if (btnSyncFromCode) {
            btnSyncFromCode.addEventListener('click', () => this.syncMetaFromCode());
        }

        const btnSyncToCode = document.getElementById('editor-sync-to-code-btn');
        if (btnSyncToCode) {
            btnSyncToCode.addEventListener('click', () => this.syncMetaToCode());
        }

        // Compile & Deploy buttons
        const btnCompile = document.getElementById('editor-compile-btn');
        if (btnCompile) {
            btnCompile.addEventListener('click', () => this.compile());
        }

        const btnRunLocal = document.getElementById('editor-run-local-btn');
        if (btnRunLocal) {
            btnRunLocal.addEventListener('click', () => this.runLocal());
        }

        const btnUploadHw = document.getElementById('editor-upload-hw-btn');
        if (btnUploadHw) {
            btnUploadHw.addEventListener('click', () => this.uploadToHardware());
        }

        const btnSaveDraft = document.getElementById('editor-save-draft-btn');
        if (btnSaveDraft) {
            btnSaveDraft.addEventListener('click', () => this.saveDraft());
        }

        const btnDownloadMsbc = document.getElementById('editor-download-msbc-btn');
        if (btnDownloadMsbc) {
            btnDownloadMsbc.addEventListener('click', () => this.downloadMsbc());
        }

        const btnDownloadScm = document.getElementById('editor-download-scm-btn');
        if (btnDownloadScm) {
            btnDownloadScm.addEventListener('click', () => this.downloadScm());
        }

        // File inputs for manual import
        const inputScm = document.getElementById('editor-input-scm');
        if (inputScm) {
            inputScm.addEventListener('change', (ev) => {
                const file = ev.target.files && ev.target.files[0];
                if (!file) return;
                const reader = new FileReader();
                reader.onload = () => {
                    this.codeArea.value = reader.result;
                    this.syncMetaFromCode();
                    this._updateStatusLine();
                    this.compile();
                };
                reader.readAsText(file, 'utf-8');
            });
        }

        const inputMsbc = document.getElementById('editor-input-msbc');
        if (inputMsbc) {
            inputMsbc.addEventListener('change', (ev) => {
                const file = ev.target.files && ev.target.files[0];
                if (!file) return;
                const reader = new FileReader();
                reader.onload = () => {
                    this.loadMsbcBinary(new Uint8Array(reader.result), file.name);
                };
                reader.readAsArrayBuffer(file);
            });
        }

        // Template selector
        const appSelect = document.getElementById('editor-app-select');
        if (appSelect) {
            appSelect.addEventListener('change', () => {
                const val = appSelect.value;
                if (val) this.loadAppFromMarketOrTemplate(val);
            });
        }

        // Close / Return to REPL button
        const btnClose = document.getElementById('editor-close-btn');
        if (btnClose) {
            btnClose.addEventListener('click', () => this.close());
        }

        // Tab key support in textarea
        if (this.codeArea) {
            this.codeArea.addEventListener('keydown', (e) => {
                if (e.key === 'Tab') {
                    e.preventDefault();
                    const start = this.codeArea.selectionStart;
                    const end = this.codeArea.selectionEnd;
                    this.codeArea.value = this.codeArea.value.substring(0, start) + '  ' + this.codeArea.value.substring(end);
                    this.codeArea.selectionStart = this.codeArea.selectionEnd = start + 2;
                }
            });
            this.codeArea.addEventListener('input', () => {
                this._updateStatusLine();
            });
        }
    }

    _updateStatusLine() {
        const statusEl = document.getElementById('editor-status-line');
        if (!statusEl || !this.codeArea) return;
        const text = this.codeArea.value;
        const lines = text.split('\n').length;
        const chars = text.length;
        statusEl.textContent = `共 ${lines} 行，${chars} 字符`;
    }

    open(initialCode = null) {
        if (!this.dialog) this.init();
        const replView = document.getElementById('repl-workspace-view');
        const tabRepl = document.getElementById('tab-btn-repl');
        const tabEditor = document.getElementById('tab-btn-editor');

        if (replView) replView.hidden = true;
        if (this.dialog) {
            this.dialog.hidden = false;
            if (typeof this.dialog.showModal === 'function') {
                try { this.dialog.showModal(); } catch (e) {}
            }
            if (initialCode) {
                this.codeArea.value = initialCode;
            } else if (this.codeArea && !this.codeArea.value.trim()) {
                const draft = localStorage.getItem('minischeme_editor_draft_my_app');
                this.codeArea.value = draft || DEFAULT_SCHEME_TEMPLATE;
            }
            this.syncMetaFromCode();
            this._updateStatusLine();
            this._populateAppSelector();
        }
        if (tabRepl) {
            tabRepl.classList.remove('active');
            tabRepl.setAttribute('aria-selected', 'false');
        }
        if (tabEditor) {
            tabEditor.classList.add('active');
            tabEditor.setAttribute('aria-selected', 'true');
        }
    }

    openWithApp(app) {
        this.open();
        if (app && app.id) {
            this.loadAppFromMarketOrTemplate(app.id);
        }
    }

    close() {
        const replView = document.getElementById('repl-workspace-view');
        const tabRepl = document.getElementById('tab-btn-repl');
        const tabEditor = document.getElementById('tab-btn-editor');

        if (this.dialog) {
            this.dialog.hidden = true;
            if (typeof this.dialog.close === 'function') {
                try { this.dialog.close(); } catch (e) {}
            }
        }
        if (replView) replView.hidden = false;
        if (tabRepl) {
            tabRepl.classList.add('active');
            tabRepl.setAttribute('aria-selected', 'true');
        }
        if (tabEditor) {
            tabEditor.classList.remove('active');
            tabEditor.setAttribute('aria-selected', 'false');
        }
    }

    async _populateAppSelector() {
        const select = document.getElementById('editor-app-select');
        if (!select || select.options.length > 2) return;

        try {
            let list = null;
            try {
                const ghRes = await fetch('https://raw.githubusercontent.com/chk-jxcn/minischeme-apps/main/apps/index.json', { cache: 'no-store' });
                if (ghRes.ok) list = await ghRes.json();
            } catch (e) { /* fallback to local */ }

            if (!list) {
                const res = await fetch('apps/index.json', { cache: 'no-store' });
                if (res.ok) list = await res.json();
            }

            if (list && Array.isArray(list)) {
                this.bundledApps = list;
                for (const app of list) {
                    const opt = document.createElement('option');
                    opt.value = app.id;
                    opt.textContent = `📦 ${app.name} (${app.id}.allinone.scm)`;
                    select.appendChild(opt);
                }
            }
        } catch (e) {
            console.warn('Failed to load apps/index.json', e);
        }
    }

    async loadAppFromMarketOrTemplate(appId) {
        if (appId === '__blank__') {
            this.codeArea.value = DEFAULT_SCHEME_TEMPLATE;
            this.syncMetaFromCode();
            this._updateStatusLine();
            return;
        }

        const statusEl = document.getElementById('editor-build-status');
        if (statusEl) statusEl.textContent = `正在从 GitHub/本地加载 ${appId}.allinone.scm 源码...`;

        try {
            let scmText = null;

            // 1. Try GitHub repo apps/<id>.allinone.scm
            const urls = [
                `apps/${appId}.allinone.scm`,
                `https://raw.githubusercontent.com/chk-jxcn/minischeme-apps/main/apps/${appId}.allinone.scm`,
                `https://raw.githubusercontent.com/chk-jxcn/minischeme-apps/main/dist/${appId}.allinone.scm`,
                `https://raw.githubusercontent.com/chk-jxcn/minischeme-apps/main/apps/${appId}/${appId}.allinone.scm`,
                `https://raw.githubusercontent.com/chk-jxcn/minischeme-apps/main/apps/${appId}/${appId}.scm`,
                `apps/${appId}.scm`
            ];

            for (const url of urls) {
                try {
                    const res = await fetch(url);
                    if (res.ok) {
                        scmText = await res.text();
                        if (scmText && scmText.trim().length > 10) break;
                    }
                } catch (e) { /* try next */ }
            }

            if (!scmText) {
                throw new Error(`未能获取 ${appId}.allinone.scm 源码 (请确认网络或手动打开本地文件)`);
            }

            this.codeArea.value = scmText;
            this.syncMetaFromCode();
            this._updateStatusLine();
            this.compile();
            if (statusEl) statusEl.textContent = `✔ 已载入并编译 ${appId}.allinone.scm (点击“本地模拟”可在右侧屏幕预览)`;
        } catch (e) {
            alert(`加载源码失败: ${e.message}`);
            if (statusEl) statusEl.textContent = `加载失败: ${e.message}`;
        }
    }

    loadMsbcBinary(bytes, filename) {
        const parsed = parseMsbcTrailer(bytes);
        const statusEl = document.getElementById('editor-build-status');
        if (parsed) {
            this.lastCompiled = {
                combinedBytes: bytes,
                metaBytes: new TextEncoder().encode(parsed.iniText),
                metaLen: parsed.metaLen,
                hash: parsed.hash,
                compileTimeMs: 0
            };
            this._fillMetaInputs(parsed.meta);
            if (statusEl) {
                statusEl.innerHTML = `<span style="color:#4ade80;">✔ 已载入 ${filename} (${bytes.length} B, 含 MSMD 元数据)，可直接本地模拟或安装到 ESP32</span>`;
            }
        } else {
            this.lastCompiled = {
                combinedBytes: bytes,
                compileTimeMs: 0
            };
            if (statusEl) {
                statusEl.innerHTML = `<span style="color:#fbbf24;">⚠️ 已载入 ${filename} (${bytes.length} B, 无 MSMD 元数据)</span>`;
            }
        }
    }

    _getMetaFromInputs() {
        const getVal = (id, def) => {
            const el = document.getElementById(id);
            return ((el && el.value) || def).trim();
        };
        return {
            id: getVal('editor-meta-id', 'custom_app'),
            name: getVal('editor-meta-name', '自定义应用'),
            description: getVal('editor-meta-desc', ''),
            version: getVal('editor-meta-version', '1.0.0'),
            api_version: getVal('editor-meta-api', '1.5'),
            proxy_url: getVal('editor-meta-proxy', ''),
            converter_url: getVal('editor-meta-converter', '')
        };
    }

    _fillMetaInputs(meta) {
        if (!meta) return;
        const setVal = (id, v) => {
            const el = document.getElementById(id);
            if (el) el.value = v != null ? v : '';
        };
        setVal('editor-meta-id', meta.id);
        setVal('editor-meta-name', meta.name);
        setVal('editor-meta-desc', meta.description);
        setVal('editor-meta-version', meta.version);
        setVal('editor-meta-api', meta.api_version);
        setVal('editor-meta-proxy', meta.proxy_url);
        setVal('editor-meta-converter', meta.converter_url);
    }

    syncMetaFromCode() {
        if (!this.codeArea) return;
        const code = this.codeArea.value;
        const meta = extractSchemeMetadata(code);
        this._fillMetaInputs(meta);
    }

    syncMetaToCode() {
        if (!this.codeArea) return;
        const meta = this._getMetaFromInputs();
        let code = this.codeArea.value;
        code = code.replace(/^;;;.*?\n\n/s, '');
        const header = generateSchemeHeaderComment(meta);
        this.codeArea.value = header + code;
        this._updateStatusLine();
    }

    compile() {
        if (!this.codeArea) return null;
        const source = this.codeArea.value;
        const statusEl = document.getElementById('editor-build-status');
        const metricTime = document.getElementById('editor-metric-time');
        const metricBytecode = document.getElementById('editor-metric-bytes');
        const metricTrailer = document.getElementById('editor-metric-trailer');
        const metricTotal = document.getElementById('editor-metric-total');

        if (typeof compileWithWasm !== 'function') {
            if (statusEl) statusEl.textContent = '❌ WASM 编译器未就绪';
            return null;
        }

        const res = compileWithWasm(source);
        if (!res || !res.success) {
            const err = (res && res.error) || '编译失败';
            if (statusEl) statusEl.innerHTML = `<span style="color:#f87171;">❌ 编译错误: ${err}</span>`;
            return null;
        }

        const meta = this._getMetaFromInputs();
        const packaged = attachMetaTrailerToMsbc(res.bytes, meta);

        this.lastCompiled = {
            ...packaged,
            compileTimeMs: res.compileTimeMs
        };

        if (metricTime) metricTime.textContent = `${res.compileTimeMs} ms`;
        if (metricBytecode) metricBytecode.textContent = `${res.bytes.length} B`;
        if (metricTrailer) metricTrailer.textContent = `${packaged.combinedBytes.length - res.bytes.length} B`;
        if (metricTotal) metricTotal.textContent = `${packaged.combinedBytes.length} B`;

        if (statusEl) {
            statusEl.innerHTML = `<span style="color:#4ade80;">✔ 编译成功！字节码: ${res.bytes.length} B, 元数据: ${packaged.metaLen} B, 总大小: ${packaged.combinedBytes.length} B</span>`;
        }

        return this.lastCompiled;
    }

    runLocal() {
        if (!this.compile()) return;
        const bytes = this.lastCompiled.combinedBytes;
        const statusEl = document.getElementById('editor-build-status');
        // boot it as the device boots an app (hooks, timers), and show what went wrong
        let result = '';
        if (typeof startAppOnWasmDevice === 'function') {
            result = startAppOnWasmDevice(bytes) || '';
        } else if (typeof bootAppOnWasmDevice === 'function') {
            result = bootAppOnWasmDevice(bytes) || '';
        } else {
            alert('WASM 虚拟机执行器未就绪');
            return;
        }
        if (/^Error/i.test(result)) {
            if (statusEl) statusEl.innerHTML = `<span style="color:#f87171;">❌ 运行出错: ${escapeHtml(result)}</span>`;
            if (typeof appendTerminalLine === 'function') appendTerminalLine('error', `💻 本地模拟运行出错: ${result}`);
            return;
        }
        if (statusEl) {
            statusEl.innerHTML = `<span style="color:#38bdf8;">💻 正在右侧 3.5寸 仿真屏幕上运行: ${this._getMetaFromInputs().name}</span>`;
        }
        if (typeof appendTerminalLine === 'function') {
            appendTerminalLine('info', `💻 本地 WASM 仿真器正在运行: ${this._getMetaFromInputs().name}`);
        }
    }

    async uploadToHardware() {
        if (!this.compile()) return;

        const meta = this._getMetaFromInputs();
        const targetPath = `/spiffs/apps/${meta.id}/app.msbc`;
        const bytes = this.lastCompiled.combinedBytes;

        if (!window.activeLink) {
            alert('未连接 ESP32 硬件设备！请先在顶部栏选择 “📡 ESP32 硬件 (WiFi HTTP)” 或 “🔌 ESP32 硬件 (USB 串口)” 并连接设备。');
            return;
        }

        const statusEl = document.getElementById('editor-build-status');
        if (statusEl) statusEl.textContent = `正在上传 ${meta.name} (${bytes.length} 字节) 到硬件 ${targetPath}...`;

        try {
            await window.activeLink.fsWrite(targetPath, bytes);
            if (statusEl) statusEl.innerHTML = `<span style="color:#4ade80;">✔ 已成功写入硬件: ${targetPath}</span>`;
            
            const doBoot = confirm(`✔ 应用 ${meta.name} 已成功安装到设备！\n\n是否将它设置为开机自启并立即重启设备？`);
            if (doBoot) {
                // the board has no compiler: compile here, run the bytecode there
                const comp = compileWithWasm(`(config-set! "system" "boot_app" "apps/${meta.id}/app.msbc")`);
                if (!comp.success) throw new Error(comp.error);
                const r = await window.activeLink.exec(comp.bytes, 30000);
                if (!r.success || String(r.result).trim() !== '#t') throw new Error(`设置启动应用失败: ${r.error || r.result}`);
                await window.activeLink.reset();
                if (typeof appendTerminalLine === 'function') {
                    appendTerminalLine('ok', `🚀 已设为开机启动应用并重启: apps/${meta.id}/app.msbc`);
                }
            }
        } catch (e) {
            alert(`上传硬件失败: ${e.message}`);
            if (statusEl) statusEl.textContent = `上传硬件失败: ${e.message}`;
        }
    }

    saveDraft() {
        if (!this.codeArea) return;
        const meta = this._getMetaFromInputs();
        localStorage.setItem(`minischeme_editor_draft_${meta.id}`, this.codeArea.value);
        localStorage.setItem('minischeme_editor_last_id', meta.id);
        const statusEl = document.getElementById('editor-build-status');
        if (statusEl) statusEl.innerHTML = `<span style="color:#4ade80;">✔ 草稿已保存到浏览器 LocalStorage (${meta.id})</span>`;
    }

    downloadMsbc() {
        if (!this.compile()) return;
        const meta = this._getMetaFromInputs();
        const filename = `${meta.id}.msbc`;
        const blob = new Blob([this.lastCompiled.combinedBytes], { type: 'application/octet-stream' });
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = filename;
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        URL.revokeObjectURL(url);
    }

    downloadScm() {
        if (!this.codeArea) return;
        const meta = this._getMetaFromInputs();
        const filename = `${meta.id}.allinone.scm`;
        const blob = new Blob([this.codeArea.value], { type: 'text/plain;charset=utf-8' });
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = filename;
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        URL.revokeObjectURL(url);
    }
}

// ---------------------------------------------------------------------------
// 5. Global Instances & UI Bindings
// ---------------------------------------------------------------------------
window.MiniSchemeFlasher = new WebSerialFirmwareFlasher();
window.SchemeEditor = new SchemeIdeModal();

document.addEventListener('DOMContentLoaded', () => {
    window.MiniSchemeFlasher.init();
    window.SchemeEditor.init();

    const btnFlasherOpen = document.getElementById('btn-firmware-flasher');
    if (btnFlasherOpen) {
        btnFlasherOpen.addEventListener('click', () => window.MiniSchemeFlasher.open());
    }

    const btnEditorOpen = document.getElementById('btn-scheme-editor');
    if (btnEditorOpen) {
        btnEditorOpen.addEventListener('click', () => window.SchemeEditor.open());
    }
});
