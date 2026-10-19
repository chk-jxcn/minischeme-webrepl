/**
 * @file sim_storage.js
 * @brief Keeps the WASM device's simulated flash in IndexedDB: the file system
 *        files (config.ini, installed apps, fonts) and the 768 KB font ROM
 *        partition survive a page reload, as the board's flash survives a
 *        power cycle.
 *
 * restore() runs before the device VM starts, so config.ini ([fonts]) and
 * the font ROM are in place at boot. The C side counts changes
 * (wasm_fs_gen / wasm_fontrom_gen); poll() runs every animation frame and
 * saves shortly after they move, whoever made the change (the file manager,
 * the font manager or Scheme code such as fs-write and fontrom-add).
 */

const SIM_DB_NAME = 'minischeme-sim';
/* The font ROM image the firmware ships with (minischeme-esp32 firmware/fontrom.bin:
 * simsun-16, all of GB2312), so the simulator has the same fonts as a board */
const SIM_FACTORY_FONT_ROM = 'firmware/fontrom.bin';
const SIM_DB_STORE = 'flash';
const SIM_SAVE_DELAY_MS = 400;

class SimStorage {
    constructor() {
        this.db = null;
        this.enabled = typeof indexedDB !== 'undefined';
        this.fsGen = -1;
        this.romGen = -1;
        this.timer = null;
        this.saving = false;
        this.onError = null;
    }

    _open() {
        if (this.db) return Promise.resolve(this.db);
        return new Promise((resolve, reject) => {
            const req = indexedDB.open(SIM_DB_NAME, 1);
            req.onupgradeneeded = () => req.result.createObjectStore(SIM_DB_STORE);
            req.onsuccess = () => { this.db = req.result; resolve(this.db); };
            req.onerror = () => reject(req.error);
        });
    }

    async _tx(mode, fn) {
        const db = await this._open();
        return new Promise((resolve, reject) => {
            const tx = db.transaction(SIM_DB_STORE, mode);
            const store = tx.objectStore(SIM_DB_STORE);
            const out = fn(store);
            tx.oncomplete = () => resolve(out && 'result' in out ? out.result : undefined);
            tx.onerror = () => reject(tx.error);
            tx.onabort = () => reject(tx.error);
        });
    }

    _get(key) { return this._tx('readonly', (s) => s.get(key)); }

    /**
     * Writes the saved flash into the WASM module (before wasm_init).
     * Returns {files, rom} counts, or null when nothing was saved.
     */
    async restore(ex, getMemory) {
        if (!this.enabled || !ex.wasm_fs_gen) return null;
        let files, rom;
        try {
            // the file system's record keeps its first key ('spiffs'), so saved data still loads
            [files, rom] = await Promise.all([this._get('spiffs'), this._get('fontrom')]);
        } catch (e) {
            this.enabled = false; // private window or storage blocked: memory only
            return null;
        }
        let nfiles = 0;
        for (const f of files || []) {
            const path = new TextEncoder().encode(f.path + '\0');
            const p = ex.wasm_alloc_buffer(path.length);
            const b = ex.wasm_alloc_buffer(f.data.length || 1);
            new Uint8Array(getMemory().buffer, p, path.length).set(path);
            new Uint8Array(getMemory().buffer, b, f.data.length).set(f.data);
            if (!ex.wasm_fs_write(p, b, f.data.length)) nfiles++;
            ex.wasm_free_buffer(b);
            ex.wasm_free_buffer(p);
        }
        const size = ex.wasm_fontrom_size();
        const romOk = rom instanceof Uint8Array && rom.length === size;
        if (romOk) {
            const ptr = ex.wasm_fontrom_data();
            new Uint8Array(getMemory().buffer, ptr, size).set(rom);
            ex.wasm_fontrom_reload();
        }
        this.fsGen = ex.wasm_fs_gen();
        this.romGen = ex.wasm_fontrom_gen();
        return files || romOk ? { files: nfiles, rom: romOk } : null;
    }

    /** Whether a font ROM image has a valid directory with at least one font
     *  (either copy: sectors 0 and 1, "MFRM", u16 count at offset 6) */
    static fontRomHasFonts(rom) {
        for (const base of [0, 4096]) {
            if (rom.length >= base + 8 && rom[base] === 0x4D && rom[base + 1] === 0x46 &&
                rom[base + 2] === 0x52 && rom[base + 3] === 0x4D && (rom[base + 6] | (rom[base + 7] << 8)) > 0) {
                return true;
            }
        }
        return false;
    }

    /**
     * An empty simulated font ROM gets the firmware's factory image, as a
     * flashed board has: 16 px text then covers all of GB2312 without
     * generating fonts. Runs before wasm_init (fonts apply at boot). Returns
     * the image size, or 0 when nothing was installed.
     */
    async installFactoryFontRom(ex, getMemory) {
        if (!ex.wasm_fontrom_data || !ex.wasm_fontrom_reload) return 0;
        const size = ex.wasm_fontrom_size();
        const ptr = ex.wasm_fontrom_data();
        if (SimStorage.fontRomHasFonts(new Uint8Array(getMemory().buffer, ptr, Math.min(size, 8192)))) return 0;
        let image;
        try {
            const res = await fetch(SIM_FACTORY_FONT_ROM, { cache: 'no-cache' });
            if (!res.ok) return 0;
            image = new Uint8Array(await res.arrayBuffer());
        } catch (e) {
            return 0;
        }
        if (!image.length || image.length > size || !SimStorage.fontRomHasFonts(image)) return 0;
        const rom = new Uint8Array(getMemory().buffer, ex.wasm_fontrom_data(), size);
        rom.fill(0xFF);
        rom.set(image);
        ex.wasm_fontrom_reload();
        return image.length;
    }

    /** Nothing saved yet: the factory state (seeded config.ini) needs no copy */
    markClean(ex) {
        if (!ex.wasm_fs_gen) return;
        this.fsGen = ex.wasm_fs_gen();
        this.romGen = ex.wasm_fontrom_gen();
    }

    /** Called by a timer: saves a little after the flash changed */
    poll(ex, getMemory) {
        if (!this.enabled || this.timer || this.saving || !ex.wasm_fs_gen) return;
        if (ex.wasm_fs_gen() === this.fsGen && ex.wasm_fontrom_gen() === this.romGen) return;
        this.timer = setTimeout(() => {
            this.timer = null;
            this.save(ex, getMemory);
        }, SIM_SAVE_DELAY_MS);
    }

    /** Copies the changed parts now, writes them to IndexedDB afterwards */
    async save(ex, getMemory) {
        if (!this.enabled || this.saving) return;
        this.saving = true;
        try {
            const fsGen = ex.wasm_fs_gen(), romGen = ex.wasm_fontrom_gen();
            let files = null, rom = null;
            if (fsGen !== this.fsGen) {
                files = [];
                const list = JSON.parse(readWasmCString(getMemory(), ex.wasm_fs_list())).files || [];
                for (const f of list) {
                    const path = new TextEncoder().encode(f.path + '\0');
                    const p = ex.wasm_alloc_buffer(path.length);
                    new Uint8Array(getMemory().buffer, p, path.length).set(path);
                    const size = ex.wasm_fs_size(p);
                    const data = size > 0 ? new Uint8Array(getMemory().buffer, ex.wasm_fs_data(p), size).slice() : new Uint8Array(0);
                    ex.wasm_free_buffer(p);
                    if (size >= 0) files.push({ path: f.path, data });
                }
            }
            if (romGen !== this.romGen) {
                rom = new Uint8Array(getMemory().buffer, ex.wasm_fontrom_data(), ex.wasm_fontrom_size()).slice();
            }
            await this._tx('readwrite', (s) => {
                if (files) s.put(files, 'spiffs');
                if (rom) s.put(rom, 'fontrom');
            });
            this.fsGen = fsGen;
            this.romGen = romGen;
        } catch (e) {
            if (this.onError) this.onError(e);
            this.enabled = false;
        } finally {
            this.saving = false;
        }
    }

    /** Erases the saved flash (the page reloads afterwards) */
    async wipe() {
        if (this.timer) clearTimeout(this.timer);
        this.timer = null;
        this.enabled = false; // nothing is saved again before the reload
        try {
            await this._tx('readwrite', (s) => s.clear());
        } catch (e) { /* nothing saved */ }
    }
}

function readWasmCString(memory, ptr) {
    const mem = new Uint8Array(memory.buffer);
    let end = ptr;
    while (end < mem.length && mem[end] !== 0) end++;
    return new TextDecoder('utf-8').decode(mem.subarray(ptr, end));
}
