/**
 * @file app.js
 * @brief MiniScheme WASM WebREPL Application Logic.
 *
 * The WASM module holds two VMs: a compiler VM (compiler.scm) that turns
 * source into MSBC bytecode, and a device VM configured like the ESP32
 * firmware that executes that bytecode and renders through the same RGB565
 * band pipeline. The same bytecode can instead be sent to real hardware over
 * HTTP or Web Serial (see device_link.js).
 */

let wasmInstance = null;
let wasmMemory = null;
let history = [];
let historyIdx = -1;

const terminal = document.getElementById('terminal');
const cmdInput = document.getElementById('cmd-input');
const sendBtn = document.getElementById('send-btn');
const targetMode = document.getElementById('target-mode');
const targetDesc = document.getElementById('target-desc');
const statusDot = document.getElementById('status-dot');
const statusText = document.getElementById('device-status-text');
const acPopup = document.getElementById('ac-popup');
const acList = document.getElementById('ac-list');
const acCloseBtn = document.getElementById('ac-close-btn');

// Virtual LCD & Hardware Simulation Elements
const canvas = document.getElementById('virtual-lcd');
const ledWifi = document.getElementById('led-wifi');
const ledGpio2 = document.getElementById('led-gpio2');
const simWifiStatus = document.getElementById('sim-wifi-status');
const simWifiSsid = document.getElementById('sim-wifi-ssid');
const simWifiIp = document.getElementById('sim-wifi-ip');
const simWifiRssi = document.getElementById('sim-wifi-rssi');
const hwBacklightBadge = document.getElementById('hw-backlight-badge');
const btnHwK18 = document.getElementById('btn-hw-k18');
const simLightSlider = document.getElementById('sim-light-slider');
const simLightVal = document.getElementById('sim-light-val');

// Simulation Toolbar & Telemetry Elements
const simResolutionSelect = document.getElementById('sim-resolution-select');
const simSpeedSelect = document.getElementById('sim-speed-select');
const simFbSelect = document.getElementById('sim-fb-select');
const simBppSelect = document.getElementById('sim-bpp-select');
const simPaletteSelect = document.getElementById('sim-palette-select');
const simBppItem = document.getElementById('sim-bpp-item');
const simPaletteItem = document.getElementById('sim-palette-item');
const lcdEnclosure = document.getElementById('lcd-enclosure');
const lcdBrandText = document.getElementById('lcd-brand-text');
const devVmMode = document.getElementById('dev-vm-mode');
const devHeapAlloc = document.getElementById('dev-heap-alloc');
const devHeapCapacity = document.getElementById('dev-heap-capacity');
const devVfbRam = document.getElementById('dev-vfb-ram');
const devVfbEstimate = document.getElementById('dev-vfb-estimate');
const devEsp32Estimate = document.getElementById('dev-esp32-estimate');
const devSramTotalEstimate = document.getElementById('dev-sram-total-estimate');
const devIramRow = document.getElementById('dev-iram-row');   // the board's IRAM-only heap (hardware only)
const devIram = document.getElementById('dev-iram');
const heapProgressFill = document.getElementById('heap-progress-fill');
const heapProgressText = document.getElementById('heap-progress-text');
const devExecTime = document.getElementById('dev-exec-time');

let currentSpeedMode = 240; // 240 = ESP32 240MHz typical, 80 = 80MHz, 0 = PC unthrottled
let currentLcdWidth = 320;
let currentLcdHeight = 480;
let lastFlushTimestamp = 0;

let vfbImageData = null;
let serialStill = false;   // a serial screenshot is on the canvas (app.js: takeSerialScreenshot)
let vfbPixelBuf32 = null;
let isTouchDown = false;
let appActive = false;
// The WASM device's simulated flash (file system + font ROM), kept in IndexedDB
const simStorage = new SimStorage();

// Initialize MiniScheme VM inside WebAssembly
async function initWasm() {
    try {
        const importObject = {
            env: {
                sin: Math.sin,
                cos: Math.cos,
                tan: Math.tan,
                asin: Math.asin,
                acos: Math.acos,
                atan: Math.atan,
                atan2: Math.atan2,
                pow: Math.pow,
                log: Math.log,
                exp: Math.exp,
                sqrt: Math.sqrt,
                floor: Math.floor,
                ceil: Math.ceil,
                round: Math.round,
                fabs: Math.abs,
                js_now_ms: () => performance.now(),
                js_print: (ptr, len) => {
                    if (!wasmMemory) return;
                    const bytes = new Uint8Array(wasmMemory.buffer, ptr, len);
                    const str = new TextDecoder('utf-8').decode(bytes);
                    console.log("[WASM stdout]:", str);
                    appendTerminalLine('info', str.trim());
                }
            }
        };

        let response = await fetch('wasm/minischeme_vm.wasm');
        if (!response.ok) {
            response = await fetch('minischeme_vm.wasm');
        }
        if (!response.ok) {
            throw new Error(`HTTP ${response.status} fetching minischeme_vm.wasm`);
        }
        const bytes = await response.arrayBuffer();
        const results = await WebAssembly.instantiate(bytes, importObject);
        wasmInstance = results.instance;
        wasmMemory = wasmInstance.exports.memory;

        // Saved flash first: config.ini ([fonts]) and the font ROM apply at boot
        const restored = await simStorage.restore(wasmInstance.exports, () => wasmMemory);
        simStorage.onError = (e) => appendTerminalLine('error', `模拟 Flash 无法保存到浏览器: ${e.message || e}`);
        // An empty font ROM gets the firmware's factory image (simsun-16, all of GB2312)
        const factoryFonts = await simStorage.installFactoryFontRom(wasmInstance.exports, () => wasmMemory);

        if (wasmInstance.exports.wasm_init) {
            const initRet = wasmInstance.exports.wasm_init();
            if (initRet !== 0) {
                console.error("wasm_init returned error code:", initRet);
                if (statusText) statusText.textContent = "WASM VM 初始化失败";
                if (statusDot) {
                    statusDot.className = "status-indicator offline";
                    statusDot.title = "WASM VM 初始化失败";
                }
                return;
            }
        }

        window.syncWasmProxyUrl = function(customUrl) {
            if (!wasmInstance || !wasmInstance.exports) return;
            let url = customUrl || window.LOCAL_SERVER_BASE || 'http://127.0.0.1:8087';
            if (window.DeviceSetupWizard && !window.DeviceSetupWizard.isSupportedProxyUrl(url)) {
                url = window.LOCAL_SERVER_BASE || 'http://127.0.0.1:8087';
            }
            if (typeof wasmInstance.exports.wasm_set_proxy_url === 'function' && typeof wasmInstance.exports.wasm_alloc_buffer === 'function') {
                const bytes = new TextEncoder().encode(url + '\0');
                const ptr = wasmInstance.exports.wasm_alloc_buffer(bytes.length);
                new Uint8Array(wasmMemory.buffer, ptr, bytes.length).set(bytes);
                wasmInstance.exports.wasm_set_proxy_url(ptr);
                wasmInstance.exports.wasm_free_buffer(ptr);
            }
        };
        window.syncWasmProxyUrl();

        console.log(`MiniScheme Native VM + Scheme Compiler (WASM) ready! (${bytes.byteLength} bytes)`);
        if (statusText) statusText.textContent = "WASM 原生 VM + Scheme 优化编译器已就绪";
        if (statusDot) {
            statusDot.className = "status-indicator online";
            statusDot.title = "WASM 原生 VM + Scheme 优化编译器已就绪";
        }
        // Initialize default vertical resolution 320x480 & ESP32 240MHz speed mode
        setSimulatorResolution(320, 480, true);
        if (wasmInstance.exports.wasm_set_cpu_speed_mode) {
            wasmInstance.exports.wasm_set_cpu_speed_mode(currentSpeedMode);
        }

        // Parse URL query parameters for simulator auto-configuration:
        const urlParams = new URLSearchParams(window.location.search);
        const fbParam = urlParams.get('fb');
        const bppParam = urlParams.get('bpp');
        const palParam = urlParams.get('palette');
        const resParam = urlParams.get('res');
        const speedParam = urlParams.get('speed');

        if (resParam) {
            const parts = resParam.split('x');
            if (parts.length === 2) {
                setSimulatorResolution(parseInt(parts[0], 10), parseInt(parts[1], 10), true);
                if (simResolutionSelect) simResolutionSelect.value = resParam;
            }
        }

        if (speedParam) {
            currentSpeedMode = parseInt(speedParam, 10);
            if (simSpeedSelect) simSpeedSelect.value = speedParam;
            if (wasmInstance.exports.wasm_set_cpu_speed_mode) {
                wasmInstance.exports.wasm_set_cpu_speed_mode(currentSpeedMode);
            }
        }

        // ?fb=1 / ?display=direct, ?bpp=4, ?palette=green (name or scheme number)
        if (fbParam === '1' || fbParam === 'true') setDisplayMode('1', true);
        else if (urlParams.get('display') === 'direct') setDisplayMode('0', true);
        if (urlParams.get('ntp') === '0') wasmInstance.exports.wasm_set_time_synced(0);
        if (bppParam && simBppSelect) simBppSelect.value = bppParam;
        if (palParam && simPaletteSelect) {
            const byName = SIM_SCHEMES.indexOf(palParam);
            simPaletteSelect.value = String(byName >= 0 ? byName : parseInt(palParam, 10) || 0);
        }
        applySimDisplay(false);

        // Initialize simulation Canvas & LEDs
        renderVfbToCanvas();
        syncHardwareTelemetry();

        // Start hardware simulation animation loop
        requestAnimationFrame(simLoop);

        if (restored) {
            appendTerminalLine('info', `💾 已恢复浏览器中保存的模拟 Flash: 文件系统 ${restored.files} 个文件` +
                (restored.rom ? '，系统字库分区' : '') + ' (文件管理中可清空)');
        }
        if (factoryFonts) {
            appendTerminalLine('info', `🔤 系统字库: 已装入固件自带的宋体 16px (GB2312 一、二级汉字，${Math.round(factoryFonts / 1024)} KB)`);
        }
        // Power on: the app installed in the simulated file system, else the bundled calendar
        await bootWasmDevice('开机', true);
        if (!restored) simStorage.markClean(wasmInstance.exports);
        setInterval(simHousekeeping, 250);

    } catch (e) {
        console.error("Failed to load minischeme_vm.wasm:", e);
        if (statusText) statusText.textContent = "WASM 模块加载失败";
        if (statusDot) {
            statusDot.className = "status-indicator offline";
            statusDot.title = `WASM 模块加载失败: ${e.message}`;
        }
        appendTerminalLine("error", `❌ 无法加载 minischeme_vm.wasm: ${e.message}`);
    }
}

// Pass a JS string into WASM heap memory
function passStringToWasm(str) {
    const encoder = new TextEncoder();
    const encoded = encoder.encode(str + '\0');
    const ptr = wasmInstance.exports.malloc(encoded.length);
    const dest = new Uint8Array(wasmMemory.buffer, ptr, encoded.length);
    dest.set(encoded);
    return ptr;
}

// Read a null-terminated UTF-8 string from WASM heap memory
function readStringFromWasm(ptr) {
    if (!ptr) return "";
    const mem = new Uint8Array(wasmMemory.buffer);
    let end = ptr;
    while (end < mem.length && mem[end] !== 0) end++;
    return new TextDecoder('utf-8').decode(mem.subarray(ptr, end));
}

// Compile Scheme source text using the Scheme compiler in WASM
function compileWithWasm(source) {
    if (!wasmInstance) {
        return { success: false, error: "WASM compiler not loaded" };
    }
    const t0 = performance.now();
    const srcPtr = passStringToWasm(source);
    const msbcPtr = wasmInstance.exports.wasm_compile(srcPtr);
    const t1 = performance.now();
    const compileTime = (t1 - t0).toFixed(2);

    if (msbcPtr === 0) {
        const errPtr = wasmInstance.exports.wasm_get_error();
        const errStr = readStringFromWasm(errPtr);
        wasmInstance.exports.free(srcPtr);
        return { success: false, error: errStr || "Compilation failed", compileTimeMs: compileTime };
    }

    const msbcSize = wasmInstance.exports.wasm_get_msbc_size();
    const bytes = new Uint8Array(wasmMemory.buffer, msbcPtr, msbcSize);
    
    // Convert binary to hex string
    let hex = "";
    for (let i = 0; i < msbcSize; i++) {
        hex += bytes[i].toString(16).padStart(2, '0');
    }

    // Disassemble the very code object that was serialized
    const disasmStr = readStringFromWasm(wasmInstance.exports.wasm_disasm_last());

    wasmInstance.exports.free(srcPtr);

    return {
        success: true,
        bytes: new Uint8Array(bytes),
        bytecode_hex: hex,
        byte_len: msbcSize,
        disasm: disasmStr,
        compileTimeMs: compileTime
    };
}

// Evaluate Scheme expression locally in the browser's WASM VM
function evalLocalWasm(source) {
    if (!wasmInstance) {
        return { success: false, result: "WASM VM not loaded", error: "WASM VM not loaded" };
    }
    const t0 = performance.now();
    const srcPtr = passStringToWasm(source);
    const resPtr = wasmInstance.exports.wasm_eval(srcPtr);
    const t1 = performance.now();
    const resStr = readStringFromWasm(resPtr);
    wasmInstance.exports.free(srcPtr);
    pumpDisplay();
    return finishLocalResult(resStr, t0, t1);
}

// Run the most recent wasm_compile() output on the device VM
function execLastOnWasmDevice() {
    const t0 = performance.now();
    const resStr = readStringFromWasm(wasmInstance.exports.wasm_exec_last());
    const t1 = performance.now();
    pumpDisplay();
    return finishLocalResult(resStr, t0, t1);
}

// Run an MSBC / FASL image on the device VM
// Boot an app image like the board does: fresh device VM, code run in place
// from a Code ROM image. Falls back to a RAM run for older WASM builds.
function bootAppOnWasmDevice(bytes) {
    deviceSymbolsStale = true;
    if (!wasmInstance.exports.wasm_boot_app) return execBytesOnWasmDevice(bytes);
    const ptr = wasmInstance.exports.wasm_alloc_buffer(bytes.length);
    new Uint8Array(wasmMemory.buffer, ptr, bytes.length).set(bytes);
    const resStr = readStringFromWasm(wasmInstance.exports.wasm_boot_app(ptr, bytes.length));
    wasmInstance.exports.wasm_free_buffer(ptr);
    pumpDisplay();
    return resStr;
}

function execBytesOnWasmDevice(bytes) {
    deviceSymbolsStale = true;
    const ptr = wasmInstance.exports.wasm_alloc_buffer(bytes.length);
    new Uint8Array(wasmMemory.buffer, ptr, bytes.length).set(bytes);
    const resStr = readStringFromWasm(wasmInstance.exports.wasm_run_payload(ptr, bytes.length));
    wasmInstance.exports.wasm_free_buffer(ptr);
    pumpDisplay();
    return resStr;
}

let lastBandError = '';

// Mirror of the firmware main loop's service_display(): re-render invalidated bands
function pumpDisplay() {
    if (!wasmInstance || !wasmInstance.exports.wasm_service_display) return;
    const r = wasmInstance.exports.wasm_service_display();
    if (r > 0) wasmFrames++;
    if (r < 0) {
        const err = readStringFromWasm(wasmInstance.exports.wasm_get_band_error());
        let detail = '';
        if (wasmInstance.exports.wasm_get_band_error_detail) {
            detail = readStringFromWasm(wasmInstance.exports.wasm_get_band_error_detail());
        }
        if (err && err !== lastBandError) {
            lastBandError = err;
            appendTerminalLine('error', `渲染错误 (与硬件一致): ${err}`);
            if (detail) {
                console.error('[WASM Render Error Detail]:\n' + detail);
                appendTerminalLine('error', `[调试调用栈追踪]:\n${detail}`);
                appendTerminalLine('info', '💡 提示: 若模拟文件系统缓存了旧版应用，可在控制台输入 resetSimulatorApp() 重置开机应用');
            }
        }
    }
    renderVfbToCanvas();
    syncHardwareTelemetry();
}

async function resetSimulatorApp() {
    try {
        if (wasmInstance && wasmInstance.exports.wasm_fs_remove) {
            const ptr = passStringToWasm('/spiffs/app.msbc');
            wasmInstance.exports.wasm_fs_remove(ptr);
            wasmInstance.exports.wasm_free_buffer(ptr);
        }
        appendTerminalLine('info', '已重置模拟器开机应用缓存，与板子一样进入内置系统设置...');
        await bootBundledApp('重置应用缓存: ', 'settings');
    } catch (e) {
        appendTerminalLine('error', `重置应用失败: ${e.message || e}`);
    }
}
window.resetSimulatorApp = resetSimulatorApp;

function finishLocalResult(resStr, t0, t1) {
    const wasmTimeUs = Math.round((t1 - t0) * 1000);

    // Fit execution latency according to simulated ESP32 frequency
    let simulatedUs = wasmTimeUs;
    if (currentSpeedMode === 240) {
        simulatedUs = Math.max(wasmTimeUs * 14, 180);
    } else if (currentSpeedMode === 80) {
        simulatedUs = Math.max(wasmTimeUs * 42, 540);
    }

    if (devExecTime) {
        if (currentSpeedMode > 0) {
            devExecTime.textContent = `${(simulatedUs / 1000).toFixed(2)} ms (ESP32 ${currentSpeedMode}M拟合, WASM: ${wasmTimeUs} μs)`;
        } else {
            devExecTime.textContent = `${wasmTimeUs} μs (PC WASM极速)`;
        }
    }

    // (restart) stops the code like esp_restart(); simLoop reboots the device
    const rebooting = resStr.includes('the simulated device is rebooting');
    return {
        success: rebooting || !resStr.startsWith("Error:"),
        result: rebooting ? '⏻ 模拟设备正在重启 (重新读取 config.ini，启动开机应用)' : resStr,
        execTimeUs: simulatedUs,
        wasmTimeUs: wasmTimeUs
    };
}

/**
 * Powers the WASM device on again, as the board does after (restart): a
 * fresh device VM reads config.ini, then the installed /spiffs/app.fasl or
 * app.msbc boots, else the bundled calendar (the firmware's embedded app).
 */
async function bootWasmDevice(why, firstBoot = false) {
    const ex = wasmInstance && wasmInstance.exports;
    if (!ex) return;
    if (!ex.wasm_reboot) {
        await bootBundledApp('', 'calendar');
        return;
    }
    stopPcMonitor();
    appActive = false;
    deviceSymbolsStale = true;
    const r = readStringFromWasm(ex.wasm_reboot());
    if (typeof window.syncWasmProxyUrl === 'function') {
        window.syncWasmProxyUrl();
    }
    if (r === '') {
        // as the firmware: no app installed (or boot_app empty / settings) -> the built-in settings
        if (firstBoot) {
            await bootBundledApp('', 'settings');
            return;
        }
        await bootBundledApp(`${why}: 未安装应用，进入内置系统设置；`, 'settings');
        return;
    }
    pumpDisplay();
    if (r.startsWith('Error:') && ex.wasm_failed && ex.wasm_failed()) {
        // as the firmware: the reason on the screen, the system settings in 5 s
        appendTerminalLine('error', `${why}: 开机应用失败: ${r.slice(7)}；5 秒后进入系统设置`);
        return;
    }
    if (r.startsWith('Error:')) {
        appendTerminalLine('error', `${why}: 开机应用启动失败: ${r}`);
        await bootBundledApp(`${why}: 改为`, 'calendar');
        return;
    }
    appActive = true;
    clockTick(true);
    pcmonTimer = setInterval(pcmonPump, APP_LOOP_MS); // app loop: app-step + the app's JSON feed
    appendTerminalLine('output', `=> ${why}: 已从模拟文件系统启动开机应用 (${r})`);
}

// Terminal UI helpers
function appendTerminalLine(type, text) {
    const line = document.createElement('div');
    line.className = `term-line ${type}`;
    if (type === 'input') {
        line.innerHTML = `<span class="prompt">minischeme&gt;</span> ${escapeHtml(text)}`;
    } else {
        line.textContent = text;
    }
    terminal.appendChild(line);
    terminal.scrollTop = terminal.scrollHeight;
}

function escapeHtml(str) {
    return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

// =========================================================================
// Dynamic LCD Resolution & Multi-Orientation Framebuffer Driver
// =========================================================================

function setSimulatorResolution(width, height, skipRender = false) {
    currentLcdWidth = width;
    currentLcdHeight = height;

    if (canvas) {
        canvas.width = width;
        canvas.height = height;
    }
    vfbImageData = null;
    vfbPixelBuf32 = null;

    if (lcdEnclosure) {
        if (height > width) {
            lcdEnclosure.classList.add('portrait');
            lcdEnclosure.classList.remove('landscape');
        } else {
            lcdEnclosure.classList.add('landscape');
            lcdEnclosure.classList.remove('portrait');
        }
    }

    if (wasmInstance && wasmInstance.exports.wasm_set_resolution) {
        wasmInstance.exports.wasm_set_resolution(width, height);
    }

    if (!skipRender && wasmInstance) {
        wasmInstance.exports.wasm_app_render();
        pumpDisplay();
    }
}

// Resolution dropdown selector listener
if (simResolutionSelect) {
    simResolutionSelect.addEventListener('change', (e) => {
        const parts = e.target.value.split('x');
        if (parts.length === 2) {
            const w = parseInt(parts[0], 10);
            const h = parseInt(parts[1], 10);
            setSimulatorResolution(w, h);
            appendTerminalLine('info', `📐 [屏幕分辨率切换] ➔ ${w}×${h} (${h > w ? '竖屏' : '横屏'}), Scheme 自适应重排已生效`);
        }
    });
}

// Speed throttle mode selector listener
if (simSpeedSelect) {
    simSpeedSelect.addEventListener('change', (e) => {
        currentSpeedMode = parseInt(e.target.value, 10);
        if (wasmInstance && wasmInstance.exports.wasm_set_cpu_speed_mode) {
            wasmInstance.exports.wasm_set_cpu_speed_mode(currentSpeedMode);
        }
        let desc = "PC WASM 极速无延迟";
        if (currentSpeedMode === 240) desc = "ESP32 240MHz 典型 (整屏刷新约 35ms：板上实测，13.3 MHz 8 位并口)";
        if (currentSpeedMode === 80) desc = "ESP32 80MHz 节能 (整屏刷新约 70ms：估算，未实测)";
        appendTerminalLine('info', `⏱️ [运行速度拟合模式] ➔ ${desc}`);
        syncHardwareTelemetry();
    });
}

// Display pipeline: "band" (firmware), "0" (direct), "1" (framebuffer)
function setDisplayMode(value, silent) {
    if (!wasmInstance) return;
    const mode = value === 'band' ? 0 : (value === '1' ? 2 : 1);
    wasmInstance.exports.wasm_set_display_mode(mode);
    if (simFbSelect) simFbSelect.value = value;
    wasmDisplayMode = mode;
    showWasmModeTag();
    if (!silent) {
        wasmInstance.exports.wasm_app_render();
        pumpDisplay();
    }
}

// Simulator display settings mirror [display] mode / color_bits / palette in
// config.ini: buffer mode, color bits and color scheme are independent
const SIM_SCHEMES = ['color', 'gray', 'eink', 'green', 'amber', 'cyan', 'gameboy', 'invert'];
const SIM_MODE_NAMES = { band: '条带 band', '1': '全帧 full', '0': '直驱 direct' };

function applySimDisplay(announce) {
    if (!wasmInstance) return;
    const ex = wasmInstance.exports;
    const bits = parseInt(simBppSelect ? simBppSelect.value : '16', 10);
    const scheme = parseInt(simPaletteSelect ? simPaletteSelect.value : '0', 10);
    if (ex.wasm_set_color_depth) ex.wasm_set_color_depth(bits);
    if (ex.wasm_set_color_scheme) ex.wasm_set_color_scheme(scheme);
    ex.wasm_app_render();
    pumpDisplay();
    if (announce) {
        const ram = ex.wasm_get_framebuffer_ram ? ex.wasm_get_framebuffer_ram() : 0;
        const mode = SIM_MODE_NAMES[simFbSelect ? simFbSelect.value : 'band'] || '';
        appendTerminalLine('info', `🖥️ [显示] ${mode} · ${bits}-bit · ${SIM_SCHEMES[scheme] || scheme} · 缓冲 ${(ram / 1024).toFixed(1)} KB` +
            ` (config.ini: mode / color_bits / palette)`);
    }
}

if (simFbSelect) {
    simFbSelect.addEventListener('change', (e) => {
        setDisplayMode(e.target.value, true);
        applySimDisplay(true);
    });
}
if (simBppSelect) simBppSelect.addEventListener('change', () => { applySimDisplay(true); syncDisplayToDevice(); });
if (simPaletteSelect) simPaletteSelect.addEventListener('change', () => { applySimDisplay(true); syncDisplayToDevice(); });

// WiFi Online / Offline simulator switch (default enabled/open)
window.SIM_WIFI_ENABLED = true;

window.isSimWifiOnline = function() {
    return window.SIM_WIFI_ENABLED !== false;
};

window.setSimWifiOnline = function(online, sourceEl) {
    window.SIM_WIFI_ENABLED = !!online;
    const isOnline = window.SIM_WIFI_ENABLED;

    const toggle = document.getElementById('sim-wifi-toggle');
    if (toggle && toggle !== sourceEl) toggle.checked = isOnline;

    const toggleText = document.getElementById('sim-wifi-toggle-text');
    if (toggleText) {
        toggleText.textContent = isOnline ? '已联网' : '已断开';
        toggleText.className = isOnline ? 'online' : 'offline';
    }

    const ledWifi = document.getElementById('led-wifi');
    if (ledWifi) {
        if (isOnline) ledWifi.classList.add('active');
        else ledWifi.classList.remove('active');
    }

    const awOnline = document.getElementById('aw-sys-wifi-online');
    if (awOnline && awOnline !== sourceEl) awOnline.checked = isOnline;

    const dsOnline = document.getElementById('ds-wifi-enable');
    if (dsOnline && dsOnline !== sourceEl) dsOnline.checked = isOnline;

    appendTerminalLine(isOnline ? 'info' : 'warn',
        isOnline ? '📶 [WASM 模拟器] WiFi 已连接 (网络在线)' : '📶 [WASM 模拟器] WiFi 已断开 (网络离线)');
};

const simWifiToggle = document.getElementById('sim-wifi-toggle');
if (simWifiToggle) {
    simWifiToggle.addEventListener('change', (e) => {
        window.setSimWifiOnline(e.target.checked, e.target);
    });
}

const ledWifiEl = document.getElementById('led-wifi');
if (ledWifiEl) {
    ledWifiEl.style.cursor = 'pointer';
    ledWifiEl.addEventListener('click', () => {
        window.setSimWifiOnline(!window.isSimWifiOnline());
    });
}

// Dynamic brightness calculation algorithm
// Bounded within [0, 255] and [minVal, maxVal], dynamically calculated from raw photoresistor reading (0~4095)
// combined with brightness offset exponent gamma = 0.5 * 2^(-offset / 5.0).
window.calcDynamicBacklight = function(lightRaw, minVal = 30, maxVal = 255, offset = 0) {
    let minB = Math.max(0, Math.min(255, parseInt(minVal, 10) || 0));
    let maxB = Math.max(0, Math.min(255, parseInt(maxVal, 10) || 255));
    if (minB > maxB) { const t = minB; minB = maxB; maxB = t; }
    const off = Math.max(-10, Math.min(10, parseInt(offset, 10) || 0));
    const raw = Math.max(0, Math.min(4095, parseInt(lightRaw, 10) || 0));
    const x = raw / 4095.0;
    if (x <= 0) return minB;
    if (x >= 1) return maxB;
    const gamma = 0.5 * Math.pow(2.0, -off / 5.0);
    const ratio = Math.pow(x, gamma);
    const target = Math.round(minB + (maxB - minB) * ratio);
    return Math.max(minB, Math.min(maxB, Math.max(0, Math.min(255, target))));
};

window.updateSimBrightnessConfig = function(cfg) {
    if (!cfg) return;
    if (!wasmInstance || !wasmInstance.exports) return;
    const ex = wasmInstance.exports;
    if (ex.wasm_set_backlight_params && cfg.offset !== undefined) {
        ex.wasm_set_backlight_params(cfg.offset, cfg.min, cfg.max);
    }
    if (ex.wasm_set_backlight_auto && cfg.autoBacklight !== undefined) {
        ex.wasm_set_backlight_auto(cfg.autoBacklight ? 1 : 0);
    }
    if (!cfg.autoBacklight && ex.wasm_set_backlight && cfg.backlight !== undefined) {
        ex.wasm_set_backlight(cfg.backlight);
    }
    syncHardwareTelemetry();
};

/** The board when linked over HTTP (display, button and light go to it), else null */
function httpDevice() {
    return activeLink && activeLink.kind === 'http' && typeof activeLink.input === 'function' ? activeLink : null;
}

/** The board that takes KEY 18: linked over HTTP or the serial port */
function inputDevice() {
    return activeLink && (activeLink.kind === 'http' || activeLink.kind === 'serial') &&
        typeof activeLink.input === 'function' ? activeLink : null;
}

/* Color bits and scheme of the panel applied on the board and kept in its config.ini */
async function syncDisplayToDevice() {
    const link = httpDevice();
    if (!link) return;
    const bits = parseInt(simBppSelect ? simBppSelect.value : '16', 10);
    const palette = SIM_SCHEMES[parseInt(simPaletteSelect ? simPaletteSelect.value : '0', 10)] || 'color';
    try {
        const r = await link.display({ bits, palette });
        appendTerminalLine('info', `🖥️ [硬件显示] ${r.color_bits}-bit · ${r.palette} · 缓冲 ${(r.buffer_bytes / 1024).toFixed(1)} KB` +
            (r.saved ? '，已保存到 config.ini [display]' : '，但保存 config.ini 失败 (重启后恢复原设置)'));
    } catch (e) {
        appendTerminalLine('error', `设置硬件显示失败: ${e.message}`);
    }
}

/* The panel's selects show the board's settings after connecting */
function adoptDeviceDisplay(st) {
    if (simBppSelect && st.color_bits) simBppSelect.value = String(st.color_bits);
    const scheme = SIM_SCHEMES.indexOf(st.palette);
    if (simPaletteSelect && scheme >= 0) simPaletteSelect.value = String(scheme);
    applySimDisplay(false);
}

// =========================================================================
// Virtual Framebuffer Canvas Blitter & Real-Time Telemetry
// =========================================================================

function renderVfbToCanvas(forceFull = false) {
    if (!wasmInstance || !wasmMemory || !canvas) return;
    if (hwMirror.active || serialStill || serialLinked()) return; // the board's screen is shown (HTTP mirror, serial)
    const ctx = canvas.getContext('2d');
    const width = wasmInstance.exports.wasm_get_vfb_width ? wasmInstance.exports.wasm_get_vfb_width() : currentLcdWidth;
    const height = wasmInstance.exports.wasm_get_vfb_height ? wasmInstance.exports.wasm_get_vfb_height() : currentLcdHeight;
    const vfbPtr = wasmInstance.exports.wasm_get_vfb_ptr ? wasmInstance.exports.wasm_get_vfb_ptr() : 0;

    if (!vfbPtr || width <= 0 || height <= 0) return;

    if (canvas.width !== width || canvas.height !== height) {
        canvas.width = width;
        canvas.height = height;
        vfbImageData = null;
        vfbPixelBuf32 = null;
    }

    const total = width * height;
    const vfb = new Uint16Array(wasmMemory.buffer, vfbPtr, total);

    if (!vfbImageData || vfbImageData.width !== width || vfbImageData.height !== height) {
        vfbImageData = ctx.createImageData(width, height);
        vfbPixelBuf32 = new Uint32Array(vfbImageData.data.buffer);
    }

    const buf32 = vfbPixelBuf32;

    let dx = 0, dy = 0, dw = width, dh = height;
    let isPartial = false;
    if (!forceFull && wasmInstance.exports.wasm_get_dirty_w) {
        const dirtyW = wasmInstance.exports.wasm_get_dirty_w();
        const dirtyH = wasmInstance.exports.wasm_get_dirty_h();
        if (dirtyW > 0 && dirtyH > 0 && (dirtyW < width || dirtyH < height)) {
            dx = wasmInstance.exports.wasm_get_dirty_x();
            dy = wasmInstance.exports.wasm_get_dirty_y();
            dw = dirtyW;
            dh = dirtyH;
            isPartial = true;
        }
    }

    if (isPartial) {
        // Partial refresh: unpack only dirty rectangle
        for (let r = dy; r < dy + dh; r++) {
            const rowOffset = r * width;
            for (let c = dx; c < dx + dw; c++) {
                const idx = rowOffset + c;
                const rgb565 = vfb[idx];
                const red = (rgb565 >> 11) & 0x1F;
                const green = (rgb565 >> 5) & 0x3F;
                const blue = rgb565 & 0x1F;
                const r8 = (red << 3) | (red >> 2);
                const g8 = (green << 2) | (green >> 4);
                const b8 = (blue << 3) | (blue >> 2);
                buf32[idx] = (255 << 24) | (b8 << 16) | (g8 << 8) | r8;
            }
        }
        ctx.putImageData(vfbImageData, 0, 0, dx, dy, dw, dh);
    } else {
        // Full unpack
        for (let i = 0; i < total; i++) {
            const rgb565 = vfb[i];
            const red = (rgb565 >> 11) & 0x1F;
            const green = (rgb565 >> 5) & 0x3F;
            const blue = rgb565 & 0x1F;
            const r8 = (red << 3) | (red >> 2);
            const g8 = (green << 2) | (green >> 4);
            const b8 = (blue << 3) | (blue >> 2);
            buf32[i] = (255 << 24) | (b8 << 16) | (g8 << 8) | r8;
        }
        ctx.putImageData(vfbImageData, 0, 0);
    }

    if (wasmInstance.exports.wasm_clear_vfb_dirty) {
        wasmInstance.exports.wasm_clear_vfb_dirty();
    }
}

function syncHardwareTelemetry() {
    if (!wasmInstance) return;
    if (hwMirror.active) return; // the board's figures come from /api/stats

    // 1. GPIO 2 (Green User LED)
    if (wasmInstance.exports.wasm_get_pin_level && ledGpio2) {
        const io2Level = wasmInstance.exports.wasm_get_pin_level(2);
        if (io2Level > 0) {
            ledGpio2.classList.add('active');
        } else {
            ledGpio2.classList.remove('active');
        }
    }

    // 2. WiFi Status & Telemetry
    if (wasmInstance.exports.wasm_get_wifi_status && ledWifi) {
        const connected = wasmInstance.exports.wasm_get_wifi_status() !== 0;
        if (connected) {
            ledWifi.classList.add('active');
            if (simWifiStatus) {
                simWifiStatus.textContent = "已连接 (Connected)";
                simWifiStatus.style.color = "#10b981";
            }
            if (simWifiSsid) {
                simWifiSsid.textContent = readStringFromWasm(wasmInstance.exports.wasm_get_wifi_ssid());
            }
            if (simWifiIp) {
                simWifiIp.textContent = readStringFromWasm(wasmInstance.exports.wasm_get_wifi_ip());
            }
            if (simWifiRssi) {
                simWifiRssi.textContent = `${wasmInstance.exports.wasm_get_wifi_rssi()} dBm`;
            }
        } else {
            ledWifi.classList.remove('active');
            if (simWifiStatus) {
                simWifiStatus.textContent = "未连接 (Offline)";
                simWifiStatus.style.color = "#ef4444";
            }
            if (simWifiSsid) simWifiSsid.textContent = "--";
            if (simWifiIp) simWifiIp.textContent = "0.0.0.0";
            if (simWifiRssi) simWifiRssi.textContent = "-- dBm";
        }
    }

    // 3. Backlight PWM (GPIO 22)
    if (wasmInstance.exports.wasm_get_backlight && hwBacklightBadge) {
        const bl = wasmInstance.exports.wasm_get_backlight();
        const pct = Math.round((bl / 255) * 100);
        hwBacklightBadge.textContent = `背光: ${pct}%`;
        if (canvas) {
            const brightness = 0.25 + 0.75 * (bl / 255);
            canvas.style.filter = `brightness(${brightness.toFixed(2)})`;
        }
    }

    // 5. MiniScheme Cheney GC Heap Telemetry & ESP32 Fitting Estimation
    if (wasmInstance.exports.wasm_get_heap_allocated && devHeapAlloc) {
        const totalAlloc = wasmInstance.exports.wasm_get_heap_allocated();
        const cap = wasmInstance.exports.wasm_get_heap_capacity ? wasmInstance.exports.wasm_get_heap_capacity() : (1024 * 1024);
        const baseline = wasmInstance.exports.wasm_get_compiler_baseline_bytes ? wasmInstance.exports.wasm_get_compiler_baseline_bytes() : 0;
        const appAlloc = wasmInstance.exports.wasm_get_app_heap_allocated ? wasmInstance.exports.wasm_get_app_heap_allocated() : Math.max(0, totalAlloc - baseline);

        // The device VM uses the firmware's heap budget, so these are real figures
        const appFootprint = appAlloc;
        const compilerAlloc = wasmInstance.exports.wasm_get_compiler_heap_allocated ? wasmInstance.exports.wasm_get_compiler_heap_allocated() : 0;
        devHeapAlloc.textContent = `${(appFootprint / 1024).toFixed(1)} KB (设备VM) / 编译器VM ${(compilerAlloc / 1024).toFixed(0)} KB`;
        if (devHeapCapacity) {
            devHeapCapacity.textContent = `${(cap / 1024).toFixed(0)} KB (与固件相同)`;
        }

        const esp32Semispace = cap || 98304;
        const pct = Math.min(100, Math.round((appFootprint / esp32Semispace) * 100));

        if (heapProgressFill) {
            heapProgressFill.style.width = `${pct}%`;
            if (pct < 75) {
                heapProgressFill.style.background = 'linear-gradient(90deg, #10b981 0%, #3b82f6 100%)';
            } else if (pct < 90) {
                heapProgressFill.style.background = 'linear-gradient(90deg, #3b82f6 0%, #f59e0b 100%)';
            } else {
                heapProgressFill.style.background = 'linear-gradient(90deg, #f59e0b 0%, #ef4444 100%)';
            }
        }
        if (heapProgressText) {
            heapProgressText.textContent = `${(appFootprint / 1024).toFixed(1)} / ${(esp32Semispace / 1024).toFixed(1)} KB (${pct}%)`;
        }
        if (devEsp32Estimate) {
            if (appFootprint <= 45000) {
                devEsp32Estimate.innerHTML = `<span class="status-badge-ok">🟢 充裕 (板上 VM 堆约 102 KB，当前 ${(appFootprint / 1024).toFixed(1)}KB)</span>`;
            } else if (appFootprint <= esp32Semispace) {
                devEsp32Estimate.innerHTML = `<span class="status-badge-warn">🟡 偏高 (常驻数据超过堆的约 45% 后 GC 变频繁, ${(appFootprint / 1024).toFixed(1)}KB)</span>`;
            } else {
                devEsp32Estimate.innerHTML = `<span class="status-badge-crit">🔴 接近堆上限 (${(appFootprint / 1024).toFixed(1)}KB)</span>`;
            }
        }

        // 6. Framebuffer RAM & Total ESP32 SRAM Pressure
        const fbEnabled = wasmInstance.exports.wasm_get_framebuffer_enabled ? wasmInstance.exports.wasm_get_framebuffer_enabled() : 0;
        const bpp = wasmInstance.exports.wasm_get_color_depth ? wasmInstance.exports.wasm_get_color_depth() : 16;
        const vfbRam = wasmInstance.exports.wasm_get_framebuffer_ram ? wasmInstance.exports.wasm_get_framebuffer_ram() : 0;

        const displayMode = wasmInstance.exports.wasm_get_display_mode ? wasmInstance.exports.wasm_get_display_mode() : 1;
        if (devVfbRam && displayMode === 0) {
            devVfbRam.textContent = `${(vfbRam / 1024).toFixed(1)} KB (13 行 RGB565 条带)`;
        } else if (devVfbRam) {
            if (!fbEnabled || vfbRam === 0) {
                devVfbRam.textContent = "0 KB (直驱关闭)";
            } else {
                devVfbRam.textContent = `${(vfbRam / 1024).toFixed(1)} KB (${bpp}-bit ${bpp === 1 ? '单色' : (1 << bpp) + '色'})`;
            }
        }

        if (devVfbEstimate && displayMode === 0) {
            devVfbEstimate.innerHTML = `<span class="status-badge-ok">🟢 与固件一致 (条带缓冲 ${(vfbRam / 1024).toFixed(1)} KB)</span>`;
        } else if (devVfbEstimate) {
            if (!fbEnabled || vfbRam === 0) {
                devVfbEstimate.innerHTML = `<span class="status-badge-ok">🟢 零显存 (直驱流式传输, 适合标准 ESP32)</span>`;
            } else if (vfbRam <= 40 * 1024) {
                devVfbEstimate.innerHTML = `<span class="status-badge-ok">🟢 超低开销 (<40KB, 内部 SRAM 极充裕)</span>`;
            } else if (vfbRam <= 80 * 1024) {
                devVfbEstimate.innerHTML = `<span class="status-badge-ok">🟢 推荐平衡 (~75KB, 内部 SRAM 安全)</span>`;
            } else if (vfbRam <= 160 * 1024) {
                devVfbEstimate.innerHTML = `<span class="status-badge-warn">🟡 显存偏大 (~150KB, 内部 SRAM 紧张)</span>`;
            } else {
                devVfbEstimate.innerHTML = `<span class="status-badge-crit">🔴 需外部 PSRAM (>180KB 超出内部SRAM)</span>`;
            }
        }

        if (devIramRow) devIramRow.style.display = 'none';   // the simulator has no IRAM
        if (devSramTotalEstimate) {
            const totalSram = appFootprint + ((fbEnabled || displayMode === 0) ? vfbRam : 0);
            if (totalSram <= 65536) {
                devSramTotalEstimate.innerHTML = `<span class="status-badge-ok">🟢 极佳安全 (${(totalSram / 1024).toFixed(1)} KB / ~184 KB 内部SRAM)</span>`;
            } else if (totalSram <= 135000) {
                devSramTotalEstimate.innerHTML = `<span class="status-badge-ok">🟢 正常适配 (${(totalSram / 1024).toFixed(1)} KB / ~184 KB 内部SRAM)</span>`;
            } else if (totalSram <= 184000) {
                devSramTotalEstimate.innerHTML = `<span class="status-badge-warn">🟡 接近芯片极限 (${(totalSram / 1024).toFixed(1)} KB / 184 KB)</span>`;
            } else {
                devSramTotalEstimate.innerHTML = `<span class="status-badge-crit">🔴 超标需PSRAM (${(totalSram / 1024).toFixed(1)} KB > 184 KB)</span>`;
            }
        }
    }
}

// Continuous animation and telemetry frame loop with hardware bus rate fitting
function simLoop(timestamp) {
    if (wasmInstance) {
        // LCD 8-bit parallel bus flush rate: on the board a full 320x480 frame
        // takes ~35 ms on the bus (measured, 13.3 MHz WR clock after the boot
        // check); the 80 MHz figure is an estimate.
        let minFlushInterval = 0;
        if (currentSpeedMode === 240) minFlushInterval = 35;
        else if (currentSpeedMode === 80) minFlushInterval = 70;

        if (wasmInstance.exports.wasm_service_display) {
            wasmInstance.exports.wasm_service_display();
        }
        if (!timestamp || (timestamp - lastFlushTimestamp >= minFlushInterval)) {
            if (wasmInstance.exports.wasm_is_vfb_dirty && wasmInstance.exports.wasm_is_vfb_dirty()) {
                renderVfbToCanvas();
                lastFlushTimestamp = timestamp || performance.now();
            }
        }
        syncHardwareTelemetry();
    }
    requestAnimationFrame(simLoop);
}

// (restart) and saving the simulated flash run on a timer, not on animation
// frames: those stop while the page is in the background
function simHousekeeping() {
    if (!wasmInstance) return;
    if (wasmInstance.exports.wasm_take_restart && wasmInstance.exports.wasm_take_restart()) {
        appendTerminalLine('info', '⏻ (restart): 模拟设备重启中…');
        bootWasmDevice('重启');
    }
    marketService(wasmInstance.exports);
    simStorage.poll(wasmInstance.exports, () => wasmMemory);
}

// The app market of the simulated device (minischeme_market.c): it asks for
// one URL at a time (the index, then each image); the page fetches it
// through server.py, which serves the proxy's /market/ itself
let marketFetching = false;
async function marketService(ex) {
    if (!ex.wasm_market_request || marketFetching) return;
    const url = readStringFromWasm(ex.wasm_market_request());
    if (!url) return;
    if (window.isSimWifiOnline && !window.isSimWifiOnline()) {
        ex.wasm_market_response(0, 0, 0);
        return;
    }
    marketFetching = true;
    let bytes = null, status = 0;
    try {
        const base = localServerBase();
        let res = null;
        if (base) {
            try {
                res = await fetch(base + '/api/fetch?url=' + encodeURIComponent(url), { cache: 'no-store' });
            } catch (be) {}
        }
        if (!res || !res.ok) {
            try {
                res = await fetch(url, { cache: 'no-store' });
            } catch (fe) {}
        }
        if (res && res.ok) {
            bytes = new Uint8Array(await res.arrayBuffer());
            status = 1;
        } else {
            status = res ? -res.status : 0;
        }
    } catch (e) {
        status = 0;
    }
    if (bytes) {
        const ptr = ex.wasm_alloc_buffer(bytes.length || 1);
        new Uint8Array(wasmMemory.buffer, ptr, bytes.length).set(bytes);
        ex.wasm_market_response(ptr, bytes.length, 1);
        ex.wasm_free_buffer(ptr);
    } else {
        ex.wasm_market_response(0, 0, status);
    }
    marketFetching = false;
}

// Leaving the page: save a pending change right away
document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden' && wasmInstance) simStorage.save(wasmInstance.exports, () => wasmMemory);
});

// =========================================================================
// Interactive Touchscreen Simulation (Capacitive Touch 480x320)
// =========================================================================

function getCanvasCoords(e) {
    if (!canvas) return { x: 0, y: 0, clientX: 0, clientY: 0 };
    const rect = canvas.getBoundingClientRect();
    const scaleX = canvas.width / rect.width;
    const scaleY = canvas.height / rect.height;
    const clientX = e.touches ? e.touches[0].clientX : e.clientX;
    const clientY = e.touches ? e.touches[0].clientY : e.clientY;
    const x = Math.max(0, Math.min(canvas.width - 1, Math.round((clientX - rect.left) * scaleX)));
    const y = Math.max(0, Math.min(canvas.height - 1, Math.round((clientY - rect.top) * scaleY)));
    return { x, y, clientX: clientX - rect.left, clientY: clientY - rect.top };
}

function handleTouchDown(e) {
    if (!wasmInstance || hwMirror.active || serialLinked()) return; // the board has no touch panel
    isTouchDown = true;
    const coords = getCanvasCoords(e);

    // Inject touch into WASM virtual hardware
    if (wasmInstance.exports.wasm_inject_touch) {
        wasmInstance.exports.wasm_inject_touch(1, coords.x, coords.y);
    }

    // While an app runs, the touch goes to its handler
    if (appActive) {
        wasmInstance.exports.wasm_app_touch(coords.x, coords.y);
    }
    pumpDisplay();
}

function handleTouchMove(e) {
    if (!wasmInstance || !isTouchDown || hwMirror.active || serialLinked()) return;
    const coords = getCanvasCoords(e);
    if (wasmInstance.exports.wasm_inject_touch) {
        wasmInstance.exports.wasm_inject_touch(1, coords.x, coords.y);
    }
}

function handleTouchUp(e) {
    if (!wasmInstance || hwMirror.active || serialLinked()) return;
    isTouchDown = false;
    const coords = getCanvasCoords(e);
    if (wasmInstance.exports.wasm_inject_touch) {
        wasmInstance.exports.wasm_inject_touch(0, coords.x, coords.y);
    }
}

if (canvas) {
    canvas.addEventListener('mousedown', handleTouchDown);
    canvas.addEventListener('mousemove', handleTouchMove);
    canvas.addEventListener('mouseup', handleTouchUp);
    canvas.addEventListener('mouseleave', handleTouchUp);

    canvas.addEventListener('touchstart', (e) => {
        e.preventDefault();
        handleTouchDown(e);
    }, { passive: false });
    canvas.addEventListener('touchmove', (e) => {
        e.preventDefault();
        handleTouchMove(e);
    }, { passive: false });
    canvas.addEventListener('touchend', (e) => {
        e.preventDefault();
        handleTouchUp(e);
    }, { passive: false });
}

// Hardware Pushbutton GPIO 18 (Active-low pullup). Linked over HTTP, the
// press and the release go to the board (a held button is renewed every
// second, the firmware lets go 3 s after the last renewal), so long presses
// last as long as on the real key.
const K18_RENEW_MS = 1000;
let k18Down = null; // { t0, link, timer } while held

// The WASM device reads KEY 18 like the firmware (mini_device_button_update):
// short, long (0.8 s) and mid (3.5 s) press for the app, hardware pages at 8 s, there a mid press
// opens the system settings (times: config.ini [system] button_*_ms). The
// state is fed on every change and every 40 ms around a press.
const K18_POLL_MS = 40;
const K18_EVENTS = ['', '短按', '短长按', '硬件信息页上中长按 ➔ 系统设置', '长长按 ➔ 硬件信息', '中长按'];
let k18Poll = null, k18Idle = 0;

function k18Feed(pressed) {
    const ex = wasmInstance && wasmInstance.exports;
    if (!ex || !ex.wasm_button_update) return 0;
    const ev = ex.wasm_button_update(pressed ? 1 : 0, Date.now() >>> 0);
    if (ev) {
        appendTerminalLine('info', `🔘 [KEY 18] ${K18_EVENTS[ev] || ev}`);
        pumpDisplay();
    }
    return ev;
}

function k18StartPoll() {
    k18Idle = 0;
    if (k18Poll) return;
    k18Poll = setInterval(() => {
        const down = !!k18Down;
        k18Feed(down);
        if (!down && ++k18Idle > 3) { // the release is confirmed after 30 ms
            clearInterval(k18Poll);
            k18Poll = null;
        }
    }, K18_POLL_MS);
}

function k18Press(e) {
    if (e) e.preventDefault();
    if (k18Down) return;
    btnHwK18.classList.add('pressed');
    const link = inputDevice();
    k18Down = { t0: performance.now(), link, timer: null };
    if (link) {
        const send = () => link.input({ button: true }).catch((err) => appendTerminalLine('error', `按键发送失败: ${err.message}`));
        send();
        k18Down.timer = setInterval(send, K18_RENEW_MS);
        appendTerminalLine('info', `🔘 [KEY 18] 按下 ➔ 已发送到 ${link.label}`);
        return;
    }
    k18Feed(true);
    k18StartPoll();
}

function k18Release() {
    if (!k18Down) return;
    const { t0, link, timer } = k18Down;
    k18Down = null;
    btnHwK18.classList.remove('pressed');
    if (timer) clearInterval(timer);
    if (link) {
        link.input({ button: false }).catch((err) => appendTerminalLine('error', `按键发送失败: ${err.message}`));
        appendTerminalLine('info', `🔘 [KEY 18] 松开 (按住 ${((performance.now() - t0) / 1000).toFixed(1)} s) ➔ 已发送到设备`);
        return;
    }
    k18Feed(false);
    k18StartPoll();
}

if (btnHwK18) {
    btnHwK18.addEventListener('pointerdown', (e) => {
        if (e.button !== 0) return;
        btnHwK18.setPointerCapture(e.pointerId);
        k18Press(e);
    });
    btnHwK18.addEventListener('pointerup', k18Release);
    btnHwK18.addEventListener('pointercancel', k18Release);
    btnHwK18.addEventListener('lostpointercapture', k18Release);
    btnHwK18.addEventListener('contextmenu', (e) => e.preventDefault()); // long touch
}

// Serial link: the page cannot follow the board's screen, a click takes one
// screenshot (@SCREEN); it stays on the canvas until the link closes
const btnHwShot = document.getElementById('btn-hw-shot');
const serialShotView = new HardwareMirror({ canvas });

async function takeSerialScreenshot() {
    const link = activeLink;
    if (!link || link.kind !== 'serial' || typeof link.screenshot !== 'function') return;
    btnHwShot.disabled = true;
    const label = btnHwShot.textContent;
    const t0 = performance.now();
    try {
        const replies = await link.screenshot((rows, h) => {
            btnHwShot.textContent = `⏳ ${Math.round(rows * 100 / Math.max(1, h))}%`;
        });
        if (activeLink !== link) return;
        serialStill = true;
        const flags = serialShotView.drawReplies(replies);
        const secs = ((performance.now() - t0) / 1000).toFixed(1);
        if (flags & 2) {
            appendTerminalLine('error', '📷 设备是 direct 显示模式，不保存像素，无法截图 (config.ini 中改用 band 或 full)');
            return;
        }
        const bytes = replies.reduce((n, b) => n + b.length, 0);
        if (lcdModeTagEl) {
            lcdModeTagEl.textContent = `📷 串口截图 ${new Date().toLocaleTimeString()}`;
            lcdModeTagEl.title = '设备屏幕的一次截图 (串口)，再点“截图”更新';
        }
        appendTerminalLine('info', `📷 [串口截图] ${(bytes / 1024).toFixed(1)} KB，${secs} s`);
    } catch (e) {
        appendTerminalLine('error', `串口截图失败: ${e.message}`);
    } finally {
        btnHwShot.textContent = label;
        btnHwShot.disabled = false;
    }
}

if (btnHwShot) btnHwShot.addEventListener('click', takeSerialScreenshot);

/* Linked over the serial port: the canvas is the board's (its screenshots),
 * never the WASM device's picture */
function serialLinked() {
    return !!(activeLink && activeLink.kind === 'serial');
}

/* Until the first screenshot: what the canvas is for now */
function showSerialPlaceholder() {
    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    ctx.fillStyle = '#0b1118';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.fillStyle = '#94a3b8';
    ctx.textAlign = 'center';
    ctx.font = '16px sans-serif';
    const lines = ['已通过串口连接设备', '模拟器画面已隐藏', '点击“📷 截图”查看设备画面'];
    lines.forEach((t, i) => ctx.fillText(t, canvas.width / 2, canvas.height / 2 - 24 + i * 28));
    if (lcdModeTagEl) {
        lcdModeTagEl.textContent = '🔌 串口连接';
        lcdModeTagEl.title = '串口连接时页面不能同步设备画面：点“📷 截图”取一次';
    }
}

/* Back to the simulator's picture (a serial link closed) */
function clearSerialStill() {
    serialStill = false;
    if (serialLinked()) return;
    vfbImageData = null;
    showWasmModeTag();
    renderVfbToCanvas(true);
}

// Photoresistor Light Sensor Slider (IO35 / ADC1_CH7). With "Simulate Light Sensor"
// checked and the board linked over HTTP, the slider replaces the board's
// sensor reading (POST /api/input?light=); unchecked, the board reads its own.
const simLightRemote = document.getElementById('sim-light-remote');
let lightSending = false, lightQueued = null;

/* Latest value only: one request in flight, the newest waits behind it */
async function sendLightToDevice(value) {
    const link = httpDevice();
    if (!link) return;
    lightQueued = value;
    if (lightSending) return;
    lightSending = true;
    try {
        while (lightQueued !== null) {
            const v = lightQueued;
            lightQueued = null;
            await link.input({ light: v });
        }
    } catch (e) {
        appendTerminalLine('error', `光敏数据发送失败: ${e.message}`);
    } finally {
        lightSending = false;
    }
}

function lightSliderValue() {
    return parseInt(simLightSlider ? simLightSlider.value : '2048', 10);
}

if (simLightSlider) {
    simLightSlider.addEventListener('input', (e) => {
        const val = parseInt(e.target.value, 10);
        if (wasmInstance && wasmInstance.exports.wasm_set_light_sensor) {
            wasmInstance.exports.wasm_set_light_sensor(val);
        }
        const lux = Math.round((val / 4095) * 1000);
        if (simLightVal) {
            simLightVal.textContent = `${val} (${lux} lux)`;
        }
        if (simLightRemote && simLightRemote.checked) sendLightToDevice(val);
        // Like the firmware, the app samples IO35 on its 3 s telemetry tick
        syncHardwareTelemetry();
    });
}

if (simLightRemote) {
    simLightRemote.addEventListener('change', () => {
        const link = httpDevice();
        if (simLightRemote.checked) {
            if (link) sendLightToDevice(lightSliderValue());
            appendTerminalLine('info', link ? `☀️ [光敏] 设备改用页面的光敏数据 (${lightSliderValue()})，拖动滑块即同步`
                : '☀️ [光敏] 已选中: 连接硬件 (HTTP) 后，滑块的值会发送到设备');
        } else if (link) {
            sendLightToDevice('off');
            appendTerminalLine('info', '☀️ [光敏] 设备恢复读取自己的光敏电阻');
        }
    });
}

// =========================================================================
// Quick Toolbar Actions & Application Loaders
// =========================================================================

/* The bundled app (the system settings or calendar): booted
 * on the WASM device with its app loop, or sent to the linked board */
async function bootBundledApp(prefix = '', preferredApp = 'calendar') {
    stopPcMonitor();
    try {
        const candidates = preferredApp === 'calendar'
            ? ['apps/calendar.msbc', 'calendar.msbc', 'apps/settings.msbc', 'settings.msbc', 'apps/settings/app.msbc']
            : ['apps/settings.msbc', 'settings.msbc', 'apps/calendar.msbc', 'calendar.msbc', 'apps/settings/app.msbc'];
        let res = null;
        let chosen = '';
        for (const path of candidates) {
            try {
                res = await fetch(path, { cache: 'no-store' });
                if (res && res.ok) {
                    chosen = path;
                    break;
                }
            } catch (e) {}
        }
        if (!res || !res.ok) throw new Error(`No bundled app found: HTTP ${res ? res.status : 'fetch failed'}`);
        const bytes = new Uint8Array(await res.arrayBuffer());
        if (activeLink) {
            await installOnDevice(bytes, 'app.msbc');
            return;
        }
        const r = startAppOnWasmDevice(bytes);
        if (r.startsWith('Error:')) throw new Error(r);
        const name = chosen.includes('calendar') ? '万年历' : '内置系统设置';
        appendTerminalLine('output', `=> ${prefix}已启动${name} (${bytes.length} 字节): ${r}`);
    } catch (e) {
        appendTerminalLine('error', `启动应用失败: ${e.message || e}`);
    }
}
// Expose bootBundledApp for external panels and components
window.bootBundledApp = bootBundledApp;

// =========================================================================
// PC performance monitor: same app image as the board. On the board the
// firmware polls LibreHardwareMonitor itself; here the page fetches it through
// server.py (/api/fetch, the PC's web server sends no CORS headers) and feeds
// the bytes to the same streaming parser compiled into the WASM VM.
// =========================================================================
let pcmonTimer = null;
let pcmonLastProblem = '';

// The WASM device's main loop, as the firmware's: (app-step) every pass and
// the app's JSON feed fetched through server.py when its URL changes or its
// interval (json-feed-start) has passed
const APP_LOOP_MS = 200;
let feedBusy = false, feedLastUrl = '', feedLastAt = 0, feedLastGen = 0, feedLastFailed = false;
const FEED_RETRY_MS = 5000; // as JF_RETRY_MS: a failed fetch is retried soon

async function pcmonPump() {
    const ex = wasmInstance && wasmInstance.exports;
    if (!ex || !ex.wasm_feed_url || !ex.wasm_feed_data) return;
    const url = readStringFromWasm(ex.wasm_feed_url());
    const interval = ex.wasm_feed_interval ? ex.wasm_feed_interval() : 1000;
    // a new json-feed-start (page switch, refresh) fetches at once, as on the board
    const gen = ex.wasm_feed_generation ? ex.wasm_feed_generation() : 0;
    const period = feedLastFailed ? Math.min(interval, FEED_RETRY_MS) : interval;
    const due = url && !feedBusy && (url !== feedLastUrl || gen !== feedLastGen ||
                                     Date.now() - feedLastAt >= Math.max(period, 1000));
    if (!due) {
        if (ex.wasm_app_step) ex.wasm_app_step();
        pumpDisplay();
        return;
    }
    feedBusy = true;
    feedLastUrl = url;
    feedLastGen = gen;
    feedLastAt = Date.now();
    try {
        feedLastFailed = !(await feedFetch(ex, url));
    } finally {
        feedBusy = false;
    }
    if (ex.wasm_app_step) ex.wasm_app_step();
    pumpDisplay();
}

/* The simulator's id (SIM-...): its requests carry it in X-MiniScheme-Device,
 * as a board's carry its MAC, so an app's own server can tell devices apart */
/* The local server's address: '' when the page comes from it (same origin),
 * which LOCAL_SERVER_BASE leaves empty */
function localServerBase() {
    return window.LOCAL_SERVER_BASE || (window.LOCAL_SERVER_INFO ? window.location.origin : '');
}

function simDeviceHeaders() {
    let id = '';
    try { id = localStorage.getItem('minischeme_sim_uuid') || ''; } catch (e) { /* private window */ }
    return id ? { 'X-MiniScheme-Device': id } : {};
}

async function feedFetch(ex, url) {
    let bytes = null;
    let problem = '';
    const base = localServerBase();
    let effectiveUrl = String(url || '').trim();
    if (/^https?:\/\/(proxy|converter)\.local(:\d+)?\//i.test(effectiveUrl)) {
        const localBase = base || 'http://127.0.0.1:8087';
        effectiveUrl = effectiveUrl.replace(/^https?:\/\/(proxy|converter)\.local(:\d+)?/i, localBase);
    }
    if (window.isSimWifiOnline && !window.isSimWifiOnline()) {
        problem = 'WiFi已断开 (WASM 模拟器网络开关已关闭)';
    } else if (window.DeviceSetupWizard && !window.DeviceSetupWizard.isSupportedProxyUrl(effectiveUrl)) {
        problem = '本地模拟设备 (WASM) 仅支持非加密协议，请连接本地代理服务器 (127.0.0.1 / 局域网 IP) 或公网应用代理 (124.222.231.186:8087)';
    } else {
        try {
            let res = null;
            if (base) {
                try {
                    res = await fetch(base + '/api/fetch?url=' + encodeURIComponent(effectiveUrl),
                                      { cache: 'no-store', headers: simDeviceHeaders() });
                } catch (be) {}
            }
            if (!res || !res.ok) {
                try {
                    res = await fetch(effectiveUrl, { cache: 'no-store' });
                } catch (fe) {}
            }
            if (res && res.ok) {
                bytes = new Uint8Array(await res.arrayBuffer());
            } else if (res && res.status === 404) {
                problem = 'proxy';
            } else if (res) {
                problem = (await res.text()) || `HTTP ${res.status}`;
            } else {
                problem = '网络无法连接到目标服务';
            }
        } catch (e) {
            problem = e.message;
        }
    }
    if (bytes) {
        const ptr = ex.wasm_alloc_buffer(bytes.length);
        new Uint8Array(wasmMemory.buffer, ptr, bytes.length).set(bytes);
        ex.wasm_feed_data(ptr, bytes.length, 1);
        ex.wasm_free_buffer(ptr);
    } else {
        ex.wasm_feed_data(0, 0, problem === 'proxy' ? -1 : 0);
    }
    if (problem !== pcmonLastProblem) {
        pcmonLastProblem = problem;
        if (problem === 'proxy') {
            appendTerminalLine('error', '⚠️ 当前后端服务没有 /api/fetch 转发 (旧版本仍在运行)。请结束旧的 server.py 或 MiniScheme-WebREPL.exe，再启动最新版本。');
        } else if (problem) {
            appendTerminalLine('error', `⚠️ 读取 ${url} 失败: ${problem}`);
        } else {
            appendTerminalLine('output', `=> 已收到 ${effectiveUrl.replace(/[?#].*$/, '')} 的数据`);
        }
    }
    return !!bytes;
}

function stopPcMonitor() {
    if (pcmonTimer) clearInterval(pcmonTimer);
    pcmonTimer = null;
}

// =========================================================================
// Real-time Clock Ticker (Syncs browser system time & Chinese date to Scheme)
// =========================================================================

// Same 1 Hz tick as the firmware: C formats time (or placeholders when NTP is
// unsynced), computes the lunar date and calls (app-tick ...)
let lastClockSec = -1;
function clockTick(force) {
    if (!wasmInstance || !appActive || !wasmInstance.exports.wasm_tick_wall) return;
    const now = new Date();
    const tick = Math.floor(now.getTime() / 1000);
    if (!force && tick === lastClockSec) return;
    lastClockSec = tick;
    // as the firmware: the tick is the second of the UTC day (a small fixnum)
    wasmInstance.exports.wasm_tick_wall(now.getFullYear(), now.getMonth() + 1, now.getDate(),
        now.getHours(), now.getMinutes(), now.getSeconds(), now.getDay(), tick % 86400);
    pumpDisplay();
}

setInterval(() => clockTick(false), 200);

// =========================================================================
// FASL / Bytecode File Upload & Drag-and-Drop Handler
// =========================================================================

const btnUploadFasl = document.getElementById('btn-upload-fasl');
const inputFaslUpload = document.getElementById('input-fasl-upload');

/* The metadata trailer tools/build_apps.py appends to an app image:
 * [image][meta.ini][u32 length][u32 FNV-1a]["MSMD"]; returns the [app] id or '' */
function readAppImageId(bytes) {
    const n = bytes.length;
    if (n < 16 || String.fromCharCode(...bytes.subarray(n - 4)) !== 'MSMD') return '';
    const dv = new DataView(bytes.buffer, bytes.byteOffset, n);
    const len = dv.getUint32(n - 12, true);
    if (len === 0 || len > n - 12) return '';
    const meta = bytes.subarray(n - 12 - len, n - 12);
    let h = 0x811c9dc5;
    for (const b of meta) h = Math.imul(h ^ b, 0x01000193) >>> 0;
    if (h !== dv.getUint32(n - 8, true)) return '';
    const m = /^\s*id\s*=\s*([A-Za-z0-9_-]+)/m.exec(new TextDecoder('utf-8').decode(meta));
    return m ? m[1] : '';
}

/* Boot an app image on the WASM device and run its loop, as after a reboot */
function startAppOnWasmDevice(bytes) {
    stopPcMonitor();
    const appId = readAppImageId(bytes);
    if (appId === 'pcmonitor') {
        setSimulatorResolution(480, 320);
        if (simResolutionSelect) simResolutionSelect.value = '480x320';
    } else if (appId && appId !== 'custom') {
        setSimulatorResolution(320, 480);
        if (simResolutionSelect) simResolutionSelect.value = '320x480';
    }
    const r = bootAppOnWasmDevice(bytes);
    if (r.startsWith('Error:')) return r;
    appActive = true;
    clockTick(true);
    pcmonTimer = setInterval(pcmonPump, APP_LOOP_MS); // app-step + the app's JSON feed
    return r;
}

async function handleUploadedPayloadFile(file) {
    if (!file) return;
    appendTerminalLine('info', `📥 正在载入文件: ${file.name} (${file.size} 字节)...`);
    try {
        const arrayBuf = await file.arrayBuffer();
        const uint8Data = new Uint8Array(arrayBuf);
        const len = uint8Data.length;

        // The file runs in the REPL of the current target, like a second fasl
        // loaded at the prompt: nothing is installed or written to the app's
        // flash, and the VM frees what it allocated afterwards. Apps are
        // installed with the editor's "安装到 ESP32" or the App manager.
        const isImage = len >= 4 && ['MSBC', 'MFAS'].includes(String.fromCharCode(...uint8Data.subarray(0, 4)));
        if (activeLink) {
            let bytes = uint8Data;
            if (!isImage) {
                const comp = compileWithWasm(new TextDecoder('utf-8').decode(uint8Data));
                if (!comp.success) {
                    appendTerminalLine('error', `❌ 编译失败: ${comp.error}`);
                    return;
                }
                bytes = comp.bytes;
            }
            await runBytesOnDevice(bytes, file.name);
        } else if (wasmInstance && wasmInstance.exports.wasm_alloc_buffer && wasmInstance.exports.wasm_run_payload) {
            const resStr = execBytesOnWasmDevice(uint8Data); // source compiles in the VM
            appendTerminalLine(resStr.startsWith('Error:') ? 'error' : 'output', `=> ${file.name} 执行结果:\n${resStr}`);
        } else {
            appendTerminalLine('error', 'WASM 引擎未就绪或未导出 wasm_run_payload');
        }
    } catch (err) {
        appendTerminalLine('error', `文件加载执行异常: ${err.message}`);
    }
}

if (btnUploadFasl && inputFaslUpload) {
    btnUploadFasl.addEventListener('click', () => {
        inputFaslUpload.click();
    });

    inputFaslUpload.addEventListener('change', async (e) => {
        const file = e.target.files && e.target.files[0];
        if (file) {
            await handleUploadedPayloadFile(file);
            inputFaslUpload.value = '';
        }
    });
}

// =========================================================================
// File Manager (board over HTTP / serial, or the WASM device's simulated file system)
// =========================================================================

const fileManager = new FileManager({
    getBackend() {
        const mode = targetMode.value;
        if (mode === 'wasm') {
            if (!wasmInstance || !wasmInstance.exports.wasm_fs_list) throw new Error('WASM 引擎未就绪');
            const backend = new WasmFsBackend(() => wasmInstance && wasmInstance.exports, () => wasmMemory);
            backend.persistent = simStorage.enabled;
            backend.reset = () => bootWasmDevice('重启');
            backend.wipe = async () => {
                await simStorage.wipe();
                location.reload();
            };
            return backend;
        }
        if (mode === 'sim') throw new Error('本地模拟进程没有文件系统，请切换到 WASM 设备仿真或 ESP32 硬件');
        if (!activeLink || typeof activeLink.fsList !== 'function') throw new Error('请先连接设备');
        return activeLink;
    },
    log: (kind, text) => appendTerminalLine(kind, text),
});

const btnFileManager = document.getElementById('btn-file-manager');
if (btnFileManager) btnFileManager.addEventListener('click', () => fileManager.open());

// =========================================================================
// System font ROM manager: Scheme runs on the selected target (fontrom-*)
// =========================================================================

const fontManager = new FontManager({
    getBackend() {
        const mode = targetMode.value;
        if (mode === 'sim') throw new Error('本地模拟进程没有字库分区，请切换到 WASM 设备仿真或 ESP32 硬件');
        if (mode === 'wasm') {
            if (!wasmInstance || !wasmInstance.exports.wasm_fs_list) throw new Error('WASM 引擎未就绪');
            const fs = new WasmFsBackend(() => wasmInstance && wasmInstance.exports, () => wasmMemory);
            return {
                label: 'WASM 设备仿真 (模拟 768 KB 字库分区)',
                async run(source) {
                    const r = evalLocalWasm(source);
                    if (!r.success) throw new Error(r.error || r.result);
                    return r.result;
                },
                fsWrite: (path, bytes, onProgress) => fs.fsWrite(path, bytes, onProgress),
                fsRemove: (path) => fs.fsRemove(path),
            };
        }
        if (!activeLink || typeof activeLink.fsWrite !== 'function') throw new Error('请先连接设备');
        const link = activeLink;
        return {
            label: link.label,
            async run(source) {
                const comp = compileWithWasm(source);
                if (!comp.success) throw new Error(comp.error);
                // erasing and writing a large font takes several seconds
                const data = await link.exec(comp.bytes, 120000);
                if (!data.success) throw new Error(data.error || '设备执行失败');
                return data.result;
            },
            fsWrite: (path, bytes, onProgress) => link.fsWrite(path, bytes, onProgress),
            fsRemove: (path) => link.fsRemove(path),
        };
    },
    log: (kind, text) => appendTerminalLine(kind, text),
    fillInput(code) {
        cmdInput.value = code;
        autoResizeInput();
        cmdInput.focus();
    },
    inputText: () => cmdInput.value,
});

const btnFontManager = document.getElementById('btn-font-manager');
if (btnFontManager) btnFontManager.addEventListener('click', () => fontManager.open());

// =========================================================================
// App manager: the target's apps (GET /api/apps on the board, "@APPS"
// over serial, wasm_apps_json in the simulator), their settings and boot app
// =========================================================================

const appManager = new AppManager({
    getBackend() {
        const mode = targetMode.value;
        if (mode === 'sim') throw new Error('本地模拟进程没有应用目录，请切换到 WASM 设备仿真或 ESP32 硬件');
        if (mode === 'wasm') {
            if (!wasmInstance || !wasmInstance.exports.wasm_apps_json) throw new Error('WASM 引擎未就绪 (需要新版 minischeme_vm.wasm)');
            const fs = new WasmFsBackend(() => wasmInstance && wasmInstance.exports, () => wasmMemory);
            return {
                kind: 'wasm',
                label: 'WASM 设备仿真',
                async apps() { return JSON.parse(readStringFromWasm(wasmInstance.exports.wasm_apps_json())); },
                async run(source) {
                    const r = evalLocalWasm(source);
                    if (!r.success) throw new Error(r.error || r.result);
                    return r.result;
                },
                fsRead: (path) => fs.fsRead(path),
                fsWrite: (path, bytes) => fs.fsWrite(path, bytes),
                fsRemove: (path) => fs.fsRemove(path),
                reset: () => bootWasmDevice('重启'),
            };
        }
        if (!activeLink || typeof activeLink.fsWrite !== 'function') throw new Error('请先连接设备');
        const link = activeLink;
        const run = async (source) => {
            const comp = compileWithWasm(source);
            if (!comp.success) throw new Error(comp.error);
            const data = await link.exec(comp.bytes, 30000);
            if (!data.success) throw new Error(data.error || '设备执行失败');
            return data.result;
        };
        return {
            kind: 'device',
            label: link.label,
            // the board's own list: GET /api/apps over HTTP, "@APPS" over serial
            apps: async () => {
                if (typeof link.apps !== 'function') throw new Error('这个连接不提供应用列表');
                return link.apps();
            },
            run,
            fsRead: (path) => link.fsRead(path),
            fsWrite: (path, bytes) => link.fsWrite(path, bytes),
            fsRemove: (path) => link.fsRemove(path),
            reset: typeof link.reset === 'function' ? () => link.reset() : undefined,
        };
    },
    log: (kind, text) => appendTerminalLine(kind, text),
});

const btnAppManager = document.getElementById('btn-app-manager');
if (btnAppManager) btnAppManager.addEventListener('click', () => appManager.open());

// 合并应用: several apps' pages in one app, built here (js/combo_builder.js)
const comboBuilder = new ComboBuilder({
    getBackend: () => appManager.getBackend(),
    log: (kind, text) => appendTerminalLine(kind, text),
});
const btnComboBuilder = document.getElementById('btn-combo-builder');
if (btnComboBuilder) btnComboBuilder.addEventListener('click', () => comboBuilder.open());

const deviceSetupWizard = new DeviceSetupWizard({
    getBackend: () => appManager.getBackend(),
    log: (kind, text) => appendTerminalLine(kind, text),
});
window.MiniSchemeDeviceSetup = deviceSetupWizard;
const btnDeviceSetup = document.getElementById('btn-device-setup');
if (btnDeviceSetup) btnDeviceSetup.addEventListener('click', () => deviceSetupWizard.open());
const btnLinkDeviceSetup = document.getElementById('btn-link-device-setup');
if (btnLinkDeviceSetup) btnLinkDeviceSetup.addEventListener('click', () => deviceSetupWizard.open());

// =========================================================================
// The running app's own web page (apps/<id>/web.html): the simulated
// device answers its calls; a board over HTTP opens its own page
// =========================================================================

const appWebPanel = new AppWebPanel({
    getTarget() {
        const mode = targetMode.value;
        if (mode === 'wasm') {
            if (!wasmInstance || !wasmInstance.exports.wasm_app_web_page) throw new Error('WASM 引擎未就绪 (需要新版 minischeme_vm.wasm)');
            return { kind: 'wasm', exports: () => wasmInstance && wasmInstance.exports, memory: () => wasmMemory };
        }
        if (activeLink) {
            // no password in the URL (history, logs): the device page asks for it on 401
            const nativeUrl = activeLink.base ? `${activeLink.base}/` : '';
            return { kind: 'device', link: activeLink, url: nativeUrl };
        }
        throw new Error('请切换到 WASM 设备仿真，或通过 HTTP / 串口连接设备');
    },
    log: (kind, text) => appendTerminalLine(kind, text),
});

const btnAppWeb = document.getElementById('btn-app-web');
if (btnAppWeb) btnAppWeb.addEventListener('click', () => appWebPanel.open());

// Support drag and drop on terminal and LCD canvas
window.addEventListener('dragover', (e) => {
    e.preventDefault();
});
window.addEventListener('drop', async (e) => {
    e.preventDefault();
    if (e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files.length > 0) {
        await handleUploadedPayloadFile(e.dataTransfer.files[0]);
    }
});

// =========================================================================
// Structured Result Printer (used for (system-info) and other nested alists)
// =========================================================================

// Minimal reader for printed Scheme data: lists, dotted pairs, strings, atoms
function parseSchemeDatum(text) {
    let i = 0;
    const skip = () => { while (i < text.length && /\s/.test(text[i])) i++; };
    const read = () => {
        skip();
        if (text[i] === '(') {
            i++;
            const items = [];
            let tail = null;
            for (;;) {
                skip();
                if (i >= text.length) throw new Error('unterminated list');
                if (text[i] === ')') { i++; break; }
                if (text[i] === '.' && /[\s()]/.test(text[i + 1] || ' ')) {
                    i++;
                    tail = read();
                    skip();
                    if (text[i] === ')') i++;
                    break;
                }
                items.push(read());
            }
            return { list: items, tail };
        }
        if (text[i] === '"') {
            let j = i + 1, out = '';
            while (j < text.length && text[j] !== '"') {
                if (text[j] === '\\' && j + 1 < text.length) j++;
                out += text[j++];
            }
            i = j + 1;
            return { str: out };
        }
        let j = i;
        while (j < text.length && !/[\s()]/.test(text[j])) j++;
        const atom = text.slice(i, j);
        i = j;
        return { atom };
    };
    return read();
}

function datumToText(d, key) {
    if (d.str !== undefined) return d.str;
    if (d.atom !== undefined) {
        if (/^-?\d+$/.test(d.atom) && /bytes|heap|block|used|total|image|partition/.test(key || '') && !/depth/.test(key || '')) {
            const n = parseInt(d.atom, 10);
            if (n >= 1048576) return `${n} (${(n / 1048576).toFixed(2)} MB)`;
            if (n >= 1024) return `${n} (${(n / 1024).toFixed(1)} KB)`;
        }
        return d.atom;
    }
    if (d.list) return d.list.map((x) => datumToText(x)).join(' ') + (d.tail ? ' . ' + datumToText(d.tail) : '');
    return '';
}

const isSymbolKeyed = (d) => d && d.list && d.list.length > 0 && d.list[0].atom !== undefined && !/^[-\d#"]/.test(d.list[0].atom);

// Renders ((section (key . val) ...) ...) as an indented report; null if not that shape
function formatSectionedAlist(resultText) {
    const root = parseSchemeDatum(resultText);
    if (!root.list || root.list.length === 0 || !root.list.every(isSymbolKeyed)) return null;
    const lines = [];
    for (const section of root.list) {
        const entries = section.tail && section.tail.list ? section.tail.list : section.list.slice(1);
        if (!entries.every(isSymbolKeyed)) return null;
        lines.push(`${section.list[0].atom}:`);
        for (const e of entries) {
            const k = e.list[0].atom;
            const v = e.tail ? datumToText(e.tail, k) : datumToText({ list: e.list.slice(1) }, k);
            lines.push(`    ${k.padEnd(20)} ${v}`);
        }
    }
    return lines.join('\n');
}

// Prints a result; (system-info) style nested alists are expanded into lines
function showResult(code, resultText, label) {
    if (/^\(\s*system-info\s*\)$/.test(code.trim())) {
        try {
            const report = formatSectionedAlist(resultText);
            if (report) {
                appendTerminalLine('output', `=> system-info  [${label}]`);
                appendTerminalLine('report', report);
                return;
            }
        } catch (e) {
            console.warn('system-info formatting failed', e);
        }
    }
    appendTerminalLine('output', `=> ${resultText}  [${label}]`);
}

// Execute Command Workflow
async function handleCommand(code) {
    deviceSymbolsStale = true; /* the command may define new names */
    code = code.trim();
    if (!code) return;

    appendTerminalLine('input', code);
    history.push(code);
    historyIdx = history.length;
    cmdInput.value = '';
    autoResizeInput();

    const mode = targetMode.value; // wasm | http | serial | sim
    const useDeviceCompiler = activeLink && deviceSrcMode && deviceSrcMode.checked && !deviceSrcMode.disabled;

    // Step 1: compile in the browser (skipped when the firmware compiles itself)
    let compRes = null;
    if (!useDeviceCompiler) {
        compRes = compileWithWasm(code);
        if (!compRes.success) {
            appendTerminalLine('error', `❌ 编译错误 (WASM Scheme 编译器): ${compRes.error}`);
            document.getElementById('disasm-viewer').textContent = `;; 编译错误:\n;; ${compRes.error}`;
            document.getElementById('hex-viewer').textContent = "未生成字节码 (语法错误被前置拦截)";
            return;
        }
        document.getElementById('metric-compile-time').textContent = `${compRes.compileTimeMs} ms`;
        document.getElementById('metric-bytecode-len').textContent = `${compRes.byte_len} 字节`;
        const hex = compRes.bytecode_hex;
        let formattedHex = "";
        for (let i = 0; i < hex.length; i += 2) {
            formattedHex += hex.substr(i, 2) + " ";
            if ((i + 2) % 32 === 0) formattedHex += "\n";
        }
        document.getElementById('hex-viewer').textContent = formattedHex.trim();
        document.getElementById('disasm-viewer').textContent = compRes.disasm;
    }

    // Step 2: run the same bytes on the simulated device or on real hardware
    if (mode === 'wasm') {
        const localRes = execLastOnWasmDevice();
        if (localRes.success) {
            showResult(code, localRes.result, 'WASM 设备仿真');
        } else {
            appendTerminalLine('error', `运行时错误: ${localRes.result.replace(/^Error: /, '')}`);
        }
        return;
    }

    if (mode === 'sim' && !activeLink) {
        activeLink = new SimDeviceLink();
    }
    if (!activeLink) {
        appendTerminalLine('error', '未连接设备: 请先在上方填写设备地址或选择串口并点击 [连接设备]');
        return;
    }
    const tStart = performance.now();
    try {
        const data = useDeviceCompiler ? await activeLink.evalSource(code) : await activeLink.exec(compRes.bytes);
        const roundtripMs = (performance.now() - tStart).toFixed(1);
        if (data.success) {
            showResult(code, data.result, activeLink.label);
            if (data.heap_allocated !== undefined) {
                document.getElementById('dev-heap-alloc').textContent =
                    `${(data.heap_allocated / 1024).toFixed(1)} KB / ${((data.heap_capacity || 0) / 1024).toFixed(0)} KB (硬件实测)`;
            }
            document.getElementById('dev-exec-time').textContent =
                `${roundtripMs} ms 往返` + (data.exec_us !== undefined ? ` (设备执行 ${data.exec_us} μs)` : '');
        } else {
            appendTerminalLine('error', `设备运行时错误: ${data.error}`);
        }
    } catch (err) {
        appendTerminalLine('error', `设备通信失败: ${err.message}`);
    }
}

// =========================================================================
// Hardware Link (HTTP / Web Serial / local simulator process)
// =========================================================================

let activeLink = null;
Object.defineProperty(window, 'activeLink', {
    get: () => activeLink,
    set: (v) => { activeLink = v; },
    configurable: true
});

// =========================================================================
// Board screen mirror and real figures (HTTP link, hw_mirror.js)
// =========================================================================

const devPanelTitle = document.getElementById('dev-panel-title');
const btnRefreshHwStats = document.getElementById('btn-refresh-hw-stats');
const devExecLabel = document.getElementById('dev-exec-label');
const heapLimitBadge = document.querySelector('.heap-limit-badge');
const lcdModeTagEl = document.getElementById('lcd-mode-tag');
const PANEL_TEXT = {
    title: devPanelTitle ? devPanelTitle.textContent : '',
    exec: devExecLabel ? devExecLabel.textContent : '',
    limit: heapLimitBadge ? heapLimitBadge.textContent : '',
};
let mirrorFps = 0;
let mirrorMode = '';

// Bottom right of the panel: display mode and frames drawn per second. The
// simulator counts the wasm_service_display calls that drew rows; the board
// reports its own count (/api/stats fps).
const DISPLAY_MODE_NAMES = { band: '条带', full: '全帧', direct: '直驱' };
const WASM_MODE_KEYS = ['band', 'direct', 'full']; // wasm_set_display_mode 0 / 1 / 2
let wasmDisplayMode = 0;
let wasmFrames = 0;
let wasmFps = 0;

function showWasmModeTag() {
    if (!lcdModeTagEl || hwMirror.active || serialStill || serialLinked()) return;
    lcdModeTagEl.textContent = `${DISPLAY_MODE_NAMES[WASM_MODE_KEYS[wasmDisplayMode]]} · ${wasmFps} 帧/s`;
    lcdModeTagEl.title = '模拟器的显示模式与每秒画出的帧数';
}

setInterval(() => {
    wasmFps = wasmFrames;
    wasmFrames = 0;
    showWasmModeTag();
}, 1000);

function hardwareModeTag() {
    return `📡 ${DISPLAY_MODE_NAMES[mirrorMode] || mirrorMode || '硬件'} · ${mirrorFps} 帧/s`;
}

const kb = (n) => (n / 1024).toFixed(1);

function badge(kind, text) {
    return `<span class="status-badge-${kind}">${text}</span>`;
}

function applyHardwareStats(st) {
    if (!st) return;
    if (st.color_bits) adoptDeviceDisplay(st);
    // panel: the board's own numbers
    if (devPanelTitle) devPanelTitle.textContent = '📟 运行内存与 ESP32 负荷 (硬件实测)';
    if (devExecLabel) devExecLabel.textContent = '实测渲染/负载:';
    if (devVmMode) devVmMode.textContent = `ESP32 硬件实测 (${activeLink ? activeLink.label : 'HTTP'})`;
    const pct = st.vm_heap_capacity ? Math.min(100, Math.round(st.vm_heap_allocated * 100 / st.vm_heap_capacity)) : 0;
    if (devHeapAlloc) devHeapAlloc.textContent = `${kb(st.vm_heap_allocated)} KB (VM 堆实测)`;
    if (devHeapCapacity) devHeapCapacity.textContent = `${kb(st.vm_heap_capacity)} KB (固件 VM 堆)`;
    if (heapProgressFill) {
        heapProgressFill.style.width = `${pct}%`;
        heapProgressFill.style.background = pct < 75 ? 'linear-gradient(90deg, #10b981 0%, #3b82f6 100%)'
            : (pct < 90 ? 'linear-gradient(90deg, #3b82f6 0%, #f59e0b 100%)' : 'linear-gradient(90deg, #f59e0b 0%, #ef4444 100%)');
    }
    if (heapProgressText) heapProgressText.textContent = `${kb(st.vm_heap_allocated)} / ${kb(st.vm_heap_capacity)} KB (${pct}%)`;
    if (heapLimitBadge) heapLimitBadge.textContent = `ESP32 ${Math.round(st.vm_heap_capacity / 1024)}KB VM 堆 (实测)`;
    if (devEsp32Estimate) {
        devEsp32Estimate.innerHTML = pct < 60 ? badge('ok', `🟢 充裕 (VM 堆 ${pct}%)`)
            : (pct < 85 ? badge('warn', `🟡 偏高 (VM 堆 ${pct}%，GC 会更频繁)`) : badge('crit', `🔴 接近上限 (VM 堆 ${pct}%)`));
    }
    const bits = st.color_bits === 16 ? 'RGB565' : `${st.color_bits}-bit ${st.palette}`;
    const layout = st.gui_mode === 'band' ? `${st.band_lines} 行条带` : (st.gui_mode === 'full' ? '全帧' : '直驱，无缓冲');
    if (devVfbRam) devVfbRam.textContent = `${kb(st.buffer_bytes)} KB (${layout}, ${bits}) + DMA ${kb(st.dma_bytes)} KB`;
    if (devVfbEstimate) devVfbEstimate.innerHTML = badge('ok', `🟢 显示共占 ${kb(st.buffer_bytes + st.dma_bytes)} KB (${st.width}×${st.height} ${st.gui_mode})`);
    if (devSramTotalEstimate) {
        const text = `空闲 ${kb(st.free_heap)} KB · 历史最低 ${kb(st.min_free_heap)} KB · 最大块 ${kb(st.largest_block)} KB / 内部 SRAM ${kb(st.internal_total)} KB`;
        devSramTotalEstimate.innerHTML = st.min_free_heap >= 24 * 1024 ? badge('ok', `🟢 ${text}`)
            : (st.min_free_heap >= 12 * 1024 ? badge('warn', `🟡 ${text}`) : badge('crit', `🔴 ${text}`));
    }
    if (devIramRow && devIram) {
        // older firmware sends no iram_total: the row stays hidden
        devIramRow.style.display = st.iram_total ? '' : 'none';
        if (st.iram_total) {
            const used = st.iram_total - st.iram_free;
            const p = Math.round(used * 100 / st.iram_total);
            const text = `${p}% · 已用 ${kb(used)} / ${kb(st.iram_total)} KB（VM ${kb(st.vm_iram)} KB）`;
            devIram.innerHTML = p < 85 ? badge('ok', `🟢 ${text}`) : (p < 95 ? badge('warn', `🟡 ${text}`) : badge('crit', `🔴 ${text}`));
        }
    }
    if (devExecTime) {
        devExecTime.textContent = `上一帧 ${(st.render_us / 1000).toFixed(1)} ms (LCD ${(st.lcd_us / 1000).toFixed(1)} ms, ${st.render_rows} 行)` +
            ` · ${st.fps} 帧/s · 主循环负载 ${st.busy_pct}% · 画面同步 ${kb(st.mirror_bytes || 0)} KB/s`;
    }
    // board peripherals
    if (ledWifi) ledWifi.classList.toggle('active', !!st.wifi);
    if (simWifiStatus) {
        simWifiStatus.textContent = st.wifi ? '已连接 (硬件)' : '未连接 (硬件)';
        simWifiStatus.style.color = st.wifi ? '#10b981' : '#ef4444';
    }
    if (simWifiIp) simWifiIp.textContent = st.ip || '0.0.0.0';
    if (simWifiRssi) simWifiRssi.textContent = st.wifi ? `${st.rssi} dBm` : '-- dBm';
    if (simWifiSsid) simWifiSsid.textContent = st.wifi ? '(硬件)' : '--';
    if (hwBacklightBadge) hwBacklightBadge.textContent = `背光: ${Math.round(st.backlight * 100 / 255)}% (硬件)`;
    if (st.light !== undefined) {
        const remote = simLightRemote && simLightRemote.checked;
        if (remote && st.light_remote === false) sendLightToDevice(lightSliderValue()); // the board restarted
        if (!remote && simLightVal) simLightVal.textContent = `${st.light} (${Math.round(st.light * 1000 / 4095)} lux, 硬件实测)`;
    }
    if (canvas) canvas.style.filter = `brightness(${(0.25 + 0.75 * st.backlight / 255).toFixed(2)})`;
    mirrorFps = st.fps;
    mirrorMode = st.gui_mode;
    if (lcdModeTagEl && hwMirror.state === 'live') lcdModeTagEl.textContent = hardwareModeTag();
}

const hwMirror = new HardwareMirror({
    canvas,
    onStats: applyHardwareStats,
    onState(state, detail) {
        if (!lcdModeTagEl) return;
        if (state === 'stopped') {
            if (btnRefreshHwStats) btnRefreshHwStats.style.display = 'none';
            showWasmModeTag();
            return;
        }
        const text = { sync: '📡 同步硬件画面…', live: hardwareModeTag(), nopixels: '📡 硬件 direct 模式: 无法镜像',
            error: '📡 硬件画面同步中断', unsupported: '📡 固件不支持画面镜像' }[state] || state;
        lcdModeTagEl.textContent = text;
        lcdModeTagEl.title = detail || '';
        if (detail && state !== 'live' && state !== 'sync') appendTerminalLine(state === 'error' ? 'error' : 'info', `📡 ${detail}`);
    },
});

/* Back to the simulator's picture and figures */
function stopHardwareMirror() {
    if (btnRefreshHwStats) btnRefreshHwStats.style.display = 'none';
    if (!hwMirror.active) return;
    hwMirror.stop();
    if (devPanelTitle) devPanelTitle.textContent = PANEL_TEXT.title;
    if (devExecLabel) devExecLabel.textContent = PANEL_TEXT.exec;
    if (heapLimitBadge) heapLimitBadge.textContent = PANEL_TEXT.limit;
    if (devVmMode) devVmMode.textContent = 'WASM 本地 VM (与固件同一 C 运行时)';
    vfbImageData = null;
    renderVfbToCanvas(true); // the whole WASM picture again
    syncHardwareTelemetry();
}

if (btnRefreshHwStats) {
    btnRefreshHwStats.addEventListener('click', async () => {
        if (!hwMirror.active) return;
        btnRefreshHwStats.disabled = true;
        const origText = btnRefreshHwStats.textContent;
        btnRefreshHwStats.textContent = '⏳ 刷新中...';
        try {
            const st = await hwMirror.fetchStats();
            if (st) adoptDeviceDisplay(st);
        } catch (err) {
            appendTerminalLine('error', `刷新硬件状态失败: ${(err && err.message) || err}`);
        } finally {
            btnRefreshHwStats.disabled = false;
            btnRefreshHwStats.textContent = origText;
        }
    });
}

const deviceLinkBar = document.getElementById('device-link-bar');
const deviceHostInput = document.getElementById('device-host');
const deviceHostLabel = document.getElementById('device-host-label');
const deviceHttpPwd = document.getElementById('device-http-pwd');
const devicePwdLabel = document.getElementById('device-pwd-label');
const devicePwdToggleLabel = document.getElementById('device-pwd-toggle-label');
const devicePwdShowToggle = document.getElementById('device-pwd-show-toggle');
const deviceConnectBtn = document.getElementById('device-connect-btn');
const deviceLinkStatus = document.getElementById('device-link-status');
const deviceSrcMode = document.getElementById('device-src-mode');

if (devicePwdShowToggle && deviceHttpPwd) {
    devicePwdShowToggle.addEventListener('change', () => {
        deviceHttpPwd.type = devicePwdShowToggle.checked ? 'text' : 'password';
    });
}

try {
    const savedHost = localStorage.getItem('minischeme.deviceHost');
    if (savedHost && deviceHostInput) deviceHostInput.value = savedHost;
    const savedPwd = localStorage.getItem('minischeme_http_password');
    if (savedPwd && deviceHttpPwd) deviceHttpPwd.value = savedPwd;
} catch (e) { /* storage unavailable */ }

// Top of the panel: what the REPL talks to (WASM emulator / ESP32: <ip> / serial)
function updateTargetLabel() {
    if (!lcdBrandText) return;
    const mode = targetMode.value;
    let text;
    if (mode === 'wasm') text = 'WASM emulator';
    else if (mode === 'sim') text = 'sim_esp32 (server.py)';
    else if (activeLink && activeLink.kind === mode) {
        text = mode === 'http' ? `ESP32：${activeLink.base.replace(/^https?:\/\//, '')}` : activeLink.label.replace(/^ESP32 /, 'ESP32：');
    } else text = mode === 'http' ? 'ESP32：未连接' : 'ESP32：串口未连接';
    lcdBrandText.textContent = text;
}

function setLinkStatus(text, online) {
    updateTargetLabel();
    if (!deviceLinkStatus) return;
    deviceLinkStatus.textContent = text;
    deviceLinkStatus.className = `device-link-status ${online ? 'online' : 'offline'}`;
    statusDot.className = `status-indicator ${online ? 'online' : 'offline'}`;
}

function describeDeviceInfo(info) {
    const parts = [];
    if (info.ip) parts.push(`IP ${info.ip}`);
    if (info.heap_capacity) parts.push(`VM堆 ${(info.heap_allocated / 1024).toFixed(0)}/${(info.heap_capacity / 1024).toFixed(0)}KB`);
    if (info.free_heap !== undefined) parts.push(`系统空闲 ${(info.free_heap / 1024).toFixed(1)}KB`);
    if (info.gui_mode) parts.push(`显示 ${info.gui_mode}`);
    if (info.time_synced !== undefined) parts.push(info.time_synced ? 'NTP已同步' : 'NTP未同步');
    parts.push(info.compiler ? '设备端编译器: 有' : '设备端编译器: 无 (发送字节码)');
    return parts.join(' | ');
}

async function disconnectDevice() {
    if (k18Down) k18Release();
    if (httpDevice() && simLightRemote && simLightRemote.checked) {
        try { await activeLink.input({ light: 'off' }); } catch (e) { /* board gone */ }
    }
    if (activeLink) {
        try { await activeLink.disconnect(); } catch (e) { /* ignore */ }
    }
    activeLink = null;
    stopHardwareMirror();
    clearSerialStill();
    if (simLightVal) { // the slider's value again, not the board's reading
        const v = lightSliderValue();
        simLightVal.textContent = `${v} (${Math.round(v * 1000 / 4095)} lux)`;
    }
    if (deviceSrcMode) { deviceSrcMode.checked = false; deviceSrcMode.disabled = true; }
    if (deviceConnectBtn) deviceConnectBtn.textContent = '连接设备';
    if (btnLinkDeviceSetup) btnLinkDeviceSetup.style.display = 'none';
    setLinkStatus('未连接', false);
    refreshTargetUi();
}
window.disconnectDevice = disconnectDevice;

/* One connection attempt at a time: a second click while the first is still
 * opening the port would open it twice ("port already open") */
let connectInProgress = false;

async function connectDevice() {
    if (connectInProgress) return;
    connectInProgress = true;
    try {
        await connectDeviceOnce();
    } finally {
        connectInProgress = false;
    }
}

async function connectDeviceOnce() {
    const mode = targetMode.value;
    await disconnectDevice();
    let link;
    if (mode === 'http') {
        const host = deviceHostInput.value.trim();
        if (!host) {
            appendTerminalLine('error', '请输入 ESP32 的 IP 地址 (串口日志或系统诊断页中可查看)');
            return;
        }
        try { localStorage.setItem('minischeme.deviceHost', host); } catch (e) { /* ignore */ }
        const pwd = deviceHttpPwd ? deviceHttpPwd.value.trim() : (localStorage.getItem('minischeme_http_password') || '');
        try {
            if (pwd) localStorage.setItem('minischeme_http_password', pwd);
            else localStorage.removeItem('minischeme_http_password');
        } catch (e) { /* ignore */ }
        link = new HttpDeviceLink(host, pwd);
    } else if (mode === 'serial') {
        link = new SerialDeviceLink(115200);
    } else {
        link = new SimDeviceLink();
    }
    link.onLog = (line) => appendTerminalLine('device', `[设备] ${line}`);
    link.onReady = () => appendTerminalLine('info', '🔄 设备已重启并就绪 (@READY)');
    setLinkStatus('连接中...', false);
    try {
        const info = await link.connect();
        activeLink = link;
        if (deviceSrcMode) {
            deviceSrcMode.disabled = !info.compiler;
            deviceSrcMode.checked = false;
        }
        if (deviceConnectBtn) deviceConnectBtn.textContent = '断开';
        if (btnLinkDeviceSetup && (link.kind === 'http' || link.kind === 'serial')) {
            btnLinkDeviceSetup.style.display = '';
        }
        setLinkStatus(`已连接 ${link.label}`, true);
        refreshTargetUi();
        appendTerminalLine('info', `🔗 已连接 ${link.label}: ${describeDeviceInfo(info)}`);
        if (link.kind === 'http') {
            hwMirror.start(link);
            if (btnRefreshHwStats) btnRefreshHwStats.style.display = 'inline-flex';
            appendTerminalLine('info', '📡 页面显示硬件实际画面；点击“🔄 刷新”可获取最新负荷数据 (断开或切回 WASM 仿真即恢复)');
            if (simLightRemote && simLightRemote.checked) sendLightToDevice(lightSliderValue());
        } else if (link.kind === 'serial') {
            showSerialPlaceholder();
            appendTerminalLine('info', '🔘 KEY 18 的按下和松开经串口发送到设备；点击“📷 截图”从串口取一次设备画面');
            // Auto-trigger initial setup wizard ONLY on serial connection if unconfigured (no WiFi SSID yet)
            await deviceSetupWizard.checkSerialAndOpenIfUnconfigured(link);
        }
    } catch (err) {
        try { await link.disconnect(); } catch (e) { /* ignore */ }
        setLinkStatus('连接失败', false);
        refreshTargetUi();
        appendTerminalLine('error', `连接设备失败: ${err.message}`);
    }
}

// Upload an image to the device. A boot app is installed by kind and the
// device reboots into it: MSBC -> /spiffs/app.msbc (built into the Flash ROM
// image, runs in place), FASL heap snapshot -> /spiffs/app.fasl (loaded to RAM).
async function installOnDevice(bytes, name) {
    if (!activeLink) return;
    const appId = readAppImageId(bytes);
    if (appId && typeof activeLink.fsWrite === 'function') {
        await installAppOnDevice(bytes, name, appId);
        return;
    }
    const isFasl = bytes.length >= 4 && String.fromCharCode(...bytes.subarray(0, 4)) === 'MFAS';
    const isApp = isFasl || /^app\.(msbc|fasl)$/i.test(name) || /pcmonitor/i.test(name);
    const path = !isApp ? '/spiffs/upload.tmp' : (isFasl ? '/spiffs/app.fasl' : '/spiffs/app.msbc');
    appendTerminalLine('info', `📤 正在发送 ${name} (${bytes.length} 字节) 到 ${activeLink.label} ➔ ${path}...`);
    const t0 = performance.now();
    try {
        const r = await activeLink.upload(bytes, path, true, (done, total) => {
            if (deviceLinkStatus) deviceLinkStatus.textContent = `上传中 ${Math.round(done * 100 / total)}%`;
        });
        setLinkStatus(`已连接 ${activeLink.label}`, true);
        const ms = (performance.now() - t0).toFixed(0);
        if (r.success && r.restart) {
            appendTerminalLine('output', `=> ${name} 已安装为开机应用 ${path} (${ms} ms)，设备正在重启: ` +
                (isFasl ? '堆快照将恢复到 VM 堆' : '字节码将构建为 Flash ROM 镜像并原地执行 (首次会多重启一次)'));
        } else if (r.success) {
            appendTerminalLine('output', `=> ${name} 已在硬件上运行 (${ms} ms): ${r.result !== undefined ? r.result : ''}`);
        } else {
            appendTerminalLine('error', `设备执行失败: ${r.error}`);
        }
    } catch (err) {
        setLinkStatus(`已连接 ${activeLink.label}`, true);
        appendTerminalLine('error', `上传失败: ${err.message}`);
    }
}

/* Bytecode run in the board's REPL (the upload button): up to 24 KB in one
 * /api/exec or @EXEC request, larger files staged in /spiffs/upload.tmp and
 * run from there (JOB_RUN_FILE); nothing is installed */
const DEVICE_EXEC_MAX = 24 * 1024;

async function runBytesOnDevice(bytes, name) {
    const link = activeLink;
    appendTerminalLine('info', `📤 正在 ${link.label} 的 REPL 中运行 ${name} (${bytes.length} 字节)...`);
    const t0 = performance.now();
    try {
        const r = bytes.length <= DEVICE_EXEC_MAX
            ? await link.exec(bytes, 30000)
            : await link.upload(bytes, '/spiffs/upload.tmp', true, (done, total) => {
                if (deviceLinkStatus) deviceLinkStatus.textContent = `上传中 ${Math.round(done * 100 / total)}%`;
            });
        setLinkStatus(`已连接 ${link.label}`, true);
        const ms = (performance.now() - t0).toFixed(0);
        if (r && r.success) {
            appendTerminalLine('output', `=> ${name} 已在硬件上运行 (${ms} ms): ${r.result !== undefined ? r.result : ''}`);
        } else {
            appendTerminalLine('error', `设备执行失败: ${(r && r.error) || '无返回'}`);
        }
    } catch (err) {
        setLinkStatus(`已连接 ${link.label}`, true);
        appendTerminalLine('error', `运行失败: ${err.message}`);
    }
}

/* An app image with metadata: /spiffs/apps/<id>/app.msbc (the market's and
 * the App manager's layout), made the boot app in config.ini, then the board
 * restarts into it */
async function installAppOnDevice(bytes, name, appId) {
    const link = activeLink;
    const isFasl = String.fromCharCode(...bytes.subarray(0, 4)) === 'MFAS';
    const rel = `apps/${appId}/app.${isFasl ? 'fasl' : 'msbc'}`;
    appendTerminalLine('info', `📤 正在安装应用 ${appId}: ${name} (${bytes.length} 字节) ➔ /spiffs/${rel}...`);
    const t0 = performance.now();
    try {
        await link.fsWrite(`/spiffs/${rel}`, bytes, (done, total) => {
            if (deviceLinkStatus) deviceLinkStatus.textContent = `上传中 ${Math.round(done * 100 / total)}%`;
        });
        setLinkStatus(`已连接 ${link.label}`, true);
        const comp = compileWithWasm(`(config-set! "system" "boot_app" "${rel}")`);
        if (!comp.success) throw new Error(comp.error);
        const r = await link.exec(comp.bytes, 30000);
        if (!r.success || String(r.result).trim() !== '#t') throw new Error(`设置启动应用失败: ${r.error || r.result}`);
        const ms = (performance.now() - t0).toFixed(0);
        if (typeof link.reset === 'function') {
            await link.reset();
            appendTerminalLine('output', `=> ${appId} 已安装到 /spiffs/${rel} 并设为启动应用 (${ms} ms)，设备正在重启`);
        } else {
            appendTerminalLine('output', `=> ${appId} 已安装到 /spiffs/${rel} 并设为启动应用 (${ms} ms)，重启设备后运行`);
        }
    } catch (err) {
        setLinkStatus(`已连接 ${link.label}`, true);
        appendTerminalLine('error', `安装失败: ${err.message}`);
    }
}

function refreshTargetUi() {
    const mode = targetMode.value;
    updateTargetLabel();
    const needsLink = mode === 'http' || mode === 'serial';
    const isLinkedHw = !!(activeLink && (activeLink.kind === 'http' || activeLink.kind === 'serial') && activeLink.kind === mode);
    if (deviceLinkBar) deviceLinkBar.style.display = needsLink ? 'flex' : 'none';
    if (deviceHostInput) deviceHostInput.style.display = mode === 'http' ? '' : 'none';
    if (deviceHostLabel) deviceHostLabel.style.display = mode === 'http' ? '' : 'none';
    if (deviceHttpPwd) deviceHttpPwd.style.display = mode === 'http' ? '' : 'none';
    if (devicePwdLabel) devicePwdLabel.style.display = mode === 'http' ? '' : 'none';
    if (devicePwdToggleLabel) devicePwdToggleLabel.style.display = mode === 'http' ? 'inline-flex' : 'none';
    if (btnLinkDeviceSetup) btnLinkDeviceSetup.style.display = isLinkedHw ? '' : 'none';
    if (btnHwShot) btnHwShot.style.display = isLinkedHw && activeLink.kind === 'serial' ? '' : 'none';
    if (btnDeviceSetup) btnDeviceSetup.style.display = (mode === 'wasm' || isLinkedHw) ? '' : 'none';
    if (mode === 'wasm') {
        targetDesc.textContent = "WASM 编译 ➔ MSBC 字节码 ➔ 浏览器内设备 VM (堆/原语/条带渲染与固件一致)";
    } else if (mode === 'http') {
        targetDesc.textContent = "WASM 编译 ➔ MSBC 字节码 ➔ HTTP POST /api/exec ➔ ESP32 执行";
    } else if (mode === 'serial') {
        targetDesc.textContent = SerialDeviceLink.supported()
            ? "WASM 编译 ➔ MSBC 字节码 ➔ Base64 串口帧 (@EXEC) ➔ ESP32 执行"
            : "当前浏览器不支持 Web Serial (请使用 Chrome / Edge)";
    } else {
        targetDesc.textContent = "WASM 编译 ➔ MSBC 字节码 ➔ 本地 sim_esp32 进程 (server.py)";
    }
}

if (deviceConnectBtn) {
    deviceConnectBtn.addEventListener('click', () => {
        if (activeLink && activeLink.kind === targetMode.value) disconnectDevice();
        else connectDevice();
    });
}

// Mode change handler
targetMode.addEventListener('change', async () => {
    if (activeLink && activeLink.kind !== targetMode.value) await disconnectDevice();
    if (targetMode.value !== 'http') stopHardwareMirror();
    if (targetMode.value === 'sim') activeLink = new SimDeviceLink();
    if (targetMode.value === 'wasm') setLinkStatus('WASM 设备仿真', true);
    refreshTargetUi();
});
refreshTargetUi();

// =========================================================================
// Autocomplete Engine (Tab to trigger, 1-9 or mouse click to select)
// =========================================================================

const SCHEME_SYMBOLS = [
    // Embedded GUI & Virtual LCD Display (3.5" 480x320 RGB565)
    { name: "gui-init", cat: "hardware", badge: "GUI", desc: "([w h]) 初始化图形显存 (默认 480x320 RGB565)" },
    { name: "gui-clear", cat: "hardware", badge: "GUI", desc: "([col]) 清屏 (指定 RGB565 颜色或默认背景色)" },
    { name: "gui-flush", cat: "hardware", badge: "GUI", desc: "() 刷新虚拟显存到物理/仿真屏幕" },
    { name: "gui-pixel", cat: "hardware", badge: "GUI", desc: "(x y col) 绘制单个像素点" },
    { name: "gui-line", cat: "hardware", badge: "GUI", desc: "(x0 y0 x1 y1 col) 绘制直线段 (Bresenham 算法)" },
    { name: "gui-rect", cat: "hardware", badge: "GUI", desc: "(x y w h col [filled?]) 绘制矩形框或实心矩形" },
    { name: "gui-round-rect", cat: "hardware", badge: "GUI", desc: "(x y w h r col [filled?]) 绘制平滑圆角矩形" },
    { name: "gui-circle", cat: "hardware", badge: "GUI", desc: "(cx cy r col [filled?]) 绘制正圆形 (线框或填充)" },
    { name: "gui-text", cat: "hardware", badge: "GUI", desc: "(x y str col [size]) 绘制可缩放点阵英文字符串 (支持°符号)" },
    { name: "gui-rgb", cat: "hardware", badge: "GUI", desc: "(r g b) 24位RGB转16位RGB565颜色编码" },
    { name: "gui-width", cat: "hardware", badge: "GUI", desc: "() 获取屏幕显存像素宽度 (480)" },
    { name: "gui-height", cat: "hardware", badge: "GUI", desc: "() 获取屏幕显存像素高度 (320)" },
    { name: "gui-touch-poll", cat: "hardware", badge: "GUI", desc: "() 轮询触摸屏，返回 (x . y) 点对或 #f" },
    { name: "gui-touch-down?", cat: "hardware", badge: "GUI", desc: "() 查询触摸屏当前是否被按下 (#t/#f)" },

    // WiFi Networking & Embedded IoT Primitives
    { name: "wifi-connect", cat: "hardware", badge: "WiFi", desc: "(ssid password) 连接无线局域网络" },
    { name: "wifi-status", cat: "hardware", badge: "WiFi", desc: "() 查询当前 WiFi 连接状态 (#t/#f)" },
    { name: "wifi-connected?", cat: "hardware", badge: "WiFi", desc: "() 查询 WiFi 是否已连通" },
    { name: "wifi-ip", cat: "hardware", badge: "WiFi", desc: "() 获取本地分配的 IP 地址字符串" },
    { name: "wifi-ssid", cat: "hardware", badge: "WiFi", desc: "() 获取当前连接的无线热点 SSID 名称" },
    { name: "wifi-rssi", cat: "hardware", badge: "WiFi", desc: "() 获取当前 WiFi 信号强度 (dBm)" },
    { name: "wifi-disconnect", cat: "hardware", badge: "WiFi", desc: "() 断开当前 WiFi 连接" },
    { name: "system-info", cat: "hardware", badge: "系统", desc: "() 全部硬件与系统信息 (chip/memory/flash/network/time/display/peripherals)" },
    { name: "chip-info", cat: "hardware", badge: "系统", desc: "() 芯片型号/核心/主频/MAC/SDK/复位原因/Flash 分区等信息 (关联表)" },
    { name: "flash-app-partition-bytes", cat: "hardware", badge: "系统", desc: "() 当前 App 分区大小 (字节)" },
    { name: "time-synced?", cat: "hardware", badge: "系统", desc: "() NTP 是否已完成校时 (#t/#f)" },
    { name: "lunar-date", cat: "hardware", badge: "系统", desc: "(y m d) 公历转农历, 返回 (月 日 闰月?) 如 (8 19 #f)" },
    { name: "lunar-date-string", cat: "hardware", badge: "系统", desc: "(y m d) 农历显示文本 (供 LCD 使用)" },
    { name: "gui-invalidate", cat: "hardware", badge: "GUI", desc: "([x y w h]) 标记需要重绘的行, 由条带渲染器重绘" },
    { name: "gui-visible?", cat: "hardware", badge: "GUI", desc: "(y h) 当前条带是否与该行区间相交 (用于跳过不可见区域)" },
    { name: "gui-render-proc", cat: "hardware", badge: "GUI", desc: "条带渲染调用的全局绘制过程" },
    { name: "free-heap", cat: "hardware", badge: "系统", desc: "() 获取 MCU 剩余可用堆内存 (字节)" },
    { name: "chip-model", cat: "hardware", badge: "系统", desc: "() 查询当前主控芯片硬件型号" },

    // High-level Scheme GUI Library Components
    { name: "gui-draw-card", cat: "sys", badge: "组件", desc: "(x y w h title body-fn) 绘制质感卡片容器" },
    { name: "gui-draw-button", cat: "sys", badge: "组件", desc: "(x y w h label pressed? bg text) 绘制立体交互按钮" },
    { name: "gui-draw-progress", cat: "sys", badge: "组件", desc: "(x y w h percent fg bg) 绘制平滑圆角进度条" },
    { name: "gui-draw-badge", cat: "sys", badge: "组件", desc: "(text x y bg text-col) 绘制圆角状态胶囊标签" },
    { name: "gui-draw-wifi-icon", cat: "sys", badge: "组件", desc: "(x y connected? rssi) 绘制动态四格WiFi天线图标" },
    { name: "gui-draw-status-bar", cat: "sys", badge: "组件", desc: "(wifi? ssid ip time) 绘制顶部系统信息状态栏" },
    { name: "make-widget", cat: "sys", badge: "组件", desc: "(type id x y w h props on-click) 构造声明式UI控件" },
    { name: "gui-hit-test", cat: "sys", badge: "组件", desc: "(widgets tx ty) 触摸坐标命中测试" },
    { name: "gui-dispatch-touch", cat: "sys", badge: "组件", desc: "(widgets) 轮询触摸并自动分发事件到控件" },

    // Hardware GPIO & Microcontroller Primitives
    { name: "pin-mode", cat: "hardware", badge: "硬件", desc: "(pin mode) 配置引脚模式: 输入(0)或输出(1)" },
    { name: "digital-write", cat: "hardware", badge: "硬件", desc: "(pin val) 输出数字电平: 高(1)或低(0)" },
    { name: "digital-read", cat: "hardware", badge: "硬件", desc: "(pin) 读取数字引脚输入电平 (0/1)" },
    { name: "analog-read", cat: "hardware", badge: "硬件", desc: "(pin) 读取 ADC 模拟引脚采样值 (0-4095)" },
    { name: "pwm-write", cat: "hardware", badge: "硬件", desc: "(pin duty) 输出硬件 PWM 占空比 (0-255)" },
    { name: "delay-ms", cat: "hardware", badge: "硬件", desc: "(ms) 毫秒延时等待" },
    { name: "millis", cat: "hardware", badge: "硬件", desc: "() 获取系统启动至今的毫秒数" },
    { name: "fs-read", cat: "hardware", badge: "硬件", desc: "(filename) 从板载文件系统读取字符串" },
    { name: "fs-write", cat: "hardware", badge: "硬件", desc: "(filename str) 写入字符串到板载闪存" },

    // Introspection, Reflection & Help
    { name: "functions", cat: "sys", badge: "反射", desc: "([category]) 查询内置函数、库函数或用户自定义函数" },
    { name: "dir", cat: "sys", badge: "反射", desc: "([category]) functions 的常用别名" },
    { name: "help", cat: "sys", badge: "帮助", desc: "([sym]) 显示内置函数文档或分类说明" },

    // Core Syntax & Hygienic Macros
    { name: "define", cat: "special", badge: "语法", desc: "(define var val) 定义全局变量或过程" },
    { name: "define-syntax", cat: "special", badge: "宏", desc: "(define-syntax name rules) 定义卫生的编译期宏" },
    { name: "syntax-rules", cat: "special", badge: "宏", desc: "(syntax-rules (lit...) rule...) 宏模板模式匹配" },
    { name: "lambda", cat: "special", badge: "语法", desc: "(lambda (args...) body...) 构造一等公民闭包" },
    { name: "if", cat: "special", badge: "语法", desc: "(if test then [else]) 条件分支" },
    { name: "cond", cat: "special", badge: "宏", desc: "(cond (c1 e1)... (else eN)) 多分支条件选择" },
    { name: "when", cat: "special", badge: "宏", desc: "(when test e1 e2...) 仅在条件为真时执行序列" },
    { name: "unless", cat: "special", badge: "宏", desc: "(unless test e1 e2...) 仅在条件为假时执行序列" },
    { name: "begin", cat: "special", badge: "语法", desc: "(begin e1 e2...) 顺序执行多个表达式" },
    { name: "let", cat: "special", badge: "宏", desc: "(let ((v e)...) body) 局部变量并行绑定或命名循环" },
    { name: "let*", cat: "special", badge: "宏", desc: "(let* ((v e)...) body) 局部变量顺序绑定" },
    { name: "letrec", cat: "special", badge: "宏", desc: "(letrec ((v e)...) body) 相互递归局部绑定" },
    { name: "quote", cat: "special", badge: "语法", desc: "(quote datum) 或 'datum 引用字面量" },
    { name: "set!", cat: "special", badge: "语法", desc: "(set! var val) 变量破坏性赋值更新" },
    { name: "and", cat: "special", badge: "宏", desc: "(and e1 e2...) 逻辑与，短路求值" },
    { name: "or", cat: "special", badge: "宏", desc: "(or e1 e2...) 逻辑或，短路求值" },
    { name: "not", cat: "special", badge: "函数", desc: "(not val) 逻辑取反，仅 #f 为假" },

    // Math & Numeric
    { name: "+", cat: "math", badge: "数学", desc: "(+ a b...) 加法求和" },
    { name: "-", cat: "math", badge: "数学", desc: "(- a b...) 减法或求负" },
    { name: "*", cat: "math", badge: "数学", desc: "(* a b...) 乘法积" },
    { name: "/", cat: "math", badge: "数学", desc: "(/ a b...) 除法商" },
    { name: "<", cat: "math", badge: "数学", desc: "(< a b...) 严格小于比较" },
    { name: ">", cat: "math", badge: "数学", desc: "(> a b...) 严格大于比较" },
    { name: "<=", cat: "math", badge: "数学", desc: "(<= a b...) 小于等于比较" },
    { name: ">=", cat: "math", badge: "数学", desc: "(>= a b...) 大于等于比较" },
    { name: "=", cat: "math", badge: "数学", desc: "(= a b...) 数值相等比较" },
    { name: "modulo", cat: "math", badge: "数学", desc: "(modulo n m) 取模 (符号与除数一致)" },
    { name: "remainder", cat: "math", badge: "数学", desc: "(remainder n m) 取余 (符号与被除数一致)" },
    { name: "quotient", cat: "math", badge: "数学", desc: "(quotient n m) 整数截断除商" },
    { name: "abs", cat: "math", badge: "数学", desc: "(abs x) 计算绝对值" },
    { name: "sqrt", cat: "math", badge: "数学", desc: "(sqrt x) 计算平方根" },
    { name: "expt", cat: "math", badge: "数学", desc: "(expt base power) 快速幂运算 (支持大整数)" },
    { name: "max", cat: "math", badge: "数学", desc: "(max a b...) 返回参数中的最大值" },
    { name: "min", cat: "math", badge: "数学", desc: "(min a b...) 返回参数中的最小值" },
    { name: "sin", cat: "math", badge: "数学", desc: "(sin x) 正弦函数" },
    { name: "cos", cat: "math", badge: "数学", desc: "(cos x) 余弦函数" },
    { name: "tan", cat: "math", badge: "数学", desc: "(tan x) 正切函数" },
    { name: "asin", cat: "math", badge: "数学", desc: "(asin x) 反正弦函数" },
    { name: "acos", cat: "math", badge: "数学", desc: "(acos x) 反余弦函数" },
    { name: "atan", cat: "math", badge: "数学", desc: "(atan x) 反正切函数" },
    { name: "exp", cat: "math", badge: "数学", desc: "(exp x) 自然指数 e^x" },
    { name: "log", cat: "math", badge: "数学", desc: "(log x) 自然对数 ln(x)" },
    { name: "floor", cat: "math", badge: "数学", desc: "(floor x) 向下取整" },
    { name: "ceiling", cat: "math", badge: "数学", desc: "(ceiling x) 向上取整" },
    { name: "round", cat: "math", badge: "数学", desc: "(round x) 四舍五入取整" },
    { name: "truncate", cat: "math", badge: "数学", desc: "(truncate x) 向零截断取整" },
    { name: "zero?", cat: "math", badge: "判断", desc: "(zero? x) 判断数值是否为 0" },
    { name: "positive?", cat: "math", badge: "判断", desc: "(positive? x) 判断是否大于 0" },
    { name: "negative?", cat: "math", badge: "判断", desc: "(negative? x) 判断是否小于 0" },
    { name: "odd?", cat: "math", badge: "判断", desc: "(odd? n) 判断是否为奇数" },
    { name: "even?", cat: "math", badge: "判断", desc: "(even? n) 判断是否为偶数" },
    { name: "number?", cat: "math", badge: "判断", desc: "(number? x) 判断是否为数值类型" },
    { name: "integer?", cat: "math", badge: "判断", desc: "(integer? x) 判断是否为整数" },

    // Pairs & Lists
    { name: "cons", cat: "list", badge: "列表", desc: "(cons car cdr) 构造点对或在表头新增元素" },
    { name: "car", cat: "list", badge: "列表", desc: "(car pair) 取点对的第一个元素" },
    { name: "cdr", cat: "list", badge: "列表", desc: "(cdr pair) 取点对的后续元素" },
    { name: "cadr", cat: "list", badge: "列表", desc: "(cadr list) 取列表第 2 个元素" },
    { name: "caddr", cat: "list", badge: "列表", desc: "(caddr list) 取列表第 3 个元素" },
    { name: "caar", cat: "list", badge: "列表", desc: "(caar pair) (car (car pair))" },
    { name: "cdar", cat: "list", badge: "列表", desc: "(cdar pair) (cdr (car pair))" },
    { name: "cddr", cat: "list", badge: "列表", desc: "(cddr pair) (cdr (cdr pair))" },
    { name: "list", cat: "list", badge: "列表", desc: "(list elem...) 构造新列表" },
    { name: "length", cat: "list", badge: "列表", desc: "(length list) 计算列表长度" },
    { name: "append", cat: "list", badge: "列表", desc: "(append l1 l2...) 连接多个列表" },
    { name: "reverse", cat: "list", badge: "列表", desc: "(reverse list) 翻转列表顺序" },
    { name: "map", cat: "list", badge: "高阶", desc: "(map proc list) 对列表每个元素映射求值" },
    { name: "for-each", cat: "list", badge: "高阶", desc: "(for-each proc list) 遍历列表执行副作用" },
    { name: "filter", cat: "list", badge: "高阶", desc: "(filter pred list) 保留满足谓词的元素" },
    { name: "fold-left", cat: "list", badge: "高阶", desc: "(fold-left proc init list) 从左到右累积折叠" },
    { name: "fold-right", cat: "list", badge: "高阶", desc: "(fold-right proc init list) 从右到左累积折叠" },
    { name: "memq", cat: "list", badge: "列表", desc: "(memq item list) 用 eq? 在列表中查找元素" },
    { name: "member", cat: "list", badge: "列表", desc: "(member item list) 用 equal? 在列表中查找元素" },
    { name: "assq", cat: "list", badge: "列表", desc: "(assq key alist) 在关联列表中按 key 查找" },
    { name: "assoc", cat: "list", badge: "列表", desc: "(assoc key alist) 在关联列表中按 equal? 查找" },
    { name: "list-ref", cat: "list", badge: "列表", desc: "(list-ref list k) 获取列表第 k 个元素 (0 起始)" },
    { name: "pair?", cat: "list", badge: "判断", desc: "(pair? obj) 判断是否为点对/列表节点" },
    { name: "null?", cat: "list", badge: "判断", desc: "(null? obj) 判断是否为空列表 '()" },
    { name: "list?", cat: "list", badge: "判断", desc: "(list? obj) 判断是否为良构列表" },

    // Vectors & Strings
    { name: "vector", cat: "list", badge: "向量", desc: "(vector elem...) 构造连续内存向量" },
    { name: "make-vector", cat: "list", badge: "向量", desc: "(make-vector len [fill]) 创建指定大小向量" },
    { name: "vector-ref", cat: "list", badge: "向量", desc: "(vector-ref vec k) O(1) 随机访问向量元素" },
    { name: "vector-set!", cat: "list", badge: "向量", desc: "(vector-set! vec k val) 修改向量第 k 个元素" },
    { name: "vector-length", cat: "list", badge: "向量", desc: "(vector-length vec) 获取向量元素个数" },
    { name: "string-append", cat: "list", badge: "字符串", desc: "(string-append s1 s2...) 拼接多个字符串" },
    { name: "string-length", cat: "list", badge: "字符串", desc: "(string-length str) 获取字符串长度" },
    { name: "substring", cat: "list", badge: "字符串", desc: "(substring str start end) 截取子字符串" },
    { name: "string->number", cat: "list", badge: "转换", desc: "(string->number str) 解析数值字符串" },
    { name: "number->string", cat: "list", badge: "转换", desc: "(number->string n) 转换为字符串" },
    { name: "string->symbol", cat: "list", badge: "转换", desc: "(string->symbol str) 字符串转符号" },
    { name: "symbol->string", cat: "list", badge: "转换", desc: "(symbol->string sym) 符号转字符串" },

    // I/O & System
    { name: "display", cat: "sys", badge: "输出", desc: "(display val) 打印人类可读格式" },
    { name: "newline", cat: "sys", badge: "输出", desc: "() 换行输出" },
    { name: "write", cat: "sys", badge: "输出", desc: "(write val) 打印精确机器表示" },
    { name: "procedure?", cat: "sys", badge: "判断", desc: "(procedure? obj) 判断是否为函数或过程" },
    { name: "equal?", cat: "sys", badge: "判断", desc: "(equal? a b) 递归深度结构相等比较" },
    { name: "eq?", cat: "sys", badge: "判断", desc: "(eq? a b) 指针/立即数同一性比较" },

    // Firmware only (not in the WASM device)
    { name: "display-bench", cat: "sys", badge: "固件", desc: "(display-bench [n]) 整屏渲染基准: 平均耗时、LCD 耗时、分配字节" },
    { name: "tick-bench", cat: "sys", badge: "固件", desc: "(tick-bench [n]) 时钟 tick + 局部刷新基准" },
    { name: "mem-report", cat: "sys", badge: "固件", desc: "(mem-report) 各任务剩余栈、VM 堆、系统空闲内存" }
];

// Names the device VM resolves (globals + primitive tables), read from the
// WASM device with wasm_symbol_catalog(); the board has the same primitives.
// Refreshed lazily after anything that can define new names.
let deviceSymbols = [];
let deviceSymbolsStale = true;

// help categories are "Group / Component" (api/components.py)
const HELP_CATEGORY_BADGE = [
    [/^Display/, 'GUI'], [/JSON/, 'JSON'], [/^Network/, '网络'], [/Numbers/, '数学'], [/lists|Vectors/, '列表'],
    [/Strings|Characters/, '字符串'], [/^Hardware/, '硬件'], [/^Storage/, '存储'], [/^Tools/, '工具'],
    [/^Extensions/, '扩展'], [/^System|Virtual machine|Output|Reflection/, '系统'], [/^Host/, 'PC'],
    [/^Language/, '语法'],
];

function loadDeviceSymbols() {
    deviceSymbolsStale = false;
    if (!wasmInstance || !wasmInstance.exports.wasm_symbol_catalog) return;
    let list;
    try {
        list = JSON.parse(readStringFromWasm(wasmInstance.exports.wasm_symbol_catalog()));
    } catch (e) {
        console.warn('symbol catalog unreadable:', e);
        return;
    }
    deviceSymbols = list.map((e) => {
        let badge = e.k === 'd' ? '定义' : (e.k === 'v' ? '变量' : '原语');
        if (e.c) {
            const hit = HELP_CATEGORY_BADGE.find(([re]) => re.test(e.c));
            badge = hit ? hit[1] : '内置';
        }
        const desc = e.s ? `${e.s} ${e.d || ''}`.trim()
            : (e.k === 'd' ? 'Scheme 定义的过程 (应用或 REPL)' : (e.k === 'v' ? '全局变量' : '设备原语 (固件与 WASM 共有)'));
        return { name: e.n, cat: e.k === 'd' ? 'user' : 'device', badge, desc };
    });
}

let acVisible = false;
let acCandidates = [];
let acActiveIndex = 0;
let acTokenStart = 0;
let acTokenEnd = 0;

// Dynamically extract user-defined functions from session history and input buffer
function getUserDefinedFunctions() {
    const userFns = new Set();
    const defRegex = /\(\s*define\s+(?:\(\s*([a-zA-Z0-9_\-+*\/<=>!?:$%&~^]+)|([a-zA-Z0-9_\-+*\/<=>!?:$%&~^]+))/g;

    for (const item of history) {
        let match;
        while ((match = defRegex.exec(item)) !== null) {
            const fnName = match[1] || match[2];
            if (fnName && !['functions', 'dir', 'hardware', 'math', 'user', 'categories'].includes(fnName)) {
                userFns.add(fnName);
            }
        }
    }

    if (cmdInput) {
        let curMatch;
        while ((curMatch = defRegex.exec(cmdInput.value)) !== null) {
            const fnName = curMatch[1] || curMatch[2];
            if (fnName && !['functions', 'dir', 'hardware', 'math', 'user', 'categories'].includes(fnName)) {
                userFns.add(fnName);
            }
        }
    }

    return Array.from(userFns);
}

// Find token before cursor
function getWordAtCursor(input) {
    const pos = input.selectionStart;
    const text = input.value;
    const delimiters = /[\s\(\)\[\]\{\}"'`;,]/;

    let start = pos - 1;
    while (start >= 0 && !delimiters.test(text[start])) {
        start--;
    }
    start++;

    let end = pos;
    while (end < text.length && !delimiters.test(text[end])) {
        end++;
    }

    return {
        prefix: text.slice(start, pos),
        fullWord: text.slice(start, end),
        start: start,
        end: end
    };
}

// Get matching candidates
function getCandidates(prefix) {
    const all = [];
    const seen = new Set();

    // 1. User-defined functions first
    const userFns = getUserDefinedFunctions();
    for (const u of userFns) {
        if (!seen.has(u)) {
            seen.add(u);
            all.push({
                name: u,
                cat: "user",
                badge: "用户",
                desc: "用户自定义函数/过程"
            });
        }
    }

    // 2. Built-in functions with curated descriptions
    for (const item of SCHEME_SYMBOLS) {
        if (!seen.has(item.name)) {
            seen.add(item.name);
            all.push(item);
        }
    }

    // 3. Everything else the device VM resolves (primitives, app definitions)
    if (deviceSymbolsStale) loadDeviceSymbols();
    for (const item of deviceSymbols) {
        if (!seen.has(item.name)) {
            seen.add(item.name);
            all.push(item);
        }
    }

    if (!prefix) {
        // Return top common recommendations
        const topList = [
            "gui-init", "gui-clear", "gui-rect", "gui-round-rect", "gui-text",
            "wifi-connect", "wifi-status", "functions", "dir", "pin-mode",
            "digital-write", "digital-read", "define", "lambda", "if", "let"
        ];
        const res = [];
        for (const t of topList) {
            const found = all.find(x => x.name === t);
            if (found && !res.includes(found)) res.push(found);
        }
        for (const u of all) {
            if (u.cat === "user" && !res.includes(u)) res.push(u);
        }
        return res.slice(0, 9);
    }

    const pLower = prefix.toLowerCase();
    const prefixMatches = all.filter(x => x.name.toLowerCase().startsWith(pLower));
    const subMatches = all.filter(x => !x.name.toLowerCase().startsWith(pLower) && x.name.toLowerCase().includes(pLower));

    return [...prefixMatches, ...subMatches].slice(0, 9);
}

// Render autocomplete popup
function renderAutocomplete(candidates, prefix, start, end) {
    acCandidates = candidates;
    acTokenStart = start;
    acTokenEnd = end;
    acActiveIndex = 0;

    if (!candidates || candidates.length === 0) {
        hideAutocomplete();
        return;
    }

    acList.innerHTML = '';
    candidates.forEach((item, index) => {
        const num = index + 1;
        const row = document.createElement('div');
        row.className = `ac-item ${index === 0 ? 'active' : ''}`;
        row.setAttribute('data-idx', index);

        let nameHtml = escapeHtml(item.name);
        if (prefix) {
            const idx = item.name.toLowerCase().indexOf(prefix.toLowerCase());
            if (idx !== -1) {
                const mBefore = escapeHtml(item.name.slice(0, idx));
                const mMatch = escapeHtml(item.name.slice(idx, idx + prefix.length));
                const mAfter = escapeHtml(item.name.slice(idx + prefix.length));
                nameHtml = `${mBefore}<span class="match-highlight">${mMatch}</span>${mAfter}`;
            }
        }

        row.innerHTML = `
            <span class="ac-num">${num}</span>
            <span class="ac-name">${nameHtml}</span>
            <span class="ac-tag ${item.cat}">${item.badge}</span>
            <span class="ac-desc" title="${escapeHtml(item.desc)}">${escapeHtml(item.desc)}</span>
        `;

        // Mouse click selection
        row.addEventListener('mousedown', (e) => {
            e.preventDefault();
            selectCandidate(index);
        });

        // Hover highlight
        row.addEventListener('mouseenter', () => {
            setActiveCandidate(index);
        });

        acList.appendChild(row);
    });

    acPopup.style.display = 'block';
    acVisible = true;
}

function setActiveCandidate(index) {
    if (!acVisible || acCandidates.length === 0) return;
    acActiveIndex = (index + acCandidates.length) % acCandidates.length;
    const items = acList.querySelectorAll('.ac-item');
    items.forEach((item, i) => {
        if (i === acActiveIndex) {
            item.classList.add('active');
            item.scrollIntoView({ block: 'nearest' });
        } else {
            item.classList.remove('active');
        }
    });
}

function selectCandidate(index) {
    if (index < 0 || index >= acCandidates.length) return;
    const chosen = acCandidates[index];
    const fullText = cmdInput.value;

    const before = fullText.slice(0, acTokenStart);
    const after = fullText.slice(acTokenEnd);

    // If typing after opening paren or at start, append a space for quick argument typing
    const needsSpace = (before.trim().endsWith('(') || before.length === 0) && !after.startsWith(' ') && !after.startsWith(')');
    const insert = chosen.name + (needsSpace ? ' ' : '');

    cmdInput.value = before + insert + after;
    const newCursor = acTokenStart + insert.length;
    cmdInput.setSelectionRange(newCursor, newCursor);

    hideAutocomplete();
    autoResizeInput();
    cmdInput.focus();
}

function hideAutocomplete() {
    acPopup.style.display = 'none';
    acVisible = false;
    acCandidates = [];
}

// Close button on popup
if (acCloseBtn) {
    acCloseBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        hideAutocomplete();
    });
}

// Close when clicking outside input area
document.addEventListener('click', (e) => {
    if (acVisible && !acPopup.contains(e.target) && e.target !== cmdInput) {
        hideAutocomplete();
    }
});

// Auto-resize textarea according to content
function autoResizeInput() {
    cmdInput.style.height = 'auto';
    cmdInput.style.height = Math.min(cmdInput.scrollHeight, 160) + 'px';
}
cmdInput.addEventListener('input', () => {
    autoResizeInput();
    if (acVisible) {
        // Dynamically refine candidates as user types
        const token = getWordAtCursor(cmdInput);
        const candidates = getCandidates(token.prefix);
        if (candidates.length > 0) {
            renderAutocomplete(candidates, token.prefix, token.start, token.end);
        } else {
            hideAutocomplete();
        }
    }
});

// Terminal input navigation & Autocomplete Hotkeys
cmdInput.addEventListener('keydown', (e) => {
    // 1. If autocomplete popup is visible
    if (acVisible) {
        // Pressing numbers 1 through 9 selects candidate directly
        if (e.key >= '1' && e.key <= '9') {
            const digit = parseInt(e.key, 10);
            const targetIdx = digit - 1;
            if (targetIdx < acCandidates.length) {
                e.preventDefault();
                selectCandidate(targetIdx);
                return;
            }
        }

        // Navigate with ArrowDown
        if (e.key === 'ArrowDown') {
            e.preventDefault();
            setActiveCandidate(acActiveIndex + 1);
            return;
        }

        // Navigate with ArrowUp
        if (e.key === 'ArrowUp') {
            e.preventDefault();
            setActiveCandidate(acActiveIndex - 1);
            return;
        }

        // Select with Enter
        if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            selectCandidate(acActiveIndex);
            return;
        }

        // Select with Tab when popup is open
        if (e.key === 'Tab') {
            e.preventDefault();
            selectCandidate(acActiveIndex);
            return;
        }

        // Dismiss with Escape
        if (e.key === 'Escape') {
            e.preventDefault();
            hideAutocomplete();
            return;
        }
    }

    // 2. Tab key triggers autocomplete
    if (e.key === 'Tab') {
        e.preventDefault();
        const token = getWordAtCursor(cmdInput);
        const candidates = getCandidates(token.prefix);
        renderAutocomplete(candidates, token.prefix, token.start, token.end);
        return;
    }

    // 3. Normal command execution on Enter
    if (e.key === 'Enter' && !e.shiftKey) {
        e.preventDefault();
        handleCommand(cmdInput.value);
    } else if (e.key === 'ArrowUp' && (cmdInput.value === '' || (cmdInput.selectionStart === 0 && cmdInput.selectionEnd === 0))) {
        if (historyIdx > 0) {
            historyIdx--;
            cmdInput.value = history[historyIdx];
            autoResizeInput();
        }
        e.preventDefault();
    } else if (e.key === 'ArrowDown' && (cmdInput.value === '' || cmdInput.selectionStart === cmdInput.value.length)) {
        if (historyIdx < history.length - 1) {
            historyIdx++;
            cmdInput.value = history[historyIdx];
            autoResizeInput();
        } else {
            historyIdx = history.length;
            cmdInput.value = '';
            autoResizeInput();
        }
        e.preventDefault();
    }
});

sendBtn.addEventListener('click', () => {
    handleCommand(cmdInput.value);
});

// Quick toolbar buttons: populate input box without auto-executing, so users can inspect/modify
document.querySelectorAll('.pill-btn[data-code]').forEach(btn => {
    btn.addEventListener('click', () => {
        let code = btn.getAttribute('data-code');
        code = code.replace(/\\n/g, '\n').replace(/&lt;/g, '<').replace(/&gt;/g, '>');
        cmdInput.value = code;
        autoResizeInput();
        cmdInput.focus();
    });
});

// Start application
window.addEventListener('DOMContentLoaded', () => {
    initWasm();
});
