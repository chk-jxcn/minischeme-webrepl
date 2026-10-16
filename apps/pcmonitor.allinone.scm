;;; =========================================================================
;;; MiniScheme Standalone Application: pcmonitor
;;; All-in-One Standalone Scheme Source (Libraries Included for WebREPL)
;;; =========================================================================
;;; [app]
;;; id = pcmonitor
;;; name = PC 性能监控
;;; description = LibreHardwareMonitor 的 CPU、温度、GPU、风扇曲线，按键切换链路和硬件页
;;; version = 1
;;; pages = 3
;;; api = 1.0 ; the device API it needs (docs/api): runs on firmware API 1.x, x >= 0
;;; 
;;; [fields]
;;; ; how the settings page shows each [config] key: type | label | help
;;; ; types: text, number:min-max, bool, select:value=label,value=label
;;; ; (no ASCII ; or # in these lines: they start a comment)
;;; pcmon_url = text | LibreHardwareMonitor 地址 | 电脑上 LHM 的 Remote Web Server，如 http://电脑IP:8085/data.json。留空时用代理所在电脑的 8085 端口
;;; 
;;; [config]
;;; pcmon_url = ; LibreHardwareMonitor web server (Options > Remote Web Server); empty: port 8085 of the proxy's PC
;;; proxy_url = http://proxy.local:8087
;;; converter_url = http://converter.local:8087

;;; =========================================================================
;;; Section: apps/lib/gui.scm
;;; =========================================================================
;;; =========================================================================
;;; MiniScheme Embedded GUI & CSS-like Layout Engine
;;; Tailored for ESP32 ILI9488 480x320 Screen & WASM WebREPL Simulator
;;; =========================================================================

;;; -------------------------------------------------------------------------
;;; 1. Standard RGB565 Palette & Modern Dark Theme Constants
;;; -------------------------------------------------------------------------

(define col-black         0)     ; #x0000
(define col-white         65535) ; #xFFFF
(define col-red           63488) ; #xF800
(define col-green         2016)  ; #x07E0
(define col-blue          31)    ; #x001F
(define col-cyan          2047)  ; #x07FF
(define col-magenta       63519) ; #xF81F
(define col-yellow        65504) ; #xFFE0
(define col-orange        64800) ; #xFD20
(define col-gray          33808) ; #x8410
(define col-dark-gray     12710) ; #x31A6
(define col-light-gray    50712) ; #xC618

;; IPS theme: dark slate canvas, outline-only surfaces, bright but not pure
;; white text, luminous accents; plus flat green segment colors for the
;; clock (plain instrument-panel LCD, no glow)
(define theme-bg           2179  ) ; #x0883: Canvas (#0b1118)
(define theme-card-bg      2179  ) ; #x0883: Surfaces are outlined, not filled (#0b1118)
(define theme-card-border  23442 ) ; #x5B92: Slate Outline (#5b7090)
(define theme-card-hdr     4358  ) ; #x1106: Header Strip (#152030)
(define theme-text-main    59262 ) ; #xE77E: Soft White (#e6ecf3)
(define theme-text-sub     48698 ) ; #xBE3A: Light Slate (#bac7d6)
(define theme-text-muted   42392 ) ; #xA598: Label Gray-Blue (#a2b2c6)
(define theme-accent       26270 ) ; #x669E: Sky Cyan (#62d0f0)
(define theme-accent-dark  4586  ) ; #x11EA: Deep Teal (#173f52)
(define theme-success      30386 ) ; #x76B2: Mint Green (#72d696)
(define theme-warning      62954 ) ; #xF5EA: Amber (#f0bc55)
(define theme-danger       60399 ) ; #xEBEF: Coral (#ee7c7c)
(define theme-purple       50462 ) ; #xC51E: Lavender (#c0a2f2)
(define theme-dark-gray    12809 ) ; #x3209: Inactive Element (#34414f)
(define theme-divider      27667 ) ; #x6C13: Divider lines (#688098): darker ones vanish on the panel
(define theme-seg-on       28271 ) ; #x6E6F: Flat LCD segment green (#6fcf7f)
(define theme-seg-off      4419  ) ; #x1143: Unlit segment ghost (#142a1c)

;; Fonts
(define FONT-SYS-16   0) ; 16px Crisp System UI & CJK Font
(define FONT-CLOCK-32 1) ; 32px Hero Digital Number Font

;; Color constructor
(define (rgb r g b)
  (gui-rgb r g b))

;;; -------------------------------------------------------------------------
;;; 2. CSS-like Box Model & Alignment Primitives
;;; -------------------------------------------------------------------------

;; Render a styled card/box with seamless background and optional border
(define (gui-box x y w h bg border radius)
  (gui-card x y w h radius (if bg bg 0) (if border border 0)))

;; Scoped Clipping helper: executes thunk with clipping region, then restores previous clip
(define (gui-with-clip x y w h thunk)
  (gui-push-clip x y w h)
  (thunk)
  (gui-pop-clip))

;; Scoped Offscreen Sub-Buffer helper: executes thunk on offscreen buffer, then restores main target
(define (gui-with-buffer buf thunk)
  (gui-set-target buf)
  (thunk)
  (gui-reset-target))

;; Content box padding helper: returns (list inner-x inner-y inner-w inner-h)
(define (gui-content-box x y w h pad-x pad-y)
  (list (+ x pad-x)
        (+ y pad-y)
        (max 0 (- w (* 2 pad-x)))
        (max 0 (- h (* 2 pad-y)))))

;; Align text inside a container: halign: 0=left, 1=center, 2=right; valign: 0=top, 1=middle, 2=bottom
(define (gui-text-align x y w h str color font-id halign valign)
  (gui-text-box x y w h str color font-id halign valign))

;; Pill Badge with auto-measured width and centered text
(define (gui-badge x y str bg-col text-col)
  (let* ((tw (gui-text-width str FONT-SYS-16))
         (w (+ tw 14))
         (h 22))
    (gui-round-rect x y w h 11 bg-col #t)
    (gui-text-box x y w h str text-col FONT-SYS-16 1 1)
    w))

;; Sleek Progress Bar
(define (gui-progress-bar x y w h percent fg-col bg-col)
  (let* ((p (max 0 (min 100 percent)))
         (track-bg (if bg-col bg-col theme-card-hdr))
         (fill-fg  (if fg-col fg-col theme-accent))
         (fill-w   (quotient (* (- w 4) p) 100)))
    (gui-round-rect x y w h 4 theme-card-border #f)
    (gui-round-rect (+ x 1) (+ y 1) (- w 2) (- h 2) 3 track-bg #t)
    (if (> fill-w 0)
        (gui-round-rect (+ x 2) (+ y 2) fill-w (- h 4) 2 fill-fg #t))))

;; Interactive Button with centered label and solid seamless background
(define (gui-button x y w h label pressed? bg-col text-col)
  (let* ((bg (if bg-col bg-col (if pressed? theme-accent-dark theme-card-bg)))
         (tc (if text-col text-col theme-text-main))
         (border (if pressed? theme-accent theme-card-border)))
    (gui-card x y w h 6 bg border)
    (gui-text-box x y w h label tc FONT-SYS-16 1 1)))

;;; -------------------------------------------------------------------------
;;; 3. CSS Grid & Flex Layout Calculations
;;; -------------------------------------------------------------------------

;; Compute bounding box for a cell in an N-column, M-row grid
(define (gui-grid-cell origin-x origin-y total-w total-h cols rows col-idx row-idx gap-x gap-y)
  (let* ((usable-w (- total-w (* gap-x (- cols 1))))
         (cell-w   (quotient usable-w cols))
         (usable-h (- total-h (* gap-y (- rows 1))))
         (cell-h   (quotient usable-h rows))
         (x        (+ origin-x (* col-idx (+ cell-w gap-x))))
         (y        (+ origin-y (* row-idx (+ cell-h gap-y)))))
    (list x y cell-w cell-h)))

;; Stat Tile: Display icon/title, hero 32px digital number, and unit with padding & clipping
(define (gui-stat-tile x y w h title val-str unit-str val-col)
  ;; Outline only: no fill behind the numbers
  (gui-round-rect x y w h 8 theme-card-border #f)
  ;; Title with 10px padding
  (gui-text-box (+ x 10) (+ y 6) (- w 20) 18 title theme-text-muted FONT-SYS-16 0 1)
  ;; Big value centred in the space under the title, clipped to the tile
  ;; push/pop instead of gui-with-clip: no closure, no heap environment
  (let ((vy (+ y 24 (max 0 (quotient (- h 24 40) 2)))))
    (gui-push-clip (+ x 10) vy (- w 18) 44)
    (gui-text-styled (+ x 10) vy val-str val-col FONT-CLOCK-32)
    (if (> (string-length unit-str) 0)
        (let ((val-w (gui-text-width val-str FONT-CLOCK-32)))
          (gui-text-styled (+ x 12 val-w) (+ vy 12) unit-str theme-text-sub FONT-SYS-16)))
    (gui-pop-clip)))

;;; -------------------------------------------------------------------------
;;; 4. WiFi Signal & System Indicators
;;; -------------------------------------------------------------------------

(define (gui-draw-wifi-icon x y connected? rssi)
  (let loop ((i 0))
    (if (< i 4)
        (let* ((bx (+ x (* i 5)))
               (bh (+ 4 (* i 3)))
               (by (+ y 14 (- bh)))
               (active? (and connected? (>= rssi (- -90 (* i 15)))))
               (col (if active? theme-success theme-dark-gray)))
          (gui-rect bx by 3 bh col #t)
          (loop (+ i 1))))))

;;; -------------------------------------------------------------------------
;;; 5. Declarative Widget Representation & Touch Dispatch
;;; -------------------------------------------------------------------------

(define (make-widget type id x y w h props on-click)
  (list type id x y w h props on-click))

(define (widget-type w)     (car w))
(define (widget-id w)       (cadr w))
(define (widget-x w)        (caddr w))
(define (widget-y w)        (cadddr w))
(define (widget-w w)        (car (cddddr w)))
(define (widget-h w)        (cadr (cddddr w)))
(define (widget-props w)    (caddr (cddddr w)))
(define (widget-handler w)  (cadddr (cddddr w)))

(define (gui-hit-test widgets tx ty)
  (let loop ((ws widgets))
    (if (null? ws)
        #f
        (let ((w (car ws)))
          (let ((x (widget-x w))
                (y (widget-y w))
                (width (widget-w w))
                (height (widget-h w)))
            (if (and (>= tx x) (< tx (+ x width))
                     (>= ty y) (< ty (+ y height)))
                w
                (loop (cdr ws))))))))

(define (gui-dispatch-touch widgets)
  (let ((touch (gui-touch-poll)))
    (if touch
        (let ((hit (gui-hit-test widgets (car touch) (cdr touch))))
          (if (and hit (procedure? (widget-handler hit)))
              ((widget-handler hit) hit touch)))
        #f)))

;;; -------------------------------------------------------------------------
;;; 6. Framebuffer, Color Depth & Palette Configuration Helpers
;;; -------------------------------------------------------------------------

(define (gui-fb? . args)
  (if (null? args)
      (gui-framebuffer-enabled?)
      (gui-framebuffer-enable (car args))))

(define (gui-bpp . args)
  (if (null? args)
      (gui-color-depth)
      (gui-color-depth (car args))))

(define (gui-vfb-ram)
  (gui-framebuffer-ram))

;;; -------------------------------------------------------------------------
;;; 7. Multi-Dirty Rects & Scanline Banding Helpers
;;; -------------------------------------------------------------------------

(define (gui-dirty-count)
  (gui-dirty-rect-count))

(define (gui-get-dirty-list)
  (gui-dirty-rects))

(define (gui-flush-partial)
  (gui-flush-dirty))

(define (gui-with-bands band-height thunk)
  (gui-render-bands band-height thunk))




;;; =========================================================================
;;; Section: apps/lib/infopages.scm
;;; =========================================================================
;;; =========================================================================
;;; Hardware pages, shared by every app (tools/build_apps.py puts this file
;;; after gui.scm in each app's image; it needs only gui.scm).
;;;
;;; KEY 18 held 8 s opens them over whatever the app shows (the short, the
;;; long and the mid press belong to the app); short presses turn them
;;; (memory, storage, network, system); a long press goes back to the app;
;;; a mid press (3.5 s) opens the system settings (the firmware does that).
;;; The device layer (minischeme_device.c) calls the hooks below:
;;; info-long-press for the hold and, while (info-active?), for the long
;;; press; info-button for short presses while open; info-tick every second. While open, the app's
;;; gui-render-proc is set aside and restored afterwards; the app keeps
;;; running underneath (its ticks and feeds), only its drawing is replaced.
;;;
;;; An app that needs to know (applib pauses its carousel) sets
;;; info-on-change to (lambda (open?) ...).
;;; =========================================================================

(define INFO-PAGE-NAMES '("内存" "存储" "网络" "系统"))
(define info-page #f)                 ; 0..3 while the pages show, else #f
(define info-on-change #f)            ; the app's (lambda (open?) ...), or #f
(define info-app-render #f)           ; the app's gui-render-proc while they show
(define info-time "--:--")            ; the clock, from the device tick
(define INFO-F 7)                     ; font slot: a 16 px CJK font while open
(define INFO-HDR-H 32)
(define INFO-TOP 42)
(define INFO-ROW 26)

;; ---- Hooks --------------------------------------------------------------------------------

(define (info-active?) (and info-page #t))

(define (info-long-press)
  (if info-page (info-close!) (info-open!)))

(define (info-button)
  (set! info-page (remainder (+ info-page 1) (length INFO-PAGE-NAMES)))
  (info-invalidate))

;; Every second, open or not: keeps the clock; open, the figures every 2 s
(define (info-tick hm . rest)
  (let ((tick (if (and (pair? rest) (>= (length rest) 6)) (list-ref rest 5) 0)))
    (if (string? hm) (set! info-time hm))
    (if (and info-page (number? tick) (= (remainder tick 2) 0)) (info-invalidate))))

;; ---- Open / close -------------------------------------------------------------------------

;; The same 16 px font the apps use: the system font when it is a 16 px ROM
;; font, else msyh or simsun from the font ROM (the built-in font lacks most
;; Chinese characters)
(define (info-load-font!)
  (let ((sys (font-info 0)))
    (or (and (pair? sys) (= (cadr sys) 16) (not (eq? (list-ref sys 3) 'builtin)) (use-font INFO-F (car sys)))
        (use-font INFO-F "msyh" 16 'system)
        (use-font INFO-F "simsun" 16 'system))))

(define (info-open!)
  (set! info-app-render gui-render-proc)
  (set! info-page 0)
  (info-load-font!)
  (set! gui-render-proc info-render)
  (if info-on-change (info-on-change #t))
  (info-invalidate))

(define (info-close!)
  (set! info-page #f)
  (set! gui-render-proc info-app-render)
  (set! info-app-render #f)
  (font-unload INFO-F)
  (if info-on-change (info-on-change #f))
  (info-invalidate))

(define (info-invalidate) (gui-invalidate 0 0 (gui-width) (gui-height)))

;; ---- Text and figures ---------------------------------------------------------------------

(define (info-txt x y s c) (gui-text-styled x y s c INFO-F))
(define (info-txt-w s) (gui-text-width s INFO-F))
(define (info-txt-right xr y s c) (info-txt (- xr (info-txt-w s)) y s c))
(define (info-int n) (number->string n))
(define (info-pad2 n) (if (< n 10) (string-append "0" (number->string n)) (number->string n)))

(define (info-ref alist . keys)              ; nested assq, #f when missing
  (let loop ((v alist) (ks keys))
    (cond ((null? ks) v)
          ((not (pair? v)) #f)
          (else (let ((e (assq (car ks) v))) (loop (if e (cdr e) #f) (cdr ks)))))))

;; n / scale with `digits` decimals: (info-fixed 1234 100 2) => "12.34"
(define (info-fixed n scale digits)
  (let* ((unit (expt 10 digits)) (v (quotient (* n unit) scale))
         (frac (number->string (remainder v unit))))
    (string-append (number->string (quotient v unit))
                   (if (> digits 0)
                       (string-append "." (if (< (string-length frac) digits) (string-append "0" frac) frac))
                       ""))))

(define (info-bytes n)
  (cond ((not (number? n)) "-")
        ((>= n 1048576) (string-append (info-fixed n 1048576 2) " MB"))
        ((>= n 1024) (string-append (info-fixed n 1024 1) " KB"))
        (else (string-append (info-int n) " B"))))

(define (info-of a b) (string-append (info-bytes a) " / " (info-bytes b)))

(define (info-duration s)                    ; seconds -> "3天 04:05" / "04:05:06"
  (let ((d (quotient s 86400)) (h (quotient (remainder s 86400) 3600)) (m (quotient (remainder s 3600) 60)))
    (if (> d 0)
        (string-append (info-int d) "天 " (info-pad2 h) ":" (info-pad2 m))
        (string-append (info-pad2 h) ":" (info-pad2 m) ":" (info-pad2 (remainder s 60))))))

;; The clock time of the boot: now minus the uptime ("09:12", "昨天 22:10", "3天前 08:00")
(define (info-boot-time uptime-s)
  (let ((h (string->fixed info-time 0))
        (m (and (>= (string-length info-time) 5) (string->fixed (substring info-time 3 5) 0))))
    (if (not (and h m))
        "-"
        (let* ((at (- (+ (* 60 h) m) (quotient uptime-s 60)))
               (days (if (>= at 0) 0 (+ 1 (quotient (- -1 at) 1440))))
               (clock (+ at (* days 1440)))
               (hm (string-append (info-pad2 (quotient clock 60)) ":" (info-pad2 (remainder clock 60)))))
          (cond ((= days 0) hm)
                ((= days 1) (string-append "昨天 " hm))
                (else (string-append (info-int days) "天前 " hm)))))))

(define (info-ends? s e)
  (and (>= (string-length s) (string-length e))
       (string=? (substring s (- (string-length s) (string-length e)) (string-length s)) e)))

(define (info-starts? s p)
  (and (>= (string-length s) (string-length p)) (string=? (substring s 0 (string-length p)) p)))

;; ---- Rows ---------------------------------------------------------------------------------

(define (info-right) (- (gui-width) 14))

;; label on the left, value right-aligned; a value too wide for that starts
;; after the label column and scrolls or is cut (config.ini [text] marquee)
(define (info-row i label value . color)
  (let ((y (+ INFO-TOP (* i INFO-ROW))) (c (if (pair? color) (car color) theme-text-main))
        (vw (- (info-right) 116)))
    (info-txt 14 y label theme-text-muted)
    (if (> (info-txt-w value) vw)
        (gui-text-fit 116 y vw value c INFO-F)
        (info-txt-right (info-right) y value c))))

;; A thin bar under row i: used of total
(define (info-bar i used total color)
  (let ((y (+ INFO-TOP (* i INFO-ROW) 20)) (w (- (info-right) 14)))
    (gui-rect 14 y w 3 theme-dark-gray #t)
    (if (and (number? used) (number? total) (> total 0) (> used 0))
        (gui-rect 14 y (max 2 (quotient (* w (min used total)) total)) 3 color #t))))

(define (info-divider i)
  (let ((y (+ INFO-TOP (* i INFO-ROW) -6)))
    (gui-line 14 y (info-right) y theme-divider)))

;; ---- Pages --------------------------------------------------------------------------------

(define (info-memory)
  (let* ((info (system-info)) (st (vm-stats))
         (free (info-ref info 'memory 'free-heap)) (total (info-ref info 'memory 'total))
         (heap (info-ref info 'memory 'vm-heap)) (used (info-ref info 'memory 'vm-used)))
    (let ((in-use (if (and free total (<= free total)) (- total free) #f)))
      (info-row 0 "系统内存" (info-of in-use total))
      (info-bar 0 in-use total theme-accent))
    (info-row 1 "空闲" (info-bytes free))
    (info-row 2 "最低空闲" (info-bytes (info-ref info 'memory 'min-free)))
    (info-row 3 "最大连续块" (info-bytes (info-ref info 'memory 'largest-block)))
    (info-divider 4)
    (info-row 4 "VM 堆" (info-of used heap))
    (info-bar 4 used heap theme-success)
    (info-row 5 "存活 / 峰值" (info-of (info-ref st 'live-bytes) (info-ref st 'live-peak)))
    (info-row 6 "累计分配" (string-append (info-int (or (info-ref st 'alloc-kb) 0)) " KB"))
    (info-row 7 "小回收" (info-int (or (info-ref st 'minor-gcs) 0)))
    (info-row 8 "全回收" (info-int (or (info-ref st 'major-gcs) 0)))
    (info-divider 9)
    (info-row 9 "代码 ROM" (info-bytes (info-ref st 'rom-bytes)))
    (info-row 10 "栈峰值" (string-append (info-int (or (info-ref st 'stack-peak) 0)) " / "
                                        (info-int (or (info-ref st 'stack-slots) 0))))))

(define (info-image? name) (or (info-ends? name ".msbc") (info-ends? name ".fasl")))

(define (info-storage)
  ;; an app sees only its own folder: the image's size from there, when it is there
  (let* ((fs (fs-info)) (rom (fontrom-info))
         (me (app-info)) (dir (if (and (pair? me) (= (length me) 4)) (cadddr me) #f))
         (mine (let loop ((f (if dir (fs-list dir) '())))
                 (cond ((null? f) #f)
                       ((info-image? (car (car f))) (cdr (car f)))
                       (else (loop (cdr f)))))))
    (info-row 0 "文件系统" (if fs (info-of (cadr fs) (car fs)) "-"))
    (if fs (info-bar 0 (cadr fs) (car fs) theme-accent))
    (info-row 1 "应用" (info-int (length (app-list))))
    (info-row 2 "本应用" (info-bytes mine))
    ;; program ROM: the firmware image in its partition; the app's Code ROM
    ;; image in the approm partition (0 when the app runs from RAM)
    (let ((fw (flash-app-bytes)) (fw-part (flash-app-partition-bytes))
          (code (vm-rom-bytes)) (code-part (app-rom-capacity)))
      (info-divider 3)
      (info-row 3 "程序 ROM" (info-of fw fw-part))
      (info-bar 3 fw fw-part theme-warning)
      (info-row 4 "应用 ROM" (if (> code 0) (info-of code code-part) "RAM 运行"))
      (if (> code 0) (info-bar 4 code code-part theme-success)))
    (info-divider 5)
    (info-row 5 "系统字库" (if rom (info-of (car rom) (cadr rom)) "-"))
    (if rom (info-bar 5 (car rom) (cadr rom) theme-purple))
    (let loop ((fonts (fontrom-list)) (i 6))
      (if (and (pair? fonts) (< i 14))
          (begin
            (info-row i (car (car fonts)) (info-bytes (cadddr (car fonts))) theme-text-sub)
            (loop (cdr fonts) (+ i 1)))))))

;; Four signal bars for an RSSI
(define (info-signal-bars x y rssi)
  (let ((n (cond ((not (number? rssi)) 0) ((>= rssi -55) 4) ((>= rssi -67) 3) ((>= rssi -78) 2) ((< rssi 0) 1) (else 0))))
    (let loop ((i 0))
      (if (< i 4)
          (begin
            (gui-rect (+ x (* i 5)) (- (+ y 14) (* (+ i 1) 3)) 3 (* (+ i 1) 3)
                      (if (< i n) theme-success theme-dark-gray) #t)
            (loop (+ i 1)))))))

(define (info-proxy)
  (let ((p (config-get "proxy")))
    (cond ((not (and (string? p) (> (string-length p) 0))) "-")
          ((info-starts? p "http://") (substring p 7 (string-length p)))
          (else p))))

(define (info-network)
  (let* ((info (system-info)) (rssi (info-ref info 'network 'rssi))
         (on (info-ref info 'network 'connected)) (st (json-feed-status))
         (state (info-ref st 'state)))
    (info-row 0 "WiFi" (if on (info-ref info 'network 'ssid) "未连接") (if on theme-text-main theme-warning))
    (info-row 1 "IP" (if on (info-ref info 'network 'ip) "-"))
    (info-row 2 "信号" (if (and on (number? rssi)) (string-append (info-int rssi) " dBm") "-"))
    (if on (info-signal-bars (- (info-right) 86) (+ INFO-TOP (* 2 INFO-ROW)) rssi))
    (info-row 3 "MAC" (or (info-ref info 'chip 'mac) "-"))
    (info-row 4 "时间同步" (if (info-ref info 'time 'ntp-synced) "已同步" "未同步"))
    (info-divider 5)
    (info-row 5 "代理" (info-proxy))
    (info-row 6 "数据源" (cond ((eq? state 'ok) "正常") ((eq? state 'error) "失败")
                              ((eq? state 'idle) "未使用") (else "连接中"))
              (if (eq? state 'error) theme-warning theme-text-main))
    (if (not (eq? state 'idle))
        (begin
          (info-row 7 "上次" (string-append (info-bytes (info-ref st 'bytes)) "  "
                                           (info-int (or (info-ref st 'fetch-ms) 0)) " ms"))
          (info-row 8 "抓取 / 失败" (string-append (info-int (or (info-ref st 'fetches) 0)) " / "
                                                  (info-int (or (info-ref st 'failures) 0))))))))

(define (info-system)
  (let* ((info (system-info)) (up (quotient (or (info-ref info 'time 'uptime-ms) 0) 1000))
         (me (app-info)) (id (if (pair? me) (cadr me) ""))
         (entry (let loop ((as (app-list)))
                  (cond ((null? as) #f) ((string=? (cadr (car as)) id) (car as)) (else (loop (cdr as))))))
         (model (info-ref info 'display 'model)))
    ;; the system fonts may lack "·": figures are set apart by spaces
    (info-row 0 "芯片" (string-append (or (info-ref info 'chip 'model) "-") "  "
                                      (info-int (or (info-ref info 'chip 'cores) 1)) " 核  "
                                      (info-int (or (info-ref info 'chip 'cpu-mhz) 0)) " MHz"))
    (info-row 1 "Flash" (info-bytes (info-ref info 'chip 'flash-bytes)))
    (info-row 2 "ESP-IDF" (or (info-ref info 'chip 'idf) "-"))
    (info-row 3 "固件" (string-append (or (info-ref info 'chip 'build) "-") "  API " (api-version)))
    (info-divider 4)
    (info-row 4 "运行时长" (info-duration up))
    (info-row 5 "启动于" (info-boot-time up))
    (info-row 6 "复位原因" (or (info-ref info 'chip 'reset-reason) "-"))
    (info-divider 7)
    (info-row 7 "应用" (if entry (string-append (caddr entry) " v" (list-ref entry 5)) (if (string=? id "") "-" id)))
    (info-row 8 "显示屏" (if (string? model)
                            (let loop ((i 0))   ; the part before the first "-"
                              (cond ((= i (string-length model)) model)
                                    ((char=? (string-ref model i) #\-) (substring model 0 i))
                                    (else (loop (+ i 1)))))
                            "-"))
    (info-row 9 "显示模式" (string-append (let ((m (info-ref info 'display 'mode))) (if (symbol? m) (symbol->string m) "-"))
                                          "  " (info-int (or (info-ref info 'display 'color-bits) 16)) " 位色"))))

;; ---- The screen ---------------------------------------------------------------------------

(define (info-render)
  (let* ((w (gui-width))
         (ind (string-append (info-int (+ info-page 1)) "/" (info-int (length INFO-PAGE-NAMES))))
         (iw (+ (info-txt-w ind) 12)) (badge (- w 8 (info-txt-w info-time) 8 iw)))
    (gui-clear theme-bg)
    (gui-rect 0 0 w INFO-HDR-H theme-card-hdr #t)
    (info-txt 8 8 "硬件信息" theme-text-main)
    (info-txt (+ 8 (info-txt-w "硬件信息") 10) 8 (list-ref INFO-PAGE-NAMES info-page) theme-accent)
    (gui-round-rect badge 5 iw 22 6 theme-accent-dark #t)
    (info-txt (+ badge 6) 8 ind theme-accent)
    (info-txt-right (- w 8) 8 info-time theme-text-main))
  (cond ((= info-page 0) (info-memory))
        ((= info-page 1) (info-storage))
        ((= info-page 2) (info-network))
        (else (info-system)))
  (info-render-footer))

;; How to leave: over the page's last rows
(define INFO-FTR-H 24)
(define (info-render-footer)
  (let ((y (- (gui-height) INFO-FTR-H)))
    (gui-rect 0 y (gui-width) INFO-FTR-H theme-card-hdr #t)
    (info-txt 8 (+ y 4) "短按翻页  长按返回  中长按：系统设置" theme-text-muted)))


;;; =========================================================================
;;; Section: apps/pcmonitor/pcmonitor.scm
;;; =========================================================================
;;; =========================================================================
;;; PC performance monitor (320x480 portrait)
;;; Shows a PC's sensors read from LibreHardwareMonitor's web server
;;; (Options -> Remote Web Server, port 8085).
;;;
;;; The firmware only offers a generic JSON feed (json-feed-start): it polls a
;;; URL in the background and keeps the JSON objects our selectors pick.
;;; Everything specific to LibreHardwareMonitor lives here: which keys a
;;; sensor node has, which sensors to keep, and how to read their values.
;;; The button cycles: monitor -> link status -> hardware info.
;;; Needs gui.scm loaded first (theme colors, fonts).
;;; =========================================================================

;; 1. LibreHardwareMonitor data source -------------------------------------

;; config.ini: [app] pcmon_url = http://<pc>:8085/data.json; unset: LibreHardwareMonitor
;; on the PC of the app proxy ([app] proxy = http://<pc>:8087), port 8085
(define (pcmon-default-url)
  (let* ((p (or (config-get "proxy") "")) (n (string-length p))
         (start (if (and (> n 7) (string=? (substring p 0 7) "http://")) 7 0)))
    (let loop ((i start))           ; the host: up to ":" or "/"
      (cond ((or (= i n) (char=? (string-ref p i) #\:) (char=? (string-ref p i) #\/))
             (if (> i start) (string-append "http://" (substring p start i) ":8085/data.json") ""))
            (else (loop (+ i 1)))))))

;; data.json is a tree of nodes, each a JSON object with these keys
(define LHM-KEYS '("SensorId" "Value" "Text" "ImageURL"))
(define K-SID 0) (define K-VALUE 1) (define K-TEXT 2) (define K-IMG 3)

;; Sensor ids; on the device (json-feed-dump) lists every node of a PC
(define pcmon-sensor-ids
  (list "/intelcpu/0/load/0"            ; 0  CPU total load
        "/intelcpu/0/clock/1"           ; 1  CPU core #1 clock
        "/intelcpu/0/temperature/6"     ; 2  CPU package temperature
        "/ram/data/0"                   ; 3  memory used (GB)
        "/ram/data/1"                   ; 4  memory available (GB)
        "/gpu-nvidia/0/load/0"          ; 5  GPU core load
        "/gpu-nvidia/0/clock/0"         ; 6  GPU core clock
        "/gpu-nvidia/0/temperature/0"   ; 7  GPU core temperature
        "/gpu-nvidia/0/smalldata/1"     ; 8  GPU memory used (MB)
        "/gpu-nvidia/0/smalldata/2"     ; 9  GPU memory total (MB)
        "/gpu-nvidia/0/power/0"         ; 10 GPU package power
        "/nvme/2/temperature/0"         ; 11 system disk temperature
        "/lpc/nct6796dr/fan/5"          ; 12 system fan (RPM)
        "/lpc/nct6796dr/fan/1"          ; 13 CPU fan (RPM)
        "/gpu-nvidia/0/fan/1"           ; 14 GPU fan (RPM)
        "/lpc/nct6796dr/control/5"      ; 15 system fan duty (%)
        "/lpc/nct6796dr/control/1"      ; 16 CPU fan duty (%)
        "/gpu-nvidia/0/control/1"))     ; 17 GPU fan duty (%)

(define S-CPU-LOAD 0) (define S-CPU-CLOCK 1) (define S-CPU-TEMP 2)
(define S-MEM-USED 3) (define S-MEM-AVAIL 4)
(define S-GPU-LOAD 5) (define S-GPU-CLOCK 6) (define S-GPU-TEMP 7)
(define S-GPU-MEM 8) (define S-GPU-MEM-TOTAL 9) (define S-GPU-POWER 10)
(define S-DISK-TEMP 11)
(define S-FAN-SYS 12) (define S-FAN-CPU 13) (define S-FAN-GPU 14)
(define S-DUTY-SYS 15) (define S-DUTY-CPU 16) (define S-DUTY-GPU 17)
(define PCMON-NSENSORS 18)

;; Per-thread loads for the core grid (the total, sensor 0, matches first)
(define pcmon-core-prefix "/intelcpu/0/load/")

;; Hardware nodes are recognised by their icon; we keep their names
(define pcmon-icons
  '("images_icon/computer.png" "images_icon/cpu.png"
    "images_icon/nvidia.png" "images_icon/ati.png" "images_icon/amd.png" "images_icon/intel.png"))

;; Selector indexes: sensors first, then the core prefix, then the icons
(define SEL-CORES PCMON-NSENSORS)
(define SEL-PC (+ SEL-CORES 1))
(define SEL-CPU (+ SEL-CORES 2))          ; anything after it is a GPU

(define (pcmon-selectors)
  (append (map (lambda (id) (list K-SID 'equal id K-VALUE)) pcmon-sensor-ids)
          (list (list K-SID 'prefix pcmon-core-prefix K-VALUE))
          (map (lambda (icon) (list K-IMG 'equal icon K-TEXT)) pcmon-icons)))

(define (pcmon-url)
  (let ((u (config-get "pcmon_url")))
    (if (and u (> (string-length u) 7)) u (pcmon-default-url))))

(define (pcmon-start!)
  (json-feed-start (pcmon-url) 1000 LHM-KEYS (pcmon-selectors)))

;; "12.3 %" -> 123 (tenths), #f when the node has no number
(define (pcmon-tenths str) (if str (string->fixed str 1) #f))

;; 2. State --------------------------------------------------------------------

(define PCMON-POINTS 80)
(define (pcmon-ring) (make-vector PCMON-POINTS 0))

(define pcmon-hist-cpu (pcmon-ring))
(define pcmon-hist-gpu (pcmon-ring))
(define pcmon-hist-tcpu (pcmon-ring))
(define pcmon-hist-tgpu (pcmon-ring))
(define pcmon-hist-tdisk (pcmon-ring))
(define pcmon-hist-fsys (pcmon-ring))
(define pcmon-hist-fcpu (pcmon-ring))
(define pcmon-hist-fgpu (pcmon-ring))
(define pcmon-head 0)      ; next ring slot
(define pcmon-filled 0)    ; samples stored, up to PCMON-POINTS

(define pcmon-vals (make-vector PCMON-NSENSORS #f)) ; latest values, tenths or #f
(define pcmon-cores (make-vector 16 #f))            ; per-thread loads, tenths
(define pcmon-ncores 0)
(define pcmon-last-seq 0)
(define pcmon-samples 0)
(define pcmon-pc-name "PC MONITOR")
(define pcmon-cpu-name "CPU")
(define pcmon-gpu-name "GPU")
(define pcmon-time "--:--")
(define PAGE-MONITOR 0) (define PAGE-LINK 1) (define PAGE-HARDWARE 2)
(define pcmon-page PAGE-MONITOR)

;; 3. Sampling -----------------------------------------------------------------

(define (pcmon-val i) (vector-ref pcmon-vals i))

(define (pcmon-push! ring i)
  (let ((v (pcmon-val i)))
    (vector-set! ring pcmon-head (if v v 0))))

;; "NVIDIA GeForce RTX 4060" -> "RTX 4060": the tile is narrow
(define (pcmon-short-gpu name)
  (let loop ((prefixes '("NVIDIA GeForce " "AMD Radeon " "Intel(R) ")))
    (cond
      ((null? prefixes) name)
      ((let ((p (car prefixes)))
         (and (> (string-length name) (string-length p))
              (string=? (substring name 0 (string-length p)) p)))
       (substring name (string-length (car prefixes)) (string-length name)))
      (else (loop (cdr prefixes))))))

;; Hardware names change rarely: read them every 30th sample
(define (pcmon-note-name! sel name gpu-seen?)
  (cond ((not name) gpu-seen?)
        ((= sel SEL-PC)
         (if (not (string=? name pcmon-pc-name))
             (begin
               (set! pcmon-pc-name name)
               (pcmon-refresh 0 28)))      ; the header only redraws on demand
         gpu-seen?)
        ((= sel SEL-CPU) (set! pcmon-cpu-name name) gpu-seen?)
        (gpu-seen? #t)                     ; keep the first GPU
        (else (set! pcmon-gpu-name (pcmon-short-gpu name)) #t)))

;; One document: route every kept object by the selector it matched
(define (pcmon-sample! seq)
  (set! pcmon-last-seq seq)
  (vector-fill! pcmon-vals #f)
  (set! pcmon-ncores 0)
  (let ((n (json-feed-count))
        (names? (= (remainder pcmon-samples 30) 0)))
    (let loop ((i 0) (gpu-seen? #f))
      (if (< i n)
          (let ((sel (json-feed-selector i)))
            (cond
              ((< sel SEL-CORES)
               (vector-set! pcmon-vals sel (pcmon-tenths (json-feed-field i K-VALUE)))
               (loop (+ i 1) gpu-seen?))
              ((= sel SEL-CORES)
               (if (< pcmon-ncores 16)
                   (begin
                     (vector-set! pcmon-cores pcmon-ncores (pcmon-tenths (json-feed-field i K-VALUE)))
                     (set! pcmon-ncores (+ pcmon-ncores 1))))
               (loop (+ i 1) gpu-seen?))
              (names? (loop (+ i 1) (pcmon-note-name! sel (json-feed-field i K-TEXT) gpu-seen?)))
              (else (loop (+ i 1) gpu-seen?)))))))
  (set! pcmon-samples (+ pcmon-samples 1))
  (pcmon-push! pcmon-hist-cpu S-CPU-LOAD)
  (pcmon-push! pcmon-hist-gpu S-GPU-LOAD)
  (pcmon-push! pcmon-hist-tcpu S-CPU-TEMP)
  (pcmon-push! pcmon-hist-tgpu S-GPU-TEMP)
  (pcmon-push! pcmon-hist-tdisk S-DISK-TEMP)
  (pcmon-push! pcmon-hist-fsys S-DUTY-SYS)
  (pcmon-push! pcmon-hist-fcpu S-DUTY-CPU)
  (pcmon-push! pcmon-hist-fgpu S-DUTY-GPU)
  (set! pcmon-head (remainder (+ pcmon-head 1) PCMON-POINTS))
  (if (< pcmon-filled PCMON-POINTS) (set! pcmon-filled (+ pcmon-filled 1)))
  (if (= pcmon-page PAGE-MONITOR) (pcmon-refresh 30 (- (gui-height) 30))))

;; 4. Formatting (values arrive in tenths) -------------------------------------

(define (pcmon-int v) (if v (number->string (quotient (+ v 5) 10)) "--"))

(define (pcmon-dec v)                      ; one decimal: 427 -> "42.7"
  (if v
      (string-append (number->string (quotient v 10)) "." (number->string (remainder v 10)))
      "--"))

(define (pcmon-mem-text)                   ; "43G/128G"
  (let ((used (pcmon-val S-MEM-USED)) (avail (pcmon-val S-MEM-AVAIL)))
    (if (and used avail)
        (string-append (pcmon-int used) "G/" (pcmon-int (+ used avail)) "G")
        "--/--")))

(define (pcmon-vram-text)                  ; MB tenths -> "3.5G/8G"
  (let ((used (pcmon-val S-GPU-MEM)) (total (pcmon-val S-GPU-MEM-TOTAL)))
    (if (and used total)
        (string-append (pcmon-dec (quotient used 1024)) "G/"
                       (number->string (quotient (+ total 5120) 10240)) "G")
        "--/--")))

;; Load / temperature colors: warn when the PC runs hot or busy
(define (pcmon-load-color v)
  (cond ((not v) theme-text-muted)
        ((>= v 900) theme-danger)
        ((>= v 700) theme-warning)
        (else theme-text-main)))

(define (pcmon-temp-color v base)
  (cond ((not v) theme-text-muted)
        ((>= v 850) theme-danger)
        ((>= v 750) theme-warning)
        (else base)))

;; 5. Drawing ------------------------------------------------------------------

(define PCMON-SEC-Y 32)      ; first section
(define PCMON-SEC-H 102)     ; section pitch
(define PCMON-CHART-X 8)
(define PCMON-CHART-W 142)
(define PCMON-CHART-H 92)
(define PCMON-INFO-X 160)

(define (pcmon-sec-y i) (+ PCMON-SEC-Y (* i PCMON-SEC-H)))

;; Chart frame plus one or more series (ring, lo, hi, color) in tenths
(define (pcmon-chart y series)
  (gui-round-rect PCMON-CHART-X y PCMON-CHART-W PCMON-CHART-H 4 theme-card-border #f)
  (let ((start (if (< pcmon-filled PCMON-POINTS) 0 pcmon-head)))
    (let loop ((s series))
      (if (pair? s)
          (let ((e (car s)))
            (if (>= pcmon-filled 2)
                (gui-chart (+ PCMON-CHART-X 2) (+ y 3) (- PCMON-CHART-W 4) (- PCMON-CHART-H 6)
                           (car e) start pcmon-filled (cadr e) (caddr e) (cadddr e)))
            (loop (cdr s)))))))

(define (pcmon-text x y str color) (gui-text-styled x y str color FONT-SYS-16))
(define (pcmon-big x y str color) (gui-text-styled x y str color FONT-CLOCK-32))

(define (pcmon-text-right x-right y str color)
  (pcmon-text (- x-right (gui-text-width str FONT-SYS-16)) y str color))

;; Big number with a small unit right after it ("12" "%" / "30" "°")
(define (pcmon-big-unit x y num unit color)
  (pcmon-big x y num color)
  (pcmon-text (+ x (gui-text-width num FONT-CLOCK-32) 1) (+ y 2) unit color))

(define (pcmon-render-header)
  (gui-rect 0 0 (gui-width) 28 theme-card-hdr #t)
  (pcmon-text 8 6 pcmon-pc-name theme-text-main)
  (pcmon-text-right (- (gui-width) 8) 6 pcmon-time theme-text-main))

;; Thread loads as a heat grid (what the original wanted to show with LEDs)
(define (pcmon-core-color v)
  (cond ((not v) theme-dark-gray)
        ((>= v 800) theme-danger)
        ((>= v 500) theme-warning)
        ((>= v 200) theme-success)
        (else theme-accent-dark)))

(define (pcmon-render-cores x y)
  (let ((cols 4) (cell 13) (gap 3))
    (let loop ((i 0))
      (if (< i (max pcmon-ncores 12))
          (begin
            (gui-rect (+ x (* (remainder i cols) (+ cell gap)))
                      (+ y (* (quotient i cols) (+ cell gap)))
                      cell cell
                      (pcmon-core-color (if (< i pcmon-ncores) (vector-ref pcmon-cores i) #f))
                      #t)
            (loop (+ i 1)))))))

(define (pcmon-render-cpu y)
  (pcmon-chart y (list (list pcmon-hist-cpu 0 1000 theme-accent)))
  (let ((load (pcmon-val S-CPU-LOAD)))
    (pcmon-text PCMON-INFO-X (+ y 4) pcmon-cpu-name theme-text-muted)
    (pcmon-big-unit PCMON-INFO-X (+ y 28) (pcmon-int load) "%" (pcmon-load-color load))
    (pcmon-text PCMON-INFO-X (+ y 70) (pcmon-mem-text) theme-text-sub))
  (pcmon-text-right 312 (+ y 4) (string-append (pcmon-int (pcmon-val S-CPU-CLOCK)) "MHz") theme-text-sub)
  (pcmon-render-cores 250 (+ y 30)))

(define (pcmon-render-temps y)
  (pcmon-chart y (list (list pcmon-hist-tcpu 200 1000 theme-danger)
                       (list pcmon-hist-tgpu 200 1000 theme-accent)
                       (list pcmon-hist-tdisk 200 1000 theme-warning)))
  (pcmon-text PCMON-INFO-X (+ y 4) "Temperature" theme-text-muted)
  (let loop ((cols (list (list "CPU" S-CPU-TEMP theme-danger)
                         (list "GPU" S-GPU-TEMP theme-accent)
                         (list "DISK" S-DISK-TEMP theme-warning)))
             (x PCMON-INFO-X))
    (if (pair? cols)
        (let* ((c (car cols)) (v (pcmon-val (cadr c))))
          (pcmon-text x (+ y 30) (car c) (caddr c))
          (pcmon-big-unit x (+ y 52) (pcmon-int v) "°" (pcmon-temp-color v theme-text-main))
          (loop (cdr cols) (+ x 52))))))

(define (pcmon-render-gpu y)
  (pcmon-chart y (list (list pcmon-hist-gpu 0 1000 theme-danger)))
  (let ((load (pcmon-val S-GPU-LOAD)) (power (pcmon-val S-GPU-POWER)))
    (pcmon-text PCMON-INFO-X (+ y 4) pcmon-gpu-name theme-text-muted)
    (pcmon-big-unit PCMON-INFO-X (+ y 28) (pcmon-int load) "%" (pcmon-load-color load))
    (pcmon-text PCMON-INFO-X (+ y 70) (pcmon-vram-text) theme-text-sub)
    (pcmon-text-right 312 (+ y 30) (string-append (pcmon-int (pcmon-val S-GPU-CLOCK)) "MHz") theme-text-sub)
    (pcmon-text-right 312 (+ y 52) (string-append (pcmon-int power) "W") theme-text-sub)))

;; Fan gauge: 270 degree track, filled by duty, RPM in the middle
(define (pcmon-gauge cx cy label rpm duty color)
  (gui-arc cx cy 24 5 135 270 theme-dark-gray)
  (if (and duty (> duty 0))
      (gui-arc cx cy 24 5 135 (max 1 (quotient (* (min duty 1000) 270) 1000)) color))
  (let ((t (pcmon-int rpm)))
    (pcmon-text (- cx (quotient (gui-text-width t FONT-SYS-16) 2)) (- cy 8) t theme-text-main))
  (pcmon-text (- cx (quotient (gui-text-width label FONT-SYS-16) 2)) (- cy 44) label color))

(define (pcmon-render-fans y)
  (pcmon-chart y (list (list pcmon-hist-fsys 0 1000 theme-success)
                       (list pcmon-hist-fcpu 0 1000 theme-danger)
                       (list pcmon-hist-fgpu 0 1000 theme-warning)))
  (pcmon-text PCMON-INFO-X (+ y 4) "Fans" theme-text-muted)
  (pcmon-gauge 184 (+ y 66) "SYS" (pcmon-val S-FAN-SYS) (pcmon-val S-DUTY-SYS) theme-success)
  (pcmon-gauge 236 (+ y 66) "CPU" (pcmon-val S-FAN-CPU) (pcmon-val S-DUTY-CPU) theme-danger)
  (pcmon-gauge 288 (+ y 66) "GPU" (pcmon-val S-FAN-GPU) (pcmon-val S-DUTY-GPU) theme-warning))

(define (pcmon-status-field key)
  (let ((e (assq key (json-feed-status)))) (if e (cdr e) #f)))

;; Bottom strip: connection state (the original left it for message icons)
(define (pcmon-render-footer)
  (let* ((y (- (gui-height) 28))
         (state (pcmon-status-field 'state))
         (ms (pcmon-status-field 'fetch-ms))
         (text (cond ((eq? state 'ok)
                      (string-append "LHM ok  " (number->string (quotient (+ (pcmon-status-field 'bytes) 512) 1024)) " KB"
                                     (if (and ms (> ms 0)) (string-append "  " (number->string ms) " ms") "")))
                     ((eq? state 'error) (string-append "LHM: " (pcmon-status-field 'error)))
                     (else "Connecting to LibreHardwareMonitor..."))))
    (gui-rect 0 y (gui-width) 28 theme-card-hdr #t)
    (pcmon-text 8 (+ y 6) text (if (eq? state 'ok) theme-text-muted theme-warning))))

;; Label / value rows for the two info pages
(define (pcmon-row y label value)
  (pcmon-text 12 y label theme-text-muted)
  (pcmon-text 132 y value theme-text-main))

(define (pcmon-show v)
  (cond ((string? v) (if (> (string-length v) 0) v "-"))
        ((symbol? v) (symbol->string v))
        ((eq? v #t) "yes")
        ((eq? v #f) "-")
        ((number? v) (number->string v))
        (else "-")))

(define (pcmon-page-title text)
  (pcmon-text 12 38 text theme-accent))

;; Page 2: everything needed to debug the connection
(define (pcmon-render-link)
  (pcmon-page-title "Link: LibreHardwareMonitor")
  (pcmon-text 12 62 (pcmon-url) theme-text-sub)
  (let loop ((rows (json-feed-status)) (y 92))
    (if (pair? rows)
        (begin
          (pcmon-row y (symbol->string (caar rows)) (pcmon-show (cdar rows)))
          (loop (cdr rows) (+ y 24))))))

;; Page 3: board and memory, like the shared hardware pages
(define (pcmon-ref alist . keys)          ; nested lookup, #f when missing
  (let loop ((v alist) (ks keys))
    (cond ((null? ks) v)
          ((not (pair? v)) #f)
          (else (let ((e (assq (car ks) v))) (loop (if e (cdr e) #f) (cdr ks)))))))

(define (pcmon-kb n)                       ; bytes -> "42.3 KB"
  (if (number? n)
      (string-append (number->string (quotient n 1024)) "."
                     (number->string (quotient (* (remainder n 1024) 10) 1024)) " KB")
      "-"))

(define (pcmon-2d n) (if (< n 10) (string-append "0" (number->string n)) (number->string n)))

(define (pcmon-uptime ms)                  ; "3d 04:05:06"
  (if (number? ms)
      (let* ((s (quotient ms 1000)) (d (quotient s 86400)) (r (remainder s 86400)))
        (string-append (if (> d 0) (string-append (number->string d) "d ") "")
                       (pcmon-2d (quotient r 3600)) ":" (pcmon-2d (quotient (remainder r 3600) 60))
                       ":" (pcmon-2d (remainder r 60))))
      "-"))

(define (pcmon-render-hardware)
  (let* ((info (system-info))
         (st (vm-stats))
         (vm-heap (pcmon-ref info 'memory 'vm-heap))
         (vm-used (pcmon-ref info 'memory 'vm-used))
         (rssi (pcmon-ref info 'network 'rssi)))
    (pcmon-page-title "Hardware")
    (pcmon-row 62 "IP" (pcmon-show (pcmon-ref info 'network 'ip)))
    (pcmon-row 84 "MAC" (pcmon-show (pcmon-ref info 'chip 'mac)))
    (pcmon-row 106 "WiFi" (string-append (pcmon-show (pcmon-ref info 'network 'ssid))
                                         (if (number? rssi) (string-append "  " (number->string rssi) " dBm") "")))
    (pcmon-row 134 "System free" (pcmon-kb (pcmon-ref info 'memory 'free-heap)))
    (pcmon-row 156 "Largest block" (pcmon-kb (pcmon-ref info 'memory 'largest-block)))
    (pcmon-row 178 "VM heap" (pcmon-kb vm-heap))
    (pcmon-row 200 "VM used" (pcmon-kb vm-used))
    (pcmon-row 222 "VM free" (if (and (number? vm-heap) (number? vm-used)) (pcmon-kb (- vm-heap vm-used)) "-"))
    (pcmon-row 244 "Allocated" (string-append (number->string (pcmon-ref st 'alloc-kb)) " KB total"))
    (pcmon-row 266 "GC" (string-append (number->string (pcmon-ref st 'minor-gcs)) " minor  "
                                       (number->string (pcmon-ref st 'major-gcs)) " major"))
    (pcmon-row 294 "Chip" (string-append (pcmon-show (pcmon-ref info 'chip 'model)) "  "
                                         (pcmon-show (pcmon-ref info 'chip 'cpu-mhz)) " MHz x"
                                         (pcmon-show (pcmon-ref info 'chip 'cores))))
    (pcmon-row 316 "Flash" (pcmon-kb (pcmon-ref info 'chip 'flash-bytes)))
    (pcmon-row 338 "App ROM" (pcmon-kb (pcmon-ref info 'memory 'app-rom)))
    (pcmon-row 360 "IDF" (pcmon-show (pcmon-ref info 'chip 'idf)))
    (pcmon-row 382 "Reset" (pcmon-show (pcmon-ref info 'chip 'reset-reason)))
    (pcmon-row 404 "Uptime" (pcmon-uptime (pcmon-ref info 'time 'uptime-ms)))))

(define (pcmon-render)
  (gui-clear theme-bg)
  (if (gui-visible? 0 28) (pcmon-render-header))
  (cond
    ((= pcmon-page PAGE-LINK) (pcmon-render-link))
    ((= pcmon-page PAGE-HARDWARE) (pcmon-render-hardware))
    (else
     (let loop ((i 0))
       (if (< i 4)
           (let ((y (pcmon-sec-y i)))
             (if (gui-visible? y PCMON-CHART-H)
                 (cond ((= i 0) (pcmon-render-cpu y))
                       ((= i 1) (pcmon-render-temps y))
                       ((= i 2) (pcmon-render-gpu y))
                       (else (pcmon-render-fans y))))
             (loop (+ i 1)))))))
  (if (gui-visible? (- (gui-height) 28) 28) (pcmon-render-footer))
  (gui-flush))

;; Every buffer mode clears the marked rows and re-runs gui-render-proc
(define (pcmon-refresh y h)
  (gui-invalidate 0 y (gui-width) h))

;; 6. Firmware hooks -----------------------------------------------------------

(define gui-render-proc pcmon-render)

;; Main loop: sample whenever the feed holds a new document
(define (app-step)
  (let ((seq (json-feed-seq)))
    (if (and (> seq 0) (not (= seq pcmon-last-seq)))
        (pcmon-sample! seq))))

;; 1 Hz clock: header time, info pages, footer state (the firmware sets the
;; backlight from the light sensor: (backlight-auto))
(define (app-tick hm sec week date lux bl . rest)
  (if (not (equal? hm pcmon-time))
      (begin
        (set! pcmon-time hm)
        (pcmon-refresh 0 28)))
  (let ((tick (if (pair? rest) (car rest) 0)))
    (cond ((not (= pcmon-page PAGE-MONITOR))
           (if (= (remainder tick 2) 0) (pcmon-refresh 30 (- (gui-height) 30))))
          ((= pcmon-last-seq 0) (pcmon-refresh (- (gui-height) 28) 28)))))

;; Button: monitor -> link status -> hardware info -> monitor
(define (app-button)
  (set! pcmon-page (remainder (+ pcmon-page 1) 3))
  (pcmon-refresh 0 (gui-height)))

(define (app-touch x y) (app-button))

;; A FASL snapshot restores Scheme state only: restart the feed task
(define (app-resume)
  (pcmon-start!)
  (pcmon-refresh 0 (gui-height)))

(pcmon-start!)
(pcmon-refresh 0 (gui-height))

