;;; =========================================================================
;;; MiniScheme Standalone Application: wxpusher
;;; All-in-One Standalone Scheme Source (Libraries Included for WebREPL)
;;; =========================================================================
;;; [app]
;;; id = wxpusher
;;; name = WxPusher
;;; description = WxPusher 接收终端：推送到你微信的消息显示在屏幕上，新消息时 LED 闪烁；首次使用时用微信扫屏幕上的二维码登录（经应用代理）
;;; version = 5
;;; pages = 1
;;; api = 1.4 ; the device API it needs (docs/api): runs on firmware API 1.x, x >= 4 (gui-bitmap for the QR code)
;;; 
;;; [fields]
;;; ; how the settings page shows each [config] key: type | label | help
;;; ; types: text, number:min-max, bool, select:value=label,value=label
;;; ; (no ASCII ; or # in these lines: they start a comment)
;;; 
;;; [config]
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
;;; Section: apps/lib/applib.scm
;;; =========================================================================
;;; =========================================================================
;;; App framework shared by the proxy apps (weather, news, stocks, usage).
;;; Loaded after gui.scm and before the app (tools/build_apps.py).
;;;
;;; An app declares its pages and the framework does the rest:
;;;
;;;   (app-define! "天气预报"
;;;     (list (app-page "首页" url-proc interval-ms render-proc) ...))
;;;
;;;   url-proc     () -> the URL of the page's data, built once at the start;
;;;                pages with the same URL share one document
;;;   interval-ms  how often the board fetches it while the page is shown
;;;   render-proc  (items) -> draws the body between header and footer
;;;
;;; Data: the app proxy (tools/app_proxy.py) answers {"items":[{t a..e}]}.
;;; Each document is copied into vectors #(t a b c d e) and kept per URL, so a
;;; page switch shows the last data at once while its new fetch runs.
;;; Screen: header (title, page n/N except on the home page, clock), body,
;;; footer (update time, fetch state or the last error).
;;; Button: short press = next page; long press = the hardware pages (memory,
;;; storage, network, system), where a short press turns the page and a long
;;; press goes back; touch = next.
;;; Carousel (the app's ini): carousel = 1 turns the pages by themselves,
;;; carousel_seconds = 10 per page, or one value per page ("15,10,10", the
;;; last one repeats); a faint bar left of the page number counts down.
;;; =========================================================================

;; 1. Fonts, layout, text -------------------------------------------------------

(define F-TEXT 2)               ; CJK text: a 16 px face from the system font ROM
(define F-BIG FONT-CLOCK-32)    ; digits " %-./0123456789:AMP" only

;; Font slot 2: the default font chosen for the system text (font 0, set by
;; config.ini [fonts] font_override system_16:<name>) when it is 16 px like
;; the layouts, else msyh / simsun 16 from the font ROM. The built-in font 0
;; has too few CJK characters for headlines, so it is never used here.
(define (app-init-fonts!)
  (let ((sys (font-info 0)))   ; (name height glyphs source bytes), #f when built in
    (or (and (pair? sys) (= (cadr sys) 16) (use-font 2 (car sys)))
        (use-font 2 "msyh" 16 'system)
        (use-font 2 "simsun" 16 'system))))

;; The default font changed (WebREPL font manager): load slot 2 again
(define (app-refresh-fonts!)
  (font-unload 2)
  (app-init-fonts!)
  (gui-invalidate 0 0 (gui-width) (gui-height)))

(define HDR-H 32)
(define FTR-H 24)
(define LINE-H 20)
(define (body-top) (+ HDR-H 6))
(define (body-bottom) (- (gui-height) FTR-H 4))
(define (scr-w) (gui-width))

(define (txt x y s c) (gui-text-styled x y s c F-TEXT))
(define (txt-w s) (gui-text-width s F-TEXT))
(define (txt-right xr y s c) (txt (- xr (txt-w s)) y s c))
(define (txt-center cx y s c) (txt (- cx (quotient (txt-w s) 2)) y s c))
(define (txt-fit x y w s c) (gui-text-fit x y w s c F-TEXT))  ; one line; too long: marquee or "…" (config.ini [text])
(define (txt-wrap x y w h s c) (gui-text-area x y w h s c F-TEXT LINE-H))  ; too tall: wrap_marquee or "…"

(define (big x y s c) (gui-text-styled x y s c F-BIG))
(define (big-w s) (gui-text-width s F-BIG))
(define (big-right xr y s c) (big (- xr (big-w s)) y s c))

;; Big number followed by a small unit ("26" "°C")
(define (big-unit x y num unit c)
  (big x y num c)
  (txt (+ x (big-w num) 2) (+ y 2) unit c))

;; Section label with a thin rule after it
(define (section y label)
  (txt 10 y label theme-accent)
  (gui-line (+ 18 (txt-w label)) (+ y 9) (- (scr-w) 10) (+ y 9) theme-divider))

;; Section label, rule, and a note at the right end
(define (section-note y label note)
  (let ((nw (txt-w note)))
    (txt 10 y label theme-accent)
    (gui-line (+ 18 (txt-w label)) (+ y 9) (- (scr-w) 18 nw) (+ y 9) theme-divider)
    (txt-right (- (scr-w) 10) y note theme-text-muted)))

;; 2. Strings and numbers ---------------------------------------------------------

(define (str-split s ch)                 ; "a,b,,c" -> ("a" "b" "" "c")
  (let ((n (string-length s)))
    (let loop ((i 0) (start 0) (acc '()))
      (cond ((= i n) (reverse (cons (substring s start n) acc)))
            ((char=? (string-ref s i) ch) (loop (+ i 1) (+ i 1) (cons (substring s start i) acc)))
            (else (loop (+ i 1) start acc))))))

(define (str-part s ch k)                ; k-th field, "" when missing
  (let ((parts (str-split s ch)))
    (if (< k (length parts)) (list-ref parts k) "")))

(define (str-empty? s) (or (not s) (= (string-length s) 0)))

(define (str-starts? s prefix)
  (and (>= (string-length s) (string-length prefix))
       (string=? (substring s 0 (string-length prefix)) prefix)))

;; Percent-encodes a query value byte by byte (strings are UTF-8 bytes)
(define (url-encode s)
  (let ((hex "0123456789ABCDEF") (n (string-length s)))
    (let loop ((i 0) (acc '()))
      (if (= i n)
          (list->string (reverse acc))
          (let* ((c (string-ref s i)) (b (char->integer c)))
            (if (or (and (>= b 48) (<= b 57)) (and (>= b 65) (<= b 90)) (and (>= b 97) (<= b 122))
                    (memv b '(44 45 46 95 126)))
                (loop (+ i 1) (cons c acc))
                (loop (+ i 1) (cons (string-ref hex (remainder b 16))
                                    (cons (string-ref hex (quotient b 16)) (cons #\% acc))))))))))

(define (int->str n) (number->string n))

(define (pad2 n) (if (< n 10) (string-append "0" (number->string n)) (number->string n)))

;; Fixed point to text: (fixed->str 1234 2) -> "12.34", (fixed->str -5 1) -> "-0.5"
(define (fixed->str v digits)
  (if (not v)
      "--"
      (let* ((neg (< v 0)) (a (abs v)) (scale (expt 10 digits))
             (frac (number->string (remainder a scale)))
             (frac (string-append (make-string-of #\0 (- digits (string-length frac))) frac)))
        (string-append (if neg "-" "") (number->string (quotient a scale))
                       (if (> digits 0) (string-append "." frac) "")))))

(define (make-string-of ch n)
  (let loop ((i 0) (acc '())) (if (>= i n) (list->string acc) (loop (+ i 1) (cons ch acc)))))

(define (clamp v lo hi) (if (< v lo) lo (if (> v hi) hi v)))

(define (list-min l) (fold-left min (car l) l))
(define (list-max l) (fold-left max (car l) l))
(define (list-sum l) (fold-left + 0 l))

(define (take l n) (if (or (null? l) (<= n 0)) '() (cons (car l) (take (cdr l) (- n 1)))))

;; Chinese market colors: red rises, green falls
(define (rise-color v)
  (cond ((not v) theme-text-muted) ((> v 0) theme-danger) ((< v 0) theme-success) (else theme-text-sub)))

;; 3. Proxy items ------------------------------------------------------------------

(define (it-t it) (vector-ref it 0))                    ; a symbol: 'now, 'day ...
(define (it-f it k) (or (vector-ref it k) ""))          ; k 1..5 = a..e
(define (it-a it) (it-f it 1))
(define (it-b it) (it-f it 2))
(define (it-c it) (it-f it 3))
(define (it-d it) (it-f it 4))
(define (it-e it) (it-f it 5))
(define (it-ints it k) (let ((v (vector-ref it k))) (if v (string->ints v) '())))
(define (it-fixed it k digits) (let ((v (vector-ref it k))) (if v (string->fixed v digits) #f)))
(define (it-int it k) (it-fixed it k 0))

;; A field the app named with app-keys! ("topic"), "" when the item lacks it
(define (it-key it name)
  (let loop ((ks APP-KEYS) (k 0))
    (cond ((null? ks) "")
          ((string=? (car ks) name) (if (< k (vector-length it)) (it-f it k) ""))
          (else (loop (cdr ks) (+ k 1))))))

;; type: the "t" text ("day"); items hold it as a symbol
(define (items-find items type)
  (let ((sym (string->symbol type)))
    (let loop ((xs items))
      (cond ((null? xs) #f)
            ((eq? (it-t (car xs)) sym) (car xs))
            (else (loop (cdr xs)))))))

(define (items-all items type)
  (let ((sym (string->symbol type)))
    (filter (lambda (it) (eq? (it-t it) sym)) items)))

(define (items-where items type k value)   ; first of a type whose field k is value
  (let ((sym (string->symbol type)))
    (let loop ((xs items))
      (cond ((null? xs) #f)
            ((and (eq? (it-t (car xs)) sym) (equal? (vector-ref (car xs) k) value)) (car xs))
            (else (loop (cdr xs)))))))

;; 4. Charts ---------------------------------------------------------------------------

;; Polyline of a list of integers in [lo, hi]
(define (line-chart x y w h vals lo hi color)
  (if (>= (length vals) 2)
      (gui-chart x y w h (list->vector vals) 0 (length vals) lo hi color)))

;; Vertical bars of a list of integers in [0, hi]; returns the bar pitch
(define (bar-chart x y w h vals hi color)
  (let* ((n (max 1 (length vals))) (pitch (quotient w n)) (bw (max 1 (- pitch 2))))
    (let loop ((v vals) (i 0))
      (if (pair? v)
          (let ((bh (if (> hi 0) (quotient (* (clamp (car v) 0 hi) h) hi) 0)))
            (if (> bh 0) (gui-rect (+ x (* i pitch) 1) (- (+ y h) bh) bw bh color #t))
            (loop (cdr v) (+ i 1)))))
    pitch))

;; Range of a series with a little head room; never empty
(define (series-range vals min-span)
  (if (null? vals)
      (cons 0 min-span)
      (let* ((lo (list-min vals)) (hi (list-max vals)) (span (max min-span (- hi lo)))
             (pad (max 1 (quotient span 8))))
        (cons (- lo pad) (+ lo span pad)))))

(define (progress-bar x y w h pct color)
  (gui-round-rect x y w h 3 theme-dark-gray #t)
  (let ((fw (quotient (* (clamp pct 0 100) w) 100)))
    (if (> fw 0) (gui-round-rect x y (max fw 6) h 3 color #t))))

;; 5. State -------------------------------------------------------------------------------

(define APP-BASE-KEYS '("t" "a" "b" "c" "d" "e"))
(define APP-KEYS APP-BASE-KEYS)              ; read per item: (app-keys! name ...) adds more
(define APP-SELECTORS '((0 prefix "")))      ; every object with a "t"
(define APP-POOL 0)                          ; value text per document: no limit (memory bounds it)
(define APP-VALUE-LEN 0)                     ; bytes per value: no limit
(define APP-CACHE-MAX 3)                     ; documents kept for quick page switches
(define CAROUSEL-BAR-H 4)                    ; countdown bar in the header
(define CAROUSEL-BAR-COLOR 46552)            ; #xB5D8 (#b2b9c2): 3/4 of the way from the header to the text

(define app-carousel #f)                     ; seconds per page (a list) while turning, else #f
(define app-carousel-left 0)                 ; seconds left on this page
(define app-carousel-paused #f)              ; (app-carousel-pause): the page stays until resumed

(define app-title "APP")
(define app-subtitle-proc #f)                ; (items) -> text after the title on page 1
(define app-tick-proc #f)                    ; (tick) -> called every second
(define app-render-empty-pages '())          ; pages drawn before their data comes (with no items)
(define app-data-proc #f)                    ; (items) -> called when a new document arrives
(define app-footer-text "")                  ; the footer of a local page (no proxy data)
(define app-pages (vector))
(define app-urls (vector))
(define app-page-index 0)
(define app-time "--:--")
(define app-sec "--")                        ; the device clock's seconds, weekday and date (月日)
(define app-week "")
(define app-date "")
(define app-utc-sec 0)                       ; second of the UTC day (the tick once the clock is synced)
(define app-lunar "")                       ; the device's lunar month and day (八月十九), "" unsynced
(define app-cache '())                       ; #(url items time) per fetched URL
(define app-error #f)                        ; message of the last error object
(define app-last-seq 0)
(define app-feed-url "")
(define app-loading #f)                      ; fetch requested, no document yet

;; More fields per item beyond t, a..e, by name: (app-keys! "topic" "text") before
;; app-define!; read them with (it-key it "topic")
(define (app-keys! . names) (set! APP-KEYS (append APP-BASE-KEYS names)))

(define (app-page name url-proc interval render) (vector name url-proc interval render))
;; A page drawn from the app's own data (memos, messages): no fetch, render gets '()
(define (app-local-page name render) (vector name (lambda () "") 0 render))
(define (app-local? i) (string=? (vector-ref app-urls i) ""))
(define (app-npages) (vector-length app-pages))
(define (app-cur) (vector-ref app-pages app-page-index))

(define (app-config key default)
  (let ((v (config-get key)))
    (if (and (string? v) (> (string-length v) 0)) v default)))

;; config.ini [app] proxy = http://<pc>:8087 (tools/app_proxy.py); "" when unset
(define (app-proxy)
  (let* ((p (app-config "proxy" "")) (n (string-length p)))
    (if (and (> n 0) (char=? (string-ref p (- n 1)) #\/)) (substring p 0 (- n 1)) p)))

(define (app-url path) (string-append (app-proxy) path))

(define (app-cache-entry url)
  (let loop ((c app-cache))
    (cond ((null? c) #f)
          ((equal? (vector-ref (car c) 0) url) (car c))
          (else (loop (cdr c))))))

;; Keep all page documents in memory so page switches are instantaneous
(define (app-cache-max) (max APP-CACHE-MAX (app-npages)))

;; Newest first; past (app-cache-max) documents the oldest one goes, never the
;; home page's (the page shown most)
(define (app-cache-put! url items)
  (let ((c (cons (vector url items app-time)
                 (filter (lambda (e) (not (equal? (vector-ref e 0) url))) app-cache))))
    (set! app-cache
          (if (<= (length c) (app-cache-max))
              c
              (let ((home (vector-ref app-urls 0)))
                (reverse (let drop ((r (reverse c)))
                           (cond ((null? r) r)
                                 ((equal? (vector-ref (car r) 0) home) (cons (car r) (drop (cdr r))))
                                 (else (cdr r))))))))))

(define (app-items)
  (let ((e (app-cache-entry (vector-ref app-urls app-page-index))))
    (if e (vector-ref e 1) #f)))

(define (app-status key)
  (let ((e (assq key (json-feed-status)))) (if e (cdr e) #f)))

;; 6. Feed --------------------------------------------------------------------------------

(define APP-NO-PROXY "未设置代理：在设置页或 config.ini [app] proxy 填写 http://电脑IP:8087")

(define (app-start-feed!)
  (set! app-feed-url (vector-ref app-urls app-page-index))
  (cond
    ((string=? app-feed-url "")     ; a local page: nothing to fetch
     (set! app-loading #f))
    ((string=? (app-proxy) "")
     (set! app-loading #f)          ; nothing to fetch from: say where to set it
     (set! app-error APP-NO-PROXY))
    (else
        (if (eq? app-error APP-NO-PROXY) (set! app-error #f))   ; set since (a snapshot made without one)
        (set! app-loading #t)
        (json-feed-start app-feed-url (vector-ref (app-cur) 2) APP-KEYS APP-SELECTORS
                         APP-POOL APP-VALUE-LEN 2))))

;; #(type a b c d e ...): the type as a symbol, a slot per key of APP-KEYS,
;; empty values as #f (heap is scarce)
(define (app-read-item i)
  (let* ((n (length APP-KEYS)) (v (make-vector n #f)))
    (let loop ((k 1))
      (if (< k n)
          (let ((s (json-feed-field i k)))
            (if (and s (> (string-length s) 0)) (vector-set! v k s))
            (loop (+ k 1)))))
    (let ((t (json-feed-field i 0)))
      (vector-set! v 0 (if t (string->symbol t) 'none)))
    v))

;; Pre-fetches the next uncached page in the background right after boot
(define (app-prefetch-next!)
  (let loop ((i 0))
    (if (< i (app-npages))
        (let ((url (vector-ref app-urls i)))
          (cond
            ((or (string=? url "") (app-cache-entry url))
             (loop (+ i 1)))
            (else
             (set! app-feed-url url)
             (set! app-loading #t)
             (json-feed-start url (vector-ref (vector-ref app-pages i) 2) APP-KEYS APP-SELECTORS
                              APP-POOL APP-VALUE-LEN 2)
             #t)))
        #f)))

;; A new document: copy it, or keep the old data when the proxy sent an error
(define (app-take-document!)
  (let ((items (let loop ((i (- (json-feed-count) 1)) (acc '()))
                 (if (< i 0) acc (loop (- i 1) (cons (app-read-item i) acc))))))
    (set! app-loading #f)
    (if (and (pair? items) (eq? (it-t (car items)) 'error))
        (set! app-error (it-a (car items)))
        (begin
          (set! app-error #f)
          (app-cache-put! (json-feed-url) items)
          (if app-data-proc (app-data-proc items))
          (app-prefetch-next!)))
    (app-invalidate-all)))

;; 7. Drawing --------------------------------------------------------------------------------

(define (app-invalidate-all) (gui-invalidate 0 0 (scr-w) (gui-height)))
(define (app-invalidate-body) (gui-invalidate 0 HDR-H (scr-w) (- (gui-height) HDR-H)))

;; The text after the title: the home page's subtitle (a city), else the page
;; name. Drawn in another color, not after a separator: the system fonts
;; may lack "·".
(define (app-header-sub items)
  (if (= app-page-index 0)
      (if (and app-subtitle-proc items) (app-subtitle-proc items) #f)
      (vector-ref (app-cur) 0)))

;; 2 px per second, 1 px for pages shown longer than 30 s (at most 90 px)
(define (carousel-px secs) (if (> secs 30) 1 2))
(define (carousel-bar-w secs) (min 90 (* secs (carousel-px secs))))

;; The countdown, right-aligned at xr: a faint track and what is left of it
(define (app-render-countdown xr)
  (let* ((secs (app-page-seconds app-page-index))
         (full (carousel-bar-w secs))
         (left (min full (* (max 0 app-carousel-left) (carousel-px secs))))
         (y (quotient (- HDR-H CAROUSEL-BAR-H) 2)))
    (gui-rect (- xr full) y full CAROUSEL-BAR-H (if app-carousel-paused theme-divider theme-dark-gray) #t)
    (if (and (> left 0) (not app-carousel-paused))  ; paused: one even bar, no countdown
        (gui-rect (- xr left) y left CAROUSEL-BAR-H CAROUSEL-BAR-COLOR #t))))

(define (app-render-header items)
  (let* ((w (scr-w))
         (tw (txt-w app-time))
         (ind (if (> app-page-index 0)
                  (string-append (int->str (+ app-page-index 1)) "/" (int->str (app-npages)))
                  #f))
         (iw (if ind (+ (txt-w ind) 12) 0))
         (badge (- w 8 tw 8 iw))
         ;; the carousel's countdown sits left of the page number (of the clock on page 1)
         (bar-r (- badge (if ind 6 0)))
         (right (if app-carousel (- bar-r (carousel-bar-w (app-page-seconds app-page-index)) 6) badge)))
    (gui-rect 0 0 w HDR-H theme-card-hdr #t)
    (if app-carousel (app-render-countdown bar-r))
    (txt-right (- w 8) 8 app-time theme-text-main)
    (if ind
        (begin
          (gui-round-rect badge 5 iw 22 6 theme-accent-dark #t)
          (txt (+ badge 6) 8 ind theme-accent)))
    (let ((sub (app-header-sub items)) (title-w (txt-w app-title)))
      (txt-fit 8 8 (- right 14) app-title theme-text-main)
      (if (and (not (str-empty? sub)) (< (+ 8 title-w 10) (- right 20)))
          (txt-fit (+ 8 title-w 10) 8 (- right 14 title-w 10) sub theme-accent)))))

(define (app-render-local-footer)
  (let ((y (- (gui-height) FTR-H)))
    (gui-rect 0 y (scr-w) FTR-H theme-card-hdr #t)
    (txt-fit 8 (+ y 3) (- (scr-w) 16) app-footer-text theme-text-muted)))

(define (app-render-footer)
  (if (app-local? app-page-index) (app-render-local-footer) (app-render-feed-footer)))

(define (app-render-feed-footer)
  (let* ((y (- (gui-height) FTR-H))
         (w (scr-w))
         (entry (app-cache-entry (vector-ref app-urls app-page-index)))
         (upd (and entry (items-find (vector-ref entry 1) "upd")))  ; the server's data time
         (state (app-status 'state))
         (failed (or app-error (eq? state 'error)))
         (text (cond (app-error (string-append "代理: " app-error))
                     ((eq? state 'error) (string-append "连接失败: " (app-status 'error)))
                     (app-loading (if entry "刷新中..." "加载中..."))
                     ;; the time the server gives for its data ({"t": "upd"}), else when
                     ;; this device fetched it (unknown before the clock was set)
                     ((and upd (it-a upd)) (string-append "更新于 " (it-a upd)))
                     (entry (if (string=? (vector-ref entry 2) "--:--") "已更新"
                                (string-append "更新于 " (vector-ref entry 2))))
                     (else "等待数据")))
         (ms (app-status 'fetch-ms))
         (right (if (and (eq? state 'ok) (number? ms) (> ms 0))
                    (string-append (fixed->str (quotient (+ (app-status 'bytes) 51) 102) 1) "KB "
                                   (int->str ms) "ms")
                    "")))
    (gui-rect 0 y w FTR-H theme-card-hdr #t)
    (txt-right (- w 8) (+ y 3) right theme-text-muted)
    (txt-fit 8 (+ y 3) (- w 24 (txt-w right)) text (if failed theme-warning theme-text-muted))))

(define (app-render-waiting)
  (let ((cx (quotient (scr-w) 2)) (y (- (quotient (gui-height) 2) 60)))
    (txt-center cx y "正在获取数据..." theme-text-sub)
    (gui-text-wrap 16 (+ y 34) (- (scr-w) 32) 60 app-feed-url theme-text-muted F-TEXT LINE-H)
    (if (or app-error (eq? (app-status 'state) 'error))
        (txt-wrap 16 (+ y 100) (- (scr-w) 32) 80
                  "请在电脑上运行 tools/app_proxy.py，并在 config.ini [app] proxy 中填写它的地址"
                  theme-warning))))

(define (app-render)
  (gui-clear theme-bg)
  (app-render-page)
  (gui-flush))

(define (app-render-page)
  (let ((items (if (app-local? app-page-index) '() (app-items))))   ; a local page: no document
    (if (gui-visible? 0 HDR-H) (app-render-header items))
    (if (gui-visible? HDR-H (- (gui-height) HDR-H FTR-H))
        (cond ((app-local? app-page-index) ((vector-ref (app-cur) 3) '()))
              (items ((vector-ref (app-cur) 3) items))
            ((memv app-page-index app-render-empty-pages) ((vector-ref (app-cur) 3) '()))
            (else (app-render-waiting)))))
  (if (gui-visible? (- (gui-height) FTR-H) FTR-H) (app-render-footer)))

;; 8. Firmware hooks ---------------------------------------------------------------------------

(define gui-render-proc app-render)

;; carousel = 1 in the app's ini (or config.ini [app]): seconds per page
(define (app-carousel-config)
  (if (member (app-config "carousel" "0") '("1" "on" "yes" "true"))
      (let ((secs (map (lambda (n) (clamp n 3 3600)) (string->ints (app-config "carousel_seconds" "10")))))
        (if (null? secs) '(10) secs))
      #f))

(define (app-page-seconds i)
  (if (< i (length app-carousel)) (list-ref app-carousel i) (list-ref app-carousel (- (length app-carousel) 1))))

(define (app-carousel-reset!)
  (if app-carousel (set! app-carousel-left (app-page-seconds app-page-index))))

(define (app-define! title pages)
  (set! app-title title)
  (set! app-pages (list->vector pages))
  (set! app-urls (list->vector (map (lambda (p) ((vector-ref p 1))) pages)))
  (set! app-page-index 0)
  (set! app-carousel (if (> (length pages) 1) (app-carousel-config) #f))
  (app-carousel-reset!)
  (app-init-fonts!)
  (app-start-feed!)
  (app-invalidate-all))

(define (app-goto! i)
  (set! app-page-index i)
  (app-carousel-reset!)
  (let ((url (vector-ref app-urls i)))
    (if (not (equal? url app-feed-url))
        (if (not (app-cache-entry url))
            (app-start-feed!))))
  (app-invalidate-all))

(define (app-next-page!) (app-goto! (remainder (+ app-page-index 1) (app-npages))))

;; Page i fetches from url from now on (the URL procedures run once, at
;; app-define!); the page shown fetches it at once
(define (app-set-url! i url)
  (if (not (equal? (vector-ref app-urls i) url))
      (begin
        (vector-set! app-urls i url)
        (if (= i app-page-index) (app-start-feed!)))))

;; From the REPL (WebREPL quick commands "暂停翻页" / "恢复翻页"): the carousel
;; stops on this page, or counts it from the start again. Short presses still
;; turn pages. => paused, running, or off (no carousel = 1 in the app's ini).
(define (app-carousel-state) (cond ((not app-carousel) 'off) (app-carousel-paused 'paused) (else 'running)))

(define (app-carousel-pause)
  (set! app-carousel-paused #t)
  (app-carousel-reset!)
  (gui-invalidate 0 0 (scr-w) HDR-H)
  (app-carousel-state))

(define (app-carousel-resume)
  (set! app-carousel-paused #f)
  (app-carousel-reset!)
  (gui-invalidate 0 0 (scr-w) HDR-H)
  (app-carousel-state))

;; One second of the carousel: the next page when this one's time is up
(define (app-carousel-tick!)
  (set! app-carousel-left (- app-carousel-left 1))
  (if (<= app-carousel-left 0)
      (app-next-page!)
      (gui-invalidate 0 0 (scr-w) HDR-H)))

(define (app-step)
  (let ((seq (json-feed-seq)))
    (if (and (> seq 0) (not (= seq app-last-seq)))
        (begin
          (set! app-last-seq seq)
          (app-take-document!)))))

(define (app-tick hm sec week date lux bl . rest)
  (let ((tick (if (pair? rest) (car rest) 0)))
    (set! app-sec sec)
    (set! app-utc-sec tick)
    (set! app-week week)
    (set! app-date date)
    (if (and (pair? rest) (pair? (cdr rest))) (set! app-lunar (cadr rest)))
    (if (not (equal? hm app-time))
        (begin
          (set! app-time hm)
          (gui-invalidate 0 0 (scr-w) HDR-H)))
    (if (= (remainder tick 2) 0)
        (gui-invalidate 0 (- (gui-height) FTR-H) (scr-w) FTR-H))
    (if (and app-carousel (not (info-active?)) (not app-carousel-paused)) ; also stops on the hardware pages
        (app-carousel-tick!))
    (if app-tick-proc (app-tick-proc tick))))

;; Short press: next page (the home page after the last; a carousel's
;; countdown starts again there). A long press opens the hardware pages
;; (apps/lib/infopages.scm, shared by every app); the carousel's countdown
;; starts again when they open and close.
(define (app-button) (app-next-page!))

(set! info-on-change (lambda (open?) (app-carousel-reset!)))

(define (app-touch x y) (app-button))

(define (app-resume)
  (app-init-fonts!)
  (app-start-feed!)
  (app-invalidate-all))


;;; =========================================================================
;;; Section: apps/lib/appweb.scm
;;; =========================================================================
;;; =========================================================================
;;; appweb.scm: the Scheme side of an app's own web page (apps/<id>/web.html).
;;;
;;; The board serves the page at /app (the first tab of its web page); the
;;; page's appCall(name, fields) posts to /api/app/call?fn=name with the fields
;;; form-encoded, and the firmware calls the app's hook
;;;
;;;   (app-web name body)  ->  a string sent back as the answer
;;;
;;; on the main loop, between frames. Answer JSON with (web-json value); read
;;; the fields with (web-field body "key"). The WASM simulator calls the same
;;; hook from its app page panel (web_repl/app_web.js).
;;; =========================================================================

;; Percent-decoding of a form value ("a+b%41" -> "a bA"): bytes in, bytes out
(define (web-hex-digit c)
  (let ((b (char->integer c)))
    (cond ((and (>= b 48) (<= b 57)) (- b 48))
          ((and (>= b 65) (<= b 70)) (- b 55))
          ((and (>= b 97) (<= b 102)) (- b 87))
          (else #f))))

(define (web-decode s)
  (let ((n (string-length s)))
    (let loop ((i 0) (acc '()))
      (if (>= i n)
          (list->string (reverse acc))
          (let ((c (string-ref s i)))
            (cond ((char=? c #\+) (loop (+ i 1) (cons #\space acc)))
                  ((and (char=? c #\%) (< (+ i 2) n)
                        (web-hex-digit (string-ref s (+ i 1))) (web-hex-digit (string-ref s (+ i 2))))
                   (loop (+ i 3) (cons (integer->char (+ (* 16 (web-hex-digit (string-ref s (+ i 1))))
                                                         (web-hex-digit (string-ref s (+ i 2)))))
                                       acc)))
                  (else (loop (+ i 1) (cons c acc)))))))))

;; The value of field key in a form body ("a=1&b=x%20y"), or #f
(define (web-field body key)
  (let ((parts (str-split (or body "") #\&)) (k (string-append key "=")))
    (let loop ((p parts))
      (cond ((null? p) #f)
            ((str-starts? (car p) k)
             (web-decode (substring (car p) (string-length k) (string-length (car p)))))
            ((string=? (car p) key) "")
            (else (loop (cdr p)))))))

;; A field as an integer, or default
(define (web-field-int body key default)
  (let ((v (web-field body key)))
    (or (and v (string->number v)) default)))

;; The double quote character
(define WEB-QUOTE #\")

;; JSON text of a value: strings, numbers, #t/#f, symbols (as strings),
;; vectors (arrays), alists with symbol or string keys (objects), other lists (arrays)
(define (web-json-string s)
  (let ((n (string-length s)) (hex "0123456789abcdef"))
    (let loop ((i 0) (acc (list WEB-QUOTE)))
      (if (>= i n)
          (list->string (reverse (cons WEB-QUOTE acc)))
          (let* ((c (string-ref s i)) (b (char->integer c)))
            (loop (+ i 1)
                  (cond ((= b 34) (cons WEB-QUOTE (cons #\\ acc)))
                        ((= b 92) (cons #\\ (cons #\\ acc)))
                        ((= b 10) (cons #\n (cons #\\ acc)))
                        ((= b 13) (cons #\r (cons #\\ acc)))
                        ((= b 9) (cons #\t (cons #\\ acc)))
                        ((< b 32) (append (list (string-ref hex (remainder b 16)) (string-ref hex (quotient b 16))
                                                #\0 #\0 #\u #\\)
                                          acc))
                        (else (cons c acc)))))))))

(define (web-alist? v)
  (and (pair? v)
       (let loop ((l v))
         (cond ((null? l) #t)
               ((and (pair? l) (pair? (car l)) (or (symbol? (caar l)) (string? (caar l)))) (loop (cdr l)))
               (else #f)))))

(define (web-join strs sep)
  (if (null? strs)
      ""
      (let loop ((l (cdr strs)) (acc (list (car strs))))
        (if (null? l)
            (apply string-append (reverse acc))
            (loop (cdr l) (cons (car l) (cons sep acc)))))))

(define (web-json v)
  (cond ((string? v) (web-json-string v))
        ((eq? v #t) "true")
        ((eq? v #f) "false")
        ((null? v) "[]")
        ((number? v) (number->string v))
        ((symbol? v) (web-json-string (symbol->string v)))
        ((vector? v) (string-append "[" (web-join (map web-json (vector->list v)) ",") "]"))
        ((web-alist? v)
         (string-append "{"
                        (web-join (map (lambda (p)
                                         (string-append (web-json-string (if (symbol? (car p))
                                                                             (symbol->string (car p))
                                                                             (car p)))
                                                        ":" (web-json (cdr p))))
                                       v)
                                  ",")
                        "}"))
        ((pair? v) (string-append "[" (web-join (map web-json v) ",") "]"))
        (else "null")))

;; {"success":false,"error":msg}: the page's appCall throws it
(define (web-error msg) (web-json (list (cons 'success #f) (cons 'error msg))))

;; {"success":true, ...fields}
(define (web-ok . fields) (web-json (cons (cons 'success #t) fields)))


;;; =========================================================================
;;; Section: apps/wxpusher/wxpusher.scm
;;; =========================================================================
;;; =========================================================================
;;; WxPusher receiver, 320x480 portrait, on the app framework (applib.scm).
;;; The app proxy (tools/app_proxy.py) is a WxPusher client device: it keeps
;;; the service's WebSocket and collects the messages pushed to the user's
;;; WeChat; this app polls them at /app/wxpusher every 5 s and keeps them on
;;; the board (wxpusher.txt in its folder). Without a login the proxy sends
;;; the login QR code, drawn here to scan with WeChat.
;;;   home: the messages: the subject (【新】 on the right while unread), under
;;;   it the topic on the left and the time on the right
;;;   short press: the full messages, newest to oldest, then home again
;;;   long press at home: everything read
;;;   long press on a message: unread -> read; already read -> home
;;; Messages deleted here (the web page) are deleted at the proxy too: the
;;; feed URL carries ?del=<ids> until a document from it arrives; the proxy
;;; drops them and deletes them on the WxPusher service.
;;; File: first line "L|<newest id taken>", then "D|<ids to delete at the
;;; proxy>" while there are any, then "id|read|time|title|text"; time is
;;; "MM-DD HH:MM", then after a space the topic (the item's "topic").
;;; An app may touch only its own folder: relative paths are in it.
;;; =========================================================================

(define WX-PATH "wxpusher.txt")         ; in the app's own folder
(define WX-MAX 20)
(define WX-INTERVAL 5000)
(define WX-ROW-H 46)
(define WX-WHITE 65535)
(define WX-BLACK 0)

(define wx-list '())                    ; #(id read time title text), newest first; ids are digit strings
(define wx-last "")                     ; the newest message id taken ("" none yet)
(define wx-view #f)                     ; #f: the list, else the id of the message shown
(define wx-state "")                    ; the proxy's: starting, login, ok, error ("" no data yet)
(define wx-info "")
(define wx-left 0)                      ; seconds the QR code stays valid
(define wx-qr-n 0)                      ; modules per side
(define wx-qr #f)                       ; the QR code as a 1-bit bitmap (gui-bitmap data), or #f
(define wx-qr-key "")                   ; the rows as sent: decoded again only when they change
(define wx-alert 0)                     ; seconds of LED blinking left
(define wx-del '())                     ; ids deleted here, not yet taken by the proxy

;; 1. Storage ---------------------------------------------------------------------------------

(define (wx-id m) (vector-ref m 0))
(define (wx-read? m) (vector-ref m 1))
(define (wx-time m) (vector-ref m 2))           ; "MM-DD HH:MM topic"
(define WX-TIME-LEN 11)                         ; "MM-DD HH:MM"
(define (wx-clock m)
  (let ((t (wx-time m))) (if (> (string-length t) WX-TIME-LEN) (substring t 0 WX-TIME-LEN) t)))
(define (wx-topic m)
  (let ((t (wx-time m)))
    (if (> (string-length t) (+ WX-TIME-LEN 1)) (substring t (+ WX-TIME-LEN 1) (string-length t)) "")))
(define (wx-title m) (vector-ref m 3))
(define (wx-text m) (vector-ref m 4))

;; Message ids are too long for fixnums: compared as digit strings
(define (wx-id>? a b)
  (or (> (string-length a) (string-length b))
      (and (= (string-length a) (string-length b)) (string>? a b))))

(define (wx-find id)
  (let loop ((l wx-list))
    (cond ((null? l) #f)
          ((string=? (wx-id (car l)) id) (car l))
          (else (loop (cdr l))))))

;; The message after (older than) id, #f past the oldest or when id is gone
(define (wx-after id)
  (let loop ((l wx-list))
    (cond ((null? l) #f)
          ((string=? (wx-id (car l)) id) (if (pair? (cdr l)) (cadr l) #f))
          (else (loop (cdr l))))))

;; The positions of the first n "|" in line, or #f
(define (wx-bars line n)
  (let loop ((i 0) (acc '()))
    (cond ((= (length acc) n) (reverse acc))
          ((>= i (string-length line)) #f)
          ((char=? (string-ref line i) #\|) (loop (+ i 1) (cons i acc)))
          (else (loop (+ i 1) acc)))))

(define (wx-parse line)
  (let ((b (wx-bars line 4)))
    (if (not b)
        #f
        (let ((field (lambda (k)
                       (substring line (if (= k 0) 0 (+ 1 (list-ref b (- k 1))))
                                  (if (= k 4) (string-length line) (list-ref b k))))))
          (vector (field 0) (string=? (field 1) "1") (field 2) (field 3) (field 4))))))

(define (wx-load!)
  (let ((text (and (fs-exists? WX-PATH) (fs-read WX-PATH))))
    (set! wx-list '())
    (if (string? text)
        (for-each (lambda (line)
                    (cond ((str-starts? line "L|") (set! wx-last (substring line 2 (string-length line))))
                          ((str-starts? line "D|")
                           (set! wx-del (filter (lambda (id) (not (str-empty? id)))
                                                (str-split (substring line 2 (string-length line)) #\,))))
                          (else (let ((m (wx-parse line))) (if m (set! wx-list (append wx-list (list m))))))))
                  (str-split text #\newline)))))

;; "|" and line ends would break a line: only the text (the last field) may hold "|"
(define (wx-safe s keep-bar)
  (list->string (map (lambda (c) (if (or (and (not keep-bar) (char=? c #\|)) (char=? c #\newline) (char=? c #\return))
                                     #\space c))
                     (string->list (or s "")))))

(define (wx-line m)
  (string-append (wx-id m) "|" (if (wx-read? m) "1" "0") "|" (wx-time m) "|" (wx-title m) "|" (wx-text m)))

(define (wx-save!)
  (fs-write WX-PATH (web-join (append (list (string-append "L|" wx-last))
                                      (if (pair? wx-del) (list (string-append "D|" (web-join wx-del ","))) '())
                                      (map wx-line wx-list))
                              (list->string (list #\newline))))
  (app-invalidate-all))

;; The feed URL: with ?del=<ids> while deletions wait for the proxy
(define (wx-base-url) (app-url "/app/wxpusher"))
(define (wx-url)
  (if (null? wx-del) (wx-base-url) (string-append (wx-base-url) "?del=" (web-join wx-del ","))))

;; Messages deleted here: gone from the board, sent to the proxy with the next fetch
(define (wx-delete! ids)
  (set! wx-list (filter (lambda (m) (not (member (wx-id m) ids))) wx-list))
  (if (and wx-view (not (wx-find wx-view))) (set! wx-view #f))
  (set! wx-del (append wx-del (filter (lambda (id) (not (member id wx-del))) ids)))
  (if (= (wx-unread) 0) (begin (set! wx-alert 0) (ws2812-clear)))
  (wx-save!)
  (app-set-url! 0 (wx-url)))

(define (wx-unread) (length (filter (lambda (m) (not (wx-read? m))) wx-list)))

(define (wx-mark-read! m)
  (vector-set! m 1 #t)
  (if (= (wx-unread) 0) (begin (set! wx-alert 0) (ws2812-clear))))

;; 2. The proxy's document ----------------------------------------------------------------------

(define (wx-hex-val c)
  (let ((n (char->integer c))) (if (>= n 97) (- n 87) (- n 48))))

;; One hex row (4 modules a digit, the first the high bit) as the (n + 7) / 8
;; bytes gui-bitmap reads: two digits a byte, a missing digit as 0
(define (wx-row-bytes hex n)
  (let ((len (string-length hex)))
    (let loop ((k (- (quotient (+ n 7) 8) 1)) (acc '()))
      (if (< k 0)
          acc
          (let ((hi (if (< (* 2 k) len) (wx-hex-val (string-ref hex (* 2 k))) 0))
                (lo (if (< (+ (* 2 k) 1) len) (wx-hex-val (string-ref hex (+ (* 2 k) 1))) 0)))
            (loop (- k 1) (cons (integer->char (+ (* hi 16) lo)) acc)))))))

;; The proxy's QR rows as one bitmap, built once per code (drawn as one
;; display-list command, not one rectangle per run of modules)
(define (wx-take-qr! items n)
  (let* ((parts (map it-b (items-all items "qr")))
         (key (web-join parts ",")))
    (if (not (string=? key wx-qr-key))
        (begin
          (set! wx-qr-key key)
          (set! wx-qr-n n)
          (set! wx-qr (if (> n 0)
                          (list->string (apply append (map (lambda (hex) (wx-row-bytes hex n)) (str-split key #\,))))
                          #f))))))

;; The stored time field: "MM-DD HH:MM", then after a space the topic (the
;; "topic" key; an older proxy put it in c after the time already)
(define (wx-item-time it)
  (let ((topic (it-key it "topic")))
    (if (str-empty? topic) (it-c it) (string-append (it-c it) " " topic))))

;; The newest stored id, "" with none
(define (wx-newest-stored)
  (let loop ((l wx-list) (hi ""))
    (cond ((null? l) hi)
          ((or (string=? hi "") (wx-id>? (wx-id (car l)) hi)) (loop (cdr l) (wx-id (car l))))
          (else (loop (cdr l) hi)))))

;; wx-last newer than every message of the document while neither the
;; document nor the board has it: nothing backs it (a test feed, another
;; proxy), and it would hide every real message. Back to the newest stored
;; ("" with none: the document's messages come in).
(define (wx-check-last! msgs)
  (if (and (pair? msgs) (not (string=? wx-last ""))
           (not (wx-find wx-last))
           (null? (filter (lambda (it) (string=? (it-a it) wx-last)) msgs))
           (null? (filter (lambda (it) (not (wx-id>? wx-last (it-a it)))) msgs)))
      (set! wx-last (wx-newest-stored))))

;; New messages: ids past the newest taken, oldest first. "m" is unread,
;; "h" was read on the service before (history); new unread ones blink the LED.
(set! app-data-proc
      (lambda (items)
        ;; a document fetched with ?del=: the proxy has the deletions
        (if (and (pair? wx-del) (equal? (json-feed-url) (wx-url)))
            (begin
              (set! wx-del '())
              (wx-save!)
              (app-set-url! 0 (wx-url))))
        (let ((st (items-find items "state")))
          (if st
              (begin
                (set! wx-state (it-a st))
                (set! wx-info (it-b st))
                (set! wx-left (or (it-int st 4) 0))
                (wx-take-qr! items (if (string=? wx-state "login") (or (it-int st 3) 0) 0)))))
        (wx-check-last! (filter (lambda (it) (and (memq (it-t it) '(m h)) (not (str-empty? (it-a it))))) items))
        (let ((fresh (filter (lambda (it)
                               (and (memq (it-t it) '(m h)) (not (str-empty? (it-a it)))
                                    (or (string=? wx-last "") (wx-id>? (it-a it) wx-last))))
                             (reverse items))))
          (if (pair? fresh)
              (begin
                (for-each (lambda (it)
                            (set! wx-list (cons (vector (it-a it) (eq? (it-t it) 'h) (wx-safe (wx-item-time it) #f)
                                                        (wx-safe (it-b it) #f)
                                                        (wx-safe (string-append (it-d it) (it-e it)) #t))
                                                wx-list))
                            (set! wx-last (it-a it)))
                          fresh)
                (if (> (length wx-list) WX-MAX) (set! wx-list (take wx-list WX-MAX)))
                (if (pair? (filter (lambda (it) (eq? (it-t it) 'm)) fresh)) (set! wx-alert 20))
                (wx-save!))))))

;; 3. The screen ------------------------------------------------------------------------------

(define WX-NEW "【新】")

(define (wx-render-qr)
  (let* ((n wx-qr-n) (box (+ n 8))
         (m (max 1 (min 6 (quotient (- (scr-w) 20) box))))
         (side (* box m))
         (x0 (quotient (- (scr-w) side) 2))
         (y0 (+ (body-top) 34)))
    (txt-center (quotient (scr-w) 2) (+ (body-top) 6) "用微信扫码登录" theme-text-main)
    (gui-rect x0 y0 side side WX-WHITE #t)               ; the quiet zone, 4 modules around
    (gui-bitmap (+ x0 (* 4 m)) (+ y0 (* 4 m)) n n wx-qr m WX-BLACK)
    (let ((y (+ y0 side 10)))
      (txt-wrap 14 y (- (scr-w) 28) 60
                "扫码后，推送到这个微信的消息会显示在这里" theme-text-sub)
      (if (> wx-left 0)
          (txt-center (quotient (scr-w) 2) (+ y 48)
                      (string-append "二维码 " (number->string (quotient (+ wx-left 59) 60)) " 分钟内有效")
                      theme-text-muted)))))

(define (wx-render-login-waiting)
  (txt 14 70 "WxPusher 未登录" theme-text-main)
  (txt-wrap 14 100 (- (scr-w) 28) 100
            (if (str-empty? wx-info) "等待代理生成登录二维码..." wx-info) theme-text-sub))

(define (wx-hint)
  (cond ((str-empty? (app-proxy)) "在系统设置中填写应用代理（运行 tools/app_proxy.py 的电脑）")
        ((string=? wx-state "error") (string-append "代理连接 WxPusher 失败：" wx-info))
        (else "推送到你微信的消息会显示在这里")))

(define (wx-render-row m y)
  (let* ((w (scr-w)) (unread (not (wx-read? m))) (nw (if unread (+ (txt-w WX-NEW) 4) 0))
         (clock (wx-clock m)) (cw (+ (txt-w clock) 10)))
    (txt-fit 10 (+ y 4) (- w 20 nw) (wx-title m) (if unread theme-text-main theme-text-sub))
    (if unread (txt-right (- w 8) (+ y 4) WX-NEW theme-danger))
    (txt-fit 10 (+ y 24) (- w 20 cw) (wx-topic m) theme-accent)
    (txt-right (- w 10) (+ y 24) clock theme-text-muted)
    (gui-line 10 (- (+ y WX-ROW-H) 1) (- w 10) (- (+ y WX-ROW-H) 1) theme-divider)))

(define (wx-render-list)
  (if (null? wx-list)
      (begin
        (txt 14 70 "暂无消息" theme-text-muted)
        (txt-wrap 14 100 (- (scr-w) 28) 80 (wx-hint) theme-text-sub))
      (let ((rows (quotient (- (body-bottom) (body-top)) WX-ROW-H)))
        (let loop ((l wx-list) (i 0) (y (body-top)))
          (if (and (pair? l) (< i rows))
              (begin
                (if (gui-visible? y WX-ROW-H) (wx-render-row (car l) y))
                (loop (cdr l) (+ i 1) (+ y WX-ROW-H))))))))

(define (wx-position id)
  (let loop ((l wx-list) (i 1))
    (cond ((null? l) 0)
          ((string=? (wx-id (car l)) id) i)
          (else (loop (cdr l) (+ i 1))))))

;; As a row of the list, larger: the mark and the position, the subject
;; (two lines), the topic on the left and the time on the right, the text
(define (wx-render-message m)
  (let* ((w (scr-w)) (y (+ (body-top) 2)) (unread (not (wx-read? m)))
         (clock (wx-clock m)) (cw (+ (txt-w clock) 10)))
    (txt 10 y (if unread WX-NEW "已读") (if unread theme-danger theme-text-muted))
    (txt-right (- w 10) y (string-append (number->string (wx-position (wx-id m))) "/"
                                         (number->string (length wx-list)))
               theme-text-muted)
    (txt-wrap 10 (+ y 26) (- w 20) 40 (wx-title m) theme-text-main)
    (txt-fit 10 (+ y 70) (- w 20 cw) (wx-topic m) theme-accent)
    (txt-right (- w 10) (+ y 70) clock theme-text-muted)
    (gui-line 10 (+ y 94) (- w 10) (+ y 94) theme-divider)
    (txt-wrap 10 (+ y 102) (- w 20) (- (body-bottom) y 102 26)
              (if (str-empty? (wx-text m)) (wx-title m) (wx-text m)) theme-text-main)
    (txt-fit 10 (- (body-bottom) 20) (- w 20)
             (string-append (if unread "长按：标为已读" "长按：返回列表")
                            (if (wx-after (wx-id m)) "  短按：下一条" "  短按：返回列表"))
             theme-text-muted)))

(define (wx-render items)
  (let ((m (and wx-view (wx-find wx-view))))
    (cond (m (wx-render-message m))
          ((and (string=? wx-state "login") wx-qr) (wx-render-qr))
          ((string=? wx-state "login") (wx-render-login-waiting))
          (else (wx-render-list)))))

;; 4. Buttons, alert ---------------------------------------------------------------------------

;; Short press: the newest message, then each older one, then the list again
(set! app-button
      (lambda ()
        (let ((next (if wx-view (wx-after wx-view) (if (pair? wx-list) (car wx-list) #f))))
          (set! wx-view (if next (wx-id next) #f))
          (app-invalidate-all))))

;; Long press: at home everything read; on a message read it, or (read
;; already) back to the list
(define (app-long-press)
  (let ((m (and wx-view (wx-find wx-view))))
    (cond ((not wx-view)
           (if (> (wx-unread) 0)
               (begin (for-each wx-mark-read! wx-list) (wx-save!))))
          ((and m (not (wx-read? m))) (wx-mark-read! m) (wx-save!))
          (else (set! wx-view #f)))
    (app-invalidate-all)))

(set! app-tick-proc
      (lambda (tick)
        (if (> wx-alert 0)
            (begin
              (if (= (remainder tick 2) 0) (ws2812-set 0 160 60) (ws2812-clear))
              (set! wx-alert (- wx-alert 1))
              (if (= wx-alert 0) (ws2812-clear))))))

(set! app-subtitle-proc
      (lambda (items)
        (cond ((string=? wx-state "login") "未登录")
              ((string=? wx-state "error") "连接中断")
              ((> (wx-unread) 0) (string-append "未读 " (number->string (wx-unread))))
              (else #f))))

;; 5. The web page's calls --------------------------------------------------------------------------

(define (wx->alist m)
  (list (cons 'id (wx-id m)) (cons 'read (wx-read? m)) (cons 'time (wx-clock m)) (cons 'topic (wx-topic m))
        (cons 'title (wx-title m)) (cons 'text (wx-text m))))

(define (wx-answer)
  (web-ok (cons 'messages (map wx->alist wx-list)) (cons 'unread (wx-unread)) (cons 'state wx-state)
          (cons 'info wx-info) (cons 'proxy (app-proxy))
          (cons 'pending (length wx-del))))

(define (app-web name body)
  (cond
    ((string=? name "list") (wx-answer))
    ((string=? name "read")
     (let ((id (or (web-field body "id") "")))
       (for-each (lambda (m) (if (or (string=? id "") (string=? (wx-id m) id)) (wx-mark-read! m))) wx-list)
       (wx-save!)
       (wx-answer)))
    ((string=? name "delete")
     (let ((id (or (web-field body "id") "")))
       (if (wx-find id) (wx-delete! (list id)))
       (wx-answer)))
    ((string=? name "clear")
     (wx-delete! (map wx-id wx-list))
     (wx-answer))
    (else (web-error (string-append "unknown call: " name)))))

;; 6. Start ------------------------------------------------------------------------------------------

(wx-load!)
(app-keys! "topic")                    ; beyond t, a..e: the message's topic
(set! app-render-empty-pages '(0))     ; the board's own messages, also before (or without) the proxy

(app-define! "WxPusher"
  (list (app-page "消息" wx-url WX-INTERVAL wx-render)))

