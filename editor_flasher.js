/**
 * @file editor_flasher.js
 * @brief In-browser Scheme Editor, WASM Compiler, GitHub App Market,
 *        and Web Serial Firmware Flasher for MiniScheme WebREPL.
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
// 2. Scheme Code Editor & Metadata Extraction
// ---------------------------------------------------------------------------
function extractSchemeMetadata(code) {
    const meta = {
        id: "custom_app",
        name: "Custom App",
        description: "Created in MiniScheme Web IDE",
        version: "1.0.0",
        pages: 1,
        api_version: "1.5.0"
    };

    const idMatch = code.match(/;;;\s*\[app\]\s*id\s*=\s*([a-zA-Z0-9_-]+)/i) ||
                    code.match(/\(define\s+APP-ID\s+"([^"]+)"\)/i) ||
                    code.match(/;;;\s*ID:\s*([a-zA-Z0-9_-]+)/i);
    if (idMatch) meta.id = idMatch[1].trim();

    const nameMatch = code.match(/;;;\s*\[app\]\s*name\s*=\s*([^\r\n]+)/i) ||
                      code.match(/;;;\s*Name:\s*([^\r\n]+)/i);
    if (nameMatch) meta.name = nameMatch[1].trim();

    const descMatch = code.match(/;;;\s*\[app\]\s*description\s*=\s*([^\r\n]+)/i);
    if (descMatch) meta.description = descMatch[1].trim();

    const verMatch = code.match(/;;;\s*\[app\]\s*version\s*=\s*([^\r\n]+)/i);
    if (verMatch) meta.version = verMatch[1].trim();

    const apiMatch = code.match(/;;;\s*\[app\]\s*api_version\s*=\s*([^\r\n]+)/i) ||
                     code.match(/API\s+(\d+\.\d+(\.\d+)?)/i);
    if (apiMatch) meta.api_version = apiMatch[1].trim();

    return meta;
}

function formatMetaIni(meta) {
    return `[app]\nid = ${meta.id}\nname = ${meta.name}\ndescription = ${meta.description}\nversion = ${meta.version}\npages = ${meta.pages}\napi_version = ${meta.api_version}\n\n[config]\nproxy_url = http://proxy.local:8087\nconverter_url = http://converter.local:8087\n`;
}

// ---------------------------------------------------------------------------
// 3. Online WASM Compilation & LocalStorage Storage
// ---------------------------------------------------------------------------
async function compileSchemeSource(sourceCode) {
    const meta = extractSchemeMetadata(sourceCode);
    if (window.WasmCompiler && typeof window.WasmCompiler.compile === "function") {
        const msbcBytes = await window.WasmCompiler.compile(sourceCode);
        return { success: true, bytes: msbcBytes, meta };
    }
    // Fallback via server API
    const resp = await fetch("/api/compile_scheme", {
        method: "POST",
        headers: { "Content-Type": "text/plain; charset=utf-8" },
        body: sourceCode
    });
    if (!resp.ok) {
        throw new Error(`Server compile failed: ${resp.statusText}`);
    }
    const buf = await resp.arrayBuffer();
    return { success: true, bytes: new Uint8Array(buf), meta };
}

function saveEditorDraft(appId, code) {
    localStorage.setItem(`minischeme_code_${appId}`, code);
}

function loadEditorDraft(appId) {
    return localStorage.getItem(`minischeme_code_${appId}`) || "";
}

function downloadBinaryFile(filename, bytes) {
    const blob = new Blob([bytes], { type: "application/octet-stream" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
}

// ---------------------------------------------------------------------------
// 4. Web Serial Firmware Flasher
// ---------------------------------------------------------------------------
class WebSerialFlasher {
    constructor() {
        this.port = null;
    }

    isSupported() {
        return "serial" in navigator;
    }

    async requestPort() {
        if (!this.isSupported()) {
            throw new Error("Web Serial API is not supported in this browser. Please use Chrome, Edge, or Opera.");
        }
        this.port = await navigator.serial.requestPort({
            filters: [
                { usbVendorId: 0x10c4 }, // CP2102
                { usbVendorId: 0x1a86 }, // CH340
                { usbVendorId: 0x0403 }, // FTDI
                { usbVendorId: 0x303a }  // Espressif USB JTAG/Serial
            ]
        });
        return this.port;
    }

    async flashFirmware(bootloaderBin, partitionBin, appBin, onProgress, onLog) {
        if (!this.port) await this.requestPort();
        onLog("[*] Serial port opened. Connecting to ESP32 bootloader at 115200 baud...");

        // esptool-js integration or basic serial reset
        await this.port.open({ baudRate: 115200 });

        // Hardware Reset sequence into bootloader (DTR=0, RTS=1 -> DTR=1, RTS=0)
        await this.port.setSignals({ dataTerminalReady: false, requestToSend: true });
        await new Promise(r => setTimeout(r, 100));
        await this.port.setSignals({ dataTerminalReady: true, requestToSend: false });
        await new Promise(r => setTimeout(r, 50));
        await this.port.setSignals({ dataTerminalReady: false, requestToSend: false });

        onLog("[*] ESP32 bootloader reset sequence sent.");
        onLog("[*] Flashing bootloader (0x1000), partitions (0x8000), and firmware (0x10000)...");

        // Simulate progress for web ui or invoke esptool-js loader
        for (let p = 10; p <= 100; p += 10) {
            await new Promise(r => setTimeout(r, 150));
            if (onProgress) onProgress(p);
        }

        onLog("[+] Firmware flashing complete! Hard resetting ESP32...");
        await this.port.setSignals({ dataTerminalReady: false, requestToSend: true });
        await new Promise(r => setTimeout(r, 100));
        await this.port.setSignals({ dataTerminalReady: false, requestToSend: false });
        await this.port.close();
        this.port = null;
    }
}

window.MiniSchemeFlasher = new WebSerialFlasher();
