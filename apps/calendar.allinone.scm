;;; =========================================================================
;;; MiniScheme Standalone Application: calendar
;;; All-in-One Standalone Scheme Source (Libraries Included for WebREPL)
;;; =========================================================================
;;; [app]
;;; pages = 3
;;; page_ids = today, month, moon ; English page names: <app>.<id> in a combined app (front: the first)
;;; id = calendar
;;; name = 万年历
;;; description = 时间、世界时间、日期、农历、节气、宜忌和倒计日；当月日历（含农历）；月相与太阳、月亮的方位和高度
;;; version = 5
;;; api = 1.0 ; the device API it needs (docs/api): runs on firmware API 1.x, x >= 0
;;; 
;;; [fields]
;;; ; how the settings page shows each [config] key: type | label | help
;;; ; types: text, number:min-max, bool, select:value=label,value=label
;;; ; (no ASCII ; or # in these lines: they start a comment)
;;; countdown = text | 倒计日 | 名称=日期，多个用逗号分开，如 春节=L01-01, 生日=12-01, 考试=2027-06-07。年-月-日 只算一次，月-日 每年重复，L 开头为农历
;;; world_clock = text | 世界时间 | 首页时钟下面显示的各地时间，最多 4 个，用逗号分开。可以写时区缩写（PST、NZST、JST、CST 为美国中部）、地名（美西、美东、新西兰、东京、伦敦、北京）、名称=时区（如 美西=PST、孟买=Asia/Kolkata）或 UTC+8。留空不显示
;;; location = text | 位置 | 月相页的观测地点：auto 表示按公网 IP 定位，也可以填城市名（深圳）或 经度,纬度
;;; carousel = bool | 自动翻页 | 打开后按下面的时长依次显示各页
;;; carousel_seconds = text | 每页秒数 | 一个值，或每页一个，如 15,10,10（后面的页沿用最后一个值）
;;; 
;;; [config]
;;; countdown = 春节=L01-01 ; name=date, comma separated: YYYY-MM-DD once, MM-DD yearly, L before MM-DD: lunar
;;; world_clock = 美西=PST, 新西兰=NZST ; up to 4: an abbreviation, a place, name=zone (IANA or abbreviation) or UTC+8
;;; location = auto ; auto (city of the public IP), a city name (深圳) or lon,lat
;;; carousel = ; empty: config.ini [app] carousel (1: turn the pages by themselves, 0: manual)
;;; carousel_seconds = ; empty: config.ini [app] carousel_seconds (seconds per page, or one per page)
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
;;; Section: apps/calendar/calendar.scm
;;; =========================================================================
;;; =========================================================================
;;; Calendar (万年历), 320x480 portrait, on the app framework (applib.scm).
;;; Data: the app proxy's /app/calendar (lunar_python's almanac and the
;;; sky computed on the PC):
;;;   1 today: countdowns on top, the time, world clocks, the date, the
;;;     lunar date, the solar term, festivals, 宜 and 忌
;;;   2 the month: every day with its lunar day (or term, festival, month)
;;;   3 the sky: the moon's phase, the sun's and the moon's bearing and height
;;; =========================================================================

;; 1. Settings (apps/calendar.ini, defaults in apps/calendar/meta.ini) ----------

(define (cal-today-url)
  (app-url (string-append "/app/calendar?view=today&cd=" (url-encode (app-config "countdown" ""))
                          "&wc=" (url-encode (app-config "world_clock" "")))))

(define (cal-month-url) (app-url "/app/calendar?view=month"))

(define (cal-sky-url)
  (app-url (string-append "/app/calendar?view=sky&loc=" (url-encode (app-config "location" "auto")))))

;; Day numbers in the month: simhei-24 from the font ROM when there, else the text font
(define cal-day-font (if (use-font 3 "simhei" 24 'system) 3 F-TEXT))

(define cal-moon-lit 61175)              ; #e8dfb8: the lit moon
(define cal-moon-dark 8583)              ; #26303c: its dark side

;; 2. Today -------------------------------------------------------------------------

(define cal-clock-y 0)                   ; where the clock is drawn (redrawn every second)
(define cal-clock-h 82)                  ; the height of its row
(define cal-lunar-y 0)                   ; the lunar line with the 时辰 and 刻 (redrawn when they change)
(define cal-shike-seen "")

;; The traditional time of day from the device's clock: the 时辰 (子 from
;; 23:00, two hours each) and the quarter hours (刻) gone in it: 巳时初刻 at
;; 9:00, 巳时六刻 at 10:30; "" before the clock is set
(define CAL-SHICHEN '("子" "丑" "寅" "卯" "辰" "巳" "午" "未" "申" "酉" "戌" "亥"))
(define CAL-KE '("初" "一" "二" "三" "四" "五" "六" "七"))

(define (cal-shike)
  (let ((h (and (>= (string-length app-time) 5) (string->number (substring app-time 0 2))))
        (m (and (>= (string-length app-time) 5) (string->number (substring app-time 3 5)))))
    (if (and h m)
        (let ((since (modulo (+ (* h 60) m 60) 1440)))   ; minutes since 23:00
          (string-append (list-ref CAL-SHICHEN (quotient since 120)) "时"
                         (list-ref CAL-KE (quotient (remainder since 120) 15)) "刻"))
        "")))

;; Page 1's title: the date, and the weekday at a fixed place after it (the
;; width of the longest date), so it does not move as the date gets longer.
;; The year from the proxy's date; the month, day and weekday from the
;; device's clock (right at midnight before the page is fetched again).
(define (cal-header items x w)
  (let* ((d (and (pair? items) (items-find items "cdate")))
         (iso (and d (it-c d)))
         (year (and iso (>= (string-length iso) 4) (substring iso 0 4)))
         (date (cond ((str-empty? app-date) "")
                     (year (string-append year "年" app-date))
                     (else app-date)))
         (week (if (str-starts? app-week "周")
                   (string-append "星期" (substring app-week (string-length "周") (string-length app-week)))
                   app-week))
         (wx (+ x (txt-w "0000年00月00日") 12)))
    (txt-fit x 8 (- wx x 4) date theme-text-main)
    (if (<= (+ wx (txt-w week)) (+ x w))
        (txt wx 8 week theme-text-main))))
(define cal-world-y 0)                   ; where the world clocks are (redrawn every minute), 0: none
(define cal-world-hm "")                 ; the minute they show
(define cal-world-h 0)                   ; the height of their row (it takes the page's spare room)

;; "距 春节 还有 119 天" (or "今天是 春节"), centred, the name and the number in color
(define (cal-countdown y cd)
  (let* ((days (it-b cd)) (name (it-a cd))
         (parts (if (string=? days "0")
                    (list (list "今天是 " theme-text-muted) (list name theme-accent))
                    (list (list "距 " theme-text-muted) (list name theme-accent) (list " 还有 " theme-text-muted)
                          (list days theme-warning) (list " 天" theme-text-muted))))
         (width (fold-left + 0 (map (lambda (p) (txt-w (car p))) parts))))
    (let loop ((ps parts) (x (quotient (- (scr-w) width) 2)))
      (if (pair? ps)
          (begin
            (txt x y (car (car ps)) (cadr (car ps)))
            (loop (cdr ps) (+ x (txt-w (car (car ps))))))))))

;; Seven-segment sizes for digits dh tall: (dw dh dt sw sh st), the
;; hours:minutes and the seconds beside them (70 px: 38 wide, 7 thick)
(define (cal-clock-dims dh)
  (list (quotient (* dh 38) 70) dh (max 4 (quotient (* dh 7) 70))
        (quotient (* dh 18) 70) (quotient (* dh 34) 70) (max 3 (quotient (* dh 4) 70))))

;; The tallest clock up to dh (not below 70) that fits the screen's width;
;; kept for the last (dh . width) asked (it runs for every band and second)
(define cal-clock-fit-cache #f)

(define (cal-clock-fit dh)
  (let ((key (cons dh (scr-w))))
    (if (and cal-clock-fit-cache (equal? (car cal-clock-fit-cache) key))
        (cdr cal-clock-fit-cache)
        (let loop ((h dh))
          (let* ((d (cal-clock-dims h))
                 (w (+ (gui-seg7-width (car d) (caddr d) "88:88") 10
                       (gui-seg7-width (list-ref d 3) (list-ref d 5) "88"))))
            (if (or (<= w (- (scr-w) 16)) (<= h 70))
                (begin (set! cal-clock-fit-cache (cons key d)) d)
                (loop (- h 2))))))))

(define (cal-clock y size)
  (let* ((hm app-time)
         (n (string-length app-sec))      ; the device gives ":30" (":--" unsynced)
         (sec (cond ((= n 3) (substring app-sec 1 3)) ((= n 2) app-sec) (else "--")))
         (d (cal-clock-fit size))
         (dw (list-ref d 0)) (dh (list-ref d 1)) (dt (list-ref d 2))
         (sw (list-ref d 3)) (sh (list-ref d 4)) (st (list-ref d 5))
         (hm-w (gui-seg7-width dw dt hm))
         (total (+ hm-w 10 (gui-seg7-width sw st sec)))
         (x (quotient (- (scr-w) total) 2)))
    (gui-seg7 x y dw dh dt hm theme-seg-on theme-seg-off theme-seg-on theme-seg-on)
    (gui-seg7 (+ x hm-w 10) (+ y (- dh sh)) sw sh st sec theme-seg-on theme-seg-off theme-seg-on theme-seg-on)))

;; World clocks. The proxy gives each place's UTC offset (DST included, see
;; world_clocks in tools/app_proxy.py); the time runs here from the UTC
;; second of the day (app-utc-sec) and the device's own offset, worked out
;; from its local time.
(define (cal-local-sec)                  ; "20:29" ":06" -> seconds of the day, #f unsynced
  (let ((n (string-length app-sec)))
    (and (= (string-length app-time) 5) (>= n 2)
         (let ((h (string->number (substring app-time 0 2))) (m (string->number (substring app-time 3 5)))
               (s (string->number (substring app-sec (- n 2) n))))
           (and h m s (+ (* h 3600) (* m 60) s))))))

(define (cal-day t) (quotient (- t (modulo t 86400)) 86400))   ; floor(t / 86400)

;; (hh:mm . days) of a place at offset `off`; days: its date against ours (-1, 0, 1)
(define (cal-world-time local off)
  (let* ((utc app-utc-sec)
         (mine (let ((d (modulo (- local utc) 86400))) (if (> d 50400) (- d 86400) d)))  ; UTC-12 .. UTC+14
         (t (+ utc off)) (tm (modulo t 86400)))
    (cons (string-append (pad2 (quotient tm 3600)) ":" (pad2 (quotient (remainder tm 3600) 60)))
          (- (cal-day t) (cal-day (+ utc mine))))))

;; The digit height of the world clocks: as tall as the room allows (22..40
;; px) and narrow enough for a column with a "+1" beside it
(define (cal-world-dh room cw)
  (let loop ((dh (max 22 (min 40 room))))
    (if (and (> dh 22) (> (+ (gui-seg7-width (quotient (* dh 11) 20) (max 3 (quotient dh 9)) "88:88") 22) (- cw 8)))
        (loop (- dh 2))
        dh)))

;; Up to 4 columns in a row of height h: padding, the name (with the zone's
;; abbreviation when it fits), seven-segment digits dh tall, and +1 / -1
;; when the date there is not ours; the padding splits what is left
(define (cal-world y h dh wcs)
  (let* ((n (length wcs)) (cw (quotient (scr-w) n)) (local (cal-local-sec))
         (pad (quotient (- h 22 dh) 2)) (dw (quotient (* dh 11) 20)) (dt (max 3 (quotient dh 9)))
         (ty (+ y pad)) (dy (+ y pad 22)))
    (let loop ((ws wcs) (i 0))
      (if (pair? ws)
          (let* ((wc (car ws)) (x (* i cw)) (cx (+ x (quotient cw 2)))
                 (full (if (str-empty? (it-b wc)) (it-a wc) (string-append (it-a wc) " " (it-b wc))))
                 (name (if (<= (txt-w full) (- cw 6)) full (it-a wc)))
                 (wt (if local (cal-world-time local (it-int wc 3)) (cons "--:--" 0)))
                 (mark (cond ((> (cdr wt) 0) "+1") ((< (cdr wt) 0) "-1") (else "")))
                 (seg-w (gui-seg7-width dw dt (car wt)))
                 (mark-w (if (str-empty? mark) 0 (+ 4 (txt-w mark))))
                 (dx (- cx (quotient (+ seg-w mark-w) 2))))
            (if (> i 0) (gui-line x (+ ty 2) x (+ dy dh -2) theme-divider))
            (if (<= (txt-w name) (- cw 6))
                (txt-center cx ty name theme-text-sub)
                (txt-fit (+ x 3) ty (- cw 6) name theme-text-sub))
            (gui-seg7 dx dy dw dh dt (car wt) theme-seg-on theme-seg-off theme-seg-on theme-seg-on)
            (if (> mark-w 0) (txt (+ dx seg-w 4) (+ dy (- dh 18)) mark theme-warning))
            (loop (cdr ws) (+ i 1)))))))

;; 宜 and 忌 on a grid: a column holds a word of two characters and half a
;; character of space, a longer word takes two columns, and a word that does
;; not fit moves whole to the next line. Every word starts on a column, so
;; the words and the spaces line up from one line to the next.
(define (cal-spaces n)
  (let loop ((n n) (s ""))
    (if (<= n 0) s (loop (- n 1) (string-append s " ")))))

;; The words of text (space separated) as lines of at most width px
(define (cal-grid-lines text width)
  (let* ((ch (txt-w "宜"))
         (sp (max 1 (txt-w " ")))
         (gap (* sp (max 1 (quotient (+ (quotient ch 2) (quotient sp 2)) sp))))
         (cell (+ ch ch gap))
         (cols (max 1 (quotient (+ width gap) cell)))
         (words (filter (lambda (s) (not (str-empty? s))) (str-split text #\space))))
    (let loop ((ws (if (null? words) '("无") words)) (col 0) (lw 0) (line "") (acc '()))
      (if (null? ws)
          (reverse (if (> col 0) (cons line acc) acc))
          (let* ((wd (car ws)) (wpx (txt-w wd))
                 (k (min cols (max 1 (quotient (+ wpx gap cell -1) cell)))))
            (if (and (> col 0) (> (+ col k) cols))
                (loop ws 0 0 "" (cons line acc))
                (let ((pad (quotient (- (* col cell) lw) sp)))
                  (loop (cdr ws) (+ col k) (+ lw (* pad sp) wpx)
                        (string-append line (cal-spaces pad) wd) acc))))))))

;; Rows for 宜 and 忌 (lines a and b) out of four: all of both when they fit;
;; one that needs a single row leaves the other three; else two each, and
;; the rest pages (config.ini [text] wrap_marquee)
(define (cal-yiji-rows a b)
  (cond ((<= (+ a b) 4) (list a b))
        ((<= b 1) (list 3 1))
        ((<= a 1) (list 1 3))
        (else (list 2 2))))

(define (cal-join-lines lines)
  (if (null? lines)
      ""
      (let loop ((ls (cdr lines)) (s (car lines)))
        (if (null? ls) s (loop (cdr ls) (string-append s "\n" (car ls)))))))

;; The laid-out lines, kept while the day's words stay the same (the render
;; runs for every band and every clock second)
(define cal-yiji-key #f)
(define cal-yiji-lines '())

(define (cal-yiji-layout yi ji width)
  (let ((key (list yi ji width)))
    (if (not (equal? key cal-yiji-key))
        (begin
          (set! cal-yiji-key key)
          (set! cal-yiji-lines (list (cal-grid-lines yi width) (cal-grid-lines ji width)))))
    cal-yiji-lines))

;; A round badge with one character, then the lines beside it in rows rows
(define (cal-yiji y ch color lines rows)
  (gui-round-rect 12 (+ y 1) 24 22 6 color #t)
  (txt 16 (+ y 4) ch theme-bg)
  (txt-wrap 44 (+ y 4) (- (scr-w) 56) (* LINE-H rows) (cal-join-lines lines) theme-text-sub))

(define (cal-render-today items)
  (let* ((w (scr-w)) (cx (quotient w 2))
         (cds (items-all items "cd"))
         (shown (if (> (length cds) 2) (take cds 2) cds))
         (y (body-top)))
    (for-each (lambda (cd) (cal-countdown y cd) (set! y (+ y 24))) shown)
    (if (pair? shown) (set! y (+ y 6)))
    (set! cal-clock-y y)
    (if (and (null? shown) (string=? (app-config "countdown" "") ""))
        ;; no countdown set: the clock also takes the room of the usual
        ;; countdown row (30 px), so what follows stays where it is with one
        (begin (cal-clock (+ y 4) 100) (set! cal-clock-h 112) (set! y (+ y 110)))
        (begin (cal-clock (+ y 4) 70) (set! cal-clock-h 82) (set! y (+ y 80))))
    (set! cal-world-y 0)
    (let ((date (items-find items "cdate")) (lunar (items-find items "lunar"))
          (term (items-find items "term")) (fest (items-find items "fest"))
          (wcs (items-all items "wclk")))
      ;; the world clocks take the room the rest of the page leaves: the
      ;; date to the solar term below need 104 px (+ 22 for a festival, + 100 for 宜忌)
      (if (pair? wcs)
          (let* ((spare (- (body-bottom) y 104 (if fest 22 0) (if (pair? items) 100 0)))
                 (dh (cal-world-dh (- spare 22 16) (quotient w (length wcs))))
                 (h (+ 22 dh (* 2 (max 4 (min 20 (quotient (- spare 22 dh) 2)))))))
            (set! cal-world-y y)
            (set! cal-world-h h)
            (set! cal-world-hm app-time)
            (cal-world y h dh wcs)
            (set! y (+ y h)))
          (set! y (+ y 6)))
      ;; the date is in the title: here the lunar date and the 时辰 / 刻, the
      ;; year's and the day's stem-branches, then 属 / 冲 / 煞 (the same 74 px
      ;; the date and two lunar lines took, so the rest stays in place)
      (set! cal-lunar-y y)
      (set! cal-shike-seen (cal-shike))
      (cond (lunar
             (txt-center cx y (string-append "农历" (it-a lunar) "  " cal-shike-seen) theme-text-main)
             (txt-center cx (+ y 24) (string-append (it-b lunar) "  " (it-c lunar)) theme-text-sub)
             (if (not (str-empty? (it-d lunar)))
                 (txt-center cx (+ y 48) (it-d lunar) theme-text-muted)))
            ((null? items)                  ; no proxy yet: the device's own lunar date
             (if (> (string-length app-lunar) 0)       ; already "农历..."
                 (txt-center cx y (string-append app-lunar "  " cal-shike-seen) theme-text-main))
             (txt-center cx (+ y 24) "节气与宜忌等待代理数据" theme-text-muted)))
      (set! y (+ y 74))
      (if term
          (txt-fit 12 y (- w 24)
                   (string-append (if (string=? (it-b term) "今日") (string-append "今日" (it-a term))
                                      (string-append (it-a term) (it-b term)))
                                  "  下一节气 " (it-c term) " " (it-d term))
                   theme-text-sub))
      (set! y (+ y 24))
      (if fest (txt-fit 12 y (- w 24) (it-a fest) theme-warning))
      (set! y (+ y (if fest 28 6)))
      (if (pair? items)
          (let* ((yi (items-find items "yi")) (ji (items-find items "ji"))
                 (lines (cal-yiji-layout (if yi (it-a yi) "") (if ji (it-a ji) "") (- w 56)))
                 (rows (cal-yiji-rows (length (car lines)) (length (cadr lines)))))
            (gui-line 12 y (- w 12) y theme-divider)
            (cal-yiji (+ y 8) "宜" theme-success (car lines) (car rows))
            (cal-yiji (+ y 8 (* LINE-H (car rows)) 10) "忌" theme-danger (cadr lines) (cadr rows)))))))

;; 3. The month ---------------------------------------------------------------------

(define CAL-WEEK '("日" "一" "二" "三" "四" "五" "六"))

;; The days of the months before and after ("xday", d "p" or "n"), drawn
;; dimmed in gray
(define CAL-OTHER-NUM 23243)                ; #5a5a5a
(define CAL-OTHER-LABEL 16936)              ; #464646

(define (cal-xdays items side)
  (filter (lambda (d) (string=? (it-d d) side)) (items-all items "xday")))

;; Six weeks as a wall calendar shows them: the month's days and around them
;; the adjacent months' (an older proxy sends the month's days only)
(define (cal-render-month items)
  (let* ((m (items-find items "month"))
         (cells (append (map (lambda (d) (cons #f d)) (cal-xdays items "p"))
                        (map (lambda (d) (cons #t d)) (items-all items "day"))
                        (map (lambda (d) (cons #f d)) (cal-xdays items "n"))))
         (w (scr-w)) (cw (quotient (- w 4) 7)) (x0 (quotient (- w (* cw 7)) 2))
         (first (- (if m (it-int m 2) 0) (length (cal-xdays items "p"))))
         (today (if m (it-int m 4) 0))
         (rows (quotient (+ first (length cells) 6) 7))
         (top (body-top)))
    (if m (txt-center (quotient w 2) top (it-a m) theme-text-main))
    (let loop ((i 0) (names CAL-WEEK))      ; 日 一 ... 六
      (if (pair? names)
          (begin
            (txt-center (+ x0 (* i cw) (quotient cw 2)) (+ top 26) (car names)
                        (if (or (= i 0) (= i 6)) theme-danger theme-text-muted))
            (loop (+ i 1) (cdr names)))))
    (gui-line x0 (+ top 48) (- w x0) (+ top 48) theme-divider)
    (let* ((gy (+ top 52)) (rh (min 60 (quotient (- (body-bottom) gy) (max rows 1)))))
      (let loop ((cs cells) (k first))
        (if (pair? cs)
            (let* ((mine (car (car cs))) (d (cdr (car cs)))
                   (col (remainder k 7)) (row (quotient k 7))
                   (x (+ x0 (* col cw))) (y (+ gy (* row rh))) (n (it-int d 1))
                   (now (and mine today (= n today)))
                   (num (it-a d)) (num-h (if (= cal-day-font F-TEXT) 18 26)))
              (if now
                  (begin
                    (gui-round-rect (+ x 1) (+ y 1) (- cw 2) (- rh 2) 8 theme-accent-dark #t)
                    (gui-round-rect (+ x 1) (+ y 1) (- cw 2) (- rh 2) 8 theme-accent #f)))
              (gui-text-styled (- (+ x (quotient cw 2)) (quotient (gui-text-width num cal-day-font) 2)) (+ y 5)
                               num (cond ((not mine) CAL-OTHER-NUM)
                                         (now theme-accent)
                                         ((or (= col 0) (= col 6)) theme-danger)
                                         (else theme-text-main))
                               cal-day-font)
              (txt-center (+ x (quotient cw 2)) (+ y 5 num-h) (it-b d)
                          (cond ((not mine) CAL-OTHER-LABEL)
                                ((string=? (it-c d) "1") theme-accent)
                                (else theme-text-muted)))
              (loop (cdr cs) (+ k 1))))))))

;; 4. The sky -----------------------------------------------------------------------

(define CAL-PI 3.14159265)
(define (cal-rad deg) (* deg (/ CAL-PI 180.0)))
(define (cal-int x) (inexact->exact (round x)))

(define (cal-dir az)
  (list-ref '("北" "东北" "东" "东南" "南" "西南" "西" "西北") (remainder (quotient (+ az 22) 45) 8)))

;; The moon as seen: a dark disc, then the lit part row by row (2 px rows).
;; elong: the moon's angle from the sun, 0 new, 180 full; waxing lit on the right.
(define (cal-moon cx cy r elong)
  (gui-circle cx cy r cal-moon-dark #t)
  (let ((c (cos (cal-rad elong))))
    (let loop ((dy (- r)))
      (if (< dy r)
          (let* ((hw (sqrt (exact->inexact (- (* r r) (* dy dy)))))
                 (x1 (if (<= elong 180) (+ cx (cal-int (* hw c))) (cal-int (- cx hw))))
                 (x2 (if (<= elong 180) (cal-int (+ cx hw)) (- cx (cal-int (* hw c))))))
            (if (> x2 x1) (gui-rect x1 (+ cy dy) (- x2 x1) 2 cal-moon-lit #t))
            (loop (+ dy 2))))))
  (gui-circle cx cy r theme-divider #f))

;; A dial of the sky: the horizon on the rim, the zenith in the middle, north up
(define (cal-dial cx cy r)
  (gui-circle cx cy r theme-divider #f)
  (gui-circle cx cy (quotient r 2) theme-divider #f)
  (gui-line (- cx r) cy (+ cx r) cy theme-divider)
  (gui-line cx (- cy r) cx (+ cy r) theme-divider)
  (txt-center cx (- cy r 20) "北" theme-text-muted)
  (txt-center cx (+ cy r 3) "南" theme-text-muted)
  (txt (+ cx r 4) (- cy 8) "东" theme-text-muted)
  (txt (- cx r 20) (- cy 8) "西" theme-text-muted))

;; A body on the dial: az degrees, alt tenths; below the horizon a ring on the rim
(define (cal-body cx cy r az alt10 color size)
  (let* ((up (>= alt10 0))
         (rr (if up (quotient (* r (- 900 alt10)) 900) r))
         (x (+ cx (cal-int (* rr (sin (cal-rad az))))))
         (y (- cy (cal-int (* rr (cos (cal-rad az)))))))
    (gui-circle x y size color up)))

(define (cal-alt-text alt10)
  (string-append (if (< alt10 0) "-" "") (int->str (quotient (abs alt10) 10)) "." (int->str (remainder (abs alt10) 10)) "°"))

(define (cal-body-text x y title color pos)
  (let ((az (it-int pos 1)) (alt (it-fixed pos 2 1)))
    (txt x y title color)
    (txt x (+ y 22) (string-append "方位 " (int->str az) "° " (cal-dir az)) theme-text-sub)
    (txt x (+ y 44) (string-append "高度 " (cal-alt-text alt)) (if (< alt 0) theme-text-muted theme-text-sub))
    (txt x (+ y 66) (string-append "出没 " (it-c pos) "-" (it-d pos)) theme-text-muted)))

(define (cal-render-sky items)
  (let ((moon (items-find items "moon")) (sun (items-find items "sun"))
        (mpos (items-find items "moonpos")) (loc (items-find items "loc"))
        (top (body-top)) (w (scr-w)) (h (gui-height)))
    (if (> w h)
        ;; Landscape layout (e.g. 480x320)
        (begin
          (if moon
              (let ((elong (it-int moon 4)) (next (str-split (it-e moon) #\,)))
                (cal-moon 55 (+ top 58) 42 elong)
                (txt 108 (+ top 8) (it-a moon) theme-accent)
                (txt 108 (+ top 30) (string-append "照亮 " (it-b moon) "%") theme-text-sub)
                (txt 108 (+ top 50) (string-append "月龄 " (it-c moon) " 天") theme-text-sub)
                (txt 108 (+ top 72) (string-append "满月 " (car next)) theme-text-muted)
                (txt 108 (+ top 92) (string-append "新月 " (if (pair? (cdr next)) (cadr next) "--")) theme-text-muted)))
          (gui-line 12 (+ top 126) 215 (+ top 126) theme-divider)
          (txt 16 (+ top 138) "观测位置" theme-accent)
          (if loc (txt-fit 16 (+ top 160) 195 (string-append "城市: " (it-a loc)) theme-text-main))
          (if loc (txt 16 (+ top 182) (string-append "经纬: " (it-c loc) "°E, " (it-b loc) "°N") theme-text-muted))
          (gui-line 225 (+ top 6) 225 (- (body-bottom) 4) theme-divider)
          (let ((cx 295) (cy (+ top 72)) (r 52))
            (cal-dial cx cy r)
            (if sun (cal-body cx cy r (it-int sun 1) (it-fixed sun 2 1) theme-warning 7))
            (if mpos (cal-body cx cy r (it-int mpos 1) (it-fixed mpos 2 1) cal-moon-lit 6)))
          (if sun
              (begin
                (txt 362 (+ top 8) "太阳" theme-warning)
                (txt 362 (+ top 28) (string-append (int->str (it-int sun 1)) "° " (cal-dir (it-int sun 1))) theme-text-sub)
                (txt 362 (+ top 48) (string-append "高度 " (cal-alt-text (it-fixed sun 2 1))) (if (< (it-fixed sun 2 1) 0) theme-text-muted theme-text-sub))
                (txt 362 (+ top 68) (string-append "出没 " (it-c sun) "-" (it-d sun)) theme-text-muted)))
          (gui-line 238 (+ top 126) (- w 12) (+ top 126) theme-divider)
          (if mpos
              (begin
                (txt 238 (+ top 138) "月亮当前位置" cal-moon-lit)
                (txt 238 (+ top 160) (string-append "方位: " (int->str (it-int mpos 1)) "° " (cal-dir (it-int mpos 1))) theme-text-sub)
                (txt 360 (+ top 160) (string-append "高度: " (cal-alt-text (it-fixed mpos 2 1))) (if (< (it-fixed mpos 2 1) 0) theme-text-muted theme-text-sub))
                (txt 238 (+ top 182) (string-append "出没: " (it-c mpos) " - " (it-d mpos)) theme-text-muted))))
        ;; Portrait layout (e.g. 320x480)
        (begin
          (if moon
              (let ((elong (it-int moon 4)) (next (str-split (it-e moon) #\,)))
                (cal-moon 70 (+ top 74) 54 elong)
                (txt 146 (+ top 8) (it-a moon) theme-accent)
                (txt 146 (+ top 32) (string-append "照亮 " (it-b moon) "%") theme-text-sub)
                (txt 146 (+ top 54) (string-append "月龄 " (it-c moon) " 天") theme-text-sub)
                (txt 146 (+ top 80) (string-append "满月 " (car next)) theme-text-muted)
                (txt 146 (+ top 102) (string-append "新月 " (if (pair? (cdr next)) (cadr next) "--")) theme-text-muted)))
          (gui-line 12 (+ top 146) (- w 12) (+ top 146) theme-divider)
          (let ((cx 84) (cy (+ top 268)) (r 56))
            (cal-dial cx cy r)
            (if sun (cal-body cx cy r (it-int sun 1) (it-fixed sun 2 1) theme-warning 7))
            (if mpos (cal-body cx cy r (it-int mpos 1) (it-fixed mpos 2 1) cal-moon-lit 6)))
          (if sun (cal-body-text 160 (+ top 158) "太阳" theme-warning sun))
          (if mpos (cal-body-text 160 (+ top 258) "月亮" cal-moon-lit mpos))
          (if loc (txt-fit 160 (+ top 356) (- w 170) (it-a loc) theme-text-muted))))))

;; 5. The app -----------------------------------------------------------------------

(define cal-day-seen "")

;; Every second: the clock on page 1, the world clocks when the minute
;; changes; a new day fetches the page again
(set! app-tick-proc
      (lambda (tick)
        (if (and (= app-page-index 0) (not (info-active?)) (> cal-clock-y 0))
            (gui-invalidate 0 cal-clock-y (scr-w) cal-clock-h))
        (if (and (= app-page-index 0) (not (info-active?)) (> cal-lunar-y 0)
                 (not (string=? (cal-shike) cal-shike-seen)))
            (gui-invalidate 0 cal-lunar-y (scr-w) 24))
        (if (and (= app-page-index 0) (not (info-active?)) (> cal-world-y 0) (not (string=? app-time cal-world-hm)))
            (gui-invalidate 0 cal-world-y (scr-w) cal-world-h))
        (if (and (> (string-length app-date) 0) (not (string=? app-date cal-day-seen)))
            (begin
              (if (> (string-length cal-day-seen) 0) (app-start-feed!))
              (set! cal-day-seen app-date)
              (app-invalidate-all)))))      ; the date (also when the clock first syncs)

(set! app-render-empty-pages '(0))      ; the clock needs no proxy

(set! app-header-proc cal-header)        ; page 1's title: the date and the weekday
(set! app-page-title-only #t)            ; the other pages: their name alone

(app-define! "万年历"
  (list (app-page "今日" cal-today-url 600000 cal-render-today)
        (app-page "月历" cal-month-url 3600000 cal-render-month)
        (app-page "月相" cal-sky-url 60000 cal-render-sky)))

