;;; =========================================================================
;;; MiniScheme Standalone Application: medicine
;;; All-in-One Standalone Scheme Source (Libraries Included for WebREPL)
;;; =========================================================================
;;; [app]
;;; pages = 1
;;; page_ids = meds ; English page names: <app>.<id> in a combined app (front: the first)
;;; id = medicine
;;; name = 吃药提醒
;;; description = 按服药时间点自动弹出吃药提醒（从任何应用切换过来，断电重启后继续），大号粗体显示药名和服用量，逐个按键确认后回到原来的应用。药品可设长期、服用天数或按数量扣减；每个时间点选药、填服用量、可隔日；服药记录自动保存；在设备网页的应用选项卡设置；不需要代理
;;; version = 3
;;; storage_kb = 512 ; the medicines' photos in the app's folder (instead of app_storage_kb)
;;; 
;;; [fields]
;;; ; how the settings page shows each [config] key: type | label | help
;;; ; types: text, number:min-max, bool, select:value=label,value=label
;;; ; (no ASCII ; or # in these lines: they start a comment)
;;; max_minutes = select:0=永久（直到全部确认）,15=15 分钟,30=30 分钟,60=1 小时,120=2 小时,240=4 小时 | 提醒最多持续 | 超过后回到原来的应用，未确认的药记为已服用
;;; name_size = select:1=1 倍（16 像素）,2=2 倍,3=3 倍,4=4 倍 | 提醒时药名大小 | 粗体，太长时自动缩小到放得下
;;; amount_size = select:1=1 倍（16 像素）,2=2 倍,3=3 倍,4=4 倍 | 提醒时服用量大小 | 粗体
;;; list_size = select:1=1 倍（16 像素）,2=2 倍,3=3 倍 | 平时药名和服用量大小 | 轮流显示药品时，粗体
;;; 
;;; [config]
;;; max_minutes = 0 ; minutes a reminder lasts at most, 0: until every medicine is confirmed (restarts too)
;;; name_size = 3 ; the reminder's medicine name: a multiple of the 16 px font (1..4)
;;; amount_size = 2 ; the reminder's amount (1..4)
;;; list_size = 2 ; the name and the next amount in normal mode (1..3)
;;; proxy_url = ; Application proxy service URL (empty: use system config.ini)
;;; converter_url = ; Protocol converter URL (empty: use system config.ini)

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
  (let* ((p1 (config-get "proxy_url"))
         (p (if (and (string? p1) (> (string-length p1) 0)) p1 (config-get "proxy"))))
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

(define (str-contains? s sub)
  (let ((n (string-length s)) (m (string-length sub)))
    (if (> m n)
        #f
        (let loop ((i 0))
          (cond
            ((> (+ i m) n) #f)
            ((string=? (substring s i (+ i m)) sub) #t)
            (else (loop (+ i 1))))))))

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
  (if (not (pair? items))
      #f
      (let ((sym (string->symbol type)))
        (let loop ((xs items))
          (cond ((not (pair? xs)) #f)
                ((eq? (it-t (car xs)) sym) (car xs))
                (else (loop (cdr xs))))))))

(define (items-all items type)
  (if (not (pair? items))
      '()
      (let ((sym (string->symbol type)))
        (filter (lambda (it) (eq? (it-t it) sym)) items))))

(define (items-where items type k value)   ; first of a type whose field k is value
  (if (not (pair? items))
      #f
      (let ((sym (string->symbol type)))
        (let loop ((xs items))
          (cond ((not (pair? xs)) #f)
                ((and (eq? (it-t (car xs)) sym) (equal? (vector-ref (car xs) k) value)) (car xs))
                (else (loop (cdr xs))))))))

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
(define app-header-proc #f)                  ; (items x w): draws page 1's title in [x, x + w) itself
(define app-page-title-only #f)              ; #t: pages after the first are titled by their name alone
(define app-tick-proc #f)                    ; (tick) -> called every second
(define app-render-empty-pages '())          ; pages drawn before their data comes (with no items)
(define app-data-proc #f)                    ; (items) -> called when a new document arrives
(define app-views '())                       ; (name . (lambda (items i) ...)): views a combined app can show
(define app-index-always #f)                 ; #t: the page number also on page 1 (a combined app)
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
(define app-cache '())                       ; #(url items time second) per fetched URL
(define app-error #f)                        ; message of the last error object
(define app-error-url "")                    ; the page URL whose document carried it
(define app-last-seq 0)
(define app-feed-url "")
(define app-loading #f)                      ; fetch requested, no document yet

;; More fields per item beyond t, a..e, by name: (app-keys! "topic" "text") before
;; app-define!; read them with (it-key it "topic")
(define (app-keys! . names) (set! APP-KEYS (append APP-BASE-KEYS names)))

(define (app-page name url-proc interval render) (vector name url-proc interval render))
;; A view of the app's data a combined app (apps/lib/combo.scm) may show as
;; one of its pages: "news[0]" calls (proc items 0) on the page it belongs to
(define (app-view! name page proc) (set! app-views (cons (list name page proc) app-views)))
;; A page drawn from the app's own data (memos, messages): no fetch, render gets '()
(define (app-local-page name render) (vector name (lambda () "") 0 render))
(define (app-local? i) (string=? (vector-ref app-urls i) ""))
(define (app-npages) (vector-length app-pages))
(define (app-cur) (vector-ref app-pages app-page-index))

(define (app-config key default)
  (let ((v (config-get key)))
    (if (and (string? v) (> (string-length v) 0)) v default)))

;; config.ini [server] proxy_url / [app] proxy = http://<pc>:8087 (tools/app_proxy.py); "" when unset
(define (app-proxy)
  (let* ((p (app-config "proxy_url" (app-config "proxy" ""))) (n (string-length p)))
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
  (let ((c (cons (vector url items app-time app-utc-sec)
                 (filter (lambda (e) (not (equal? (vector-ref e 0) url))) app-cache))))
    (set! app-cache
          (if (<= (length c) (app-cache-max))
              c
              (let ((home (vector-ref app-urls 0)))
                (reverse (let drop ((r (reverse c)))
                           (cond ((null? r) r)
                                 ((equal? (vector-ref (car r) 0) home) (cons (car r) (drop (cdr r))))
                                 (else (cdr r))))))))))

;; Page i's data is younger than the page's interval: shown again without
;; fetching (a page turn or the carousel does not fetch it every time)
(define (app-fresh? i)
  (let ((e (app-cache-entry (vector-ref app-urls i))))
    (and e (< (* 1000 (modulo (- app-utc-sec (vector-ref e 3)) 86400))
              (vector-ref (vector-ref app-pages i) 2)))))

;; The one stream follows the page on screen once its data is due
(define (app-follow-page!)
  (if (and (not (equal? (vector-ref app-urls app-page-index) app-feed-url))
           (not (app-local? app-page-index))
           (not (app-fresh? app-page-index)))
      (app-start-feed!)))

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
        (begin (set! app-error (it-a (car items))) (set! app-error-url (json-feed-url)))
        (begin
          (set! app-error #f)
          (app-cache-put! (json-feed-url) items)
          (if app-data-proc (app-data-proc items))
          ;; every page cached: the firmware's one stream goes back to the
          ;; page on screen when its data is due (app-tick checks again)
          (if (not (app-prefetch-next!)) (app-follow-page!))))
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

(define (app-demo-data? items)
  (and (pair? items)
       (or (items-find items "demo")
           (let ((loc (items-find items "loc")))
             (and loc (or (string=? (it-b loc) "MiniScheme-Proxy")
                          (string=? (it-b loc) "和风天气(回退)")
                          (str-contains? (it-b loc) "演示")))))))

(define (app-header-title items)
  (let ((t-it (if (pair? items) (items-find items "title") #f)))
    (cond
      ((and t-it (not (str-empty? (it-a t-it))))
       (it-a t-it))
      ((app-demo-data? items)
       (if (str-contains? app-title "【演示数据】")
           app-title
           (string-append app-title "【演示数据】")))
      (else app-title))))

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
         (ind (if (or app-index-always (> app-page-index 0))
                  (string-append (int->str (+ app-page-index 1)) "/" (int->str (app-npages)))
                  #f))
         (iw (if ind (+ (txt-w ind) 12) 0))
         (badge (- w 8 tw 8 iw))
         ;; the carousel's countdown sits left of the page number (of the clock on page 1)
         (bar-r (- badge (if ind 6 0)))
         (right (if (pair? app-carousel) (- bar-r (carousel-bar-w (app-page-seconds app-page-index)) 6) badge)))
    (gui-rect 0 0 w HDR-H theme-card-hdr #t)
    (if (pair? app-carousel) (app-render-countdown bar-r))
    (txt-right (- w 8) 8 app-time theme-text-main)
    (if ind
        (begin
          (gui-round-rect badge 5 iw 22 6 theme-accent-dark #t)
          (txt (+ badge 6) 8 ind theme-accent)))
    (if (and app-header-proc (= app-page-index 0))
        (app-header-proc items 8 (- right 14))
        (let* ((named (and app-page-title-only (> app-page-index 0)))
               (title (if named (vector-ref (app-cur) 0) (app-header-title items)))
               (sub (if named #f (app-header-sub items)))
               (title-w (txt-w title)))
          (txt-fit 8 8 (- right 14) title theme-text-main)
          (if (and (not (str-empty? sub)) (< (+ 8 title-w 10) (- right 20)))
              (txt-fit (+ 8 title-w 10) 8 (- right 14 title-w 10) sub theme-accent))))))

(define (app-render-local-footer)
  (let ((y (- (gui-height) FTR-H)))
    (gui-rect 0 y (scr-w) FTR-H theme-card-hdr #t)
    (txt-fit 8 (+ y 3) (- (scr-w) 16) app-footer-text theme-text-muted)))

(define (app-render-footer)
  (if (app-local? app-page-index) (app-render-local-footer) (app-render-feed-footer)))

;; "http://host:port" shown as "host:port"
(define (app-server-name s)
  (cond ((not (string? s)) "服务器")
        ((str-starts? s "http://") (substring s 7 (string-length s)))
        ((str-starts? s "tcp://") (substring s 6 (string-length s)))
        (else s)))

(define (app-render-feed-footer)
  (let* ((y (- (gui-height) FTR-H))
         (w (scr-w))
         (url (vector-ref app-urls app-page-index))
         (entry (app-cache-entry url))
         (upd (and entry (items-find (vector-ref entry 1) "upd")))  ; the server's data time
         ;; the time the server gives for its data ({"t": "upd"}), else when
         ;; this device fetched it (unknown before the clock was set)
         (last (cond ((and upd (it-a upd)) (string-append "更新于 " (it-a upd)))
                     ((not entry) #f)
                     ((string=? (vector-ref entry 2) "--:--") "已更新")
                     (else (string-append "更新于 " (vector-ref entry 2)))))
         ;; this page's fetch only: a prefetch of another page failing says nothing about it
         (mine (equal? (json-feed-url) url))
         (state (if mine (app-status 'state) 'ok))
         (page-error (and app-error (or (eq? app-error APP-NO-PROXY) (equal? app-error-url url)) app-error))
         ;; what the fetch waits for now (firmware 1.0.57+): it replaces an old error
         (step (app-status 'step))
         (busy (memq step '(clock register wifi)))
         (failed (and (not busy) (or page-error (eq? state 'error))))
         (text (cond ((eq? step 'register)
                      (string-append "正在向 " (app-server-name (app-status 'step-server)) " 注册加密通道..."))
                     ((eq? step 'clock) "等待网络对时...")
                     ((eq? step 'wifi) "等待 WiFi 连接...")      ; firmware 1.0.61+
                     (page-error (string-append "代理: " page-error))
                     ((eq? state 'error) (string-append "连接失败: " (app-status 'error)))
                     ((and app-loading mine) (if last (string-append last "，刷新中...") "加载中..."))
                     (last last)
                     (else "等待数据")))
         (ms (app-status 'fetch-ms))
         (right (if (and mine (eq? state 'ok) (number? ms) (> ms 0))
                    (string-append (fixed->str (quotient (+ (app-status 'bytes) 51) 102) 1) "KB "
                                   (int->str ms) "ms")
                    "")))
    (gui-rect 0 y w FTR-H theme-card-hdr #t)
    (txt-right (- w 8) (+ y 3) right theme-text-muted)
    (txt-fit 8 (+ y 3) (- w 24 (txt-w right)) text (if failed theme-warning theme-text-muted))))

(define (app-render-waiting)
  (let ((cx (quotient (scr-w) 2)) (y (- (quotient (gui-height) 2) 60)))
    (txt-center cx y "正在获取数据..." theme-text-sub)
    ;; the address without its query: a token there would show on the screen and mirror
    (gui-text-wrap 16 (+ y 34) (- (scr-w) 32) 60 (car (str-split app-feed-url #\?)) theme-text-muted F-TEXT LINE-H)
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
  (if (member (app-config "carousel" "1") '("1" "on" "yes" "true"))
      (let ((secs (map (lambda (n) (clamp n 3 3600)) (string->ints (app-config "carousel_seconds" "10")))))
        (if (null? secs) '(10) secs))
      #f))

(define (app-page-seconds i)
  (cond
    ((or (not (pair? app-carousel)) (null? app-carousel)) 10)
    ((< i (length app-carousel)) (list-ref app-carousel i))
    (else (list-ref app-carousel (- (length app-carousel) 1)))))

(define (app-carousel-reset!)
  (if (pair? app-carousel) (set! app-carousel-left (app-page-seconds app-page-index))))

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
  (app-follow-page!)                 ; its data still fresh: shown from the cache
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
    (if (> (app-npages) 0) (app-follow-page!))   ; the shown page's cached data became due
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
;;; Section: apps/medicine/medicine.scm
;;; =========================================================================
;;; =========================================================================
;;; Medicine reminder, 320x480 portrait, on the app framework (applib.scm).
;;; Set up on the board's web page (the app's tab, apps/medicine/web.html):
;;;   medicines  name, unit (粒, 片, 袋 ...), photo (photos/m<id>.jpg) and a
;;;              plan: long-term, for N days from a date, or by quantity
;;;              (N units: each confirmed dose takes its amount off)
;;;   times      the time points; each lists its medicines with the amount
;;;              taken then, every day or every other day from a date
;;;   settings   how long a reminder may last (0: until every medicine is
;;;              confirmed), the text sizes
;;; The times go into schedule.ini (persist = 1): the system starts this app
;;; at each of them from any app and, until (app-return), again after a
;;; restart or a power cut (API 1.7, firmware 1.0.68+).
;;;   normal:   the medicines in use one after another: photo, the name and
;;;             the next amount large and bold, the next time bottom left,
;;;             the plan's progress bottom right; a press: the next one
;;;   reminder: "共 N 个药 第 k 个" blinks in the title; a press confirms one;
;;;             after the last, back to the app that ran before. Past the
;;;             time limit the rest count as taken.
;;; Amounts and quantities are kept in tenths (0.5 粒 = 5).
;;; Files (the app's folder):
;;;   meds.txt     id|name|unit|plan|n|start|left    plan long, days (n days), count (n, left: tenths)
;;;   slots.txt    id|HH:MM|med.alt.ref.amount,...   alt 1: every other day from day ref
;;;   log.txt      day|HH:MM|med|how|HH:MM|amount    how ok, auto (time limit), skip
;;;   pending.txt  day|HH:MM|start                   the reminder in progress (start: minutes)
;;; Days are counted from 1970-01-01 (time-local), minutes from that day too.
;;; =========================================================================

(define MED-PATH "meds.txt")
(define SLOT-PATH "slots.txt")
(define LOG-PATH "log.txt")
(define PENDING-PATH "pending.txt")
(define MED-SCHEDULE "schedule.ini")
(define MED-MAX 20)
(define SLOT-MAX 6)
(define LOG-KEEP 300)                   ; lines of log.txt kept
(define MED-NAME-MAX 60)                ; bytes
(define MED-UNIT-MAX 12)
(define MED-PHOTO-TOP 37)               ; 5 px under the title bar (HDR-H)
(define MED-SHOW-SECONDS 8)             ; normal mode: seconds per medicine
(define MED-DONE-SECONDS 3)
(define MED-WAIT-SECONDS 20)            ; a scheduled start waits this long for the date
(define MED-NL (list->string (list #\newline)))
(define MED-SCALE-KEYS '(("name_size" "3" 4) ("amount_size" "2" 4) ("list_size" "2" 3)))

(define med-list '())                   ; #(id name unit plan n start left)
(define slot-list '())                  ; #(id time entries), entries: (#(med alt ref amount) ...)
(define med-index 0)
(define med-left MED-SHOW-SECONDS)
(define med-info-cache '())             ; (id . image-info)
(define med-scales '())
(define med-max-minutes 0)              ; 0: a reminder lasts until every medicine is confirmed
(define med-due '())                    ; reminder: ((med . amount) ...) still to take
(define med-due-total 0)
(define med-due-done 0)
(define med-due-at "")                  ; reminder: its time, "" in normal mode
(define med-due-day 0)                  ; reminder: its day
(define med-due-start 0)                ; reminder: when it began (minutes)
(define med-done-left 0)
(define med-blink #t)
(define med-pending-at #f)              ; a scheduled start waiting for the date
(define med-pending-secs 0)

;; 1. Small helpers ------------------------------------------------------------------------

(define (med-trim s)
  (let* ((n (string-length s))
         (blank? (lambda (i) (<= (char->integer (string-ref s i)) 32)))
         (a (let loop ((i 0)) (if (and (< i n) (blank? i)) (loop (+ i 1)) i)))
         (b (let loop ((j n)) (if (and (> j a) (blank? (- j 1))) (loop (- j 1)) j))))
    (substring s a b)))

(define (med-int s default)
  (let ((n (and (string? s) (string->number (med-trim s))))) (if (integer? n) n default)))

;; "8:05" / "08:05" -> "08:05", else #f
(define (med-hm s)
  (let ((p (str-split (med-trim s) #\:)))
    (and (= (length p) 2)
         (= (string-length (cadr p)) 2)
         (let ((h (string->number (car p))) (m (string->number (cadr p))))
           (and (integer? h) (integer? m) (>= h 0) (< h 24) (>= m 0) (< m 60)
                (string-append (pad2 h) ":" (pad2 m)))))))

;; One line of at most limit bytes without | and ~ (the files' separators),
;; never cut inside a UTF-8 character
(define (med-clean s limit)
  (let* ((flat (med-trim (list->string (map (lambda (c) (if (or (memv c '(#\| #\~)) (< (char->integer c) 32)) #\space c))
                                            (string->list s)))))
         (n (string-length flat)))
    (if (<= n limit)
        flat
        (let back ((k limit))
          (if (and (> k 0) (= (quotient (char->integer (string-ref flat k)) 64) 2))
              (back (- k 1))
              (substring flat 0 k))))))

(define (med-read path)
  (let ((text (and (fs-exists? path) (fs-read path))))
    (if (string? text) (filter (lambda (l) (> (string-length (med-trim l)) 0)) (str-split text #\newline)) '())))

(define (med-write path lines) (fs-write path (web-join lines MED-NL)))

;; tenths -> "2", "0.5", "12.5"
(define (amt-text a)
  (if (= (remainder a 10) 0)
      (number->string (quotient a 10))
      (string-append (number->string (quotient a 10)) "." (number->string (remainder a 10)))))

(define (med-digit? c) (let ((b (char->integer c))) (or (and (>= b 48) (<= b 57)) (= b 46))))

;; "0.5粒" / "2 粒" / "半片" -> (tenths . unit): the leading number (1 without one) and the rest
(define (dose-split s)
  (let* ((t (med-trim s)) (n (string-length t))
         (end (let loop ((i 0)) (if (and (< i n) (med-digit? (string-ref t i))) (loop (+ i 1)) i)))
         (num (and (> end 0) (string->number (substring t 0 end))))
         (unit (med-trim (substring t end n))))
    (cons (if (and num (> num 0)) (max 1 (round->int (* num 10))) 10) (if (str-empty? unit) "次" unit))))

(define (round->int x) (let ((r (round x))) (if (exact? r) r (inexact->exact r))))

;; Days since 1970-01-01 of a date
(define (med-civil-days y m d)
  (let* ((y (if (<= m 2) (- y 1) y))
         (era (quotient (if (>= y 0) y (- y 399)) 400))
         (yoe (- y (* era 400)))
         (doy (+ (quotient (+ (* 153 (+ m (if (> m 2) -3 9))) 2) 5) (- d 1)))
         (doe (+ (* yoe 365) (quotient yoe 4) (- (quotient yoe 100)) doy)))
    (+ (* era 146097) doe -719468)))

(define (med-today)
  (let ((t (time-local))) (if t (med-civil-days (car t) (cadr t) (caddr t)) #f)))

;; minutes since day 0 (local wall time), #f without the clock
(define (med-now-minutes)
  (let ((t (time-local)))
    (if t (+ (* 1440 (med-civil-days (car t) (cadr t) (caddr t))) (* 60 (list-ref t 3)) (list-ref t 4)) #f)))

;; 2. Medicines --------------------------------------------------------------------------

(define (med-id m) (vector-ref m 0))
(define (med-name m) (vector-ref m 1))
(define (med-unit m) (vector-ref m 2))
(define (med-plan m) (vector-ref m 3))          ; "long" "days" "count"
(define (med-n m) (vector-ref m 4))             ; days, or tenths bought
(define (med-start m) (vector-ref m 5))         ; first day
(define (med-units m) (vector-ref m 6))         ; tenths left (count plan)
(define (med-shape m) (vector-ref m 7))         ; auto, capsule, tablet, ball, oval, sachet, none
(define (med-color m) (vector-ref m 8))         ; white, yellow, orange, red, pink, blue, green, brown
(define (med-photo-path m) (string-append "photos/m" (number->string (med-id m)) ".jpg"))

;; meds.txt: 7 fields; the 8 of version 3 (id|name|dose|per|plan|n|start|left,
;; whole units) are converted, their dose's amount kept for the time points
(define med-v3-amounts '())             ; (id . tenths) of converted version 3 lines

(define (med-parse line)
  (let ((f (str-split line #\|)))
    (cond ((or (= (length f) 7) (= (length f) 9))
           (let ((id (med-int (car f) #f)) (plan (list-ref f 3)))
             (and id (member plan '("long" "days" "count"))
                  (vector id (cadr f) (caddr f) plan (max 0 (med-int (list-ref f 4) 0)) (med-int (list-ref f 5) 0)
                          (max 0 (med-int (list-ref f 6) 0))
                          (if (and (= (length f) 9) (member (list-ref f 7) MED-SHAPES)) (list-ref f 7) "auto")
                          (if (and (= (length f) 9) (assoc (list-ref f 8) MED-COLORS)) (list-ref f 8) "white")))))
          ((= (length f) 8)
           (let ((id (med-int (car f) #f)) (plan (list-ref f 4)) (d (dose-split (caddr f))))
             (and id (member plan '("long" "days" "count"))
                  (begin
                    (set! med-v3-amounts (cons (cons id (car d)) med-v3-amounts))
                    (vector id (cadr f) (cdr d) plan
                            (* (if (string=? plan "count") 10 1) (max 0 (med-int (list-ref f 5) 0)))
                            (med-int (list-ref f 6) 0) (* 10 (max 0 (med-int (list-ref f 7) 0))) "auto" "white")))))
          (else #f))))

(define (med-line m)
  (web-join (list (number->string (med-id m)) (med-name m) (med-unit m) (med-plan m)
                  (number->string (med-n m)) (number->string (med-start m)) (number->string (med-units m))
                  (med-shape m) (med-color m))
            "|"))

(define (med-find id)
  (let loop ((l med-list)) (cond ((null? l) #f) ((= (med-id (car l)) id) (car l)) (else (loop (cdr l))))))

;; 'later (not started), 'active, 'done (days over or used up) on day d (#f: unknown)
(define (med-status m d)
  (cond ((and d (< d (med-start m))) 'later)
        ((and d (string=? (med-plan m) "days") (>= d (+ (med-start m) (med-n m)))) 'done)
        ((and (string=? (med-plan m) "count") (<= (med-units m) 0)) 'done)
        (else 'active)))

(define (med-active? m d) (eq? (med-status m d) 'active))

;; "长期" / "剩余 5/7 天" / "剩余 20/60 粒"
(define (med-plan-text m d)
  (let ((st (med-status m d)))
    (cond ((eq? st 'later) "尚未开始")
          ((eq? st 'done) (if (string=? (med-plan m) "count") "已用完" "疗程已结束"))
          ((string=? (med-plan m) "days")              ; 疗程: day k of N
           (string-append "疗程: " (number->string (clamp (+ 1 (- (or d (med-start m)) (med-start m))) 1 (med-n m)))
                          "/" (number->string (med-n m)) "天"))
          ((string=? (med-plan m) "count")             ; 疗程: taken / bought
           (string-append "疗程: " (amt-text (- (med-n m) (med-units m))) "/" (amt-text (med-n m)) " " (med-unit m)))
          (else "长期"))))

;; 3. Time points ------------------------------------------------------------------------

(define (slot-id s) (vector-ref s 0))
(define (slot-time s) (vector-ref s 1))
(define (slot-entries s) (vector-ref s 2))
(define (ent-med e) (vector-ref e 0))
(define (ent-alt? e) (= (vector-ref e 1) 1))
(define (ent-ref e) (vector-ref e 2))
(define (ent-amount e) (vector-ref e 3))        ; tenths

(define (ent-parse s)
  (let ((f (str-split s #\.)))
    (and (>= (length f) 3) (<= (length f) 4) (med-int (car f) #f)
         (let ((id (med-int (car f) 0)))
           (vector id (if (string=? (cadr f) "1") 1 0) (med-int (caddr f) 0)
                   (if (= (length f) 4)
                       (clamp (med-int (list-ref f 3) 10) 1 10000)
                       (let ((v3 (assv id med-v3-amounts))) (if v3 (cdr v3) 10))))))))

(define (slot-parse line)
  (let ((f (str-split line #\|)))
    (and (>= (length f) 2) (med-int (car f) #f) (med-hm (cadr f))
         (vector (med-int (car f) 0) (med-hm (cadr f))
                 (if (and (>= (length f) 3) (> (string-length (caddr f)) 0))
                     (filter (lambda (e) e) (map ent-parse (str-split (caddr f) #\,)))
                     '())))))

(define (ent-text e)
  (string-append (number->string (ent-med e)) "." (if (ent-alt? e) "1" "0") "." (number->string (ent-ref e))
                 "." (number->string (ent-amount e))))

(define (slot-line s)
  (string-append (number->string (slot-id s)) "|" (slot-time s) "|" (web-join (map ent-text (slot-entries s)) ",")))

(define (slot-at time)
  (let loop ((l slot-list)) (cond ((null? l) #f) ((string=? (slot-time (car l)) time) (car l)) (else (loop (cdr l))))))

(define (slot-entry s id)
  (let loop ((l (slot-entries s))) (cond ((null? l) #f) ((= (ent-med (car l)) id) (car l)) (else (loop (cdr l))))))

;; taken on day d: every day, or every other day from its ref
(define (ent-day? e d) (or (not (ent-alt? e)) (not d) (= (modulo (- d (ent-ref e)) 2) 0)))

;; The slots sorted by time
(define (slots-sorted)
  (let insert-all ((l slot-list) (acc '()))
    (if (null? l)
        acc
        (insert-all (cdr l)
                    (let ins ((s (car l)) (a acc))
                      (cond ((null? a) (list s))
                            ((string<? (slot-time s) (slot-time (car a))) (cons s a))
                            (else (cons (car a) (ins s (cdr a))))))))))

;; m's next dose: (days-ahead time amount) after now (today, tomorrow or the day
;; after, counting every-other-day plans), #f when no time point takes it
(define (med-next-dose m)
  (let ((d (med-today)) (now (if (string=? app-time "--:--") "" app-time)) (slots (slots-sorted)))
    (let day-loop ((k 0))
      (if (> k 2)
          #f
          (or (let loop ((l slots))
                (cond ((null? l) #f)
                      ((let ((e (slot-entry (car l) (med-id m))))
                         (and e (ent-day? e (and d (+ d k))) (or (> k 0) (string<? now (slot-time (car l))))
                              (list k (slot-time (car l)) (ent-amount e)))))
                      (else (loop (cdr l)))))
              (day-loop (+ k 1)))))))

;; 4. Load and save ----------------------------------------------------------------------

;; Files of version 1 and 2: meds.txt "id|name|qty|slots|alt|ref" (slots: time
;; point numbers), the times only in schedule.ini. Made into the new files once.
(define (med-migrate!)
  (let ((lines (med-read MED-PATH)))
    (if (and (pair? lines) (not (fs-exists? SLOT-PATH)) (= (length (str-split (car lines) #\|)) 6))
        (let* ((old (filter (lambda (f) (= (length f) 6)) (map (lambda (l) (str-split l #\|)) lines)))
               (ini (med-read MED-SCHEDULE))
               (tline (let loop ((l ini)) (cond ((null? l) #f) ((str-starts? (med-trim (car l)) "times") (car l)) (else (loop (cdr l))))))
               (tval (and tline (let ((kv (str-split tline #\=))) (and (pair? (cdr kv)) (car (str-split (cadr kv) #\;))))))
               (times (if tval (filter (lambda (t) t) (map med-hm (str-split tval #\,))) '())))
          (set! med-list (map (lambda (f) (vector (med-int (car f) 0) (cadr f) (cdr (dose-split (caddr f))) "long" 0 0 0 "auto" "white")) old))
          (set! slot-list
                (let loop ((ts times) (k 1) (acc '()))
                  (if (null? ts)
                      (reverse acc)
                      (loop (cdr ts) (+ k 1)
                            (cons (vector k (car ts)
                                          (filter (lambda (e) e)
                                                  (map (lambda (f)
                                                         (and (memv k (map (lambda (x) (med-int x 0)) (str-split (list-ref f 3) #\,)))
                                                              (vector (med-int (car f) 0) (if (string=? (list-ref f 4) "1") 1 0)
                                                                      (med-int (list-ref f 5) 0) (car (dose-split (caddr f))))))
                                                       old)))
                                  acc)))))
          (med-write MED-PATH (map med-line med-list))
          (slots-save!)))))

(define (med-load!)
  (set! med-v3-amounts '())
  (set! med-list (filter (lambda (m) m) (map med-parse (med-read MED-PATH))))
  (set! slot-list (filter (lambda (s) s) (map slot-parse (med-read SLOT-PATH))))
  (if (pair? med-v3-amounts)                       ; version 3 files: written in the new form once
      (begin (med-write MED-PATH (map med-line med-list)) (slots-save!) (set! med-v3-amounts '())))
  (set! med-info-cache '()))

(define (med-save!)
  (med-write MED-PATH (map med-line med-list))
  (set! med-info-cache '())
  (app-invalidate-all))

;; slots.txt and schedule.ini (the firmware reads times and persist)
(define (slots-save!)
  (med-write SLOT-PATH (map slot-line slot-list))
  (fs-write MED-SCHEDULE
            (string-append "[schedule]" MED-NL
                           "; written by the medicine app: the system starts it at these times" MED-NL
                           "times = " (web-join (map slot-time slot-list) ", ") MED-NL
                           "persist = 1 ; a reminder comes back after a restart until it is confirmed" MED-NL))
  (app-invalidate-all))

(define (med-load-settings!)
  (set! med-scales
        (map (lambda (k)
               (cons (car k) (clamp (med-int (app-config (car k) (cadr k)) (string->number (cadr k))) 1 (caddr k))))
             MED-SCALE-KEYS))
  (set! med-max-minutes (clamp (med-int (app-config "max_minutes" "0") 0) 0 1440)))

(define (med-scale key) (let ((hit (assoc key med-scales))) (if hit (cdr hit) 1)))

;; 5. The log ----------------------------------------------------------------------------

;; "day|HH:MM|med|how|HH:MM|amount" lines; the last LOG-KEEP kept
(define (log-add! day time med how amount)
  (let* ((lines (med-read LOG-PATH))
         (all (append lines (list (web-join (list (number->string day) time (number->string med) how
                                                  (if (string=? app-time "--:--") "" app-time) (number->string amount))
                                            "|"))))
         (n (length all)))
    (med-write LOG-PATH (if (> n LOG-KEEP) (list-tail all (- n LOG-KEEP)) all))))

;; The medicines logged for day and time (taken, timed out or skipped)
(define (log-meds day time)
  (let ((prefix (string-append (number->string day) "|" time "|")))
    (map (lambda (l) (med-int (list-ref (str-split l #\|) 2) -1))
         (filter (lambda (l) (str-starts? l prefix)) (med-read LOG-PATH)))))

;; 6. The reminder -----------------------------------------------------------------------

(define (med-reminding?) (not (string=? med-due-at "")))

(define (med-led on) (if (defined? 'led-set) (if on (led-set 255 96 0) (led-set 0 0 0))))

;; ((med . amount) ...) of time point at due on day d and not logged yet
(define (med-due-for at d)
  (let ((s (slot-at at)) (done (if d (log-meds d at) '())))
    (if (not s)
        '()
        (filter (lambda (x) x)
                (map (lambda (e)
                       (let ((m (med-find (ent-med e))))
                         (and m (med-active? m d) (ent-day? e d) (not (memv (med-id m) done)) (cons m (ent-amount e)))))
                     (slot-entries s))))))

(define (pending-save!)
  (fs-write PENDING-PATH (string-append (number->string med-due-day) "|" med-due-at "|" (number->string med-due-start))))

(define (pending-clear!) (if (fs-exists? PENDING-PATH) (fs-remove PENDING-PATH)))

;; The reminder of time point at on day d (a new one, or one a restart cut short)
(define (med-remind! at d start)
  (let* ((day (or d 0))
         (ids (map (lambda (x) (med-id (car x))) med-due))
         (more (filter (lambda (x) (not (memv (med-id (car x)) ids))) (med-due-for at d))))
    (if (null? med-due)
        ;; already confirmed at this time point (a reminder a restart cut short) count as done
        (let* ((s (slot-at at))
               (sids (if s (map ent-med (slot-entries s)) '()))
               (done (if d (length (filter (lambda (id) (memv id sids)) (log-meds d at))) 0)))
          (set! med-due-done (if (null? more) 0 done))
          (set! med-due-total med-due-done)))
    (set! med-due (append med-due more))
    (set! med-due-total (+ med-due-total (length more)))
    (set! med-due-at at)
    (set! med-due-day day)
    (set! med-due-start (or start (med-now-minutes) 0))
    (set! med-done-left 0)
    (set! med-blink #t)
    (if (null? med-due)
        (med-finish!)                                  ; nothing to take now
        (begin (pending-save!) (med-led #t) (app-invalidate-all)))))

;; Takes one dose (med . amount): logged, the amount off a count plan
(define (med-take! x how)
  (let ((m (med-find (med-id (car x)))))
    (log-add! med-due-day med-due-at (med-id (car x)) how (cdr x))
    (if (and m (string=? (med-plan m) "count") (not (string=? how "skip")))
        (begin (vector-set! m 6 (max 0 (- (med-units m) (cdr x))))
               (med-save!)))))

;; Back to the app that ran before; when this app is that one, its normal screen
(define (med-finish!)
  (set! med-due '())
  (set! med-due-at "")
  (set! med-due-total 0)
  (set! med-due-done 0)
  (set! med-done-left 0)
  (pending-clear!)
  (med-led #f)
  (if (not (app-return))
      (begin (set! med-left MED-SHOW-SECONDS) (app-invalidate-all))))

(define (med-confirm!)
  (if (pair? med-due)
      (begin
        (med-take! (car med-due) "ok")
        (set! med-due (cdr med-due))
        (set! med-due-done (+ med-due-done 1))
        (if (null? med-due) (begin (set! med-done-left MED-DONE-SECONDS) (med-led #f) (pending-clear!)))
        (app-invalidate-all))))

;; Every medicine left, logged as how ("auto": the time limit, "skip": ended on the web page)
(define (med-close-all! how)
  (for-each (lambda (x) (med-take! x how)) med-due)
  (med-finish!))

;; Past the time limit: the rest count as taken
(define (med-check-limit!)
  (let ((now (med-now-minutes)))
    (if (and (> med-max-minutes 0) now (pair? med-due) (>= (- now med-due-start) med-max-minutes))
        (med-close-all! "auto"))))

(define (med-shown) (filter (lambda (m) (med-active? m (med-today))) med-list))

(define (med-next! step)
  (let ((n (length (med-shown))))
    (if (> n 0) (set! med-index (modulo (+ med-index step) n)))
    (set! med-left MED-SHOW-SECONDS)
    (app-invalidate-all)))

;; 7. Screen -----------------------------------------------------------------------------

(define (med-photo-info m)
  (let ((hit (assv (med-id m) med-info-cache)))
    (if hit
        (cdr hit)
        (let ((info (image-info (med-photo-path m))))
          (set! med-info-cache (cons (cons (med-id m) info) med-info-cache))
          info))))

;; The photo under the title bar, centered across, cut at bottom
(define (med-render-photo m bottom)
  (let ((info (med-photo-info m)))
    (if info (gui-image (quotient (- (scr-w) (car info)) 2) MED-PHOTO-TOP (med-photo-path m)))
    (gui-rect 0 bottom (scr-w) (- (gui-height) bottom) theme-bg #t)))

;; Without a photo the name and the amount are one size larger
(define (med-size m key) (+ (med-scale key) (if (med-photo-info m) 0 1)))

;; Where the text block (block px high) goes between the photo and bottom:
;; (cut . y), the photo cut at cut, the block at y, centered in the space
;; under the photo, or pushed up into the photo when the space is short
(define (med-layout m block bottom)
  (let* ((info (med-photo-info m))
         (photo-end (+ MED-PHOTO-TOP (if info (cadr info) 0)))
         (space (- bottom photo-end)))
    (if (>= space (+ block 16))
        (cons photo-end (+ photo-end (quotient (- space block) 2)))
        (cons (- bottom block 16) (- bottom block 8)))))

;; The largest multiple up to s at which text (1 px wider: bold) fits the width
(define (med-fit-scale s text)
  (if (or (<= s 1) (<= (+ 1 (* s (txt-w text))) (- (scr-w) 16))) (max s 1) (med-fit-scale (- s 1) text)))

;; Bold text at x, y, k times the font's size: drawn twice, 1 px apart
(define (med-bold-at x y text color k)
  (if (> k 1)
      (begin (gui-text-scaled x y text color k F-TEXT)
             (gui-text-scaled (+ x 1) y text color k F-TEXT))
      (begin (txt x y text color) (txt (+ x 1) y text color))))

;; The amount, then the dose drawn as that many shapes of the medicine's
;; kind (a half one for .5), at most 5, tilted: their boxes overlap, the
;; shapes do not
(define MED-PILL-MAX 5)
(define MED-SHAPES '("auto" "capsule" "tablet" "ball" "oval" "sachet" "none"))
(define MED-COLORS '(("white" 235 235 228) ("yellow" 240 200 60) ("orange" 240 140 50) ("red" 215 60 60)
                     ("pink" 240 150 180) ("blue" 80 140 230) ("green" 90 190 110) ("brown" 165 110 70)))

(define (med-rgb name)
  (let ((c (assoc name MED-COLORS))) (if c (gui-rgb (cadr c) (caddr c) (cadddr c)) (gui-rgb 235 235 228))))

;; The shape drawn: the medicine's, or one from its unit ("auto")
(define (med-shape-of m)
  (let ((sh (med-shape m)) (u (med-unit m)))
    (if (not (string=? sh "auto"))
        sh
        (cond ((member u '("粒")) "capsule")
              ((member u '("片")) "tablet")
              ((member u '("颗" "丸")) "ball")
              ((member u '("袋" "包")) "sachet")
              (else "none")))))

(define (med-isqrt n) (if (<= n 0) 0 (inexact->exact (floor (sqrt (exact->inexact n))))))

;; The left half of a disk (a broken tablet)
(define (med-half-disk cx cy r color)
  (let loop ((dy (- r)))
    (if (<= dy r)
        (let ((dx (med-isqrt (- (* r r) (* dy dy)))))
          (gui-rect (- cx dx) (+ cy dy) (+ dx 1) 1 color #t)
          (loop (+ dy 1))))))

;; An oval tablet along the rising diagonal, semi-axes a and b; half: its lower-left half
(define (med-oval cx cy a b color half)
  (let* ((fa (exact->inexact a)) (fb (exact->inexact b))
         (qa (/ 1.0 (* 2.0 fa fa))) (qb (/ 1.0 (* 2.0 fb fb)))
         (aa (+ qa qb)))
    (let loop ((dy (- a)))
      (if (<= dy a)
          (let* ((y (exact->inexact dy))
                 (bb (* 2.0 y (- qb qa)))
                 (cc (- (* aa y y) 1.0))
                 (disc (- (* bb bb) (* 4.0 aa cc))))
            (if (>= disc 0.0)
                (let* ((r (sqrt disc))
                       (lo (/ (- (- bb) r) (* 2.0 aa)))
                       (hi (/ (+ (- bb) r) (* 2.0 aa)))
                       (hi (if half (min hi y) hi))
                       (x0 (inexact->exact (round lo)))
                       (x1 (inexact->exact (round hi))))
                  (if (>= x1 x0) (gui-rect (+ cx x0) (+ cy dy) (+ 1 (- x1 x0)) 1 color #t))))
            (loop (+ dy 1)))))))

;; One dose shape in the box x y (s x s)
(define (med-pill shape x y s color half)
  (let* ((cx (+ x (quotient s 2))) (cy (+ y (quotient s 2)))
         (light (gui-rgb 235 235 228)) (shade (gui-rgb 120 120 120)))
    (cond
      ((string=? shape "capsule")              ; two halves along the rising diagonal
       (let* ((r (max 2 (quotient s 6)))
              (e (quotient (* (- s (* 2 r)) 4) 10))
              (steps (max 2 e))
              (other (if (= color light) (gui-rgb 190 190 185) light)))
         (let loop ((i 0))
           (if (<= i (if half steps (* 2 steps)))
               (let ((px (+ (- cx e) (quotient (* i e) steps)))
                     (py (- (+ cy e) (quotient (* i e) steps))))
                 (gui-circle px py r (if (<= i steps) color other) #t)
                 (loop (+ i 2)))))))
      ((string=? shape "tablet")               ; a round tablet with its score line
       (let ((r (quotient (* s 3) 10)) (d (quotient (* s 2) 10)))
         (if half
             (med-half-disk cx cy r color)
             (begin (gui-circle cx cy r color #t)
                    (gui-line (- cx d) (+ cy d) (+ cx d) (- cy d) shade)))))
      ((string=? shape "ball")                 ; a ball with a highlight
       (let ((r (quotient (* s 3) 10)))
         (if half (med-half-disk cx cy r color) (gui-circle cx cy r color #t))
         (gui-circle (- cx (quotient r 3)) (- cy (quotient r 3)) (max 1 (quotient r 4)) light #t)))
      ((string=? shape "oval")                 ; an oval tablet along the diagonal
       (med-oval cx cy (quotient (* s 45) 100) (quotient (* s 2) 10) color half))
      ((string=? shape "sachet")               ; a sachet, crimped at both ends
       (let* ((w (quotient (* s 55) 100)) (h (quotient (* s 8) 10)) (h (if half (quotient h 2) h))
              (x0 (- cx (quotient w 2))) (y0 (- (+ cy (quotient (* s 4) 10)) h)) (c (max 2 (quotient h 8))))
         (gui-rect x0 y0 w h color #t)
         (gui-rect x0 y0 w c shade #t)
         (gui-rect x0 (- (+ y0 h) c) w c shade #t)))
      (else #f))))

(define (med-amount-line y m a color k)
  (let* ((text (string-append (amt-text a) " " (med-unit m)))
         (k (med-fit-scale k text))
         (tw (+ 1 (* k (txt-w text))))
         (shape (med-shape-of m))
         (whole (quotient a 10))
         (half (>= (remainder a 10) 5))
         (n (+ whole (if half 1 0)))
         (avail (- (scr-w) 16 tw 12))
         (want (* 16 k))                                   ; a box as tall as the text
         (span (lambda (sz) (+ sz (quotient (* (- n 1) sz 62) 100))))
         (s (if (and (not (string=? shape "none")) (> n 0) (<= a (* 10 MED-PILL-MAX)))
                (if (<= (span want) avail) want (quotient (* avail 100) (+ 100 (* (- n 1) 62))))
                0))
         (pills (>= s 12))
         (step (quotient (* s 62) 100))
         (total (if pills (+ tw 12 (span s)) tw))
         (x0 (quotient (- (scr-w) total) 2)))
    (med-bold-at x0 y text color k)
    (if pills
        (let loop ((i 0) (x (+ x0 tw 12)))
          (if (< i n)
              (begin (med-pill shape x (+ y (quotient (- (* 16 k) s) 2)) s (med-rgb (med-color m)) (and half (= i (- n 1))))
                     (loop (+ i 1) (+ x step))))))))

;; Bold text centered at y, k times the font's size: drawn twice, 1 px apart
(define (med-bold y text color k)
  (let ((x (quotient (- (scr-w) (* k (txt-w text)) 1) 2)))
    (cond ((> k 1)
           (gui-text-scaled x y text color k F-TEXT)
           (gui-text-scaled (+ x 1) y text color k F-TEXT))
          ((<= (txt-w text) (- (scr-w) 16))
           (txt x y text color)
           (txt (+ x 1) y text color))
          (else (txt-fit 8 y (- (scr-w) 16) text color)))))

(define (med-header title right bg fg)
  (med-header-colors title right bg fg fg))

;; The title on the left, the clock right-aligned (as every app's header)
(define (med-header-colors title right bg fg right-fg)
  (gui-rect 0 0 (scr-w) HDR-H bg #t)
  (txt-fit 8 8 (- (scr-w) 24 (txt-w right)) title fg)
  (txt-right (- (scr-w) 8) 8 right right-fg))


;; "【已服1/共4种  服药时间08:00】"
(define (med-reminder-title)
  (string-append "【已服" (number->string med-due-done) "/共" (number->string med-due-total) "种  服药时间" med-due-at "】"))

;; 1..99 in Chinese numerals: 一, 十二, 二十
(define (cn-num n)
  (let ((d (vector "零" "一" "二" "三" "四" "五" "六" "七" "八" "九")))
    (cond ((< n 10) (vector-ref d n))
          ((< n 20) (string-append "十" (if (= n 10) "" (vector-ref d (- n 10)))))
          ((< n 100) (string-append (vector-ref d (quotient n 10)) "十"
                                    (if (= (remainder n 10) 0) "" (vector-ref d (remainder n 10)))))
          (else (number->string n)))))

;; A count: 两 for 2 ("共两个药"), else as cn-num
(define (cn-count n) (if (= n 2) "两" (cn-num n)))

;; The next time point of all, "08:00" (the first one tomorrow after the last), #f
(define (med-next-time)
  (if (or (null? slot-list) (string=? app-time "--:--"))
      #f
      (let loop ((l (map slot-time slot-list)) (best #f) (first #f))
        (if (null? l)
            (or best first)
            (let ((t (car l)))
              (loop (cdr l)
                    (if (and (string<? app-time t) (or (not best) (string<? t best))) t best)
                    (if (or (not first) (string<? t first)) t first)))))))

;; A medicine's next dose and what is left, in small text on the line ending at bottom
(define MED-INFO-H 22)
(define (med-info-line m bottom)
  (let ((y (- bottom MED-INFO-H)) (right (med-plan-text m (med-today))))
    (txt-right (- (scr-w) 10) (+ y 2) right theme-text-sub)
    (txt-fit 10 (+ y 2) (- (scr-w) 30 (txt-w right)) (next-text (med-next-dose m)) theme-text-sub)))

;; The bottom bar: left and right texts
(define (med-footer left right)
  (let ((y (- (gui-height) FTR-H)))
    (gui-rect 0 y (scr-w) FTR-H theme-card-hdr #t)
    (txt-right (- (scr-w) 8) (+ y 3) right theme-text-sub)
    (txt-fit 8 (+ y 3) (- (scr-w) 24 (txt-w right)) left theme-text-main)))

(define (next-text nd)
  (if nd
      (string-append "下次: " (cond ((= (car nd) 1) "明天 ") ((= (car nd) 2) "后天 ") (else "")) (cadr nd))
      "下次: 未安排"))

(define (med-render-empty)
  (let ((cx (quotient (scr-w) 2)))
    (txt-center cx 180 (if (null? med-list) "还没有药品" "没有正在服用的药品") theme-text-main)
    (txt-center cx 212 "在设备网页的应用标签里设置" theme-text-muted)
    (txt-center cx 236 "药品和服药时间" theme-text-muted)
    (if (wifi-connected?) (txt-center cx 272 (string-append "http://" (wifi-ip) "/") theme-accent))))

(define (med-render-normal)
  (let* ((shown (med-shown)) (n (length shown)) (d (med-today)))
    (if (>= med-index (max 1 n)) (set! med-index 0))
    (med-header (if (> n 1) (string-append "吃药提醒  " (number->string (+ med-index 1)) "/" (number->string n)) "吃药提醒")
                app-time theme-card-hdr theme-text-main)
    (if (= n 0)
        (med-render-empty)
        (let* ((m (list-ref shown med-index))
               (nd (med-next-dose m))
               (amount (if nd (string-append (amt-text (caddr nd)) " " (med-unit m)) ""))
               (k (med-size m "list_size"))
               (kn (med-fit-scale k (med-name m)))
               (ka (med-fit-scale k amount))
               (block (+ (* 16 kn) (if nd (+ 8 (* 16 ka)) 0)))
               (place (med-layout m block (- (gui-height) FTR-H MED-INFO-H)))
               (name-y (cdr place))
               (amount-y (+ name-y (* 16 kn) 8)))
          (med-render-photo m (car place))
          (med-bold name-y (med-name m) theme-text-main kn)
          (if nd (med-amount-line amount-y m (caddr nd) theme-accent ka))
          (med-info-line m (- (gui-height) FTR-H))))
    (let ((next (med-next-time)))
      (med-footer (cond ((null? slot-list) "未设置服药时间") (next (string-append "下次提醒 " next)) (else ""))
                  (if (wifi-connected?) (string-append "网页 " (wifi-ip)) "")))))

(define (med-render-reminder)
  (let* ((cx (quotient (scr-w) 2))
         (x (car med-due))
         (m (car x))
         (amount (string-append (amt-text (cdr x)) " " (med-unit m)))
         (kn (med-fit-scale (med-size m "name_size") (med-name m)))
         (kq (med-fit-scale (med-size m "amount_size") amount))
         (confirm "服药后按背部按钮确认")
         (kb (let fit ((k kq)) (if (or (<= k 1) (<= (* k (txt-w confirm)) (scr-w))) (max k 1) (fit (- k 1)))))   ; as the amount, the width at most
         (bar-h (+ (* 16 kb) 12))
         (bar-y (- (gui-height) bar-h))
         (place (med-layout m (+ (* 16 kn) 10 (* 16 kq)) (- bar-y MED-INFO-H)))
         (name-y (cdr place))
         (amount-y (+ name-y (* 16 kn) 10)))
    (med-header-colors (med-reminder-title) app-time
                       (if med-blink theme-warning theme-card-hdr)
                       (if med-blink theme-bg theme-warning)
                       (if med-blink theme-bg theme-text-main))   ; white, dark on the yellow (white would not show)
    (med-render-photo m (car place))
    (med-bold name-y (med-name m) theme-text-main kn)
    (med-amount-line amount-y m (cdr x) theme-accent kq)
    (med-info-line m bar-y)
    (gui-rect 0 bar-y (scr-w) bar-h theme-accent-dark #t)
    (med-bold-at (max 0 (quotient (- (scr-w) (* kb (txt-w confirm))) 2)) (+ bar-y 6) confirm theme-text-main kb)))

(define (med-render-done)
  (let ((cx (quotient (scr-w) 2)))
    (med-header (med-reminder-title) app-time theme-card-hdr theme-text-main)
    (med-bold 200 "已全部服用" theme-success 2)
    (txt-center cx 256 "即将回到原来的应用" theme-text-muted)))

(define (med-render-waiting)
  (let ((cx (quotient (scr-w) 2)))
    (med-header "吃药时间" med-pending-at theme-warning theme-bg)
    (txt-center cx 220 "正在读取日期..." theme-text-muted)))

(define (med-render)
  (gui-clear theme-bg)
  (cond ((pair? med-due) (med-render-reminder))
        ((med-reminding?) (med-render-done))
        (med-pending-at (med-render-waiting))
        (else (med-render-normal)))
  (gui-flush))

;; 8. Button, time, the scheduled start --------------------------------------------------

(define (app-button)
  (cond ((pair? med-due) (med-confirm!))
        ((med-reminding?) (med-finish!))
        (med-pending-at #t)
        (else (med-next! 1))))

(define (app-touch x y) (app-button))

;; The system: one of the times came while this app runs
(define (app-schedule at) (med-start! at))

;; Day counting needs the date: a start waits for the first clock tick. A
;; reminder a restart cut short (pending.txt) goes on with its own day and start.
(define (med-start! at)
  (if (or (time-local) (>= med-pending-secs MED-WAIT-SECONDS))
      (let* ((p (med-read PENDING-PATH))
             (f (if (pair? p) (str-split (car p) #\|) '()))
             (same (and (= (length f) 3) (string=? (cadr f) at))))
        (set! med-pending-at #f)
        (if same
            (med-remind! at (med-int (car f) 0) (med-int (caddr f) #f))
            (med-remind! at (med-today) #f)))
      (begin (set! med-pending-at at) (app-invalidate-all))))

;; At the start: a reminder a power cut interrupted while this app was the
;; boot app (no scheduled launch then) goes on
(define (med-resume!)
  (let* ((p (med-read PENDING-PATH)) (f (if (pair? p) (str-split (car p) #\|) '())))
    (if (= (length f) 3) (med-start! (cadr f)))))

(set! app-tick-proc
      (lambda (tick)
        (cond (med-pending-at
               (set! med-pending-secs (+ med-pending-secs 1))
               (med-start! med-pending-at))
              ((pair? med-due)
               (if (= (remainder tick 10) 0) (med-check-limit!)))
              ((med-reminding?)
               (set! med-done-left (- med-done-left 1))
               (if (<= med-done-left 0) (med-finish!)))
              (else
               (if (and (> (length (med-shown)) 1) (not (info-active?)))
                   (begin (set! med-left (- med-left 1))
                          (if (<= med-left 0) (med-next! 1))))
               (if (= (remainder tick 30) 0) (gui-invalidate 0 (- (gui-height) FTR-H) (scr-w) FTR-H))))))

;; The reminder's title bar blinks twice a second (the LED with it), from the app loop
(define med-applib-step app-step)
(define med-blink-at 0)
(define (app-step)
  (med-applib-step)
  (if (pair? med-due)
      (let ((now (time-ms)))
        (if (>= (- now med-blink-at) 500)
            (begin (set! med-blink-at now)
                   (set! med-blink (not med-blink))
                   (med-led med-blink)
                   (gui-invalidate 0 0 (scr-w) HDR-H))))))

;; 9. The web page's calls (app-web name body) -------------------------------------------

(define (med->alist m d)
  (let ((nd (med-next-dose m)))
    (list (cons 'id (med-id m)) (cons 'name (med-name m)) (cons 'unit (med-unit m))
          (cons 'plan (med-plan m)) (cons 'n (med-n m)) (cons 'start (med-start m)) (cons 'left (med-units m))
          (cons 'status (symbol->string (med-status m d))) (cons 'text (med-plan-text m d))
          (cons 'next (if nd (string-append (next-text nd) " · " (amt-text (caddr nd)) " " (med-unit m)) ""))
          (cons 'shape (med-shape m)) (cons 'drawn (med-shape-of m)) (cons 'color (med-color m))
          (cons 'photo (if (med-photo-info m) #t #f)))))

(define (slot->alist s d)
  (let ((done (if d (log-meds d (slot-time s)) '())))
    (list (cons 'id (slot-id s)) (cons 'time (slot-time s))
          (cons 'entries (map (lambda (e)
                                (list (cons 'med (ent-med e)) (cons 'alt (ent-alt? e)) (cons 'ref (ent-ref e))
                                      (cons 'amount (ent-amount e))
                                      (cons 'today (ent-day? e d)) (cons 'done (if (memv (ent-med e) done) #t #f))))
                              (slot-entries s))))))

(define (med-answer . extra)
  (let ((d (med-today)))
    (apply web-ok (append (list (cons 'today (or d 0)) (cons 'time app-time)
                                (cons 'meds (map (lambda (m) (med->alist m d)) med-list))
                                (cons 'slots (map (lambda (s) (slot->alist s d)) (slots-sorted)))
                                (cons 'max MED-MAX) (cons 'maxslots SLOT-MAX)
                                (cons 'reminding (med-reminding?)) (cons 'at med-due-at)
                                (cons 'settings (cons (cons 'max_minutes med-max-minutes)
                                                      (map (lambda (p) (cons (string->symbol (car p)) (cdr p))) med-scales))))
                          extra))))

(define (med-next-id)
  (+ 1 (let loop ((l med-list) (hi 0)) (if (null? l) hi (loop (cdr l) (max hi (med-id (car l))))))))

;; The medicine of body (id 0: a new one); its id, or a message. n and left
;; of a count plan are tenths.
(define (med-save-from! body)
  (let* ((id (web-field-int body "id" 0))
         (old (and (> id 0) (med-find id)))
         (name (med-clean (or (web-field body "name") "") MED-NAME-MAX))
         (unit (med-clean (or (web-field body "unit") "") MED-UNIT-MAX))
         (plan (or (web-field body "plan") "long"))
         (n (med-int (web-field body "n") 0))
         (start (med-int (web-field body "start") (or (med-today) 0)))
         (left (web-field body "left"))
         (shape (or (web-field body "shape") (if old (med-shape old) "auto")))
         (color (or (web-field body "color") (if old (med-color old) "white"))))
    (cond ((str-empty? name) "药品名称不能为空")
          ((not (member shape MED-SHAPES)) "shape: auto, capsule, tablet, ball, oval, sachet or none")
          ((not (assoc color MED-COLORS)) "color: white, yellow, orange, red, pink, blue, green or brown")
          ((not (member plan '("long" "days" "count"))) "plan: long, days or count")
          ((and (string=? plan "days") (or (< n 1) (> n 3650))) "服用天数应为 1..3650")
          ((and (string=? plan "count") (or (< n 1) (> n 1000000))) "总数量应为 0.1..100000")
          ((and (> id 0) (not old)) "没有这个药品")
          ((and (not old) (>= (length med-list) MED-MAX)) "最多 20 个药品")
          (else
           ;; left: given, else kept while the plan is the same, else full
           (let* ((units (cond ((and (string? left) (string=? plan "count")) (clamp (med-int left n) 0 1000000))
                               ((and old (string=? (med-plan old) plan) (= (med-n old) n)) (med-units old))
                               (else n)))
                  (m (vector (if old id (med-next-id)) name (if (str-empty? unit) "粒" unit) plan n start units shape color)))
             (set! med-list (if old (map (lambda (x) (if (eq? x old) m x)) med-list) (append med-list (list m))))
             (med-save!)
             (med-id m))))))

(define (every-med? entries)
  (let loop ((l entries)) (cond ((null? l) #t) ((and (car l) (med-find (ent-med (car l)))) (loop (cdr l))) (else #f))))

;; slots=08:00=1.0.0.20,2.1.20380.5|12:30=...: every time point at once
;; (med.alt.ref.amount, the amount in tenths); #t or a message
(define (slots-save-from! body)
  (let* ((text (or (web-field body "slots") ""))
         (parts (filter (lambda (p) (> (string-length p) 0)) (str-split text #\|)))
         (parsed (map (lambda (p)
                        (let ((kv (str-split p #\=)))
                          (and (med-hm (car kv))
                               (cons (med-hm (car kv))
                                     (if (and (= (length kv) 2) (> (string-length (cadr kv)) 0))
                                         (map ent-parse (str-split (cadr kv) #\,))
                                         '())))))
                      parts)))
    (cond ((memv #f parsed) "时间格式应为 HH:MM")
          ((> (length parsed) SLOT-MAX) "最多 6 个时间点")
          ((let dup ((l (map car parsed))) (and (pair? l) (or (member (car l) (cdr l)) (dup (cdr l))))) "时间点重复")
          ((let bad ((l parsed)) (and (pair? l) (or (not (every-med? (cdar l))) (bad (cdr l))))) "药品不存在")
          (else
           (set! slot-list
                 (let loop ((l parsed) (k 1) (acc '()))
                   (if (null? l) (reverse acc) (loop (cdr l) (+ k 1) (cons (vector k (caar l) (cdar l)) acc)))))
           (slots-save!)
           #t))))

;; Saves the settings body has; #t, or the first key with a bad value
(define (med-save-settings! body)
  (let loop ((ks (cons '("max_minutes" "0" 1440) MED-SCALE-KEYS)))
    (if (null? ks)
        (begin (med-load-settings!) (app-invalidate-all) #t)
        (let* ((k (car ks)) (v (web-field body (car k))) (n (and v (string->number v)))
               (lo (if (string=? (car k) "max_minutes") 0 1)))
          (cond ((not v) (loop (cdr ks)))
                ((and (integer? n) (>= n lo) (<= n (caddr k))) (app-config-set! (car k) v) (loop (cdr ks)))
                (else (car k)))))))

;; The last 60 lines of the log, newest first
(define (log-answer)
  (let* ((lines (med-read LOG-PATH)) (n (length lines)) (last (if (> n 60) (list-tail lines (- n 60)) lines)))
    (web-ok (cons 'log (reverse
                        (filter (lambda (x) x)
                                (map (lambda (l)
                                       (let ((f (str-split l #\|)))
                                         (and (>= (length f) 4)
                                              (let ((m (med-find (med-int (list-ref f 2) -1)))
                                                    (amt (if (>= (length f) 6) (med-int (list-ref f 5) 0) 0)))
                                                (list (cons 'day (med-int (car f) 0)) (cons 'time (cadr f))
                                                      (cons 'med (med-int (list-ref f 2) -1))
                                                      (cons 'name (if m (med-name m) "（已删除）"))
                                                      (cons 'amount (if (and m (> amt 0)) (string-append (amt-text amt) " " (med-unit m)) ""))
                                                      (cons 'how (list-ref f 3))
                                                      (cons 'at (if (>= (length f) 5) (list-ref f 4) "")))))))
                                     last)))))))

(define (app-web name body)
  (cond
    ((string=? name "list") (med-load!) (med-load-settings!) (app-invalidate-all) (med-answer))
    ((string=? name "save")
     (let ((r (med-save-from! body))) (if (string? r) (web-error r) (med-answer (cons 'id r)))))
    ((string=? name "delete")
     (let ((m (med-find (web-field-int body "id" -1))))
       (if (not m)
           (web-error "没有这个药品")
           (begin (set! med-list (filter (lambda (x) (not (eq? x m))) med-list))
                  (set! slot-list (map (lambda (s) (vector (slot-id s) (slot-time s)
                                                           (filter (lambda (e) (not (= (ent-med e) (med-id m)))) (slot-entries s))))
                                       slot-list))
                  (med-save!)
                  (slots-save!)
                  (med-answer)))))
    ((string=? name "slots")
     (let ((r (slots-save-from! body))) (if (string? r) (web-error r) (med-answer))))
    ((string=? name "settings")
     (let ((r (med-save-settings! body))) (if (string? r) (web-error (string-append "bad value for " r)) (med-answer))))
    ((string=? name "log") (log-answer))
    ((string=? name "remind")                       ; the page's test: a time point's reminder now
     (let ((s (slot-at (or (med-hm (or (web-field body "time") "")) ""))))
       (if (not s)
           (web-error "没有这个时间点")
           (begin (med-remind! (slot-time s) (med-today) #f) (med-answer)))))
    ((string=? name "stop") (if (pair? med-due) (med-close-all! "skip") (if (med-reminding?) (med-finish!))) (med-answer))
    (else (web-error (string-append "unknown call: " name)))))

;; 10. Start ----------------------------------------------------------------------------

(med-migrate!)
(med-load!)
(med-load-settings!)
(app-define! "吃药提醒" (list (app-local-page "药品" (lambda (items) #t))))
(set! gui-render-proc med-render)
(let ((at (app-scheduled))) (if at (med-start! at) (med-resume!)))
(app-invalidate-all)

