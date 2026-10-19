/**
 * @file wasm_bridge.c
 * @brief WASM bridge for the MiniScheme WebREPL.
 *
 * Two VMs live in the module:
 * - Compiler VM: init.scm + compiler.scm, turns source into MSBC bytecode.
 * - Device VM: configured exactly like the ESP32 firmware (no init.scm,
 *   4KB eden, firmware heap size, same primitive set). It executes the very
 *   MSBC bytes that would be sent to the hardware, and renders the display
 *   through the same RGB666 band pipeline as the firmware.
 */

#include "../../minischeme_image.h"
#include "wasm_libc.h"
#include "../../minischeme.h"
#include "../../minischeme_market.h"
#include "../../minischeme_api.h"
#include "../../minischeme_internal.h"
#include "../../minischeme_gui.h"
#include "../../minischeme_fonts.h"
#include "../../minischeme_fontrom.h"
#include "../../minischeme_help.h"
#include "../../minischeme_device.h"
#include "../../minischeme_jsonfeed.h"
#include "../msbc.h"
#include "compiler_msbc.h"
#include "../../examples/app_settings_msbc.h"

/* Host clock (performance.now() in milliseconds) */
extern double js_now_ms(void);

/* Firmware-identical device VM profile (see examples/esp_idf/main/main.c) */
#define DEV_HEAP_BYTES   (108 * 1024) /* what the ESP32 board gets */
#define DEV_EDEN_BYTES   (4 * 1024)
#define DEV_STACK_SLOTS  1024
#define DEV_FRAMES       256
/* System heap left after WiFi + HTTP on the real board (from /api/info) */
#define DEV_SYS_FREE     15076
#define DEV_SYS_LARGEST  10240
#define DEV_FLASH_APP    1078192
#define DEV_FLASH_APP_PART (1536 * 1024)  /* the board's factory partition */
#define DEV_FLASH_TOTAL  (4 * 1024 * 1024)

static MiniVM *g_vm = NULL;   /* compiler */
static MiniVM *g_dev = NULL;  /* device */
static uint32_t g_compiler_baseline_bytes = 0;
static double g_boot_ms = 0.0;

#define WASM_OUT_MAX 65536
static char g_out_buf[WASM_OUT_MAX];
static uint8_t *g_msbc_buf = NULL;
static size_t g_msbc_len = 0;
static char g_disasm_buf[WASM_OUT_MAX];

static int g_display_mode = 0;      /* 0 = band (firmware), 1 = direct, 2 = framebuffer */
static bool g_sim_time_synced = true;
static int g_last_lux = -1;
static int g_last_bl = 220;

static void use_compiler(void) { mini_set_active_vm(g_vm); }
static void use_device(void) { mini_set_active_vm(g_dev); }

static void register_device_prims(MiniVM *vm);
static void mk_attach(void);   /* the app market's host (below) */
static const uint8_t *mock_fs_font_file(const char *path, size_t *len);
static void mock_font_rom_attach(void);
static void mock_font_config(void);
static void mock_backlight_config(void);

/* Device VM: identical profile and primitive set to the ESP32 build */
static MiniVM *create_device_vm(void) {
    MiniConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.initial_heap_bytes = DEV_HEAP_BYTES;
    cfg.max_heap_bytes     = DEV_HEAP_BYTES;
    cfg.eden_bytes         = DEV_EDEN_BYTES;
    cfg.stack_size         = DEV_STACK_SLOTS;
    cfg.frame_capacity     = DEV_FRAMES;
    cfg.skip_init_fasl     = true;
    MiniVM *vm = mini_create_ext(&cfg);
    if (!vm) return NULL;
    register_device_prims(vm);
    mini_register_gui_lib(vm);
    mini_font_set_file_hook(mock_fs_font_file);
    mock_font_rom_attach();
    mock_font_config();
    mock_backlight_config();
    mini_register_help_lib(vm);
    mini_register_device_lib(vm);
    mini_register_json_feed_lib(vm);
    mini_register_api_lib(vm);
    mini_api_set_extensions(mini_api_extension_bit("esp32"));  /* as the firmware */
    mini_register_market_lib(vm);
    mk_attach();
    return vm;
}

/* ========================================================================= */
/* Device Mock Primitives (same names as mini_register_hardware_lib)         */
/* ========================================================================= */

static int g_mock_pins[64] = {0};
static int g_mock_modes[64] = {0};

static int arg_int(int argc, Value *argv, int i, int dflt) {
    return (argc > i && mini_is_fixnum(argv[i])) ? (int)mini_to_fixnum(argv[i]) : dflt;
}

static Value prim_mock_pin_mode(MiniVM *vm, int argc, Value *argv) {
    (void)vm;
    int pin = arg_int(argc, argv, 0, -1);
    if (pin >= 0 && pin < 64) g_mock_modes[pin] = arg_int(argc, argv, 1, 0);
    return mini_void();
}

static Value prim_mock_digital_write(MiniVM *vm, int argc, Value *argv) {
    (void)vm;
    int pin = arg_int(argc, argv, 0, -1);
    if (pin >= 0 && pin < 64) g_mock_pins[pin] = arg_int(argc, argv, 1, 0) ? 1 : 0;
    return mini_void();
}

static Value prim_mock_digital_read(MiniVM *vm, int argc, Value *argv) {
    (void)vm;
    int pin = arg_int(argc, argv, 0, -1);
    return mini_make_fixnum((pin >= 0 && pin < 64) ? g_mock_pins[pin] : 0);
}

static Value prim_mock_analog_read(MiniVM *vm, int argc, Value *argv) {
    (void)vm;
    /* as the firmware: ADC1 pins 32..39 (IO35 is the photoresistor, the
     * others read mid-scale); 0 for other pins */
    int pin = arg_int(argc, argv, 0, 0);
    return mini_make_fixnum(pin == 35 ? mini_light_read() : (pin >= 32 && pin <= 39 ? 2048 : 0));
}

static Value prim_mock_pwm_write(MiniVM *vm, int argc, Value *argv) {
    (void)vm;
    int pin = arg_int(argc, argv, 0, -1);
    if (pin == 22) mini_backlight_set((uint8_t)arg_int(argc, argv, 2, 255));
    return mini_void();
}

/* as the firmware: bignums past the fixnum range */
static Value prim_mock_millis(MiniVM *vm, int argc, Value *argv) {
    (void)argc; (void)argv;
    return bigint_from_int64(vm, (int64_t)(js_now_ms() - g_boot_ms));
}

static Value prim_mock_micros(MiniVM *vm, int argc, Value *argv) {
    (void)argc; (void)argv;
    return bigint_from_int64(vm, (int64_t)((js_now_ms() - g_boot_ms) * 1000.0));
}

static Value prim_mock_noop(MiniVM *vm, int argc, Value *argv) {
    (void)vm; (void)argc; (void)argv;
    return mini_void();
}

static bool g_mock_wifi_connected = false;
static char g_mock_wifi_ssid[64] = "";
static char g_mock_wifi_ip[32] = "0.0.0.0";
static int  g_mock_wifi_rssi = -48;

static Value prim_mock_wifi_connect(MiniVM *vm, int argc, Value *argv) {
    (void)vm;
    snprintf(g_mock_wifi_ssid, sizeof(g_mock_wifi_ssid), "%s",
             (argc >= 1 && mini_is_string(argv[0])) ? mini_string_data(argv[0]) : "");
    g_mock_wifi_connected = true;
    snprintf(g_mock_wifi_ip, sizeof(g_mock_wifi_ip), "192.168.1.108");
    return mini_true();
}

/* The simulated setup access point (the firmware's setup_portal.c) */
static bool g_mock_ap = false;
static char g_mock_ap_ssid[33] = "";
static char g_mock_ap_pass[64] = "";
static int g_mock_ap_preset = 0;
static uint32_t s_mock_rand_state = 0;

static uint32_t mock_rand_u32(void) {
    if (s_mock_rand_state == 0) {
        s_mock_rand_state = (uint32_t)js_now_ms() ^ 0x9e3779b9u;
        if (s_mock_rand_state == 0) s_mock_rand_state = 123456789u;
    }
    s_mock_rand_state ^= s_mock_rand_state << 13;
    s_mock_rand_state ^= s_mock_rand_state >> 17;
    s_mock_rand_state ^= s_mock_rand_state << 5;
    return s_mock_rand_state;
}

static void mock_gen_random_letters(char *buf, size_t count) {
    if (count == 0) return;
    while (1) {
        for (size_t i = 0; i < count; i++) {
            buf[i] = (char)('A' + (mock_rand_u32() % 26));
        }
        buf[count] = '\0';
        if (count >= 4 && strncmp(buf, "MINI", 4) == 0) continue;
        break;
    }
}

static void mock_gen_random_digits(char *buf, size_t len) {
    if (len < 2) {
        if (len == 1) buf[0] = '\0';
        return;
    }
    size_t digits = len - 1;
    while (1) {
        bool all_same = true;
        bool asc = true;
        bool desc = true;
        for (size_t i = 0; i < digits; i++) {
            buf[i] = (char)('0' + (mock_rand_u32() % 10));
            if (i > 0) {
                if (buf[i] != buf[0]) all_same = false;
                if (buf[i] != buf[i - 1] + 1) asc = false;
                if (buf[i] != buf[i - 1] - 1) desc = false;
            }
        }
        buf[digits] = '\0';
        if (!all_same && !asc && !desc) break;
    }
}

/* Configurable server / proxy base URL (defaults to http://127.0.0.1:8087) */
static char g_mock_proxy_url[128] = "http://127.0.0.1:8087";

void wasm_set_proxy_url(const char *url) {
    if (url && url[0]) {
        snprintf(g_mock_proxy_url, sizeof(g_mock_proxy_url), "%s", url);
        mini_json_feed_set_https_proxy(g_mock_proxy_url);
    }
}

const char *wasm_get_proxy_url(void) {
    return g_mock_proxy_url;
}

static Value prim_mock_wifi_ap(MiniVM *vm, int argc, Value *argv) {
    (void)vm;
    if (argc < 1 || !mini_is_string(argv[0]) || !mini_string_data(argv[0])[0]) return mini_false();
    snprintf(g_mock_ap_ssid, sizeof(g_mock_ap_ssid), "%s", mini_string_data(argv[0]));
    g_mock_ap = true;
    return mini_true();
}

static Value prim_mock_wifi_connected_p(MiniVM *vm, int argc, Value *argv) {
    (void)vm; (void)argc; (void)argv;
    return mini_make_bool(g_mock_wifi_connected);
}

static Value prim_mock_wifi_ip(MiniVM *vm, int argc, Value *argv) {
    (void)argc; (void)argv;
    return mini_make_string(vm, g_mock_wifi_ip);
}

static Value prim_mock_wifi_ssid(MiniVM *vm, int argc, Value *argv) {
    (void)argc; (void)argv;
    return mini_make_string(vm, g_mock_wifi_connected ? g_mock_wifi_ssid : "");
}

static Value prim_mock_wifi_rssi(MiniVM *vm, int argc, Value *argv) {
    (void)vm; (void)argc; (void)argv;
    return mini_make_fixnum(g_mock_wifi_connected ? g_mock_wifi_rssi : 0);
}

static Value prim_mock_wifi_disconnect(MiniVM *vm, int argc, Value *argv) {
    (void)vm; (void)argc; (void)argv;
    g_mock_wifi_connected = false;
    snprintf(g_mock_wifi_ip, sizeof(g_mock_wifi_ip), "0.0.0.0");
    return mini_void();
}

static Value prim_mock_time_synced_p(MiniVM *vm, int argc, Value *argv) {
    (void)vm; (void)argc; (void)argv;
    return mini_make_bool(g_sim_time_synced);
}

/* Simulated SPIFFS: the files the firmware's file manager and fs-* primitives
 * see, binary-safe and NUL-terminated. Starts with the firmware's config.ini.
 * The bump allocator never frees, so a slot keeps its largest buffer. */
#define MOCK_FS_FILES 64
#define MOCK_FS_TOTAL 1378241u /* usable SPIFFS bytes of the board's 1472K partition */
static struct { char path[64]; uint8_t *data; size_t len, cap; bool used; } g_mock_fs[MOCK_FS_FILES];
/* Bumped by every change of the simulated SPIFFS / font ROM: the page keeps
 * both in IndexedDB (web_repl/sim_storage.js) and saves when they move */
static uint32_t g_fs_gen = 0;
static uint32_t g_rom_gen = 0;

static int mock_fs_find(const char *path) {
    for (int i = 0; i < MOCK_FS_FILES; i++) {
        if (g_mock_fs[i].used && strcmp(g_mock_fs[i].path, path) == 0) return i;
    }
    return -1;
}

static size_t mock_fs_used(void) {
    size_t n = 0;
    for (int i = 0; i < MOCK_FS_FILES; i++) if (g_mock_fs[i].used) n += g_mock_fs[i].len;
    return n;
}

/* Same rule as the firmware's safe_spiffs_path; quotes and control
 * characters are refused too so names never need JSON escaping */
static bool mock_fs_path_ok(const char *path) {
    if (strncmp(path, "/spiffs/", 8) != 0 || strstr(path, "..") || strlen(path) >= 64 || !path[8]) return false;
    for (const char *p = path; *p; p++) if (*p == '"' || *p == '\\' || (unsigned char)*p < 0x20) return false;
    return true;
}

static Value mock_alist_put(MiniVM *vm, Value lst, const char *key, Value v) {
    mini_push_root(vm, &lst);
    mini_push_root(vm, &v);
    Value k = mini_make_symbol(vm, key);
    mini_push_root(vm, &k);
    Value cell = mini_make_cons(vm, k, v);
    mini_push_root(vm, &cell);
    lst = mini_make_cons(vm, cell, lst);
    mini_pop_root(vm);
    mini_pop_root(vm);
    mini_pop_root(vm);
    mini_pop_root(vm);
    return lst;
}

/* (setup-mode-start [switch?]) => (ssid ip pass), as the firmware's access point */
static Value prim_mock_setup_mode_start(MiniVM *vm, int argc, Value *argv) {
    if (!mini_access_privileged(vm, "setup-mode-start")) return mini_void();
    bool do_switch = (argc > 0 && mini_is_true(argv[0]));
    if (do_switch) {
        g_mock_ap_preset = (g_mock_ap_preset + 1) % 2;
    } else {
        g_mock_ap_preset = 0;
    }
    char prefix[5];
    mock_gen_random_letters(prefix, 4);
    if (g_mock_ap_preset == 0) {
        snprintf(g_mock_ap_ssid, sizeof(g_mock_ap_ssid), "%s-51AB", prefix);
    } else {
        snprintf(g_mock_ap_ssid, sizeof(g_mock_ap_ssid), "%s-AP", prefix);
    }
    mock_gen_random_digits(g_mock_ap_pass, 9);
    g_mock_ap = true;
    Value list = mini_nil(), tmp = mini_nil();
    mini_push_root(vm, &list);
    mini_push_root(vm, &tmp);
    tmp = mini_make_string(vm, g_mock_ap_pass);
    list = mini_make_cons(vm, tmp, list);
    tmp = mini_make_string(vm, "192.168.4.1");
    list = mini_make_cons(vm, tmp, list);
    tmp = mini_make_string(vm, g_mock_ap_ssid);
    list = mini_make_cons(vm, tmp, list);
    mini_pop_root(vm);
    mini_pop_root(vm);
    return list;
}

static Value prim_mock_setup_mode_status(MiniVM *vm, int argc, Value *argv) {
    (void)argc; (void)argv;
    if (g_mock_ap_ssid[0] == '\0') {
        char prefix[5];
        mock_gen_random_letters(prefix, 4);
        snprintf(g_mock_ap_ssid, sizeof(g_mock_ap_ssid), "%s-51AB", prefix);
    }
    if (g_mock_ap_pass[0] == '\0') {
        mock_gen_random_digits(g_mock_ap_pass, 9);
    }
    Value lst = mini_nil();
    mini_push_root(vm, &lst);
    lst = mock_alist_put(vm, lst, "saved", mini_make_fixnum(0));
    lst = mock_alist_put(vm, lst, "sta-ip", mini_make_string(vm, g_mock_wifi_ip));
    lst = mock_alist_put(vm, lst, "sta-ssid", mini_make_string(vm, g_mock_wifi_ssid));
    lst = mock_alist_put(vm, lst, "sta-connected", mini_make_bool(g_mock_wifi_connected));
    lst = mock_alist_put(vm, lst, "clients", mini_make_fixnum(0));
    lst = mock_alist_put(vm, lst, "ap-pass", mini_make_string(vm, g_mock_ap_pass));
    lst = mock_alist_put(vm, lst, "ap-ip", mini_make_string(vm, "192.168.4.1"));
    lst = mock_alist_put(vm, lst, "ap-ssid", mini_make_string(vm, g_mock_ap_ssid));
    lst = mock_alist_put(vm, lst, "ap", mini_make_bool(g_mock_ap));
    mini_pop_root(vm);
    return lst;
}

/* (fs-info) => (total used) */
static Value prim_mock_fs_info(MiniVM *vm, int argc, Value *argv) {
    (void)argc; (void)argv;
    Value list = mini_make_cons(vm, mini_make_fixnum((int64_t)mock_fs_used()), mini_nil());
    mini_push_root(vm, &list);
    list = mini_make_cons(vm, mini_make_fixnum(MOCK_FS_TOTAL), list);
    mini_pop_root(vm);
    return list;
}

/* (fs-list "/spiffs/apps") => (("weather.msbc" . 32109) ...): files directly in dir */
static Value prim_mock_fs_list(MiniVM *vm, int argc, Value *argv) {
    if (argc < 1 || !mini_is_string(argv[0])) {
        vm_error(vm, "fs-list: expected a directory path");
        return mini_void();
    }
    char dir[96];
    if (!mini_access_file(vm, "fs-list", mini_string_data(argv[0]), false, dir, sizeof(dir) - 1)) return mini_void();
    strcat(dir, "/");
    size_t dl = strlen(dir);
    Value list = mini_nil(), name = mini_nil();
    mini_push_root(vm, &list);
    mini_push_root(vm, &name);
    for (int i = MOCK_FS_FILES - 1; i >= 0; i--) {
        if (!g_mock_fs[i].used || strncmp(g_mock_fs[i].path, dir, dl) != 0) continue;
        const char *rest = g_mock_fs[i].path + dl;
        if (!*rest || strchr(rest, '/')) continue;
        name = mini_make_string(vm, rest);
        name = mini_make_cons(vm, name, mini_make_fixnum((int64_t)g_mock_fs[i].len));
        list = mini_make_cons(vm, name, list);
    }
    mini_pop_root(vm);
    mini_pop_root(vm);
    return list;
}

/* Image files (minischeme_image) read straight out of the simulated SPIFFS;
 * a few handles in a fixed table (the allocator never frees) */
typedef struct { int slot; long pos; bool used; } MockImageFile;
static MockImageFile g_image_files[4];

static void *mock_image_open(const char *path) {
    int slot = mock_fs_find(path);
    for (int i = 0; slot >= 0 && i < 4; i++) {
        if (!g_image_files[i].used) {
            g_image_files[i] = (MockImageFile){ slot, 0, true };
            return &g_image_files[i];
        }
    }
    return NULL;
}

static int mock_image_read(void *f, void *buf, int n) {
    MockImageFile *h = (MockImageFile *)f;
    if (!g_mock_fs[h->slot].used) return -1;
    size_t len = g_mock_fs[h->slot].len;
    if ((size_t)h->pos >= len || n <= 0) return 0;
    size_t k = len - (size_t)h->pos < (size_t)n ? len - (size_t)h->pos : (size_t)n;
    memcpy(buf, g_mock_fs[h->slot].data + h->pos, k);
    h->pos += (long)k;
    return (int)k;
}

static bool mock_image_seek(void *f, long off) {
    MockImageFile *h = (MockImageFile *)f;
    if (off < 0 || (size_t)off > g_mock_fs[h->slot].len) return false;
    h->pos = off;
    return true;
}

static void mock_image_close(void *f) { ((MockImageFile *)f)->used = false; }

static const MiniImageIO g_mock_image_io = { mock_image_open, mock_image_read, mock_image_seek, mock_image_close };

/* NULL on success, else the firmware's error message */
static const char *mock_fs_put(const char *path, const uint8_t *data, size_t len) {
    if (!mock_fs_path_ok(path)) return "path must be under /spiffs/";
    int slot = mock_fs_find(path);
    if (mock_fs_used() - (slot >= 0 ? g_mock_fs[slot].len : 0) + len > MOCK_FS_TOTAL) return "file system full";
    for (int i = 0; slot < 0 && i < MOCK_FS_FILES; i++) if (!g_mock_fs[i].used) slot = i;
    if (slot < 0) return "file system full";
    if (!g_mock_fs[slot].data || g_mock_fs[slot].cap < len + 1) {
        uint8_t *buf = (uint8_t *)malloc(len + 1);
        if (!buf) return "out of memory";
        g_mock_fs[slot].data = buf;
        g_mock_fs[slot].cap = len + 1;
    }
    if (len) memcpy(g_mock_fs[slot].data, data, len);
    g_mock_fs[slot].data[len] = '\0';
    g_mock_fs[slot].len = len;
    g_mock_fs[slot].used = true;
    g_fs_gen++;
    snprintf(g_mock_fs[slot].path, sizeof(g_mock_fs[slot].path), "%s", path);
    return NULL;
}

static const char *mock_fs_remove(const char *path) {
    if (!mock_fs_path_ok(path)) return "path must be under /spiffs/";
    int slot = mock_fs_find(path);
    if (slot < 0) return "no such file";
    g_mock_fs[slot].used = false;
    g_fs_gen++;
    return NULL;
}

/* font-load / use-font read fonts uploaded to the mock file system */
static const uint8_t *mock_fs_font_file(const char *path, size_t *len) {
    int slot = mock_fs_find(path);
    if (slot < 0) return NULL;
    *len = g_mock_fs[slot].len;
    return g_mock_fs[slot].data;
}

/* The board's 768 KB fontrom partition, as NOR flash: erase sets 0xFF and
 * writes can only clear bits. Kept while the page is open, like the mock FS. */
#define MOCK_FONT_ROM_BYTES (768u * 1024u)
static uint8_t *g_font_rom = NULL;

static bool mock_font_rom_erase(size_t off, size_t len, void *user) {
    (void)user;
    if (off % MINI_FONTROM_SECTOR || len % MINI_FONTROM_SECTOR || off + len > MOCK_FONT_ROM_BYTES) return false;
    memset(g_font_rom + off, 0xFF, len);
    g_rom_gen++;
    return true;
}

static bool mock_font_rom_write(size_t off, const void *data, size_t len, void *user) {
    (void)user;
    if (off + len > MOCK_FONT_ROM_BYTES) return false;
    const uint8_t *src = (const uint8_t *)data;
    for (size_t i = 0; i < len; i++) g_font_rom[off + i] &= src[i];
    g_rom_gen++;
    return true;
}

static void mock_font_rom_mount(void) {
    MiniFontRomFlash flash = { g_font_rom, MOCK_FONT_ROM_BYTES, mock_font_rom_erase, mock_font_rom_write, NULL };
    mini_fontrom_attach(&flash);
}

static void mock_font_rom_attach(void) {
    if (g_font_rom) return;
    g_font_rom = (uint8_t *)malloc(MOCK_FONT_ROM_BYTES);
    if (!g_font_rom) return;
    memset(g_font_rom, 0xFF, MOCK_FONT_ROM_BYTES);
    mock_font_rom_mount();
}

/* The partition's bytes, for the page to save and restore */
__attribute__((visibility("default")))
uint8_t *wasm_fontrom_data(void) {
    mock_font_rom_attach();
    return g_font_rom;
}

__attribute__((visibility("default")))
uint32_t wasm_fontrom_size(void) { return MOCK_FONT_ROM_BYTES; }

__attribute__((visibility("default")))
uint32_t wasm_fontrom_gen(void) { return g_rom_gen; }

/* Reads the directory again after the page wrote saved bytes */
__attribute__((visibility("default")))
void wasm_fontrom_reload(void) {
    if (g_font_rom) mock_font_rom_mount();
}

static void mock_fs_seed(void);

/* config.ini [fonts], read at device boot like the firmware does */
static void mock_font_config(void) {
    mock_fs_seed();
    int slot = mock_fs_find("/spiffs/config.ini");
    const char *ini = slot >= 0 ? (const char *)g_mock_fs[slot].data : NULL;
    mini_device_apply_font_config(ini);
    mini_device_apply_text_config(ini);
}

static void mock_fs_seed(void) {
    static bool seeded = false;
    if (seeded) return;
    seeded = true;
    mock_fs_put("/spiffs/config.ini", (const uint8_t *)mini_device_config_template,
                strlen(mini_device_config_template));
}

/* As the firmware: an app's paths are in its folder (minischeme_device.h) */
static Value prim_mock_fs_write(MiniVM *vm, int argc, Value *argv) {
    char path[96], why[96];
    if (argc < 2 || !mini_is_string(argv[0]) || !mini_is_string(argv[1])) return mini_false();
    if (!mini_access_file(vm, "fs-write", mini_string_data(argv[0]), true, path, sizeof(path))) return mini_void();
    int old = mock_fs_find(path);
    if (!mini_app_storage_ok(mini_string_len(argv[1]), old >= 0 ? g_mock_fs[old].len : 0, why, sizeof(why))) {
        vm_error(vm, "fs-write: %s", why);
        return mini_void();
    }
    return mini_make_bool(!mock_fs_put(path, (const uint8_t *)mini_string_data(argv[1]), mini_string_len(argv[1])));
}

static Value prim_mock_fs_read(MiniVM *vm, int argc, Value *argv) {
    char path[96];
    if (argc < 1 || !mini_is_string(argv[0])) return mini_false();
    if (!mini_access_file(vm, "fs-read", mini_string_data(argv[0]), false, path, sizeof(path))) return mini_void();
    int slot = mock_fs_find(path);
    return slot < 0 ? mini_false() : mini_make_string_len(vm, (const char *)g_mock_fs[slot].data, g_mock_fs[slot].len);
}

static Value prim_mock_fs_exists_p(MiniVM *vm, int argc, Value *argv) {
    char path[96];
    if (argc < 1 || !mini_is_string(argv[0])) return mini_false();
    if (!mini_access_file(vm, "fs-exists?", mini_string_data(argv[0]), false, path, sizeof(path))) return mini_void();
    return mini_make_bool(mock_fs_find(path) >= 0);
}

static Value prim_mock_fs_remove(MiniVM *vm, int argc, Value *argv) {
    char path[96];
    if (argc < 1 || !mini_is_string(argv[0])) return mini_false();
    if (!mini_access_file(vm, "fs-remove", mini_string_data(argv[0]), true, path, sizeof(path))) return mini_void();
    return mini_make_bool(!mock_fs_remove(path));
}

/* Bytes of the files under dir (an app's storage quota) */
static size_t mock_dir_used(const char *dir) {
    size_t n = strlen(dir), total = 0;
    for (int i = 0; i < MOCK_FS_FILES; i++) {
        if (g_mock_fs[i].used && strncmp(g_mock_fs[i].path, dir, n) == 0 && g_mock_fs[i].path[n] == '/') {
            total += g_mock_fs[i].len;
        }
    }
    return total;
}

/* ------------------------------------------------------------------------- */
/* File manager exports: same results as the firmware's /api/fs routes      */
/* ------------------------------------------------------------------------- */
static char g_fs_json[4096];

__attribute__((visibility("default")))
const char *wasm_fs_list(void) {
    mock_fs_seed();
    size_t n = (size_t)snprintf(g_fs_json, sizeof(g_fs_json), "{\"success\":true,\"total\":%u,\"used\":%u,\"files\":[",
                                MOCK_FS_TOTAL, (unsigned)mock_fs_used());
    const char *sep = "";
    for (int i = 0; i < MOCK_FS_FILES && n < sizeof(g_fs_json); i++) {
        if (!g_mock_fs[i].used) continue;
        n += (size_t)snprintf(g_fs_json + n, sizeof(g_fs_json) - n, "%s{\"path\":\"%s\",\"size\":%u}",
                              sep, g_mock_fs[i].path, (unsigned)g_mock_fs[i].len);
        sep = ",";
    }
    if (n < sizeof(g_fs_json)) snprintf(g_fs_json + n, sizeof(g_fs_json) - n, "]}");
    return g_fs_json;
}

/* Size of a file, or -1 when it does not exist */
__attribute__((visibility("default")))
int32_t wasm_fs_size(const char *path) {
    mock_fs_seed();
    int slot = mock_fs_find(path);
    return slot < 0 ? -1 : (int32_t)g_mock_fs[slot].len;
}

__attribute__((visibility("default")))
const uint8_t *wasm_fs_data(const char *path) {
    int slot = mock_fs_find(path);
    return slot < 0 ? NULL : g_mock_fs[slot].data;
}

/* The write/remove/rename exports return NULL on success, else an error */
__attribute__((visibility("default")))
const char *wasm_fs_write(const char *path, const uint8_t *buf, uint32_t len) {
    mock_fs_seed();
    return mock_fs_put(path, buf, len);
}

__attribute__((visibility("default")))
const char *wasm_fs_remove(const char *path) {
    mock_fs_seed();
    return mock_fs_remove(path);
}

__attribute__((visibility("default")))
const char *wasm_fs_rename(const char *from, const char *to) {
    mock_fs_seed();
    if (!mock_fs_path_ok(from) || !mock_fs_path_ok(to)) return "path must be under /spiffs/";
    int slot = mock_fs_find(from);
    if (slot < 0) return "no such file";
    if (mock_fs_find(to) >= 0) return "target exists";
    snprintf(g_mock_fs[slot].path, sizeof(g_mock_fs[slot].path), "%s", to);
    g_fs_gen++;
    return NULL;
}

__attribute__((visibility("default")))
uint32_t wasm_fs_gen(void) { return g_fs_gen; }

static Value prim_mock_free_heap(MiniVM *vm, int argc, Value *argv) {
    (void)vm; (void)argc; (void)argv;
    return mini_make_fixnum(DEV_SYS_FREE);
}

static Value prim_mock_min_free_heap(MiniVM *vm, int argc, Value *argv) {
    (void)vm; (void)argc; (void)argv;
    return mini_make_fixnum(DEV_SYS_FREE - 12 * 1024); /* a board's low point under load */
}

static Value prim_mock_heap_total(MiniVM *vm, int argc, Value *argv) {
    (void)vm; (void)argc; (void)argv;
    return mini_make_fixnum(316 * 1024);
}

static Value prim_mock_max_alloc_heap(MiniVM *vm, int argc, Value *argv) {
    (void)vm; (void)argc; (void)argv;
    return mini_make_fixnum(DEV_SYS_LARGEST);
}

static Value prim_vm_allocated_bytes(MiniVM *vm, int argc, Value *argv) {
    (void)argc; (void)argv;
    return mini_make_fixnum((int64_t)mini_get_allocated_bytes(vm));
}

static Value prim_vm_heap_size(MiniVM *vm, int argc, Value *argv) {
    (void)argc; (void)argv;
    return mini_make_fixnum((int64_t)mini_get_heap_size(vm));
}

static Value prim_vm_stack_depth(MiniVM *vm, int argc, Value *argv) {
    (void)argc; (void)argv;
    return mini_make_fixnum((vm && vm->stack) ? (int64_t)(vm->sp - vm->stack) : 0);
}

static Value prim_vm_frame_depth(MiniVM *vm, int argc, Value *argv) {
    (void)argc; (void)argv;
    return mini_make_fixnum(vm ? (int64_t)vm->call_frame_count : 0);
}

static Value prim_mock_flash_app(MiniVM *vm, int argc, Value *argv) {
    (void)vm; (void)argc; (void)argv;
    return mini_make_fixnum(DEV_FLASH_APP);
}

static Value prim_mock_flash_total(MiniVM *vm, int argc, Value *argv) {
    (void)vm; (void)argc; (void)argv;
    return mini_make_fixnum(DEV_FLASH_TOTAL);
}

static Value prim_mock_flash_app_part(MiniVM *vm, int argc, Value *argv) {
    (void)vm; (void)argc; (void)argv;
    return mini_make_fixnum(DEV_FLASH_APP_PART);
}

/* (app-rom-capacity): the approm partition the Code ROM image stands in for */
static Value prim_mock_app_rom_capacity(MiniVM *vm, int argc, Value *argv) {
    (void)vm; (void)argc; (void)argv;
    return mini_make_fixnum(256 * 1024);
}

static void alist_add(MiniVM *vm, Value *head, const char *key, Value val) {
    mini_push_root(vm, &val);
    Value k = mini_make_symbol(vm, key);
    mini_push_root(vm, &k);
    Value pair = mini_make_cons(vm, k, val);
    mini_push_root(vm, &pair);
    *head = mini_make_cons(vm, pair, *head);
    mini_pop_root(vm);
    mini_pop_root(vm);
    mini_pop_root(vm);
}

/* Same keys as the firmware's (chip-info); values describe the simulator */
static Value prim_mock_chip_info(MiniVM *vm, int argc, Value *argv) {
    (void)argc; (void)argv;
    Value l = mini_nil();
    mini_push_root(vm, &l);
    alist_add(vm, &l, "spiffs-used", mini_make_fixnum(23845));
    alist_add(vm, &l, "spiffs-bytes", mini_make_fixnum(1371000));
    alist_add(vm, &l, "app-partition-bytes", mini_make_fixnum(DEV_FLASH_APP_PART));
    alist_add(vm, &l, "app-image-bytes", mini_make_fixnum(DEV_FLASH_APP));
    alist_add(vm, &l, "flash-bytes", mini_make_fixnum(DEV_FLASH_TOTAL));
    alist_add(vm, &l, "reset-reason", mini_make_string(vm, "power-on"));
    alist_add(vm, &l, "build", mini_make_string(vm, "WASM simulator"));
    alist_add(vm, &l, "idf", mini_make_string(vm, "wasm32 (simulated v6.1)"));
    alist_add(vm, &l, "mac", mini_make_string(vm, "00:00:00:00:00:00"));
    alist_add(vm, &l, "wifi-bt", mini_make_string(vm, "WiFi+BT"));
    alist_add(vm, &l, "cpu-mhz", mini_make_fixnum(240));
    alist_add(vm, &l, "cores", mini_make_fixnum(2));
    alist_add(vm, &l, "revision", mini_make_fixnum(100));
    alist_add(vm, &l, "model", mini_make_string(vm, "ESP32 (WASM simulator)"));
    mini_pop_root(vm);
    return l;
}

/* The simulator has no config.ini: apps fall back to their defaults */
/* (config-get "key"): reads /spiffs/config.ini like the firmware does */
/* The app this boot runs and its own config file, as on the board */
static char g_app_path[64] = "/spiffs/app.msbc";
static char g_app_id[32] = "app";
static char g_app_name[64] = "";      /* its display name (metadata), for the error screen */
static char g_app_ini[80] = "";
static char g_app_dir[64] = "";        /* the running app's folder (minischeme_device.h) */
static bool g_settings_mode;           /* the system settings run (set by wasm_reboot) */

static const char *mock_meta(int slot, size_t *len) {
    return slot >= 0 ? mini_app_meta_find(g_mock_fs[slot].data, g_mock_fs[slot].len, len) : NULL;
}

static bool mock_has_magic(int slot, const char *magic) {
    return slot >= 0 && g_mock_fs[slot].len >= 4 && memcmp(g_mock_fs[slot].data, magic, 4) == 0;
}

/* The boot app's file slot: [system] boot_app, else app.fasl / app.msbc */
static int mock_select_boot_app(void) {
    int slot = mock_fs_find("/spiffs/app.fasl");
    if (!mock_has_magic(slot, "MFAS")) slot = mock_fs_find("/spiffs/app.msbc");
    snprintf(g_app_path, sizeof(g_app_path), "%s", mock_has_magic(slot, "MFAS") ? "/spiffs/app.fasl" : "/spiffs/app.msbc");
    int cfg = mock_fs_find("/spiffs/config.ini");
    char boot[64], path[72];
    if (cfg >= 0 && mini_device_config_value((const char *)g_mock_fs[cfg].data, "boot_app", boot, sizeof(boot)) && boot[0]) {
        const char *rel = strncmp(boot, "/spiffs/", 8) == 0 ? boot + 8 : (boot[0] == '/' ? boot + 1 : boot);
        snprintf(path, sizeof(path), "/spiffs/%s", rel);
        int s2 = strncmp(path, "/spiffs/apps/settings/", 22) == 0 ? -1 : mock_fs_find(path);   /* never the settings */
        if (mock_has_magic(s2, "MSBC") || mock_has_magic(s2, "MFAS")) {
            slot = s2;
            snprintf(g_app_path, sizeof(g_app_path), "%s", path);
        }
    }
    size_t mlen = 0;
    const char *meta = mock_meta(slot, &mlen);
    char *text = NULL;
    if (meta && (text = (char *)malloc(mlen + 1)) != NULL) {
        memcpy(text, meta, mlen);
        text[mlen] = '\0';
    }
    mini_app_id(g_app_path, text, g_app_id, sizeof(g_app_id));
    mini_app_dir_of(g_app_path, g_app_id, g_app_dir, sizeof(g_app_dir));
    snprintf(g_app_ini, sizeof(g_app_ini), "%s/config.ini", g_app_dir);
    if (!text || !mini_device_config_value(text, "name", g_app_name, sizeof(g_app_name))) g_app_name[0] = '\0';
    const char *defaults = text ? mini_app_meta_config(text) : NULL;
    int ini_slot = mock_fs_find(g_app_ini);
    if (defaults && ini_slot >= 0) {
        /* settings an app update added: appended with their defaults, as the firmware */
        const char *old = (const char *)g_mock_fs[ini_slot].data;
        char *missing = mini_app_ini_missing(old, defaults);
        size_t ol = g_mock_fs[ini_slot].len, ml = missing ? strlen(missing) : 0;
        char *ini = ml ? (char *)malloc(ol + ml + 2) : NULL;
        if (ini) {
            memcpy(ini, old, ol);
            size_t n = ol;
            if (n && ini[n - 1] != '\n') ini[n++] = '\n';
            memcpy(ini + n, missing, ml + 1);
            mock_fs_put(g_app_ini, (const uint8_t *)ini, n + ml);
            free(ini);
        }
        free(missing);
    } else if (defaults) {
        const char *head = "; settings of this app; they override config.ini\n";
        size_t hl = strlen(head), dl = strlen(defaults);
        char *ini = (char *)malloc(hl + dl + 1);
        if (ini) {
            memcpy(ini, head, hl);
            memcpy(ini + hl, defaults, dl + 1);
            mock_fs_put(g_app_ini, (const uint8_t *)ini, hl + dl);
            free(ini);
        }
    }
    free(text);
    return slot;
}

static bool mock_ini_value(const char *path, const char *key, char *val, size_t cap) {
    int slot = path[0] ? mock_fs_find(path) : -1;
    return slot >= 0 && mini_device_config_value((const char *)g_mock_fs[slot].data, key, val, cap);
}

static Value prim_mock_config_get(MiniVM *vm, int argc, Value *argv) {
    if (argc < 1 || !mini_is_string(argv[0])) {
        vm_error(vm, "config-get: expected a key string");
        return mini_void();
    }
    mock_fs_seed();
    char val[160];
    const char *key = mini_string_data(argv[0]);
    if (mock_ini_value(g_app_ini, key, val, sizeof(val)) ||
        (mini_app_config_key_ok(key) && mock_ini_value("/spiffs/config.ini", key, val, sizeof(val)))) {
        /* the simulator's requests go through server.py on the PC that runs
         * the app proxy: an unset proxy is that PC's */
        if (!val[0] && strcmp(key, "proxy") == 0) return mini_make_string(vm, g_mock_proxy_url);
        return mini_make_string(vm, val);
    }
    if (strcmp(key, "proxy") == 0) return mini_make_string(vm, g_mock_proxy_url);
    return mini_false();
}

/* (app-config-set! key value), (app-info), (app-list): as the firmware */
static Value prim_mock_app_config_set(MiniVM *vm, int argc, Value *argv) {
    if (argc < 2 || !mini_is_string(argv[0]) || !mini_is_string(argv[1])) {
        vm_error(vm, "app-config-set!: expected key and value strings");
        return mini_void();
    }
    int slot = mock_fs_find(g_app_ini);
    const char *text = slot >= 0 ? (const char *)g_mock_fs[slot].data : "";
    char *next = mini_device_config_set(text, "config", mini_string_data(argv[0]), mini_string_data(argv[1]));
    if (!next) return mini_false();
    bool ok = mock_fs_put(g_app_ini, (const uint8_t *)next, strlen(next)) == NULL;
    free(next);
    return ok ? mini_true() : mini_false();
}

static Value prim_mock_app_info(MiniVM *vm, int argc, Value *argv) {
    (void)argc; (void)argv;
    Value list = mini_nil(), tmp = mini_nil();
    mini_push_root(vm, &list);
    mini_push_root(vm, &tmp);
    const char *fields[4] = { g_app_dir, g_app_ini, g_app_id, g_app_path };
    for (int i = 0; i < 4; i++) {
        tmp = mini_make_string(vm, fields[i]);
        list = mini_make_cons(vm, tmp, list);
    }
    mini_pop_root(vm);
    mini_pop_root(vm);
    return list;
}

/* The metadata of a file slot, malloc'd and NUL-terminated, or NULL */
static char *mock_meta_text(int slot) {
    size_t mlen = 0;
    const char *meta = mock_meta(slot, &mlen);
    char *text = meta ? (char *)malloc(mlen + 1) : NULL;
    if (text) {
        memcpy(text, meta, mlen);
        text[mlen] = '\0';
    }
    return text;
}

/* The installed apps' file slots, as the firmware's installed_apps: apps/
 * first, then a root app.msbc / app.fasl unless its id is in apps/ too */
static int mock_installed_apps(int *slots, int max) {
    int n = 0;
    for (int pass = 0; pass < 2; pass++) {
        for (int i = 0; i < MOCK_FS_FILES && n < max; i++) {
            if (!g_mock_fs[i].used) continue;
            const char *path = g_mock_fs[i].path;
            bool root_app = strcmp(path, "/spiffs/app.msbc") == 0 || strcmp(path, "/spiffs/app.fasl") == 0;
            char key[48];
            mini_app_key(path, key, sizeof(key));
            bool in_folder = strcmp(key, "builtin") != 0 &&
                             (strstr(path, "/app.msbc") || strstr(path, "/app.fasl")) &&
                             strlen(path) == 8 + strlen(key) + 9;          /* /spiffs/<key>/app.xxxx */
            if (pass ? !root_app : !in_folder) continue;
            if (strcmp(key, "apps/settings") == 0) continue;           /* the system settings: no boot app */
            if (!mock_has_magic(i, "MSBC") && !mock_has_magic(i, "MFAS")) continue;
            if (root_app) {
                char *text = mock_meta_text(i);
                char id[32], copy[64];
                mini_app_id(path, text, id, sizeof(id));
                free(text);
                snprintf(copy, sizeof(copy), "/spiffs/apps/%.31s/app.msbc", id);
                bool shadowed = mock_has_magic(mock_fs_find(copy), "MSBC");
                snprintf(copy, sizeof(copy), "/spiffs/apps/%.31s/app.fasl", id);
                if (shadowed || mock_has_magic(mock_fs_find(copy), "MFAS")) continue;
            }
            slots[n++] = i;
        }
    }
    return n;
}

/* As the firmware's migrate_app_layout: the old flat /spiffs/apps (<id>.msbc,
 * <id>.ini, <id>.*) moves into the apps' folders, boot_app with it */
static void mock_migrate_layout(void) {
    for (int i = 0; i < MOCK_FS_FILES; i++) {
        if (!g_mock_fs[i].used || strncmp(g_mock_fs[i].path, "/spiffs/apps/", 13) != 0) continue;
        const char *name = g_mock_fs[i].path + 13;
        char rel[64], to[80];
        if (strchr(name, '/') || !mini_app_legacy_name(name, rel, sizeof(rel))) continue;
        snprintf(to, sizeof(to), "/spiffs/apps/%s", rel);
        if (mock_fs_find(to) >= 0) {
            g_mock_fs[i].used = false;
        } else if (strlen(to) < sizeof(g_mock_fs[i].path)) {
            snprintf(g_mock_fs[i].path, sizeof(g_mock_fs[i].path), "%s", to);
        }
        g_fs_gen++;
    }
    int cfg = mock_fs_find("/spiffs/config.ini");
    char boot[64], moved[64];
    if (cfg >= 0 && mini_device_config_value((const char *)g_mock_fs[cfg].data, "boot_app", boot, sizeof(boot)) &&
        mini_app_legacy_boot(boot, moved, sizeof(moved))) {
        char *next = mini_device_config_set((const char *)g_mock_fs[cfg].data, "system", "boot_app", moved);
        if (next) {
            mock_fs_put("/spiffs/config.ini", (const uint8_t *)next, strlen(next));
            free(next);
        }
    }
}

static Value prim_mock_app_list(MiniVM *vm, int argc, Value *argv) {
    (void)argc; (void)argv;
    int slots[MOCK_FS_FILES];
    int n = mock_installed_apps(slots, MOCK_FS_FILES);
    Value list = mini_nil(), entry = mini_nil();
    mini_push_root(vm, &list);
    mini_push_root(vm, &entry);
    for (int i = n - 1; i >= 0; i--) {
        char *text = mock_meta_text(slots[i]);
        entry = mini_app_entry(vm, g_mock_fs[slots[i]].path, text);
        free(text);
        list = mini_make_cons(vm, entry, list);
    }
    mini_pop_root(vm);
    mini_pop_root(vm);
    return list;
}

/* The app config.ini boots now: [system] boot_app, else app.fasl / app.msbc */
static void mock_configured_boot(char *out, size_t cap) {
    int cfg = mock_fs_find("/spiffs/config.ini");
    char boot[64] = "", path[72];
    if (cfg >= 0) mini_device_config_value((const char *)g_mock_fs[cfg].data, "boot_app", boot, sizeof(boot));
    const char *rel = strncmp(boot, "/spiffs/", 8) == 0 ? boot + 8 : (boot[0] == '/' ? boot + 1 : boot);
    snprintf(path, sizeof(path), "/spiffs/%s", rel);
    int s2 = boot[0] ? mock_fs_find(path) : -1;
    if (mock_has_magic(s2, "MSBC") || mock_has_magic(s2, "MFAS")) snprintf(out, cap, "%s", path);
    else snprintf(out, cap, "%s", mock_has_magic(mock_fs_find("/spiffs/app.fasl"), "MFAS") ? "/spiffs/app.fasl" : "/spiffs/app.msbc");
}

/* The installed apps as the firmware's GET /api/apps; a static buffer */
static char *g_apps_json = NULL;

__attribute__((visibility("default")))
const char *wasm_apps_json(void) {
    mock_fs_seed();
    int slots[MOCK_FS_FILES];
    int n = mock_installed_apps(slots, MOCK_FS_FILES);
    char boot[72];
    mock_configured_boot(boot, sizeof(boot));
    size_t cap = 256, len;
    for (int i = 0; i < n; i++) { /* room for each app and its escaped metadata */
        size_t mlen = 0;
        mock_meta(slots[i], &mlen);
        cap += 768 + 2 * mlen;
    }
    free(g_apps_json);
    g_apps_json = (char *)malloc(cap);
    if (!g_apps_json) return "{\"success\":false,\"error\":\"out of memory\"}";
    len = (size_t)snprintf(g_apps_json, cap, "{\"success\":true,\"boot\":\"%s\",\"apps\":[", boot);
    for (int i = 0; i < n; i++) {
        char *text = mock_meta_text(slots[i]);
        size_t room = cap - len - 4;
        const char *p = g_mock_fs[slots[i]].path;
        int flags = MINI_APP_META | (strcmp(p, boot) == 0 ? MINI_APP_BOOT : 0) |
                    (!g_settings_mode && strcmp(p, g_app_path) == 0 ? MINI_APP_RUNNING : 0) |
                    (mini_app_web_find(g_mock_fs[slots[i]].data, g_mock_fs[slots[i]].len, NULL) ? MINI_APP_WEB : 0);
        size_t k = mini_app_json(g_apps_json + len + (len && g_apps_json[len - 1] != '[' ? 1 : 0), room,
                                 p, text, (long)g_mock_fs[slots[i]].len, flags);
        free(text);
        if (!k) continue;
        if (g_apps_json[len - 1] != '[') g_apps_json[len++] = ',';
        len += k;
    }
    snprintf(g_apps_json + len, cap - len, "]}");
    return g_apps_json;
}

/* The app the settings replaced (a mid press on the hardware pages), as the firmware's RTC record */
static bool g_last_app_valid = false;
static char g_last_app_id[32];
static MiniStats g_last_app_stats;
static size_t g_last_app_heap = 0;
static char g_last_app_phase[8];       /* "rom", "load", "crash" when the app failed */
static char g_last_app_error[120];

static Value prim_mock_last_app_stats(MiniVM *vm, int argc, Value *argv) {
    (void)argc; (void)argv;
    if (!g_last_app_valid) return mini_false();
    Value lst = mini_nil();
    mini_push_root(vm, &lst);
    if (g_last_app_error[0]) {
        lst = mock_alist_put(vm, lst, "error", mini_make_string(vm, g_last_app_error));
        lst = mock_alist_put(vm, lst, "phase", mini_make_symbol(vm, g_last_app_phase));
    }
    lst = mock_alist_put(vm, lst, "min-free", mini_make_fixnum(0));
    lst = mock_alist_put(vm, lst, "free-heap", mini_make_fixnum(0));
    lst = mock_alist_put(vm, lst, "uptime-s", mini_make_fixnum(0));
    lst = mock_alist_put(vm, lst, "rom", mini_make_fixnum((int64_t)g_last_app_stats.rom_bytes));
    lst = mock_alist_put(vm, lst, "peak", mini_make_fixnum((int64_t)g_last_app_stats.live_peak));
    lst = mock_alist_put(vm, lst, "live", mini_make_fixnum((int64_t)g_last_app_stats.live_bytes));
    lst = mock_alist_put(vm, lst, "heap", mini_make_fixnum((int64_t)g_last_app_heap));
    lst = mock_alist_put(vm, lst, "id", mini_make_string(vm, g_last_app_id));
    mini_pop_root(vm);
    return lst;
}

/* (config-set! "section" "key" "value"), as the firmware: the simulated
 * config.ini (saved with the rest of the simulated flash) */
static Value prim_mock_config_set(MiniVM *vm, int argc, Value *argv) {
    if (!mini_access_privileged(vm, "config-set!")) return mini_void();
    if (argc < 3 || !mini_is_string(argv[0]) || !mini_is_string(argv[1]) || !mini_is_string(argv[2])) {
        vm_error(vm, "config-set!: expected section, key and value strings");
        return mini_void();
    }
    mock_fs_seed();
    int slot = mock_fs_find("/spiffs/config.ini");
    const char *text = slot >= 0 ? (const char *)g_mock_fs[slot].data : "";
    char *next = mini_device_config_set(text, mini_string_data(argv[0]), mini_string_data(argv[1]),
                                        mini_string_data(argv[2]));
    if (!next) return mini_false();
    bool ok = mock_fs_put("/spiffs/config.ini", (const uint8_t *)next, strlen(next)) == NULL;
    free(next);
    return ok ? mini_true() : mini_false();
}

/* config.ini [display] auto_backlight / backlight, as the firmware: read when
 * the device VM starts, written when Scheme changes them (no flash to wear
 * here, so at once) */
static void mock_backlight_save(bool auto_on, int level) {
    mock_fs_seed();
    int slot = mock_fs_find("/spiffs/config.ini");
    char *text = mini_device_config_set(slot >= 0 ? (const char *)g_mock_fs[slot].data : "", "display",
                                        "auto_backlight", auto_on ? "1" : "0");
    if (text && !auto_on) {
        char v[8];
        snprintf(v, sizeof(v), "%d", level);
        char *next = mini_device_config_set(text, "display", "backlight", v);
        free(text);
        text = next;
    }
    if (text) mock_fs_put("/spiffs/config.ini", (const uint8_t *)text, strlen(text));
    free(text);
}

static void mock_backlight_config(void) {
    mock_fs_seed();
    int slot = mock_fs_find("/spiffs/config.ini");
    char v[16];
    bool auto_on = true;
    int level = 220;
    int offset = 0;
    int min_val = 30;
    int max_val = 255;
    if (slot >= 0) {
        const char *text = (const char *)g_mock_fs[slot].data;
        if (mini_device_config_value(text, "auto_backlight", v, sizeof(v))) auto_on = v[0] != '0';
        if (mini_device_config_value(text, "backlight", v, sizeof(v))) level = (int)strtoll(v, NULL, 10);
        if (mini_device_config_value(text, "backlight_offset", v, sizeof(v))) offset = (int)strtoll(v, NULL, 10);
        if (mini_device_config_value(text, "backlight_min", v, sizeof(v))) min_val = (int)strtoll(v, NULL, 10);
        if (mini_device_config_value(text, "backlight_max", v, sizeof(v))) max_val = (int)strtoll(v, NULL, 10);
    }
    if (level < 0 || level > 255) level = 220;
    mini_backlight_set((uint8_t)level);
    mini_backlight_set_params(offset, min_val, max_val);
    mini_backlight_auto_set(auto_on);
    mini_backlight_set_hook(mock_backlight_save);
}

/* The firmware's diagnostics, as main.c: the same work and result keys,
 * timed with the browser's clock; the simulator has no LCD transfer
 * (lcd-us 0) and no FreeRTOS tasks (no stack-free entries) */
static void request_full_redraw(void);

static int mock_bench_count(int argc, Value *argv, int dflt) {
    int n = (argc > 0 && mini_is_fixnum(argv[0])) ? (int)mini_to_fixnum(argv[0]) : dflt;
    return n < 1 ? 1 : (n > 600 ? 600 : n);
}

static Value prim_mock_display_bench(MiniVM *vm, int argc, Value *argv) {
    int n = mock_bench_count(argc, argv, 10);
    int y0 = 0, y1 = mini_gui_get_height();
    if (argc >= 3 && mini_is_fixnum(argv[1]) && mini_is_fixnum(argv[2])) {
        y0 = (int)mini_to_fixnum(argv[1]);
        y1 = y0 + (int)mini_to_fixnum(argv[2]);
    }
    bool replay = argc >= 4 && mini_is_true(argv[3]);
    if (replay) {
        mini_gui_forget_recording();
        mini_gui_band_render(vm, y0, y1, NULL, NULL);
    }
    MiniStats s0, s1;
    mini_get_stats(vm, &s0);
    double t0 = js_now_ms();
    for (int i = 0; i < n; i++) {
        if (!replay) mini_gui_forget_recording();
        mini_gui_band_render(vm, y0, y1, NULL, NULL);
    }
    double total_us = (js_now_ms() - t0) * 1000.0;
    mini_get_stats(vm, &s1);
    Value lst = mini_nil();
    mini_push_root(vm, &lst);
    alist_add(vm, &lst, "alloc-bytes", mini_make_fixnum((int64_t)((s1.alloc_bytes - s0.alloc_bytes) / (uint64_t)n)));
    alist_add(vm, &lst, "lcd-us", mini_make_fixnum(0));
    alist_add(vm, &lst, "full-render-us", mini_make_fixnum((int64_t)(total_us / n)));
    mini_pop_root(vm);
    request_full_redraw();
    return lst;
}

static Value prim_mock_tick_bench(MiniVM *vm, int argc, Value *argv) {
    int n = mock_bench_count(argc, argv, 60);
    MiniStats s0, s1;
    mini_get_stats(vm, &s0);
    double t0 = js_now_ms();
    for (int i = 1; i <= n; i++) {
        MiniWallTime t;
        memset(&t, 0, sizeof(t));
        t.synced = true;
        t.year = 2026; t.month = 9; t.day = 29; t.wday = 2;
        t.hour = 14; t.minute = (i / 60) % 60; t.second = i % 60;
        mini_device_clock_tick(vm, &t, 1000 + i, 400 + (i % 50), 200);
        mini_clear_error(vm);
        int y0, y1;
        while (mini_gui_take_invalidated(&y0, &y1)) mini_gui_band_render(vm, y0, y1, NULL, NULL);
    }
    double total_us = (js_now_ms() - t0) * 1000.0;
    mini_get_stats(vm, &s1);
    request_full_redraw();
    Value lst = mini_nil();
    mini_push_root(vm, &lst);
    alist_add(vm, &lst, "minor-gcs", mini_make_fixnum((int64_t)(s1.minor_gcs - s0.minor_gcs)));
    alist_add(vm, &lst, "alloc-bytes", mini_make_fixnum((int64_t)((s1.alloc_bytes - s0.alloc_bytes) / (uint64_t)n)));
    alist_add(vm, &lst, "tick-us", mini_make_fixnum((int64_t)(total_us / n)));
    mini_pop_root(vm);
    return lst;
}

static Value prim_mock_mem_report(MiniVM *vm, int argc, Value *argv) {
    (void)argc; (void)argv;
    mini_gc(vm);
    Value lst = mini_nil();
    mini_push_root(vm, &lst);
    alist_add(vm, &lst, "vm-live", mini_make_fixnum((int64_t)mini_get_allocated_bytes(vm)));
    alist_add(vm, &lst, "vm-heap", mini_make_fixnum((int64_t)mini_get_heap_size(vm)));
    alist_add(vm, &lst, "largest-block", mini_make_fixnum(110 * 1024));
    alist_add(vm, &lst, "min-free-heap", mini_make_fixnum(14 * 1024));
    alist_add(vm, &lst, "free-heap", mini_make_fixnum(37 * 1024));
    mini_pop_root(vm);
    return lst;
}

/* The esp32 extension API: fixed simulator values */
static Value prim_mock_esp32_mac(MiniVM *vm, int argc, Value *argv) {
    (void)argc; (void)argv;
    return mini_make_string(vm, "24:0a:c4:00:00:01");
}

static Value prim_mock_esp32_reset_reason(MiniVM *vm, int argc, Value *argv) {
    (void)argc; (void)argv;
    return mini_make_symbol(vm, "power-on");
}

static Value prim_mock_esp32_idf_version(MiniVM *vm, int argc, Value *argv) {
    (void)argc; (void)argv;
    return mini_make_string(vm, "v6.1 (WASM simulator)");
}

static Value prim_mock_chip_model(MiniVM *vm, int argc, Value *argv) {
    (void)argc; (void)argv;
    return mini_make_string(vm, "ESP32 (WASM simulator)");
}

/* (restart): like esp_restart() it does not return; the page then reboots
 * the simulated device (wasm_take_restart, wasm_reboot) */
static bool g_restart_pending = false;
/* A mid press on the hardware pages: the next reboot runs the system settings (app_settings_msbc.h) */
static bool g_settings_boot = false;
static bool g_settings_mode;
/* The market's automatic update across reboots, as the firmware's RTC flag:
 * UPDATE makes the settings install the updates, SKIP keeps the app boot
 * after that round from checking again */
enum { MARKET_AUTO_NONE, MARKET_AUTO_NEXT_UPDATE, MARKET_AUTO_NEXT_SKIP };
static int g_market_auto = MARKET_AUTO_NONE;

/* After a factory reset the next settings boot runs the built-in copy, as the firmware */
static bool g_builtin_boot = false;
static Value prim_mock_factory_reset(MiniVM *vm, int argc, Value *argv);

static Value prim_mock_restart(MiniVM *vm, int argc, Value *argv) {
    (void)argc; (void)argv;
    g_restart_pending = true;
    vm_error(vm, "restart: the simulated device is rebooting");
    return mini_void();
}

/* A failed app: its error screen stays until g_restart_at, then the settings */
static bool g_failed = false;
static double g_restart_at = 0;
static char g_boot_phase[8] = "load";   /* what wasm_boot_app failed at: rom, load, api */
static void wasm_app_failed(const char *phase, const char *reason);

__attribute__((visibility("default")))
uint32_t wasm_take_restart(void) {
    if (!g_restart_pending || (g_restart_at > 0 && js_now_ms() < g_restart_at)) return 0;
    g_restart_pending = false;
    return 1;
}

/* 1 while a failed app's error screen shows (the page then waits for the restart) */
__attribute__((visibility("default")))
int wasm_failed(void) { return g_failed ? 1 : 0; }

static void register_device_prims(MiniVM *vm) {
    static const struct { const char *name; MiniCFunc fn; } funcs[] = {
        { "pin-mode",           prim_mock_pin_mode },
        { "digital-write",      prim_mock_digital_write },
        { "digital-read",       prim_mock_digital_read },
        { "analog-read",        prim_mock_analog_read },
        { "pwm-write",          prim_mock_pwm_write },
        { "millis",             prim_mock_millis },
        { "micros",             prim_mock_micros },
        { "delay-ms",           prim_mock_noop },
        { "delay-us",           prim_mock_noop },
        { "wifi-connect",       prim_mock_wifi_connect },
        { "wifi-ap",            prim_mock_wifi_ap },
        { "setup-mode-start",   prim_mock_setup_mode_start },
        { "setup-mode-status",  prim_mock_setup_mode_status },
        { "fs-info",            prim_mock_fs_info },
        { "fs-list",            prim_mock_fs_list },
        { "last-app-stats",     prim_mock_last_app_stats },
        { "wifi-connected?",    prim_mock_wifi_connected_p },
        { "wifi-status",        prim_mock_wifi_connected_p },
        { "wifi-ip",            prim_mock_wifi_ip },
        { "wifi-ssid",          prim_mock_wifi_ssid },
        { "wifi-rssi",          prim_mock_wifi_rssi },
        { "wifi-disconnect",    prim_mock_wifi_disconnect },
        { "time-synced?",       prim_mock_time_synced_p },
        { "fs-write",           prim_mock_fs_write },
        { "fs-read",            prim_mock_fs_read },
        { "fs-exists?",         prim_mock_fs_exists_p },
        { "fs-remove",          prim_mock_fs_remove },
        { "free-heap",          prim_mock_free_heap },
        { "max-alloc-heap",     prim_mock_max_alloc_heap },
        { "min-free-heap",      prim_mock_min_free_heap },
        { "heap-total",         prim_mock_heap_total },
        { "vm-allocated-bytes", prim_vm_allocated_bytes },
        { "vm-heap-size",       prim_vm_heap_size },
        { "vm-stack-depth",     prim_vm_stack_depth },
        { "vm-frame-depth",     prim_vm_frame_depth },
        { "flash-app-bytes",    prim_mock_flash_app },
        { "flash-total-bytes",  prim_mock_flash_total },
        { "flash-app-partition-bytes", prim_mock_flash_app_part },
        { "app-rom-capacity",   prim_mock_app_rom_capacity },
        { "chip-info",          prim_mock_chip_info },
        { "restart",            prim_mock_restart },
        { "deep-sleep",         prim_mock_noop },
        { "chip-model",         prim_mock_chip_model },
        { "config-get",         prim_mock_config_get },
        { "app-config-set!",    prim_mock_app_config_set },
        { "app-info",           prim_mock_app_info },
        { "app-list",           prim_mock_app_list },
        { "factory-reset",      prim_mock_factory_reset },
        { "config-set!",        prim_mock_config_set },
        { "display-bench",      prim_mock_display_bench },
        { "tick-bench",         prim_mock_tick_bench },
        { "mem-report",         prim_mock_mem_report },
        { "esp32-mac",          prim_mock_esp32_mac },
        { "esp32-reset-reason", prim_mock_esp32_reset_reason },
        { "esp32-idf-version",  prim_mock_esp32_idf_version },
    };
    for (size_t i = 0; i < sizeof(funcs) / sizeof(funcs[0]); i++) {
        mini_register_c_func(vm, funcs[i].name, funcs[i].fn);
    }
}

/* ========================================================================= */
/* Value Formatting                                                          */
/* ========================================================================= */

static void format_val_rec(MiniVM *vm, Value v, char *buf, size_t max_len, size_t *pos) {
    if (*pos >= max_len - 1) return;
    if (mini_is_fixnum(v)) {
        *pos += snprintf(buf + *pos, max_len - *pos, "%lld", (long long)mini_to_fixnum(v));
    } else if (mini_is_bigint(v)) {
        char *str = mini_bigint_to_str(v, 10);
        if (str) {
            *pos += snprintf(buf + *pos, max_len - *pos, "%s", str);
            free(str);
        }
    } else if (v == MINI_CONST_NIL) {
        *pos += snprintf(buf + *pos, max_len - *pos, "()");
    } else if (v == MINI_CONST_TRUE) {
        *pos += snprintf(buf + *pos, max_len - *pos, "#t");
    } else if (v == MINI_CONST_FALSE) {
        *pos += snprintf(buf + *pos, max_len - *pos, "#f");
    } else if (v == MINI_CONST_VOID) {
        *pos += snprintf(buf + *pos, max_len - *pos, "#<void>");
    } else if (mini_is_symbol(v)) {
        *pos += snprintf(buf + *pos, max_len - *pos, "%s", mini_symbol_name(v));
    } else if (mini_is_string(v)) {
        size_t lit = mini_format_string_literal(buf + *pos, max_len - *pos, v);
        *pos += lit < max_len - *pos ? lit : max_len - *pos - 1;   /* cut: stay inside buf */
    } else if (mini_is_flonum(v)) {
        *pos += snprintf(buf + *pos, max_len - *pos, "%g", mini_to_flonum(v));
    } else if (mini_is_closure(v) || mini_is_cfunc(v)) {
        *pos += snprintf(buf + *pos, max_len - *pos, "#<procedure>");
    } else if (mini_is_vector(v)) {
        *pos += snprintf(buf + *pos, max_len - *pos, "#(");
        size_t len = mini_vector_length(v);
        for (size_t i = 0; i < len; i++) {
            if (i > 0) *pos += snprintf(buf + *pos, max_len - *pos, " ");
            format_val_rec(vm, mini_vector_ref(vm, v, i), buf, max_len, pos);
        }
        *pos += snprintf(buf + *pos, max_len - *pos, ")");
    } else if (mini_is_pair(v)) {
        *pos += snprintf(buf + *pos, max_len - *pos, "(");
        Value curr = v;
        bool first = true;
        while (mini_is_pair(curr)) {
            if (!first) *pos += snprintf(buf + *pos, max_len - *pos, " ");
            first = false;
            format_val_rec(vm, mini_car(curr), buf, max_len, pos);
            curr = mini_cdr(curr);
        }
        if (!mini_is_nil(curr)) {
            *pos += snprintf(buf + *pos, max_len - *pos, " . ");
            format_val_rec(vm, curr, buf, max_len, pos);
        }
        *pos += snprintf(buf + *pos, max_len - *pos, ")");
    } else {
        *pos += snprintf(buf + *pos, max_len - *pos, "#<object>");
    }
}

/* ========================================================================= */
/* Display Pipeline                                                          */
/* ========================================================================= */

/* Mirrors service_display() in the firmware main loop */
__attribute__((visibility("default")))
int wasm_service_display(void) {
    if (!g_dev || g_failed) return 0;   /* a failed app: its error screen stays */
    int rows = 0;
    use_device();
    mini_gui_animate((uint32_t)(js_now_ms() - g_boot_ms)); /* scrolling text, as the firmware loop */
    int errors = mini_gui_service(g_dev, &rows); /* every mode, like the firmware */
    if (!errors) {
        mini_device_app_render_ok();
    } else {
        const char *detail = mini_gui_band_last_error_detail();
        if (detail && detail[0]) {
            js_print("[Render Error Detail]\n", 23);
            js_print(detail, (int)strlen(detail));
            js_print("\n", 1);
        }
        if (!g_settings_mode && mini_device_app_error("render", mini_gui_band_last_error(), (uint32_t)js_now_ms())) {
            char why[160];
            snprintf(why, sizeof(why), "%s", mini_device_app_crash_reason());
            wasm_app_failed("crash", why);
        }
    }
    return errors ? -1 : rows;
}

__attribute__((visibility("default")))
const char *wasm_get_band_error(void) {
    return mini_gui_band_last_error();
}

__attribute__((visibility("default")))
const char *wasm_get_band_error_detail(void) {
    return mini_gui_band_last_error_detail();
}

static void request_full_redraw(void) {
    mini_gui_invalidate(0, mini_gui_get_height());
}

__attribute__((visibility("default")))
void wasm_set_display_mode(int mode) {
    int w = mini_gui_get_width(), h = mini_gui_get_height();
    g_display_mode = (mode >= 0 && mode <= 2) ? mode : 0;
    static const MiniGuiMode modes[3] = { MINI_GUI_MODE_BAND, MINI_GUI_MODE_DIRECT, MINI_GUI_MODE_FULL };
    MiniGuiConfig cfg;
    mini_gui_get_config(&cfg); /* keeps color bits and scheme */
    cfg.width = w;
    cfg.height = h;
    cfg.mode = modes[g_display_mode];
    cfg.band_lines = 13;
    mini_gui_configure(&cfg);
}

__attribute__((visibility("default")))
int wasm_get_display_mode(void) {
    return g_display_mode;
}

/* ========================================================================= */
/* Lifecycle                                                                 */
/* ========================================================================= */

__attribute__((visibility("default")))
int wasm_init(void) {
    if (g_vm) return 0;
    g_boot_ms = js_now_ms();

    /* Compiler VM: large heap, carries init.scm + compiler.scm */
    MiniConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.initial_heap_bytes = 1024 * 1024;
    cfg.stack_size         = 65536;
    cfg.frame_capacity     = 4096;
    cfg.skip_init_fasl     = true;
    g_vm = mini_create_ext(&cfg);
    if (!g_vm) return -1;
    use_compiler();
    Value code_val = msbc_deserialize(g_vm, compiler_msbc_data, compiler_msbc_len);
    if (mini_get_error(g_vm) || !mini_is_code(code_val)) return -2;
    Value clo = mini_make_closure(g_vm, code_val, mini_nil());
    mini_vm_run(g_vm, clo, 0, NULL);
    if (mini_get_error(g_vm)) return -3;
    mini_gc(g_vm);
    g_compiler_baseline_bytes = (uint32_t)mini_get_allocated_bytes(g_vm);

    /* Display: same RGB666 band pipeline as the firmware */
    mini_gui_init_config(MINI_GUI_DEFAULT_WIDTH, MINI_GUI_DEFAULT_HEIGHT, MINI_GUI_MODE_BAND, 13, MINI_GUI_COLOR_RGB565);

    g_dev = create_device_vm();
    if (!g_dev) return -4;
    use_device();
    return 0;
}

__attribute__((visibility("default")))
const char *wasm_get_error(void) {
    if (g_dev && mini_get_error(g_dev)) return mini_get_error(g_dev);
    if (!g_vm) return "VM not initialized";
    return mini_get_error(g_vm);
}

__attribute__((visibility("default")))
void wasm_clear_error(void) {
    if (g_vm) mini_clear_error(g_vm);
    if (g_dev) mini_clear_error(g_dev);
}

/* ========================================================================= */
/* Compile (compiler VM) & Execute (device VM)                               */
/* ========================================================================= */

/* Compiles source to MSBC; keeps the code object for the disassembler */
__attribute__((visibility("default")))
uint8_t *wasm_compile(const char *scm_code) {
    if (!g_vm && wasm_init() != 0) return NULL;
    if (!scm_code) return NULL;
    use_compiler();
    mini_clear_error(g_vm);

    Value helper = env_lookup_name(g_vm, "%compile-source-to-code");
    if (mini_is_void(helper)) {
        vm_error(g_vm, "compiler helper %%compile-source-to-code not found");
        return NULL;
    }
    Value arg = mini_make_string(g_vm, scm_code);
    mini_push_root(g_vm, &arg);
    helper = env_lookup_name(g_vm, "%compile-source-to-code");
    Value code_val = mini_call(g_vm, helper, 1, &arg);
    mini_pop_root(g_vm);

    if (mini_get_error(g_vm) || !mini_is_code(code_val)) {
        if (!mini_get_error(g_vm)) vm_error(g_vm, "compiler returned non-code object");
        return NULL;
    }
    mini_set_global(g_vm, "%last-compiled-code", code_val);

    free(g_msbc_buf);
    g_msbc_buf = NULL;
    g_msbc_len = 0;
    if (!msbc_serialize(g_vm, env_lookup_name(g_vm, "%last-compiled-code"), &g_msbc_buf, &g_msbc_len)) {
        vm_error(g_vm, "failed to serialize MSBC bytecode");
        return NULL;
    }
    return g_msbc_buf;
}

__attribute__((visibility("default")))
uint32_t wasm_get_msbc_size(void) {
    return (uint32_t)g_msbc_len;
}

/* Runs an MSBC/FASL image on the device VM, exactly like the firmware's
 * remote job handler. Returns the printed result or "Error: ...". */
static const char *run_image_on_device(const uint8_t *buf, size_t len) {
    use_device();
    mini_clear_error(g_dev);
    Value res = mini_void();
    if (len >= 4 && memcmp(buf, "MFAS", 4) == 0) {
        if (mini_load_fasl_mem(g_dev, buf, len) && !mini_get_error(g_dev)) {
            mini_device_resume_app(g_dev);
            res = mini_true();
        }
    } else if (len >= 4 && memcmp(buf, "MSBC", 4) == 0) {
        Value code_val = msbc_deserialize(g_dev, buf, len);
        if (!mini_get_error(g_dev) && mini_is_code(code_val)) {
            mini_push_root(g_dev, &code_val);
            Value clo = mini_make_closure(g_dev, code_val, mini_nil());
            mini_pop_root(g_dev);
            mini_push_root(g_dev, &clo);
            res = mini_vm_run(g_dev, clo, 0, NULL);
            mini_pop_root(g_dev);
        } else if (!mini_get_error(g_dev)) {
            vm_error(g_dev, "invalid MSBC code object");
        }
    } else {
        vm_error(g_dev, "payload is not an MSBC image");
    }
    request_full_redraw();
    if (mini_get_error(g_dev)) {
        snprintf(g_out_buf, sizeof(g_out_buf), "Error: %s", mini_get_error(g_dev));
        mini_clear_error(g_dev);
        return g_out_buf;
    }
    g_out_buf[0] = '\0';
    size_t pos = 0;
    format_val_rec(g_dev, res, g_out_buf, sizeof(g_out_buf), &pos);
    return g_out_buf;
}

/* ------------------------------------------------------------------------- */
/* App boot, as on the board: a fresh device VM runs the app's bytecode and  */
/* literals in place from a Code ROM image (stands in for the approm         */
/* partition). The bump allocator never frees, so the old VM's memory and    */
/* one scratch VM, reused for every build, stay allocated.                    */
/* ------------------------------------------------------------------------- */
#define DEV_ROM_BYTES (256 * 1024) /* approm partition size */
#define DEV_ROM_KEY   0x4D524F4Du
static uint8_t *g_rom = NULL;
/* The app's bytes for the streaming build, as the firmware reads its file */
typedef struct {
    const uint8_t *p;
    size_t n, pos;
} RomMemIn;

static size_t rom_mem_read(void *buf, size_t n, void *user) {
    RomMemIn *in = (RomMemIn *)user;
    size_t k = in->n - in->pos < n ? in->n - in->pos : n;
    memcpy(buf, in->p + in->pos, k);
    in->pos += k;
    return k;
}

static bool rom_buffer_write(size_t off, const void *data, size_t len, void *user) {
    (void)user;
    if (off + len > DEV_ROM_BYTES) return false;
    memcpy(g_rom + off, data, len);
    return true;
}

const char *wasm_boot_app(const uint8_t *buf, uint32_t len);

/* As the firmware's app_failed: the reason on the screen for 5 s, then the
 * system settings, which show it again (never from the settings themselves) */
static void wasm_app_failed(const char *phase, const char *reason) {
    if (g_settings_mode || g_failed) return;
    char why[120];
    snprintf(why, sizeof(why), "%s", reason ? reason : "");
    char line[200];
    snprintf(line, sizeof(line), "[device] app failed (%s): %s; the system settings in 5 s\n", phase, why);
    js_print(line, (int)strlen(line));
    if (g_dev) {
        mini_get_stats(g_dev, &g_last_app_stats);
        g_last_app_heap = mini_get_heap_size(g_dev);
    }
    snprintf(g_last_app_id, sizeof(g_last_app_id), "%s", g_app_id);
    snprintf(g_last_app_phase, sizeof(g_last_app_phase), "%s", phase);
    snprintf(g_last_app_error, sizeof(g_last_app_error), "%s", why);
    g_last_app_valid = true;
    mini_gui_set_hold_overlay(0, 0, 0, 0);
    mini_device_error_screen(mini_device_fail_title(phase), g_app_name[0] ? g_app_name : g_app_id, why);
    g_failed = true;
    g_settings_boot = true;
    g_restart_pending = true;
    g_restart_at = js_now_ms() + 5000;
}

/* After an app hook, as the firmware's check_app_error */
static void wasm_check_app_error(const char *where) {
    const char *err = mini_get_error(g_dev);
    if (err && !g_settings_mode && !g_failed && mini_device_app_error(where, err, (uint32_t)js_now_ms())) {
        char why[160];
        snprintf(why, sizeof(why), "%s", mini_device_app_crash_reason());
        mini_clear_error(g_dev);
        wasm_app_failed("crash", why);
    }
    mini_clear_error(g_dev);
}

/* Power-on as on the board: fonts loaded by the last app are gone, a fresh
 * device VM reads config.ini ([fonts]) again and boots the installed app,
 * /spiffs/app.fasl else /spiffs/app.msbc. Returns "" when none is installed
 * (the page then boots its bundled app, like the firmware's embedded one). */
/* (factory-reset what), as the firmware's: the simulated Code ROM, the apps'
 * configs, the font ROM, every file (config.ini written again as on a first
 * boot) or all but the fonts; then the built-in settings 1.5 s later */
static Value prim_mock_factory_reset(MiniVM *vm, int argc, Value *argv) {
    if (!mini_access_privileged(vm, "factory-reset")) return mini_void();
    if (argc != 1 || !mini_is_symbol(argv[0])) {
        vm_error(vm, "factory-reset: expected 'rom, 'configs, 'fonts, 'files or 'all");
        return mini_void();
    }
    if (!g_settings_mode) return mini_make_string(vm, "factory-reset: only in the system settings");
    const char *what = mini_symbol_name(argv[0]);
    bool all = strcmp(what, "all") == 0;
    if (!all && strcmp(what, "rom") && strcmp(what, "configs") && strcmp(what, "fonts") && strcmp(what, "files")) {
        return mini_make_string(vm, "factory-reset: expected rom, configs, fonts, files or all");
    }
    if ((all || !strcmp(what, "rom")) && g_rom) memset(g_rom, 0xFF, DEV_ROM_BYTES);
    if (all || !strcmp(what, "files") || !strcmp(what, "configs")) {
        bool files = all || !strcmp(what, "files");
        for (int i = 0; i < MOCK_FS_FILES; i++) {
            if (!g_mock_fs[i].used) continue;
            const char *path = g_mock_fs[i].path;
            size_t pl = strlen(path);
            bool config = (!strncmp(path, "/spiffs/apps/", 13) || !strncmp(path, "/spiffs/user/", 13)) &&
                          pl > 11 && !strcmp(path + pl - 11, "/config.ini");
            if (files || config) mock_fs_remove(path);
        }
        if (files) {   /* the firmware's first boot writes it */
            mock_fs_put("/spiffs/config.ini", (const uint8_t *)mini_device_config_template,
                        strlen(mini_device_config_template));
        }
    }
    if (!strcmp(what, "fonts") && mini_fontrom_present()) {
        for (int id = 1; id < MINI_FONT_SLOTS; id++) mini_font_unload(id);
        for (int guard = 0; mini_fontrom_count() > 0 && guard < 64; guard++) {
            char name[48];
            const char *entry = mini_fontrom_entry(0, NULL, NULL);
            if (!entry) break;
            snprintf(name, sizeof(name), "%s", entry);
            if (mini_fontrom_remove(name)) return mini_make_string(vm, "factory-reset: font ROM erase failed");
        }
    }
    g_builtin_boot = true;
    g_settings_boot = true;
    g_restart_pending = true;
    g_restart_at = js_now_ms() + 1500;
    return mini_true();
}

__attribute__((visibility("default")))
const char *wasm_reboot(void) {
    if (!g_dev && wasm_init() != 0) return "Error: VM initialization failed";
    g_restart_pending = false;
    g_failed = false;
    g_restart_at = 0;
    mini_device_app_health_reset();
    for (int id = 0; id < MINI_FONT_SLOTS; id++) mini_font_unload(id);
    mock_fs_seed();
    g_mock_ap = false;
    g_settings_mode = g_settings_boot;
    g_settings_boot = false;
    mock_migrate_layout();
    mini_app_set_storage(256 * 1024, mock_dir_used);
    mini_app_sandbox_set("");                  /* set again once the app is known */
    mini_image_set_io(&g_mock_image_io);
    {   /* apps' https:// feeds go through the protocol converter, as on the board */
        char conv[128] = "";
        if (!mock_ini_value("/spiffs/config.ini", "https_proxy", conv, sizeof(conv)) || !conv[0]) {
            if (!mock_ini_value("/spiffs/config.ini", "proxy", conv, sizeof(conv)) || !conv[0]) {
                snprintf(conv, sizeof(conv), "%s", g_mock_proxy_url);
            }
        }
        mini_json_feed_set_https_proxy(conv);
    }
    bool builtin_settings = g_builtin_boot && g_settings_mode;   /* after a factory reset */
    g_builtin_boot = false;
    /* the market starts over, as after a power-on, with this boot's automatic round */
    mk_attach();
    if (mini_market_state() == MINI_MARKET_REFRESHING || mini_market_state() == MINI_MARKET_INSTALLING)
        mini_market_cancel();
    mini_market_release();
    {
        int market_auto = g_market_auto;
        g_market_auto = MARKET_AUTO_NONE;
        if (g_settings_mode && market_auto == MARKET_AUTO_NEXT_UPDATE) {
            g_market_auto = MARKET_AUTO_NEXT_SKIP;
            mini_market_auto_start(MINI_MARKET_AUTO_UPDATE);
        } else if (!g_settings_mode && market_auto != MARKET_AUTO_NEXT_SKIP) {
            mini_market_auto_start(MINI_MARKET_AUTO_CHECK);
        } else {
            mini_market_auto_start(MINI_MARKET_AUTO_OFF);
        }
    }
    if (!g_settings_mode) {
        g_last_app_valid = false;
        g_last_app_error[0] = '\0';
    }
    mini_device_button_system_gesture(!g_settings_mode);
    {   /* the KEY 18 times, as the firmware reads them at boot */
        int cfg = mock_fs_find("/spiffs/config.ini");
        mini_device_button_config(cfg >= 0 ? (const char *)g_mock_fs[cfg].data : NULL);
    }
    if (g_settings_mode) {
        snprintf(g_app_path, sizeof(g_app_path), "(system settings)");
        snprintf(g_app_id, sizeof(g_app_id), "settings");
        snprintf(g_app_dir, sizeof(g_app_dir), "/spiffs/apps/settings");
        snprintf(g_app_ini, sizeof(g_app_ini), "/spiffs/apps/settings/config.ini");
        /* as the firmware: the settings from the market when valid, else the built-in bootstrap */
        int ss = mock_fs_find("/spiffs/apps/settings/app.msbc");
        char *text = mock_has_magic(ss, "MSBC") ? mock_meta_text(ss) : NULL;
        char why[112];
        if (!builtin_settings && text &&
            mini_market_use_installed("settings", text, app_settings_msbc_data, APP_SETTINGS_MSBC_LEN,
                                              why, sizeof(why))) {
            size_t len = g_mock_fs[ss].len;
            uint8_t *copy = (uint8_t *)malloc(len);
            const char *r = copy ? (memcpy(copy, g_mock_fs[ss].data, len), wasm_boot_app(copy, (uint32_t)len))
                                 : "Error: out of memory";
            free(copy);
            free(text);
            if (strncmp(r, "Error: ", 7) != 0) return r;
            const char *note = "[settings] /spiffs/apps/settings/app.msbc failed, using the built-in copy\n";
            js_print(note, (int)strlen(note));
        } else {
            if (text && !builtin_settings) {
                js_print("[settings] /spiffs/apps/settings/app.msbc not used: ", 52);
                js_print(why, (int)strlen(why));
                js_print("\n", 1);
            }
            free(text);
        }
        return wasm_boot_app(app_settings_msbc_data, APP_SETTINGS_MSBC_LEN);
    }
    int slot = mock_select_boot_app();
    mini_app_sandbox_set(g_app_dir);           /* the app's own code touches only its folder */
    if (slot < 0) {
        MiniVM *fresh = create_device_vm(); /* config.ini read again */
        if (fresh) {
            mini_destroy(g_dev);
            g_dev = fresh;
            use_device();
        }
        return "";
    }
    /* a copy: the app may write files while it boots */
    size_t len = g_mock_fs[slot].len;
    uint8_t *copy = (uint8_t *)malloc(len ? len : 1);
    if (!copy) return "Error: out of memory booting the app";
    memcpy(copy, g_mock_fs[slot].data, len);
    const char *r = wasm_boot_app(copy, (uint32_t)len);
    free(copy);
    if (strncmp(r, "Error: ", 7) == 0) wasm_app_failed(g_boot_phase, r + 7);
    return r;
}

__attribute__((visibility("default")))
const char *wasm_boot_app(const uint8_t *buf, uint32_t len) {
    if (!g_dev && wasm_init() != 0) return "Error: VM initialization failed";
    snprintf(g_boot_phase, sizeof(g_boot_phase), "load");
    /* as the firmware: an app needing another API version does not start */
    size_t mlen = 0;
    const char *meta = buf ? mini_app_meta_find(buf, len, &mlen) : NULL;
    char *text = meta ? (char *)malloc(mlen + 1) : NULL;
    if (text) {
        memcpy(text, meta, mlen);
        text[mlen] = '\0';
        char why[128];
        bool ok = mini_api_check_meta(text, why, sizeof(why));
        free(text);
        if (!ok) {
            snprintf(g_boot_phase, sizeof(g_boot_phase), "api");
            snprintf(g_out_buf, sizeof(g_out_buf), "Error: %s", why);
            return g_out_buf;
        }
    }
    if (buf && len >= 4 && memcmp(buf, "MFAS", 4) == 0) {
        /* app.fasl: a heap snapshot restored into a fresh device VM */
        MiniVM *fresh = create_device_vm();
        if (!fresh) return "Error: out of memory booting the app";
        mini_destroy(g_dev);
        g_dev = fresh;
        return run_image_on_device(buf, len);
    }
    if (!buf || len < 4 || memcmp(buf, "MSBC", 4) != 0) return run_image_on_device(buf, len);
    if (!g_rom) g_rom = (uint8_t *)malloc(DEV_ROM_BYTES);
    MiniVM *dev = create_device_vm();
    if (!g_rom || !dev) return "Error: out of memory booting the app";
    mini_destroy(g_dev);
    g_dev = dev;

    /* streamed from the bytecode as the firmware does (no scratch VM) */
    RomMemIn in = { buf, len, 0 };
    memset(g_rom, 0xFF, DEV_ROM_BYTES);   /* erased flash */
    const char *err = NULL;
    size_t size = mini_rom_build_stream(rom_mem_read, &in, (uintptr_t)g_rom, NULL, DEV_ROM_KEY,
                                        rom_buffer_write, NULL, NULL, &err);

    use_device();
    Value root = size ? mini_rom_attach(g_dev, g_rom, DEV_ROM_BYTES, DEV_ROM_KEY) : mini_void();
    if (!mini_is_code(root)) {   /* as the firmware: a failed image build is an error */
        snprintf(g_boot_phase, sizeof(g_boot_phase), "rom");
        snprintf(g_out_buf, sizeof(g_out_buf), "Error: %s", err ? err : "rom: image fails verification");
        return g_out_buf;
    }
    snprintf(g_boot_phase, sizeof(g_boot_phase), "load");
    mini_clear_error(g_dev);
    Value clo = mini_make_closure(g_dev, root, mini_nil());
    mini_push_root(g_dev, &clo);
    mini_vm_run(g_dev, clo, 0, NULL);
    mini_pop_root(g_dev);
    request_full_redraw();
    if (mini_get_error(g_dev)) {
        snprintf(g_out_buf, sizeof(g_out_buf), "Error: %s", mini_get_error(g_dev));
        mini_clear_error(g_dev);
        return g_out_buf;
    }
    snprintf(g_out_buf, sizeof(g_out_buf), "booted from a %u-byte Code ROM image", (unsigned)size);
    return g_out_buf;
}

/* Executes the most recent wasm_compile() output on the device VM */
__attribute__((visibility("default")))
const char *wasm_exec_last(void) {
    if (!g_msbc_buf || g_msbc_len == 0) return "Error: nothing compiled";
    mini_app_privileged_begin();       /* the REPL is the owner, not the app's sandbox */
    const char *r = run_image_on_device(g_msbc_buf, g_msbc_len);
    mini_app_privileged_end();
    return r;
}

__attribute__((visibility("default")))
const char *wasm_exec_msbc(const uint8_t *buf, uint32_t len) {
    if (!g_dev && wasm_init() != 0) return "Error: VM initialization failed";
    if (!buf || len == 0) return "Error: empty payload";
    mini_app_privileged_begin();
    const char *r = run_image_on_device(buf, len);
    mini_app_privileged_end();
    return r;
}

/* Compile in the compiler VM, then run the bytecode on the device VM */
__attribute__((visibility("default")))
const char *wasm_eval(const char *scm_code) {
    if (!g_vm && wasm_init() != 0) return "Error: VM initialization failed";
    if (!scm_code) return "";
    if (!wasm_compile(scm_code)) {
        snprintf(g_out_buf, sizeof(g_out_buf), "Error: %s", mini_get_error(g_vm) ? mini_get_error(g_vm) : "compile failed");
        mini_clear_error(g_vm);
        return g_out_buf;
    }
    return wasm_exec_last();
}

/* Opcode names table for the disassembler */
static const char *OPCODE_NAMES[] = {
    "OP_HALT", "OP_CONST", "OP_INT8", "OP_NIL", "OP_TRUE", "OP_FALSE", "OP_VOID",
    "OP_GET_LOCAL", "OP_SET_LOCAL", "OP_GET_UPVALUE", "OP_SET_UPVALUE",
    "OP_GET_GLOBAL", "OP_SET_GLOBAL", "OP_DEF_GLOBAL", "OP_POP",
    "OP_JUMP", "OP_JUMP_IF_FALSE", "OP_CLOSURE", "OP_CALL", "OP_TAIL_CALL",
    "OP_RETURN", "OP_TAIL_CALL_SELF"
};

static const char *disasm_code(Value code_val) {
    CodeObj *co = (CodeObj *)UNTAG_PTR(code_val);
    int pos = 0;
    int cap = (int)sizeof(g_disasm_buf);
    pos += snprintf(g_disasm_buf + pos, cap - pos,
                    ";; MiniScheme Bytecode Disassembly\n"
                    ";; Code size: %u bytes, Consts: %u, Stack: %u, Params: %u\n\n",
                    co->code_len, co->num_consts, co->max_stack, co->num_params);

    Value *consts = CODE_CONSTS(co);
    if (co->num_consts > 0) {
        pos += snprintf(g_disasm_buf + pos, cap - pos, "; Constants:\n");
        for (uint16_t i = 0; i < co->num_consts && pos < cap - 80; i++) {
            Value c = consts[i];
            if (mini_is_fixnum(c)) {
                pos += snprintf(g_disasm_buf + pos, cap - pos, "  #%u: %lld\n", i, (long long)mini_to_fixnum(c));
            } else if (mini_is_symbol(c)) {
                pos += snprintf(g_disasm_buf + pos, cap - pos, "  #%u: '%s\n", i, mini_symbol_name(c));
            } else if (mini_is_string(c)) {
                pos += snprintf(g_disasm_buf + pos, cap - pos, "  #%u: \"%s\"\n", i, mini_string_data(c));
            } else if (mini_is_flonum(c)) {
                pos += snprintf(g_disasm_buf + pos, cap - pos, "  #%u: %g\n", i, mini_to_flonum(c));
            } else if (mini_is_code(c)) {
                pos += snprintf(g_disasm_buf + pos, cap - pos, "  #%u: <nested-code>\n", i);
            } else {
                pos += snprintf(g_disasm_buf + pos, cap - pos, "  #%u: <obj>\n", i);
            }
        }
        pos += snprintf(g_disasm_buf + pos, cap - pos, "\n");
    }

    pos += snprintf(g_disasm_buf + pos, cap - pos, "; Instructions:\n");
    const uint8_t *code = CODE_BYTES(co);
    uint32_t pc = 0;
    while (pc < co->code_len && pos < cap - 80) {
        uint8_t op = code[pc];
        const char *op_name = (op < (sizeof(OPCODE_NAMES) / sizeof(OPCODE_NAMES[0]))) ? OPCODE_NAMES[op] : "UNKNOWN";
        pos += snprintf(g_disasm_buf + pos, cap - pos, "  %04x: %-16s", pc, op_name);
        pc++;
        switch (op) {
            case OP_CONST:
            case OP_GET_GLOBAL:
            case OP_SET_GLOBAL:
            case OP_DEF_GLOBAL:
            case OP_CLOSURE:
            case OP_JUMP:
            case OP_JUMP_IF_FALSE:
                if (pc + 2 <= co->code_len) {
                    uint16_t arg = (uint16_t)(code[pc] | (code[pc + 1] << 8));
                    pc += 2;
                    pos += snprintf(g_disasm_buf + pos, cap - pos, " #%u", arg);
                }
                break;
            case OP_INT8:
                if (pc < co->code_len) {
                    int8_t v = (int8_t)code[pc++];
                    pos += snprintf(g_disasm_buf + pos, cap - pos, " %d", (int)v);
                }
                break;
            case OP_GET_LOCAL:
            case OP_SET_LOCAL:
            case OP_CALL:
            case OP_TAIL_CALL:
                if (pc < co->code_len) {
                    pos += snprintf(g_disasm_buf + pos, cap - pos, " %u", (unsigned)code[pc++]);
                }
                break;
            case OP_GET_UPVALUE:
            case OP_SET_UPVALUE:
                if (pc + 2 <= co->code_len) {
                    uint8_t d = code[pc++];
                    uint8_t idx = code[pc++];
                    pos += snprintf(g_disasm_buf + pos, cap - pos, " depth=%u, slot=%u", (unsigned)d, (unsigned)idx);
                }
                break;
            default:
                break;
        }
        pos += snprintf(g_disasm_buf + pos, cap - pos, "\n");
    }
    return g_disasm_buf;
}

__attribute__((visibility("default")))
const char *wasm_disasm_last(void) {
    if (!g_vm) return "";
    use_compiler();
    Value code_val = env_lookup_name(g_vm, "%last-compiled-code");
    if (!mini_is_code(code_val)) return ";; nothing compiled yet";
    return disasm_code(code_val);
}

/* Legacy entry: compiles again, then disassembles */
__attribute__((visibility("default")))
const char *wasm_disasm(const char *scm_code) {
    if (!wasm_compile(scm_code)) {
        snprintf(g_disasm_buf, sizeof(g_disasm_buf), "Compile error: %s",
                 mini_get_error(g_vm) ? mini_get_error(g_vm) : "invalid code object");
        return g_disasm_buf;
    }
    return wasm_disasm_last();
}

/* ========================================================================= */
/* Device Runtime Hooks (mirror the firmware main loop)                      */
/* ========================================================================= */

/* 1 Hz tick with a host wall clock. tick_sec is the second of the UTC day,
 * as the firmware passes once synced (apps run world clocks from it);
 * lux/backlight are sampled every 3 s like the firmware. */
__attribute__((visibility("default")))
int wasm_tick_wall(int year, int month, int day, int hour, int minute, int second, int wday, int tick_sec) {
    if (!g_dev || g_failed) return 0;
    use_device();
    if (tick_sec % 3 == 0 || g_last_lux < 0) {
        g_last_lux = (mini_light_read() * 1000) / 4095;
        g_last_bl = mini_backlight_get();
    }
    MiniWallTime t;
    memset(&t, 0, sizeof(t));
    t.synced = g_sim_time_synced;
    t.year = year; t.month = month; t.day = day;
    t.hour = hour; t.minute = minute; t.second = second; t.wday = wday;
    mini_device_clock_tick(g_dev, &t, tick_sec, g_last_lux, g_last_bl);
    if (mini_get_error(g_dev)) {
        js_print("[device] app-tick: ", 19);
        js_print(mini_get_error(g_dev), (int)strlen(mini_get_error(g_dev)));
        js_print("\n", 1);
        wasm_check_app_error("app-tick");
        return -1;
    }
    return 1;
}

__attribute__((visibility("default")))
void wasm_set_time_synced(int synced) {
    g_sim_time_synced = synced != 0;
}

__attribute__((visibility("default")))
int wasm_get_time_synced(void) {
    return g_sim_time_synced ? 1 : 0;
}

__attribute__((visibility("default")))
int wasm_app_touch(int x, int y) {
    Value args[2] = { mini_make_fixnum(x), mini_make_fixnum(y) };
    use_device();
    mini_device_call_hook(g_dev, "app-touch", NULL, 2, args);
    if (mini_get_error(g_dev)) { mini_clear_error(g_dev); return -1; }
    return 1;
}

/* Full redraw: invalidation in band mode, immediate render otherwise */
__attribute__((visibility("default")))
int wasm_app_render(void) {
    request_full_redraw(); /* drawn by the next wasm_service_display */
    return 1;
}

/* KEY 18 as the firmware reads it: the page passes the button state on
 * every change and every ~40 ms while it matters. Returns the gesture
 * (0 none, 1 short press, 2 long press, 3 settings opened (a mid press on the hardware pages),
 * 4 the hold: hardware pages, 5 mid press) */
__attribute__((visibility("default")))
int wasm_button_update(int pressed, uint32_t now_ms) {
    if (!g_dev || g_failed) return 0;
    use_device();
    mini_clear_error(g_dev);
    mini_button_set(pressed != 0);
    MiniButtonEvent ev = mini_device_button_update(g_dev, pressed != 0, now_ms);
    wasm_check_app_error("button");
    if (ev == MINI_BUTTON_SYSTEM && !g_settings_mode) {
        /* as the firmware: remember the app, restart into the embedded system settings */
        mini_get_stats(g_dev, &g_last_app_stats);
        g_last_app_heap = mini_get_heap_size(g_dev);
        snprintf(g_last_app_id, sizeof(g_last_app_id), "%s", g_app_id);
        g_last_app_valid = true;
        g_settings_boot = true;
        g_restart_pending = true;
    }
    return (int)ev;
}

/* Held time of the current press (ms), 0 when released */
__attribute__((visibility("default")))
uint32_t wasm_button_held_ms(uint32_t now_ms) { return mini_device_button_held_ms(now_ms); }

/* Main-loop step, called by the page like the firmware loop does */
__attribute__((visibility("default")))
int wasm_app_step(void) {
    if (!g_dev || g_failed) return 0;
    use_device();
    mini_clear_error(g_dev);
    mini_device_call_hook(g_dev, "app-step", NULL, 0, NULL);
    bool failed = mini_get_error(g_dev) != NULL;
    wasm_check_app_error("app-step");
    return failed ? -1 : 1;
}

/* ========================================================================= */
/* App market (minischeme_market.c): the page fetches, the mock fs stores     */
/* ========================================================================= */

/* One fetch at a time, as on the board: the page takes the URL
 * (wasm_market_request), fetches it through server.py and hands the bytes
 * back (wasm_market_response) */
static struct {
    char url[240];
    char file[64];      /* "" : into memory */
    size_t max;
    int state;          /* 0 waiting for the page, 3 fetching, 1 done, -1 failed, 2 idle */
    size_t len, total;
    char *buf;
    char err[64];
} MK = { .state = 2 };

static bool mk_fetch_start(const char *url, const char *file, size_t max) {
    if (MK.state == 0 || MK.state == 3) return false;
    free(MK.buf);
    MK.buf = NULL;
    MK.len = MK.total = 0;
    MK.err[0] = '\0';
    snprintf(MK.url, sizeof(MK.url), "%s", url);
    snprintf(MK.file, sizeof(MK.file), "%s", file ? file : "");
    MK.max = max ? max : 512 * 1024;
    MK.state = 0;
    return true;
}

static int mk_fetch_poll(size_t *received, size_t *total, const char **err) {
    *received = MK.len;
    *total = MK.total;
    *err = MK.err;
    return (MK.state == 0 || MK.state == 3) ? 0 : (MK.state == 1 ? 1 : -1);
}

static const char *mk_fetch_data(size_t *len) {
    *len = MK.len;
    return MK.buf;
}

static void mk_fetch_release(void) {
    free(MK.buf);
    MK.buf = NULL;
    MK.len = 0;
    if (MK.state != 0 && MK.state != 3) MK.state = 2;
}

static void mk_fetch_cancel(void) {
    MK.state = 2;   /* a late response is dropped */
    mk_fetch_release();
}

static bool mk_file_hash(const char *path, size_t *size, uint32_t *hash, uint8_t head[4]) {
    int slot = mock_fs_find(path);
    if (slot < 0) return false;
    const uint8_t *d = g_mock_fs[slot].data;
    size_t n = g_mock_fs[slot].len;
    memset(head, 0, 4);
    memcpy(head, d, n < 4 ? n : 4);
    *size = n;
    *hash = mini_fnv1a(d, n);
    return true;
}

static char *mk_file_meta(const char *path) {
    int slot = mock_fs_find(path);
    size_t mlen = 0;
    const char *meta = mock_meta(slot, &mlen);
    char *text = meta ? (char *)malloc(mlen + 1) : NULL;
    if (text) {
        memcpy(text, meta, mlen);
        text[mlen] = '\0';
    }
    return text;
}

static bool mk_file_replace(const char *tmp, const char *path) {
    int slot = mock_fs_find(tmp);
    if (slot < 0) return false;
    size_t n = g_mock_fs[slot].len;
    uint8_t *copy = (uint8_t *)malloc(n ? n : 1);
    if (!copy) return false;
    memcpy(copy, g_mock_fs[slot].data, n);
    mock_fs_remove(tmp);
    const char *err = mock_fs_put(path, copy, n);
    free(copy);
    return err == NULL;
}

static void mk_file_remove(const char *path) { mock_fs_remove(path); }

static bool mk_config(const char *key, char *out, size_t cap) {
    mock_fs_seed();
    out[0] = '\0';
    if (mock_ini_value("/spiffs/config.ini", key, out, cap) && out[0]) return true;
    /* as prim_mock_config_get: the simulator's proxy is this PC's */
    if (strcmp(key, "proxy") == 0) {
        snprintf(out, cap, "%s", g_mock_proxy_url);
        return true;
    }
    return false;
}

static bool mk_online(void) { return true; }

/* as the firmware: installs only in the system settings */
static bool mk_install_here(void) { return g_settings_mode; }

/* The boot check found updates: the settings a second later, as the firmware */
static void mk_auto_update(void) {
    g_market_auto = MARKET_AUTO_NEXT_UPDATE;
    g_settings_boot = true;
    g_restart_pending = true;
    g_restart_at = js_now_ms() + 1000;
}

/* The market's view of the system settings built into the simulator */
static const uint8_t *mk_builtin(const char *id, size_t *len) {
    if (strcmp(id, "settings") != 0) return NULL;
    *len = APP_SETTINGS_MSBC_LEN;
    return app_settings_msbc_data;
}

static void mk_log(const char *msg) {
    js_print("[market] ", 9);
    js_print(msg, (int)strlen(msg));
    js_print("\n", 1);
}

static const MiniMarketHost MK_HOST = {
    mk_fetch_start, mk_fetch_poll, mk_fetch_data, mk_fetch_release, mk_fetch_cancel,
    mk_file_hash, mk_file_meta, mk_file_replace, mk_file_remove, mk_config, mk_online, mk_log, mk_install_here,
    mk_auto_update, mk_builtin,
};

static void mk_attach(void) { mini_market_set_host(&MK_HOST); }

/* The running app's own web page (minischeme_device.h), as the board's /app:
 * the gzip'd bytes inside its image; the WebREPL's app page panel unpacks it */
static uint32_t g_app_web_len = 0;

__attribute__((visibility("default")))
const uint8_t *wasm_app_web_page(void) {
    g_app_web_len = 0;
    if (g_settings_mode) return NULL;
    int slot = mock_fs_find(g_app_path);
    size_t n = 0;
    const uint8_t *page = slot >= 0 ? mini_app_web_find(g_mock_fs[slot].data, g_mock_fs[slot].len, &n) : NULL;
    g_app_web_len = page ? (uint32_t)n : 0;
    return page;
}

__attribute__((visibility("default")))
uint32_t wasm_app_web_len(void) { return g_app_web_len; }

/* The app's name for the panel's title */
__attribute__((visibility("default")))
const char *wasm_app_web_name(void) { return g_app_name[0] ? g_app_name : g_app_id; }

/* As the board's /api/app/call: (app-web name body) on the device VM; the
 * answer string, and wasm_app_web_failed() when it is a JSON error */
static int g_app_web_failed = 0;

__attribute__((visibility("default")))
int wasm_app_web_failed(void) { return g_app_web_failed; }

/* As the board's /api/app/file: the running app's own files for its web
 * page. A name is relative to the app's folder, one folder level at most;
 * its image and config.ini stay out of reach (main.c app_file_name_ok). */
static bool app_file_name_ok(const char *n) {
    size_t len = strlen(n);
    if (len == 0 || len > 64 || n[0] == '/' || n[len - 1] == '/' || strstr(n, "..") || strstr(n, "//")) return false;
    int slashes = 0;
    for (const char *p = n; *p; p++) {
        char c = *p;
        if (c == '/') {
            if (++slashes > 1) return false;
        } else if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
                     c == '_' || c == '-' || c == '.')) {
            return false;
        }
    }
    return strcmp(n, "app.msbc") != 0 && strcmp(n, "app.fasl") != 0 && strcmp(n, "config.ini") != 0;
}

static bool app_file_path(const char *name, char *out, size_t cap) {
    if (!g_dev || g_settings_mode || !g_app_dir[0] || !name || !app_file_name_ok(name)) return false;
    return snprintf(out, cap, "%s/%s", g_app_dir, name) < (int)cap;
}

static size_t g_app_file_len = 0;

/* A file's bytes (wasm_app_file_len() of them), NULL when there is none */
__attribute__((visibility("default")))
const uint8_t *wasm_app_file_read(const char *name) {
    char path[160];
    int slot = app_file_path(name, path, sizeof(path)) ? mock_fs_find(path) : -1;
    g_app_file_len = slot >= 0 ? g_mock_fs[slot].len : 0;
    return slot >= 0 ? g_mock_fs[slot].data : NULL;
}

__attribute__((visibility("default")))
uint32_t wasm_app_file_len(void) { return (uint32_t)g_app_file_len; }

/* Writes (data, len) or removes (data NULL) a file; the JSON answer */
__attribute__((visibility("default")))
const char *wasm_app_file_write(const char *name, const uint8_t *data, uint32_t len) {
    static char out[160];
    char path[160], why[96] = "";
    if (!app_file_path(name, path, sizeof(path))) {
        snprintf(out, sizeof(out), "{\"success\":false,\"error\":\"name: a file of the app's folder\"}");
        return out;
    }
    int slot = mock_fs_find(path);
    const char *err = NULL;
    if (!data) {
        err = mock_fs_remove(path);
    } else if (len == 0 || len > 512 * 1024) {
        err = "a file of 1 byte to 512 KB";
    } else if (!mini_app_storage_ok(len, slot >= 0 ? g_mock_fs[slot].len : 0, why, sizeof(why))) {
        err = why;
    } else {
        err = mock_fs_put(path, data, len);
    }
    mini_gui_image_forget();
    request_full_redraw();
    if (err) snprintf(out, sizeof(out), "{\"success\":false,\"error\":\"%s\"}", err);
    else snprintf(out, sizeof(out), "{\"success\":true,\"size\":%u}", (unsigned)(data ? len : 0));
    return out;
}

__attribute__((visibility("default")))
const char *wasm_app_web_call(const char *name, const char *body, uint32_t len) {
    static char out[8192];
    g_app_web_failed = 1;
    if (!g_dev || g_settings_mode) {
        snprintf(out, sizeof(out), "{\"success\":false,\"error\":\"no app runs (system settings)\"}");
        return out;
    }
    use_device();
    mini_clear_error(g_dev);
    Value fn = mini_get_global(g_dev, "app-web");
    if (!(mini_is_closure(fn) || mini_is_cfunc(fn))) {
        snprintf(out, sizeof(out), "{\"success\":false,\"error\":\"this app has no (app-web name body)\"}");
        return out;
    }
    Value args[2] = { mini_void(), mini_void() };
    mini_push_root(g_dev, &args[0]);
    mini_push_root(g_dev, &args[1]);
    args[0] = mini_make_string(g_dev, name ? name : "");
    args[1] = mini_make_string_len(g_dev, body ? body : "", body ? len : 0);
    Value res = mini_call(g_dev, fn, 2, args);
    mini_pop_root(g_dev);
    mini_pop_root(g_dev);
    if (mini_get_error(g_dev)) {
        char esc[300];
        size_t k = 0;
        for (const char *p = mini_get_error(g_dev); *p && k < sizeof(esc) - 3; p++) {
            if (*p == '"' || *p == '\\') esc[k++] = '\\';
            esc[k++] = (*p == '\n' || *p == '\r') ? ' ' : *p;
        }
        esc[k] = '\0';
        snprintf(out, sizeof(out), "{\"success\":false,\"error\":\"%s\"}", esc);
        mini_clear_error(g_dev);
        return out;
    }
    g_app_web_failed = 0;
    if (mini_is_string(res)) {
        size_t n = mini_string_len(res);
        if (n >= sizeof(out)) n = sizeof(out) - 1;
        memcpy(out, mini_string_data(res), n);
        out[n] = '\0';
    } else {
        snprintf(out, sizeof(out), "%s", mini_is_void(res) ? "" : "(not a string)");
    }
    request_full_redraw();   /* the call may have changed what the app shows */
    return out;
}

/* The page's housekeeping: advance the market. The URL to fetch, or "" */
__attribute__((visibility("default")))
const char *wasm_market_request(void) {
    mini_market_poll();
    if (!g_restart_pending) mini_market_auto((uint32_t)(js_now_ms() - g_boot_ms));
    if (MK.state != 0) return "";
    MK.state = 3;
    return MK.url;
}

/* The page's answer: status 1 = the bytes, else a failure */
__attribute__((visibility("default")))
void wasm_market_response(const uint8_t *buf, uint32_t len, int status) {
    if (MK.state != 3) return;   /* cancelled meanwhile */
    if (status != 1) {
        snprintf(MK.err, sizeof(MK.err), status == 0 ? "unreachable" : "HTTP %d", status < 0 ? -status : status);
        MK.state = -1;
        return;
    }
    MK.total = len;
    if (MK.file[0]) {
        const char *err = mock_fs_put(MK.file, buf, len);
        if (err) {
            snprintf(MK.err, sizeof(MK.err), "%s", err);
            MK.state = -1;
            return;
        }
        MK.len = len;
    } else {
        if (len > MK.max || !(MK.buf = (char *)malloc((size_t)len + 1))) {
            snprintf(MK.err, sizeof(MK.err), len > MK.max ? "too large" : "out of memory");
            MK.state = -1;
            return;
        }
        memcpy(MK.buf, buf, len);
        MK.buf[len] = '\0';
        MK.len = len;
    }
    MK.state = 1;
}

/* GET /api/market as the board answers it, for the page's own UI */
__attribute__((visibility("default")))
const char *wasm_market_json(void) {
    static char out[6144];
    mini_market_json(out, sizeof(out));
    return out;
}

/* The page's market buttons (refresh / install / cancel), as POST /api/market */
__attribute__((visibility("default")))
const char *wasm_market_action(const char *action, const char *id) {
    static char err[112];
    err[0] = '\0';
    if (strcmp(action, "refresh") == 0) mini_market_refresh(err, sizeof(err));
    else if (strcmp(action, "install") == 0) mini_market_install(id && id[0] ? id : "updates", err, sizeof(err));
    else if (strcmp(action, "cancel") == 0) mini_market_cancel();
    return err;
}

/* JSON feed document fetched by the page through server.py (/api/fetch).
 * status: 1 = document, 0 = URL unreachable, -1 = server.py has no /api/fetch */
__attribute__((visibility("default")))
void wasm_feed_data(const uint8_t *buf, uint32_t len, int status) {
    mini_json_feed_begin();
    if (status == 1) mini_json_feed_data((const char *)buf, len);
    mini_json_feed_end(status == 1, status == -1 ? "server.py too old: restart it (no /api/fetch)"
                                                 : "URL unreachable");
}

__attribute__((visibility("default")))
const char *wasm_feed_url(void) {
    return mini_json_feed_url();
}

/* The feed's polling interval (ms), so the page fetches as often as the firmware */
__attribute__((visibility("default")))
uint32_t wasm_feed_interval(void) {
    return mini_json_feed_interval();
}

__attribute__((visibility("default")))
uint32_t wasm_feed_generation(void) {
    return mini_json_feed_generation();
}

/* ========================================================================= */
/* Virtual LCD, Framebuffer & Telemetry Exports                              */
/* ========================================================================= */

/* ========================================================================= */
/* Symbol Catalog (WebREPL autocompletion)                                   */
/* ========================================================================= */

/* Every name the device VM resolves: its global bindings plus primitives not
 * bound yet (they live in static tables until first use). The device VM has
 * the firmware's primitive set, so this is what code typed in the REPL can
 * call on the board too. JSON array:
 *   [{"n":"restart","k":"p","s":"(restart)","c":"I/O & System","d":"..."}, ...]
 * k: p = C primitive, d = defined by Scheme code (app or REPL), v = other value.
 * s/c/d come from the help table when it documents the name. */
static char g_catalog[128 * 1024];
static size_t g_catalog_len;
static bool g_catalog_full;

static void cat_raw(const char *text) {
    size_t n = strlen(text);
    if (g_catalog_len + n + 4 >= sizeof(g_catalog)) {
        g_catalog_full = true;
        return;
    }
    memcpy(g_catalog + g_catalog_len, text, n);
    g_catalog_len += n;
}

static void cat_str(const char *text) {
    char esc[8];
    cat_raw("\"");
    for (const unsigned char *p = (const unsigned char *)text; *p && !g_catalog_full; p++) {
        if (*p == '"' || *p == '\\') { esc[0] = '\\'; esc[1] = (char)*p; esc[2] = 0; cat_raw(esc); }
        else if (*p < 0x20) { snprintf(esc, sizeof(esc), "\\u%04x", *p); cat_raw(esc); }
        else { esc[0] = (char)*p; esc[1] = 0; cat_raw(esc); }
    }
    cat_raw("\"");
}

static void cat_entry(const char *name, char kind) {
    if (g_catalog_full) return;
    char head[16];
    if (g_catalog_len > 1) cat_raw(",");
    cat_raw("{\"n\":");
    cat_str(name);
    snprintf(head, sizeof(head), ",\"k\":\"%c\"", kind);
    cat_raw(head);
    const MiniHelpEntry *h = mini_help_lookup(name);
    if (h) {
        cat_raw(",\"s\":");
        cat_str(h->syntax ? h->syntax : "");
        cat_raw(",\"c\":");
        cat_str(h->category ? h->category : "");
        cat_raw(",\"d\":");
        cat_str(h->description ? h->description : "");
    }
    cat_raw("}");
}

__attribute__((visibility("default")))
const char *wasm_symbol_catalog(void) {
    g_catalog_len = 0;
    g_catalog_full = false;
    cat_raw("[");
    MiniVM *vm = g_dev;
    if (vm) {
        for (Value curr = mini_cdr(vm->global_env); mini_is_pair(curr); curr = mini_cdr(curr)) {
            Value b = mini_car(curr);
            if (!mini_is_pair(b) || !mini_is_symbol(mini_car(b))) continue;
            Value v = mini_cdr(b);
            cat_entry(mini_symbol_name(mini_car(b)), mini_is_cfunc(v) ? 'p' : (mini_is_closure(v) ? 'd' : 'v'));
        }
        for (int t = 0; t < vm->prim_table_count; t++) {
            for (size_t i = 0; i < vm->prim_table_sizes[t]; i++) {
                const char *name = vm->prim_tables[t][i].name;
                if (prim_table_find(vm, name) != &vm->prim_tables[t][i]) continue; /* shadowed */
                if (!mini_is_void(env_lookup(vm, vm->global_env, mini_make_symbol(vm, name)))) continue;
                cat_entry(name, 'p');
            }
        }
    }
    cat_raw("]");
    g_catalog[g_catalog_len] = '\0';
    return g_catalog;
}

__attribute__((visibility("default"))) uint32_t wasm_get_vfb_ptr(void) { return (uint32_t)mini_gui_get_vfb(); }
__attribute__((visibility("default"))) int wasm_get_vfb_width(void) { return mini_gui_get_width(); }
__attribute__((visibility("default"))) int wasm_get_vfb_height(void) { return mini_gui_get_height(); }

__attribute__((visibility("default")))
void wasm_set_resolution(int width, int height) {
    mini_gui_set_resolution(width, height);
    request_full_redraw();
}

__attribute__((visibility("default"))) void wasm_set_framebuffer_enabled(int enabled) { mini_gui_set_fb_enabled(enabled ? true : false); }
__attribute__((visibility("default"))) int wasm_get_framebuffer_enabled(void) { return mini_gui_is_fb_enabled() ? 1 : 0; }
__attribute__((visibility("default"))) void wasm_set_color_depth(int bpp) { mini_gui_set_color_depth(bpp); }
__attribute__((visibility("default"))) int wasm_get_color_depth(void) { return mini_gui_get_color_depth(); }
__attribute__((visibility("default"))) uint32_t wasm_get_framebuffer_ram(void) { return (uint32_t)mini_gui_get_fb_ram(); }
__attribute__((visibility("default"))) void wasm_set_mono_colors(uint16_t fg, uint16_t bg) { mini_gui_set_mono_colors(fg, bg); }

__attribute__((visibility("default")))
uint16_t wasm_get_mono_fg(void) {
    uint16_t fg = 0, bg = 0;
    mini_gui_get_mono_colors(&fg, &bg);
    return fg;
}

__attribute__((visibility("default")))
uint16_t wasm_get_mono_bg(void) {
    uint16_t fg = 0, bg = 0;
    mini_gui_get_mono_colors(&fg, &bg);
    return bg;
}

__attribute__((visibility("default"))) void wasm_set_palette_preset(int preset_id) { mini_gui_set_palette_preset(preset_id); }
/* Color scheme by MiniGuiScheme number (0 color .. 7 custom) */
__attribute__((visibility("default"))) void wasm_set_color_scheme(int scheme) { mini_gui_set_scheme((MiniGuiScheme)scheme); }
__attribute__((visibility("default"))) int wasm_get_color_scheme(void) { return (int)mini_gui_get_scheme(); }
__attribute__((visibility("default"))) void wasm_requantize(void) { mini_gui_requantize(); }

/* Heap telemetry reports the device VM (what the ESP32 would see) */
__attribute__((visibility("default")))
uint32_t wasm_get_heap_allocated(void) {
    return g_dev ? (uint32_t)mini_get_allocated_bytes(g_dev) : 0;
}

__attribute__((visibility("default")))
uint32_t wasm_get_heap_capacity(void) {
    return g_dev ? (uint32_t)mini_get_heap_size(g_dev) : 0;
}

__attribute__((visibility("default")))
uint32_t wasm_get_app_heap_allocated(void) {
    return wasm_get_heap_allocated();
}

__attribute__((visibility("default")))
uint32_t wasm_get_compiler_heap_allocated(void) {
    return g_vm ? (uint32_t)mini_get_allocated_bytes(g_vm) : 0;
}

__attribute__((visibility("default")))
uint32_t wasm_get_compiler_baseline_bytes(void) {
    return g_compiler_baseline_bytes;
}

__attribute__((visibility("default")))
uint32_t wasm_get_gui_buffer_ram(void) {
    return (uint32_t)mini_gui_get_fb_ram();
}

__attribute__((visibility("default")))
void wasm_gc(void) {
    if (g_dev) { use_device(); mini_gc(g_dev); }
}

static int g_cpu_speed_mode = 240;
__attribute__((visibility("default"))) void wasm_set_cpu_speed_mode(int mode) { g_cpu_speed_mode = mode; }
__attribute__((visibility("default"))) int wasm_get_cpu_speed_mode(void) { return g_cpu_speed_mode; }

__attribute__((visibility("default"))) int wasm_is_vfb_dirty(void) { return mini_gui_is_dirty() ? 1 : 0; }

__attribute__((visibility("default")))
int wasm_get_dirty_x(void) { int x, y, w, h; mini_gui_get_dirty_rect(&x, &y, &w, &h); return x; }
__attribute__((visibility("default")))
int wasm_get_dirty_y(void) { int x, y, w, h; mini_gui_get_dirty_rect(&x, &y, &w, &h); return y; }
__attribute__((visibility("default")))
int wasm_get_dirty_w(void) { int x, y, w, h; mini_gui_get_dirty_rect(&x, &y, &w, &h); return w; }
__attribute__((visibility("default")))
int wasm_get_dirty_h(void) { int x, y, w, h; mini_gui_get_dirty_rect(&x, &y, &w, &h); return h; }
__attribute__((visibility("default"))) void wasm_clear_vfb_dirty(void) { mini_gui_clear_dirty(); }

__attribute__((visibility("default"))) void wasm_inject_touch(int is_down, int x, int y) { mini_gui_inject_touch(is_down != 0, x, y); }

__attribute__((visibility("default"))) int wasm_get_wifi_status(void) { return g_mock_wifi_connected ? 1 : 0; }
__attribute__((visibility("default"))) const char *wasm_get_wifi_ip(void) { return g_mock_wifi_ip; }
__attribute__((visibility("default"))) const char *wasm_get_wifi_ssid(void) { return g_mock_wifi_ssid; }
__attribute__((visibility("default"))) int wasm_get_wifi_rssi(void) { return g_mock_wifi_rssi; }

__attribute__((visibility("default")))
int wasm_get_pin_level(int pin) {
    return (pin >= 0 && pin < 64) ? g_mock_pins[pin] : 0;
}

__attribute__((visibility("default")))
int wasm_get_ws2812_r(void) { uint8_t r, g, b; mini_ws2812_get(&r, &g, &b); return r; }
__attribute__((visibility("default")))
int wasm_get_ws2812_g(void) { uint8_t r, g, b; mini_ws2812_get(&r, &g, &b); return g; }
__attribute__((visibility("default")))
int wasm_get_ws2812_b(void) { uint8_t r, g, b; mini_ws2812_get(&r, &g, &b); return b; }

__attribute__((visibility("default"))) int wasm_get_light_sensor(void) { return mini_light_read(); }
__attribute__((visibility("default"))) void wasm_set_light_sensor(int val) { mini_light_set(val); }
__attribute__((visibility("default"))) int wasm_get_backlight(void) { return mini_backlight_get(); }
__attribute__((visibility("default")))
void wasm_set_backlight(int val) {
    if (val < 0) val = 0;
    if (val > 255) val = 255;
    mini_backlight_set((uint8_t)val);
}
__attribute__((visibility("default")))
void wasm_set_backlight_auto(int on) {
    mini_backlight_auto_set(on != 0);
    if (on) mini_backlight_auto_step();
}
__attribute__((visibility("default")))
int wasm_get_backlight_auto(void) {
    return mini_backlight_auto() ? 1 : 0;
}
__attribute__((visibility("default")))
void wasm_set_backlight_params(int offset, int min_val, int max_val) {
    mini_backlight_set_params(offset, min_val, max_val);
}
__attribute__((visibility("default")))
int wasm_get_backlight_offset(void) {
    return mini_backlight_get_offset();
}
__attribute__((visibility("default")))
int wasm_get_backlight_min(void) {
    return mini_backlight_get_min();
}
__attribute__((visibility("default")))
int wasm_get_backlight_max(void) {
    return mini_backlight_get_max();
}
__attribute__((visibility("default"))) void wasm_set_button_k18(int pressed) { mini_button_set(pressed != 0); }
__attribute__((visibility("default"))) int wasm_get_button_k18(void) { return mini_button_read() ? 1 : 0; }

/* ========================================================================= */
/* Payload Execution (FASL / MSBC / Scheme source)                           */
/* ========================================================================= */

__attribute__((visibility("default")))
uint8_t *wasm_alloc_buffer(uint32_t size) {
    return (uint8_t *)malloc(size ? size : 1);
}

__attribute__((visibility("default")))
void wasm_free_buffer(uint8_t *ptr) {
    free(ptr);
}

__attribute__((visibility("default")))
const char *wasm_run_payload(const uint8_t *buf, uint32_t len) {
    if (!g_vm && wasm_init() != 0) return "Error: VM initialization failed";
    if (!buf || len == 0) return "Error: empty payload buffer";
    if (len >= 4 && (memcmp(buf, "MSBC", 4) == 0 || memcmp(buf, "MFAS", 4) == 0)) {
        return wasm_exec_msbc(buf, len);
    }
    /* Otherwise treat it as UTF-8 Scheme source */
    char *text_buf = (char *)malloc(len + 1);
    if (!text_buf) return "Error: out of memory allocating text buffer";
    memcpy(text_buf, buf, len);
    text_buf[len] = '\0';
    const char *res_str = wasm_eval(text_buf);
    free(text_buf);
    return res_str;
}
