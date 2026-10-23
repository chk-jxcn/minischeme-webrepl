;;; =========================================================================
;;; MiniScheme Standalone Application: tide
;;; All-in-One Standalone Scheme Source (Libraries Included for WebREPL)
;;; =========================================================================
;;; [app]
;;; pages = 3
;;; page_ids = now, table, about ; English page names: <app>.<id> in a combined app (front: the first)
;;; id = tide
;;; name = 潮汐
;;; description = 今天潮位曲线、当前潮高与涨落、高低潮时刻；应用代理按设备位置取全球潮汐模型，没有数据时用海口（秀英）官方月报表
;;; version = 4
;;; api = 1.8 ; the device API it needs (docs/api): theme-css (color schemes) since 1.8
;;; 
;;; [fields]
;;; ; how the settings page shows each [config] key: type | label | help
;;; ; (no ASCII ; or # in these lines: they start a comment)
;;; location = text | 位置 | auto 表示按公网 IP 定位，也可以填沿海城市名（厦门）或 经度,纬度（内陆没有潮汐数据）
;;; proxy_url = text | 应用代理 | 留空用系统设置里的应用代理（提供 /app/tide）
;;; carousel = bool | 自动翻页 | 打开后按下面的时长依次显示各页
;;; carousel_seconds = text | 每页秒数 | 一个值，或每页一个，如 15,10,10
;;; 
;;; [config]
;;; location = auto ; auto (the public IP), a coastal city (厦门) or lon,lat
;;; proxy_url = ; Application proxy service URL (empty: use system config.ini)
;;; carousel = ; empty: config.ini [app] carousel (1: turn the pages by themselves, 0: manual)
;;; carousel_seconds = ; empty: config.ini [app] carousel_seconds (seconds per page, or one per page)

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

;;; -------------------------------------------------------------------------
;;; 1b. Color schemes: color aliases, a day and a night scheme
;;; -------------------------------------------------------------------------
;; Colors are named by alias: titlebar_bg, text_fg, card_border, bar_fg ...
;; The value of an alias, the first found wins:
;;   1. a color given to the call itself (a number, "#rrggbb", rgb(r, g, b))
;;   2. the app's theme.css (in its folder), the block of the scheme in use
;;   3. the system's /spiffs/theme.css (theme-css, API 1.8), the same block
;;   4. the app's own defaults (theme-defaults!)
;;   5. the built-in day or night scheme (THEME-DAY, THEME-NIGHT)
;; When none of them names the alias, the same steps for its category, the
;; part after the last "_" (titlebar_bg -> bg, text_sub_fg -> fg,
;; card_border -> border). A value is #rgb, #rrggbb, rgb(r, g, b) or
;; another alias, so names of your own work too:
;;   day   { my_orange: #f08c32; warning_fg: my_orange; }
;;   night { titlebar_bg: #152030; }
;;   *     { seg_on_fg: #6fcf7f; }        (every scheme)
;;   sakura { bg: #fff4f6; }              (a scheme of your own)
;; The mode (config.ini [theme], an app's own config.ini may override):
;;   theme        auto (default), day or night
;;   theme_switch light (default: light-lux at or over theme_light_day is
;;                day, at or under theme_light_night night), time
;;                (theme_day_start .. theme_night_start) or sun (sunrise to
;;                sunset at theme_lat / theme_lon; the time when unknown)
;;   theme_day / theme_night  the scheme each mode uses: day / night, or a
;;                block of theme.css of your own
;; The theme-* colors above are set from the aliases at the start and again
;; whenever the mode or a theme.css changes (theme-tick!, from the app loop).

(define THEME-NIGHT
  '(("bg" . "#0b1118") ("fg" . "#e6ecf3") ("border" . "#5b7090")
    ("card_bg" . "bg") ("card_border" . "#5b7090") ("titlebar_bg" . "#152030")
    ("text_fg" . "#e6ecf3") ("text_sub_fg" . "#bac7d6") ("text_muted_fg" . "#a2b2c6")
    ("accent_fg" . "#62d0f0") ("accent_bg" . "#173f52")
    ("success_fg" . "#72d696") ("warning_fg" . "#f0bc55") ("danger_fg" . "#ee7c7c") ("purple_fg" . "#c0a2f2")
    ("inactive_fg" . "#34414f") ("divider_border" . "#688098")
    ("seg_on_fg" . "#6fcf7f") ("seg_off_fg" . "#142a1c")
    ("bar_fg" . "accent_fg") ("bar_bg" . "titlebar_bg") ("icon_fg" . "accent_fg")))

(define THEME-DAY
  '(("bg" . "#ffffff") ("fg" . "#17202b") ("border" . "#8d9cae")
    ("card_bg" . "bg") ("card_border" . "#8d9cae") ("titlebar_bg" . "#d7e1ec")
    ("text_fg" . "#17202b") ("text_sub_fg" . "#33404f") ("text_muted_fg" . "#556377")
    ("accent_fg" . "#0a6f9c") ("accent_bg" . "#c2e0ee")
    ("success_fg" . "#1d7f45") ("warning_fg" . "#b8700a") ("danger_fg" . "#bf3434") ("purple_fg" . "#6c49b0")
    ("inactive_fg" . "#c4cdd8") ("divider_border" . "#a3b0bf")
    ("seg_on_fg" . "#000000") ("seg_off_fg" . "bg")      ; unlit segments not shown by day
    ("bar_fg" . "accent_fg") ("bar_bg" . "titlebar_bg") ("icon_fg" . "accent_fg")))

(define theme-mode "night")        ; "day" or "night"
(define theme-scheme "night")      ; the block of theme.css in use
(define theme-sys-text #f)         ; the files as last read, to notice a change
(define theme-app-text #f)
(define theme-sys-css '())         ; parsed: ((block (alias . value) ...) ...)
(define theme-app-css '())
(define theme-app-defaults '())    ; ((block (alias . value) ...) ...), theme-defaults!
(define theme-cache '())           ; (alias . rgb565) of the scheme in use
(define theme-ticks 0)
(define theme-utc-offset #f)       ; seconds east of UTC, learnt from the app loop

;; -- small text helpers (gui.scm comes before applib.scm) --

(define (theme-space? c) (let ((b (char->integer c))) (or (= b 32) (= b 9) (= b 10) (= b 13))))

(define (theme-trim s)
  (let* ((n (string-length s))
         (a (let loop ((i 0)) (if (and (< i n) (theme-space? (string-ref s i))) (loop (+ i 1)) i)))
         (b (let loop ((j n)) (if (and (> j a) (theme-space? (string-ref s (- j 1)))) (loop (- j 1)) j))))
    (substring s a b)))

(define (theme-split s ch)
  (let ((n (string-length s)))
    (let loop ((i 0) (start 0) (acc '()))
      (cond ((= i n) (reverse (cons (substring s start n) acc)))
            ((char=? (string-ref s i) ch) (loop (+ i 1) (+ i 1) (cons (substring s start i) acc)))
            (else (loop (+ i 1) start acc))))))

(define (theme-index s ch)
  (let ((n (string-length s)))
    (let loop ((i 0)) (cond ((= i n) #f) ((char=? (string-ref s i) ch) i) (else (loop (+ i 1)))))))

(define (theme-last-index s ch)
  (let loop ((i (- (string-length s) 1))) (cond ((< i 0) #f) ((char=? (string-ref s i) ch) i) (else (loop (- i 1))))))

;; s without /* comments */
(define (theme-uncomment s)
  (let ((n (string-length s)))
    (let loop ((i 0) (acc '()) (in #f))
      (cond ((>= i n) (list->string (reverse acc)))
            ((and (not in) (< (+ i 1) n) (char=? (string-ref s i) #\/) (char=? (string-ref s (+ i 1)) #\*))
             (loop (+ i 2) acc #t))
            ((and in (< (+ i 1) n) (char=? (string-ref s i) #\*) (char=? (string-ref s (+ i 1)) #\/))
             (loop (+ i 2) acc #f))
            (in (loop (+ i 1) acc #t))
            (else (loop (+ i 1) (cons (string-ref s i) acc) #f))))))

;; "name, name { alias: value; ... }" blocks -> ((name (alias . value) ...) ...)
(define (theme-parse text)
  (if (not (string? text))
      '()
      (let loop ((chunks (theme-split (theme-uncomment text) #\})) (acc '()))
        (if (null? chunks)
            (reverse acc)
            (let* ((c (car chunks)) (open (theme-index c #\{)))
              (loop (cdr chunks)
                    (if (not open)
                        acc
                        (let ((pairs (theme-pairs (substring c (+ open 1) (string-length c)))))
                          (let add ((names (theme-split (substring c 0 open) #\,)) (acc acc))
                            (if (null? names)
                                acc
                                (let ((nm (theme-trim (car names))))
                                  (add (cdr names) (if (> (string-length nm) 0) (cons (cons nm pairs) acc) acc)))))))))))))

(define (theme-pairs body)
  (let loop ((parts (theme-split body #\;)) (acc '()))
    (if (null? parts)
        (reverse acc)
        (let ((colon (theme-index (car parts) #\:)))
          (loop (cdr parts)
                (if colon
                    (let ((k (theme-trim (substring (car parts) 0 colon)))
                          (v (theme-trim (substring (car parts) (+ colon 1) (string-length (car parts))))))
                      (if (and (> (string-length k) 0) (> (string-length v) 0)) (cons (cons k v) acc) acc))
                    acc))))))

;; The value of alias in the blocks named scheme (else "*"), the last one wins
(define (theme-block-get css scheme alias)
  (let loop ((l css) (own #f) (any #f))
    (if (null? l)
        (or own any)
        (let* ((b (car l)) (hit (and (or (string=? (car b) scheme) (string=? (car b) "*")) (assoc alias (cdr b)))))
          (cond ((not hit) (loop (cdr l) own any))
                ((string=? (car b) scheme) (loop (cdr l) (cdr hit) any))
                (else (loop (cdr l) own (cdr hit))))))))

;; -- values --

(define (theme-hex s i n) (string->number (substring s i (+ i n)) 16))

;; "#rgb", "#rrggbb", "rgb(r, g, b)" -> rgb565, else #f
(define (theme-literal v)
  (let ((n (string-length v)))
    (cond ((and (= n 7) (char=? (string-ref v 0) #\#))
           (let ((r (theme-hex v 1 2)) (g (theme-hex v 3 2)) (b (theme-hex v 5 2)))
             (and r g b (gui-rgb r g b))))
          ((and (= n 4) (char=? (string-ref v 0) #\#))
           (let ((r (theme-hex v 1 1)) (g (theme-hex v 2 1)) (b (theme-hex v 3 1)))
             (and r g b (gui-rgb (* r 17) (* g 17) (* b 17)))))
          ((and (> n 5) (string=? (substring v 0 4) "rgb(") (char=? (string-ref v (- n 1)) #\)))
           (let ((p (map (lambda (x) (string->number (theme-trim x))) (theme-split (substring v 4 (- n 1)) #\,))))
             (and (= (length p) 3) (integer? (car p)) (integer? (cadr p)) (integer? (caddr p))
                  (gui-rgb (max 0 (min 255 (car p))) (max 0 (min 255 (cadr p))) (max 0 (min 255 (caddr p)))))))
          (else #f))))

;; Steps 2-5 for exactly this alias: its value as written, or #f
(define (theme-lookup alias)
  (or (theme-block-get theme-app-css theme-scheme alias)
      (theme-block-get theme-sys-css theme-scheme alias)
      (theme-block-get theme-app-defaults theme-scheme alias)
      (theme-block-get theme-app-defaults theme-mode alias)
      (let ((d (assoc alias (if (string=? theme-mode "day") THEME-DAY THEME-NIGHT)))) (and d (cdr d)))))

(define (theme-resolve name depth)
  (or (theme-literal name)
      (and (< depth 8)
           (let ((v (theme-lookup name)))
             (or (and v (theme-resolve v (+ depth 1)))
                 (let ((u (theme-last-index name #\_)))   ; the category: titlebar_bg -> bg
                   (and u (theme-resolve (substring name (+ u 1) (string-length name)) (+ depth 1)))))))))

;; A color for drawing: a number as it is, else an alias or a literal resolved
;; through the scheme in use (the foreground for a name nothing resolves)
(define (theme-color c)
  (cond ((number? c) c)
        ((symbol? c) (theme-color (symbol->string c)))
        ((not (string? c)) 0)
        (else
         (let ((hit (assoc c theme-cache)))
           (if hit
               (cdr hit)
               (let ((v (or (theme-resolve c 0) (theme-resolve "fg" 0) 65535)))
                 (set! theme-cache (cons (cons c v) theme-cache))
                 v))))))

;; The app's own defaults: (theme-defaults! "day" '(("titlebar_bg" . "#ffe9a8")))
;; for the day scheme ("night", a scheme of theme.css or "*" for every one)
(define (theme-defaults! scheme alist)
  (set! theme-app-defaults (append theme-app-defaults (list (cons scheme alist))))
  (theme-apply!))

;; -- the mode --

(define (theme-setting key default)
  (let ((v (config-get key))) (if (and (string? v) (> (string-length (theme-trim v)) 0)) (theme-trim v) default)))

(define (theme-number key default)
  (let ((n (string->number (theme-setting key "")))) (if n n default)))

;; "07:30" -> minutes, else default
(define (theme-hm key default)
  (let ((p (theme-split (theme-setting key "") #\:)))
    (if (= (length p) 2)
        (let ((h (string->number (car p))) (m (string->number (cadr p))))
          (if (and (integer? h) (integer? m)) (+ (* h 60) m) default))
        default)))

(define (theme-now-minutes)
  (let ((t (time-local))) (and t (+ (* 60 (list-ref t 3)) (list-ref t 4)))))

(define (theme-in-day? now from to)
  (if (<= from to) (and (>= now from) (< now to)) (or (>= now from) (< now to))))

(define (theme-by-time)
  (let ((now (theme-now-minutes)))
    (if (not now)
        theme-mode
        (if (theme-in-day? now (theme-hm "theme_day_start" 420) (theme-hm "theme_night_start" 1140)) "day" "night"))))

(define (theme-by-light)
  (let ((lux (light-lux))
        (on (theme-number "theme_light_day" 120))
        (off (theme-number "theme_light_night" 50)))
    (cond ((>= lux on) "day")
          ((<= lux off) "night")
          ((= theme-ticks 0) (if (>= lux (quotient (+ on off) 2)) "day" "night"))   ; at the start: the nearer
          (else theme-mode))))                                                  ; between: as it was

;; Sunrise and sunset (minutes of the local day) at lat / lon, #f without
;; the place or the local time's offset (NOAA's approximation, about a minute)
(define (theme-sun-times)
  (let ((lat (theme-number "theme_lat" #f)) (lon (theme-number "theme_lon" #f)) (t (time-local)))
    (and lat lon t theme-utc-offset
         (let* ((pi 3.141592653589793) (rad (/ pi 180.0))
                (doy (theme-day-of-year (car t) (cadr t) (caddr t)))
                (g (* (/ (* 2.0 pi) 365.0) (- doy 1)))
                (eq (* 229.18 (+ 0.000075 (* 0.001868 (cos g)) (* -0.032077 (sin g))
                                 (* -0.014615 (cos (* 2 g))) (* -0.040849 (sin (* 2 g))))))
                (decl (+ 0.006918 (* -0.399912 (cos g)) (* 0.070257 (sin g)) (* -0.006758 (cos (* 2 g)))
                         (* 0.000907 (sin (* 2 g))) (* -0.002697 (cos (* 3 g))) (* 0.00148 (sin (* 3 g)))))
                (la (* lat rad))
                (x (- (/ (cos (* 90.833 rad)) (* (cos la) (cos decl))) (* (/ (sin la) (cos la)) (/ (sin decl) (cos decl)))))
                (ha (/ (acos (max -1.0 (min 1.0 x))) rad))
                (tz (/ theme-utc-offset 60.0))
                (rise (+ (- 720.0 (* 4.0 (+ lon ha)) eq) tz))
                (down (+ (- 720.0 (* 4.0 (- lon ha)) eq) tz)))
           (cons (modulo (inexact->exact (round rise)) 1440) (modulo (inexact->exact (round down)) 1440))))))

(define (theme-day-of-year y m d)
  (let loop ((i 1) (n d))
    (if (>= i m)
        n
        (loop (+ i 1) (+ n (list-ref (list 31 (if (and (= (modulo y 4) 0) (or (not (= (modulo y 100) 0)) (= (modulo y 400) 0))) 29 28)
                                            31 30 31 30 31 31 30 31 30 31)
                                      (- i 1)))))))

(define (theme-by-sun)
  (let ((s (theme-sun-times)) (now (theme-now-minutes)))
    (if (and s now) (if (theme-in-day? now (car s) (cdr s)) "day" "night") (theme-by-time))))

(define (theme-pick-mode)
  (let ((m (theme-setting "theme" "auto")))
    (cond ((string=? m "day") "day")
          ((string=? m "night") "night")
          (else (let ((how (theme-setting "theme_switch" "light")))
                  (cond ((string=? how "time") (theme-by-time))
                        ((string=? how "sun") (theme-by-sun))
                        (else (theme-by-light))))))))

;; The theme-* colors from the aliases of the scheme in use
(define (theme-apply!)
  (set! theme-scheme (theme-setting (if (string=? theme-mode "day") "theme_day" "theme_night") theme-mode))
  (set! theme-cache '())
  (set! theme-bg          (theme-color "bg"))
  (set! theme-card-bg     (theme-color "card_bg"))
  (set! theme-card-border (theme-color "card_border"))
  (set! theme-card-hdr    (theme-color "titlebar_bg"))
  (set! theme-text-main   (theme-color "text_fg"))
  (set! theme-text-sub    (theme-color "text_sub_fg"))
  (set! theme-text-muted  (theme-color "text_muted_fg"))
  (set! theme-accent      (theme-color "accent_fg"))
  (set! theme-accent-dark (theme-color "accent_bg"))
  (set! theme-success     (theme-color "success_fg"))
  (set! theme-warning     (theme-color "warning_fg"))
  (set! theme-danger      (theme-color "danger_fg"))
  (set! theme-purple      (theme-color "purple_fg"))
  (set! theme-dark-gray   (theme-color "inactive_fg"))
  (set! theme-divider     (theme-color "divider_border"))
  (set! theme-seg-on      (theme-color "seg_on_fg"))
  (set! theme-seg-off     (theme-color "seg_off_fg")))

;; Reads the files again; #t when one changed
(define (theme-read!)
  (let ((sys (if (defined? 'theme-css) (theme-css) #f))
        (app (fs-read "theme.css")))
    (let ((changed (not (and (equal? sys theme-sys-text) (equal? app theme-app-text)))))
      (if changed
          (begin (set! theme-sys-text sys)
                 (set! theme-app-text app)
                 (set! theme-sys-css (theme-parse sys))
                 (set! theme-app-css (if (equal? app sys) '() (theme-parse app)))))   ; the settings read the system's
      changed)))

(define (theme-load!)
  (theme-read!)
  (set! theme-mode (theme-pick-mode))
  (theme-apply!))

;; From the app loop once a second (utc: the second of the UTC day, the
;; app-tick's tick once the clock is set: with the local time it gives the
;; time zone, for the sunset); every 10 s the mode and the files are
;; checked. #t when the colors changed: the screen is to be drawn again.
(define (theme-tick! . utc)
  (if (and (pair? utc) (integer? (car utc)) (>= (car utc) 0) (< (car utc) 86400))
      (let ((t (time-local)))
        (if t (set! theme-utc-offset
                    (let ((d (- (+ (* 3600 (list-ref t 3)) (* 60 (list-ref t 4)) (list-ref t 5)) (car utc))))
                      (* 900 (round->exact (/ (cond ((> d 50400) (- d 86400)) ((< d -50400) (+ d 86400)) (else d)) 900))))))))
  (set! theme-ticks (+ theme-ticks 1))
  (if (= (remainder theme-ticks 10) 0)
      (let* ((files (theme-read!)) (mode (theme-pick-mode)) (changed (or files (not (string=? mode theme-mode)))))
        (if changed (begin (set! theme-mode mode) (theme-apply!)))
        changed)
      #f))

(define (round->exact x) (let ((r (round x))) (if (exact? r) r (inexact->exact r))))

(theme-load!)

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

;; (json-feed-status) builds a new list on each call: a caller that needs
;; several fields reads it once and passes it as st
(define (app-status key . st)
  (let ((e (assq key (if (pair? st) (car st) (json-feed-status))))) (if e (cdr e) #f)))

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
         (fs (json-feed-status))
         (state (if mine (app-status 'state fs) 'ok))
         (page-error (and app-error (or (eq? app-error APP-NO-PROXY) (equal? app-error-url url)) app-error))
         ;; what the fetch waits for now (firmware 1.0.57+): it replaces an old error
         (step (app-status 'step fs))
         (busy (memq step '(clock register wifi)))
         (failed (and (not busy) (or page-error (eq? state 'error))))
         (text (cond ((eq? step 'register)
                      (string-append "正在向 " (app-server-name (app-status 'step-server fs)) " 注册加密通道..."))
                     ((eq? step 'clock) "等待网络对时...")
                     ((eq? step 'wifi) "等待 WiFi 连接...")      ; firmware 1.0.61+
                     (page-error (string-append "代理: " page-error))
                     ((eq? state 'error) (string-append "连接失败: " (app-status 'error fs)))
                     ((and app-loading mine) (if last (string-append last "，刷新中...") "加载中..."))
                     (last last)
                     (else "等待数据")))
         (ms (app-status 'fetch-ms fs))
         (right (if (and mine (eq? state 'ok) (number? ms) (> ms 0))
                    (string-append (fixed->str (quotient (+ (app-status 'bytes fs) 51) 102) 1) "KB "
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
    (if (theme-tick! tick) (app-invalidate-all))   ; the day / night scheme or a theme.css changed
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
;;; Section: apps/tide/tide.scm
;;; =========================================================================
;;; =========================================================================
;;; Tide (潮汐), 320x480 portrait, on the app framework (applib.scm).
;;;
;;; Two data paths, one screen:
;;;   * the app proxy (default): /app/tide?loc= from the system proxy, or
;;;     the app's own proxy_url. The proxy locates the device from its
;;;     public IP (or the location setting: a city, or lon,lat) and returns
;;;     Open-Meteo's global tide model, 15 min apart, for that point.
;;;   * built-in table (fallback, no network): the National Marine Data and
;;;     Information Service monthly table for Haikou (Xiuying), stored by
;;;     lunar day (1..30) with a half-cosine between the extrema. The firmware
;;;     gives a lunar date but no year (time-epoch is a reserved API), so the
;;;     table keeps the app useful on a board without a server.
;;;
;;; Pages 1 and 2 show whichever path has data; page 1's section line names
;;; the height datum (the table uses its chart datum, the model reports
;;; heights above mean sea level).
;;;   1 now   2 today's extrema   3 about
;;; =========================================================================

(define TIDE-PI 3.14159265358979)
(define TIDE-STATION "海口（秀英）")
(define TIDE-INTERVAL 300000)          ; the model updates hourly: 5 min is plenty

;; (minute-of-day . height-cm) per lunar day, from the official table
(define TIDE-DAYS
  '(
    (1  (187 . 103) (547 . 173) (840 . 122) (1265 . 231))
    (2  (198 . 126) (526 . 184) (891 . 91) (1326 . 226))
    (3  (208 . 150) (515 . 203) (941 . 68) (1386 . 216))
    (4  (215 . 168) (518 . 224) (991 . 57))
    (5  (13 . 202) (220 . 180) (537 . 241) (1038 . 56))
    (6  (568 . 251) (1077 . 62))
    (7  (606 . 254) (1107 . 71))
    (8  (642 . 251) (1133 . 80))
    (9  (660 . 244) (1171 . 90) (1310 . 95))
    (10 (2 . 91) (595 . 239))
    (11 (56 . 89) (604 . 232))
    (12 (83 . 89) (602 . 221))
    (13 (96 . 90) (582 . 208) (769 . 201) (939 . 205))
    (14 (113 . 95) (564 . 194) (776 . 177) (1094 . 204))
    (15 (135 . 105) (537 . 183) (811 . 146) (1199 . 213))
    (16 (157 . 124) (501 . 180) (853 . 112) (1268 . 221))
    (17 (172 . 149) (471 . 192) (897 . 79) (1338 . 225))
    (18 (181 . 175) (466 . 215) (943 . 52) (1426 . 222))
    (19 (190 . 199) (481 . 240) (991 . 35))
    (20 (508 . 260) (1041 . 29))
    (21 (539 . 271) (1094 . 35))
    (22 (520 . 274) (1169 . 49))
    (23 (614 . 260) (1139 . 48))
    (24 (622 . 265) (1199 . 60))
    (25 (611 . 264))
    (26 (40 . 59) (627 . 258))
    (27 (107 . 54) (656 . 244))
    (28 (146 . 56) (982 . 230))
    (29 (167 . 66) (1097 . 227))
    (30 (177 . 82) (583 . 176) (790 . 158) (1194 . 230))
    ))

;; 1. The built-in day curve ------------------------------------------------------

(define (tide-wrap L) (cond ((< L 1) 30) ((> L 30) 1) (else L)))

(define (tide-day L)
  (let ((e (assv (tide-wrap L) TIDE-DAYS))) (if e (cdr e) '())))

(define (tide-last l) (if (null? (cdr l)) (car l) (tide-last (cdr l))))

;; The day's extrema plus one on each side, so 0..1440 is always bracketed
(define (tide-points L)
  (let* ((prev (tide-day (- L 1)))
         (cur (tide-day L))
         (next (tide-day (+ L 1)))
         (a (if (pair? prev)
                (list (cons (- (car (tide-last prev)) 1440) (cdr (tide-last prev))))
                '()))
         (b (if (pair? next)
                (list (cons (+ (car (car next)) 1440) (cdr (car next))))
                '())))
    (append a cur b)))

;; Height (cm) at minute m: half a cosine between the two bracketing extrema
(define (tide-at pts m)
  (let loop ((p pts))
    (cond ((null? p) #f)
          ((null? (cdr p)) (cdr (car p)))
          ((<= m (car (cadr p)))
           (let* ((p0 (car p)) (p1 (cadr p))
                  (t0 (car p0)) (h0 (cdr p0)) (t1 (car p1)) (h1 (cdr p1))
                  (f (/ (- m t0) (max 1 (- t1 t0)))))
             (+ h0 (* (- h1 h0) (/ (- 1 (cos (* TIDE-PI f))) 2)))))
          (else (loop (cdr p))))))

;; 'high / 'low of an extremum, from its neighbours; -1/+1 cm steps included
(define (tide-kind prev cur next)
  (let ((h (cdr cur)))
    (cond ((and prev next) (if (and (>= h (cdr prev)) (>= h (cdr next))) 'high 'low))
          (prev (if (>= h (cdr prev)) 'high 'low))
          (next (if (>= h (cdr next)) 'high 'low))
          (else 'high))))

;; (minute cm kind) of every extremum in the given points
(define (tide-extrema pts)
  (let loop ((prev #f) (rest pts) (acc '()))
    (if (null? rest)
        (reverse acc)
        (let ((cur (car rest)) (next (if (null? (cdr rest)) #f (cadr rest))))
          (loop cur (cdr rest)
                (cons (list (car cur) (cdr cur) (tide-kind prev cur next)) acc))))))

(define (tide-in-day es)
  (filter (lambda (e) (and (>= (car e) 0) (< (car e) 1440))) es))

;; (max . min) of a sample vector: the day's highest and lowest water
(define (tide-samples-range v)
  (let loop ((i 1) (hi (vector-ref v 0)) (lo (vector-ref v 0)))
    (if (< i (vector-length v))
        (loop (+ i 1) (max hi (vector-ref v i)) (min lo (vector-ref v i)))
        (cons hi lo))))

;; 97 samples, every 15 minutes
(define (tide-samples pts)
  (let ((v (make-vector 97 0)))
    (let loop ((i 0))
      (if (< i 97)
          (begin (vector-set! v i (tide-int (tide-at pts (* i 15)))) (loop (+ i 1)))
          v))))

;; 2. Text and time --------------------------------------------------------------

(define (tide-int x) (if (inexact? x) (inexact->exact (round x)) x))
(define (tide-m cm) (fixed->str (tide-int cm) 2))        ; 152 -> "1.52"

(define (tide-hm m)
  (let ((m (min 1439 (max 0 m))))
    (string-append (pad2 (quotient m 60)) ":" (pad2 (remainder m 60)))))

(define (tide-hm->min s)
  (if (or (not (string? s)) (< (string-length s) 5) (string=? s "--:--"))
      #f
      (+ (* 60 (string->number (substring s 0 2))) (string->number (substring s 3 5)))))

(define (tide-cn-num s)
  (cond ((string=? s "一") 1) ((string=? s "二") 2) ((string=? s "三") 3)
        ((string=? s "四") 4) ((string=? s "五") 5) ((string=? s "六") 6)
        ((string=? s "七") 7) ((string=? s "八") 8) ((string=? s "九") 9)
        ((string=? s "十") 10) (else #f)))

;; "农历九月十三" -> 13 ("农历闰二月初一" -> 1); #f while the clock is unsynced
(define (tide-lunar-day)
  (let* ((s app-lunar) (n (string-length s)))
    (if (< n 6)
        #f
        (let* ((d (substring s (- n 6) n)) (a (substring d 0 3)) (b (substring d 3 6)))
          (cond ((string=? a "初") (tide-cn-num b))
                ((string=? a "廿") (let ((k (tide-cn-num b))) (and k (+ 20 k))))
                ((and (string=? a "二") (string=? b "十")) 20)
                ((and (string=? a "三") (string=? b "十")) 30)
                ((string=? a "十") (let ((k (tide-cn-num b))) (and k (+ 10 k))))
                (else #f))))))

(define (tide-cn-day n)
  (let ((d (list-ref '("" "一" "二" "三" "四" "五" "六" "七" "八" "九") (remainder n 10)))
        (t (quotient n 10)))
    (cond ((= n 10) "初十") ((= n 20) "二十") ((= n 30) "三十")
          ((< n 10) (string-append "初" d))
          ((< n 20) (string-append "十" d))
          (else (string-append "廿" d)))))

(define (tide-range-kind r)
  (cond ((< r 80) "小潮") ((< r 150) "中潮") (else "大潮")))

;; 3. The two data paths, one view ------------------------------------------------
;; view: #(datum station samples lo hi es now-min now-cm rate source top bot labels days)
;;   es      ((minute cm kind) ...), minutes from today 00:00 (1440+ = tomorrow)
;;   labels  ("今日 农历十三" "明日 农历十四" "后日 农历十五")

(define (tide-view-frame datum station samples es now-min now-cm rate source top bot labels)
  (vector datum station samples
          (- (* 20 (quotient bot 20)) 20)                 ; axis: 20 cm steps + pad
          (+ (* 20 (+ 1 (quotient top 20))) 20)
          es now-min now-cm rate source top bot labels
          ;; days: the extrema of today, tomorrow and the day after (page 2)
          (list (tide-day-rows es 0) (tide-day-rows es 1) (tide-day-rows es 2))))

(define (tide-v-datum v) (vector-ref v 0))
(define (tide-v-station v) (vector-ref v 1))
(define (tide-v-samples v) (vector-ref v 2))
(define (tide-v-lo v) (vector-ref v 3))
(define (tide-v-hi v) (vector-ref v 4))
(define (tide-v-es v) (vector-ref v 5))
(define (tide-v-now v) (vector-ref v 6))
(define (tide-v-cur v) (vector-ref v 7))
(define (tide-v-rate v) (vector-ref v 8))
(define (tide-v-source v) (vector-ref v 9))
(define (tide-v-top v) (vector-ref v 10))
(define (tide-v-bot v) (vector-ref v 11))
(define (tide-v-labels v) (vector-ref v 12))
(define (tide-v-day v d) (list-ref (vector-ref v 13) d))

;; Everything one lunar day needs, built once: the board redraws the chart
;; every minute and must not allocate a new vector and lists each time.
(define tide-cache-L #f)
(define tide-pts '())
(define tide-es '())
(define tide-nx '())
(define tide-nv '())
(define tide-samples-v (vector))
(define tide-lo 0)
(define tide-hi 300)
(define tide-top 300)
(define tide-bot 0)

(define (tide-prepare! L)
  (if (not (eqv? L tide-cache-L))
      (let* ((pts (tide-points L))
             (es (tide-in-day (tide-extrema pts)))
             (samples (tide-samples pts))
             (st (tide-samples-range samples))
             (top (car st))
             (bot (cdr st)))
        (set! tide-cache-L L)
        (set! tide-pts pts)
        (set! tide-es es)
        (set! tide-top top)
        (set! tide-bot bot)
        (set! tide-lo (- (* 20 (quotient bot 20)) 20))
        (set! tide-hi (+ (* 20 (+ 1 (quotient top 20))) 20))
        (set! tide-samples-v samples)
        (set! tide-nx (tide-in-day (tide-extrema (tide-points (+ L 1)))))
        (set! tide-nv (tide-in-day (tide-extrema (tide-points (+ L 2))))))))

;; a day's extrema shifted to minutes from today
(define (tide-shift es off)
  (map (lambda (e) (list (+ off (car e)) (cadr e) (caddr e))) es))

;; The local view, made again only when the minute or the lunar day changes:
;; a render must not allocate a new view (vector, lists, strings) each time.
(define tide-local-time "")
(define tide-local-lunar "")
(define tide-local-view #f)

(define (tide-view-local)
  (if (not (and (string=? app-time tide-local-time) (string=? app-lunar tide-local-lunar)))
      (begin (set! tide-local-view (tide-view-local-make))
             (set! tide-local-time app-time)
             (set! tide-local-lunar app-lunar)))
  tide-local-view)

(define (tide-view-local-make)
  (let ((L (tide-lunar-day)))
    (if (not L)
        #f
        (begin
          (tide-prepare! L)
          (let* ((nm (tide-hm->min app-time))
                 (es (append tide-es (tide-shift tide-nx 1440) (tide-shift tide-nv 2880))))
            (tide-view-frame
             "潮高基准面" TIDE-STATION tide-samples-v es nm
             (if nm (tide-at tide-pts nm) (tide-at tide-pts 720))
             (if nm (* 3 (- (tide-at tide-pts (+ nm 10)) (tide-at tide-pts (- nm 10)))) 0)
             "本地月报表" tide-top tide-bot
             (list (string-append "农历" (tide-cn-day L))
                   (string-append "农历" (tide-cn-day (tide-wrap (+ L 1))))
                   (string-append "农历" (tide-cn-day (tide-wrap (+ L 2)))))))))))

;; /app/tide document: meta | now | curve (97 cm values) | ext (a hh:mm, b cm,
;; c high|low, d day offset) | upd
(define tide-view-of #f)                 ; the document the cached view was made from
(define tide-view-cached #f)

;; The network view, parsed once per document (render runs per band)
(define (tide-view-items items)
  (if (not (eq? items tide-view-of))
      (begin (set! tide-view-cached (tide-view-items-parse items))
             (set! tide-view-of items)))
  tide-view-cached)

(define (tide-view-items-parse items)
  (let ((cu (items-find items "curve")))
    (if (and cu (pair? (string->ints (it-a cu))))
        (let* ((vals (string->ints (it-a cu)))
               (v (list->vector vals))
               (mt (items-find items "meta"))
               (nw (items-find items "now"))
               (es (map (lambda (it)
                          (let* ((t (tide-hm->min (it-a it)))
                                 (off (if (equal? (it-f it 4) "1") 1440 0))
                                 (kind (if (equal? (it-c it) "high") 'high 'low)))
                            (list (+ off (if t t 0))
                                  (tide-int (or (string->number (it-b it)) 0))
                                  kind)))
                        (items-all items "ext")))
               (top-bot (tide-samples-range v)))
          (tide-view-frame
           "平均海面"
           (if mt (it-a mt) "模型点")
           v es
           (if nw (tide-hm->min (it-a nw)) (tide-hm->min app-time))
           (if nw (tide-int (or (string->number (it-b nw)) 0)) 0)
           (if nw (tide-int (or (string->number (it-c nw)) 0)) 0)
           "联网模型" (car top-bot) (cdr top-bot) '("" "" "")))
        #f)))

;; 4. Page 1: now ------------------------------------------------------------------

(define CH-X 10)
(define CH-Y 168)
(define CH-W 300)
(define CH-H 156)

(define (tide-y h lo hi)
  (- (+ CH-Y CH-H) (quotient (* CH-H (- h lo)) (max 1 (- hi lo)))))

(define (tide-dot x y c)
  (gui-rect (- x 2) (- y 2) 5 5 c #t))

(define (tide-render-chart samples lo hi nm es top bot)
  (gui-rect CH-X CH-Y CH-W CH-H theme-card-hdr #t)
  (let loop ((i 1))
    (if (< i 4)
        (begin (gui-line CH-X (+ CH-Y (quotient (* CH-H i) 4))
                         (+ CH-X CH-W) (+ CH-Y (quotient (* CH-H i) 4)) theme-dark-gray)
               (loop (+ i 1)))))
  (gui-chart CH-X CH-Y CH-W CH-H samples 0 (vector-length samples) lo hi theme-accent)
  ;; every extremum gets a dot; the text only on the day's dominant high and
  ;; low (in dead water the 2nd high differs from the 1st by a few cm)
  (let loop ((es es))
    (if (pair? es)
        (let* ((e (car es)) (t (car e)) (h (cadr e)) (k (caddr e))
               (mark (if (eq? k 'high) (<= (- top h) 15) (<= (- h bot) 15))))
          (if (and (>= t 0) (< t 1440))
              (let ((x (+ CH-X (quotient (* CH-W t) 1440)))
                    (y (tide-y h lo hi)))
                (tide-dot x y (if (eq? k 'high) theme-accent theme-text-sub))
                (if mark
                    (if (eq? k 'high)
                        (txt (- x 8) (max (+ CH-Y 2) (- y 22)) "高" theme-accent)
                        (txt (- x 8) (min (- (+ CH-Y CH-H) 20) (+ y 4)) "低" theme-text-sub)))))
          (loop (cdr es)))))
  (if nm
      (let ((x (+ CH-X (quotient (* CH-W nm) 1440))))
        (gui-line x CH-Y x (+ CH-Y CH-H) theme-warning))))

(define (tide-render-waiting why)
  (txt 14 70 why theme-text-muted)
  (txt-wrap 14 98 (- (scr-w) 28) 60 "联网时由应用代理按设备的公网 IP（或设置里的位置）取潮汐模型；没有数据时用本机海口月报表。"
            theme-text-sub))

(define (tide-render-now items)
  (let ((v (if (pair? items) (tide-view-items items) (tide-view-local))))
    (if (not v)
        (tide-render-waiting "等待网络对时")
        (let* ((nm (tide-v-now v))
               (cur (tide-v-cur v))
               (rate (tide-v-rate v))
               (es (tide-v-es v))
               (next (let loop ((l es))
                       (cond ((null? l) #f)
                             ((and nm (> (car (car l)) nm)) (car l))
                             (else (loop (cdr l))))))
               (hi-cm (tide-v-top v))
               (lo-cm (tide-v-bot v))
               (up (> rate 0)))
          ;; now
          (txt 10 42 "现在潮高" theme-text-muted)
          (big 10 56 (tide-m cur) theme-text-main)
          (txt (+ 14 (big-w (tide-m cur))) 72 "米" theme-text-sub)
          (gui-round-rect 206 58 100 24 6 (if up theme-accent-dark theme-card-hdr) #t)
          (txt-center 256 61 (if up "涨潮" "落潮") (if up theme-accent theme-warning))
          (txt-right 306 88 (string-append (if up "+" "-") (tide-m (abs rate)) " 米/时")
                     theme-text-muted)
          ;; the next extremum
          (if next
              (begin
                (txt 10 106
                     (string-append "下次" (if (eq? (caddr next) 'high) "高潮" "低潮") " "
                                    (if (>= (car next) 1440) "明天 " "")
                                    (tide-hm (remainder (car next) 1440)) "  " (tide-m (cadr next)) " 米")
                     theme-text-sub)
                (if nm
                    (let* ((left (- (car next) nm)) (hr (quotient left 60)) (mi (remainder left 60)))
                      (txt 10 128
                           (string-append "还有 "
                                          (if (> hr 0)
                                              (string-append (number->string hr) " 小时 "
                                                             (number->string mi) " 分")
                                              (string-append (number->string mi) " 分")))
                           theme-accent))))
              (txt 10 106 "今天没有更多高低潮" theme-text-muted))
          ;; the curve
          (section-note 148 "今日潮位" (tide-v-datum v))
          (tide-render-chart (tide-v-samples v) (tide-v-lo v) (tide-v-hi v) nm es hi-cm lo-cm)
          (txt 10 (+ CH-Y CH-H 4) "00" theme-text-muted)
          (txt-center (+ CH-X (quotient CH-W 4)) (+ CH-Y CH-H 4) "06" theme-text-muted)
          (txt-center (+ CH-X (quotient CH-W 2)) (+ CH-Y CH-H 4) "12" theme-text-muted)
          (txt-center (+ CH-X (quotient (* 3 CH-W) 4)) (+ CH-Y CH-H 4) "18" theme-text-muted)
          (txt-right (+ CH-X CH-W) (+ CH-Y CH-H 4) "24" theme-text-muted)
          ;; summary
          (txt 10 366 (string-append "最高 " (tide-m hi-cm) " 米") theme-text-main)
          (txt 164 366 (string-append "最低 " (tide-m lo-cm) " 米") theme-text-main)
          (txt 10 390 (string-append "潮差 " (tide-m (- hi-cm lo-cm)) " 米") theme-text-sub)
          (txt-right 306 390 (tide-range-kind (- hi-cm lo-cm)) theme-accent)
          (txt 10 414 (string-append (tide-v-station v) " · " (tide-v-source v))
               theme-text-muted)))))

;; 5. Page 2: the extrema table ---------------------------------------------------

(define (tide-kind-text k) (if (eq? k 'high) "高潮" "低潮"))

(define (tide-row y e)
  (let ((t (car e)) (h (cadr e)) (k (caddr e)))
    (txt 12 y (tide-hm (remainder t 1440)) theme-text-main)
    (txt 96 y (tide-kind-text k) (if (eq? k 'high) theme-accent theme-text-sub))
    (txt-right 306 y (string-append (tide-m h) " 米") theme-text-main)
    (gui-line 12 (+ y 24) 306 (+ y 24) theme-divider)))

(define (tide-render-rows es y n)
  (if (or (null? es) (<= n 0))
      y
      (begin (tide-row y (car es)) (tide-render-rows (cdr es) (+ y 30) (- n 1)))))

(define (tide-day-rows es d)
  (filter (lambda (e) (and (>= (car e) (* 1440 d)) (< (car e) (* 1440 (+ d 1))))) es))

(define (tide-render-table items)
  (let ((v (if (pair? items) (tide-view-items items) (tide-view-local))))
    (if (not v)
        (tide-render-waiting "等待网络对时")
        (let* ((es (tide-v-es v))
               (labels (tide-v-labels v))
               (today (tide-v-day v 0))
               (y0 (tide-render-rows today (+ (body-top) 24) 4)))
          (section-note (body-top) "今日" (if (pair? labels) (car labels) ""))
          (if (null? today)
              (txt 12 (+ (body-top) 26) "今天没有明显的高低潮" theme-text-muted))
          (section-note y0 "明日" (if (pair? (cdr labels)) (cadr labels) ""))
          (let ((y1 (tide-render-rows (tide-v-day v 1) (+ y0 22) 4)))
            (if (and (< y1 400) (pair? (tide-v-day v 2)))
                (begin
                  (section-note y1 "后日" (if (and (pair? (cdr labels)) (pair? (cddr labels)))
                                              (caddr labels) ""))
                  (tide-render-rows (tide-v-day v 2) (+ y1 22) 2))))))))

;; 6. Page 3: about ----------------------------------------------------------------

(define (tide-about-meta items field)
  (let ((mt (items-find items "meta")))
    (if mt (it-f mt field) "")))

(define (tide-render-about items)
  (let* ((net? (pair? items))
         (mt (and net? (items-find items "meta")))
         (name (if mt (it-a mt) TIDE-STATION))
         (place (if mt (it-d mt) ""))
         (coords (if net?
                     (string-append "N" (tide-about-meta items 2) " E" (tide-about-meta items 3))
                     "N20.02 E110.27"))
         ;; the server names a point it cannot place as "N.. E..": show the place
         (shown (if (and mt (str-starts? name "N") (str-contains? name " E")) place name))
         (line2 (if (or (str-empty? place) (string=? place shown))
                    coords
                    (string-append coords " · " place))))
    (section (body-top) "站点")
    (txt-fit 12 (+ (body-top) 18) (- (scr-w) 24) shown theme-text-main)
    (txt-fit 12 (+ (body-top) 38) (- (scr-w) 24) line2 theme-text-sub)
    (section 96 "数据")
    (txt-wrap 12 114 (- (scr-w) 24) 76
              (if net?
                  "联网：应用代理按设备位置取 Open-Meteo 全球潮汐模型（15 分钟一个点），是模型值，不是港口官方表。"
                  "本地：国家海洋信息中心 2026 年 10 月海口（秀英）高低潮表，按农历日 1-30 存储，极值之间半余弦插值。")
              theme-text-sub)
    (section 200 "潮高基准")
    (txt-wrap 12 218 (- (scr-w) 24) 56
              (if net?
                  "模型相对平均海面，官方表相对潮高基准面（平均海面下 1.5 米）。"
                  "潮高相对潮高基准面（平均海面下 150 厘米），与官方月报口径一致。")
              theme-text-sub)
    (section 284 "精度")
    (txt-wrap 12 302 (- (scr-w) 24) 80
              "天文潮，不含风暴增水与径流。模型点在近岸浅水与海峡处相位可差数十分钟、振幅可差数十厘米；仅供出行参考，不可用于航海与赶海安全判断。"
              theme-warning)
    (txt 12 400 (string-append "数据路径：" (if net? "联网模型" "本地月报表")) theme-text-muted)))

;; 7. Start --------------------------------------------------------------------------

(define (tide-now-url) (app-url (string-append "/app/tide?loc=" (url-encode (app-config "location" "auto")))))

(define (tide-footer!)
  (let ((L (tide-lunar-day)))
    (set! app-footer-text
          (if L
              (string-append TIDE-STATION " · 农历" (tide-cn-day L) " · 天文潮")
              (string-append TIDE-STATION " · 等待对时")))))

(define tide-footer-lunar "")

(tide-footer!)

(set! app-subtitle-proc
      (lambda (items)
        (if (> (string-length app-lunar) 6) (substring app-lunar 6 (string-length app-lunar)) "")))

(set! app-tick-proc
      (lambda (tick)
        (if (not (string=? app-lunar tide-footer-lunar))
            (begin (set! tide-footer-lunar app-lunar) (tide-footer!)))
        (if (= (remainder tick 60) 0)
            (gui-invalidate 0 HDR-H (scr-w) (- (gui-height) HDR-H FTR-H)))))

(app-define! "潮汐"
  (list (app-page "潮位" tide-now-url TIDE-INTERVAL tide-render-now)
        (app-page "潮时" tide-now-url TIDE-INTERVAL tide-render-table)
        (app-page "关于" tide-now-url TIDE-INTERVAL tide-render-about)))

;; every page draws from the built-in table until (or unless) the server answers
(set! app-render-empty-pages '(0 1 2))

