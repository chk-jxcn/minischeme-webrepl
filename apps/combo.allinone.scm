;;; =========================================================================
;;; MiniScheme Standalone Application: combo
;;; All-in-One Standalone Scheme Source (Libraries Included for WebREPL)
;;; =========================================================================
;;; [app]
;;; id = combo
;;; name = 合集
;;; description = 把几个应用的页面合成一个轮播：天气、万年历、最新消息、股票等，每页标出所属应用和序号；各应用的设置仍在它自己的配置里
;;; version = 1
;;; pages = 5
;;; 
;;; [combo]
;;; ; the apps whose code this app carries; each reads its own config.ini
;;; members = weather, calendar, wxpusher, stocks
;;; 
;;; [fields]
;;; entries = text | 显示的页面 | 逗号分开，按顺序轮播。应用.页名（英文页名，如 weather.sevendays、calendar.today；front 为第一页），或应用提供的视图，如 wxpusher.news[0]（最新一条消息）。留空：全部页面
;;; carousel = select:=跟随系统,1=自动轮播,0=手动翻页 | 自动轮播 | 留空跟随 config.ini
;;; carousel_seconds = text | 每页秒数 | 一个数，或每页一个：15,10,10
;;; 
;;; [config]
;;; entries = ; app.page (English page names) or a view, comma separated; empty: every page
;;; carousel = 1 ; 1: turn the pages by themselves
;;; carousel_seconds = 10 ; seconds per page, or one per page

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
  '(("bg" . "#f3f5f8") ("fg" . "#17202b") ("border" . "#8d9cae")
    ("card_bg" . "bg") ("card_border" . "#8d9cae") ("titlebar_bg" . "#d7e1ec")
    ("text_fg" . "#17202b") ("text_sub_fg" . "#33404f") ("text_muted_fg" . "#556377")
    ("accent_fg" . "#0a6f9c") ("accent_bg" . "#c2e0ee")
    ("success_fg" . "#1d7f45") ("warning_fg" . "#b8700a") ("danger_fg" . "#bf3434") ("purple_fg" . "#6c49b0")
    ("inactive_fg" . "#c4cdd8") ("divider_border" . "#a3b0bf")
    ("seg_on_fg" . "#1f7a35") ("seg_off_fg" . "#dae6dd")
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
;;; Section: apps/lib/combo.scm
;;; =========================================================================
;;; combo.scm - a combined app: pages of several apps in one carousel
;;;
;;; The WebREPL's 合并应用 (or tools/build_apps.py for apps/<id>/meta.ini with
;;; [combo] members) puts applib, this file, then each member app's code
;;; followed by (combo-member! "weather" '("front" ...) '(("location" . "auto") ...))
;;; (its English page names and its meta.ini defaults), and (combo-start!) at
;;; the end, into one app.
;;;
;;; - A member's (app-define! title pages) is recorded, not started, and its
;;;   hooks (subtitle, tick, data, long press, views, empty pages) are kept
;;;   per member; the global hooks are cleared for the next member.
;;; - config "entries" lists the pages to show in order, comma separated:
;;;   <app>.<page>, the page an English name of the app's meta.ini page_ids
;;;   (weather.sevendays), front (its first page), a number (1 first) or the
;;;   page's own name; or a view the app declares with app-view!:
;;;   wxpusher.news[0] (its newest message). Empty: every page of every member.
;;; - Each entry becomes a page of this app, so applib's carousel, page turns,
;;;   prefetch and per-URL cache work as in any app. While a member's code
;;;   runs (its URL, render, hooks) app-page-index is its own page number and
;;;   app-config reads the member's own config.ini ((config-get key id),
;;;   firmware with combined apps; never run alone: its meta.ini defaults).
;;; - Short press: next entry. Long press: the entry app's own long press.

(define combo-members '())       ; #(id title pages subtitle tick data long views empty ids defaults has-ini)
(define combo-pending #f)        ; (title . pages) of the member being loaded
(define combo-entries (vector))  ; per page of this app: #(member local-page view-proc view-index)
(define combo-ctx #f)            ; the member whose code runs now, #f this app's own
(define combo-index #f)          ; this app's page index while a member's code runs

(define combo-applib-define! app-define!)
(define combo-applib-config app-config)
(define combo-applib-start-feed! app-start-feed!)
(define combo-applib-set-url! app-set-url!)
(define combo-default-button app-button)
(define app-long-press #f)       ; a member may define its own: kept per member

;; A member's app-define!: recorded (combo-member! keeps it)
(define (app-define! title pages) (set! combo-pending (cons title pages)))

(define (combo-id m) (vector-ref m 0))
(define (combo-title m) (vector-ref m 1))
(define (combo-pages m) (vector-ref m 2))

;; A member's setting, as the app gets it when it runs alone: its own
;; config.ini (a key empty there: config.ini's), else the default its code
;; gives; a member that never ran alone has no config.ini yet: its meta.ini
;; defaults stand in for it (as the file the firmware would write from them)
(define (combo-nonempty v) (and (string? v) (> (string-length v) 0) v))

(define (app-config key default)
  (if (not combo-ctx)
      (combo-applib-config key default)
      (let* ((m combo-ctx)
             (d (and (not (vector-ref m 11)) (assoc key (vector-ref m 10))))
             (v (or (and d (combo-nonempty (cdr d)))
                    (combo-nonempty (config-get key (combo-id m))))))
        (or v default))))

;; Runs thunk as the member's code: its page number, its settings
(define (combo-in m local thunk)
  (let ((saved-index app-page-index) (saved-ctx combo-ctx) (saved-combo combo-index))
    (set! combo-index (if combo-index combo-index app-page-index))
    (set! combo-ctx m)
    (set! app-page-index local)
    (let ((r (thunk)))
      (set! app-page-index saved-index)
      (set! combo-ctx saved-ctx)
      (set! combo-index saved-combo)
      r)))

;; A member restarting its page's fetch: this app's page, not the member's number
(define (app-start-feed!)
  (if combo-index
      (let ((local app-page-index))
        (set! app-page-index combo-index)
        (combo-applib-start-feed!)
        (set! app-page-index local))
      (combo-applib-start-feed!)))

;; A member changing its page i's URL: every entry showing that page
(define (app-set-url! i url)
  (if combo-ctx
      (let ((m combo-ctx) (local app-page-index))
        (if combo-index (set! app-page-index combo-index))
        (let loop ((k 0))
          (if (< k (vector-length combo-entries))
              (let ((e (vector-ref combo-entries k)))
                (if (and (eq? (vector-ref e 0) m) (= (vector-ref e 1) i))
                    (combo-applib-set-url! k url))
                (loop (+ k 1)))))
        (set! app-page-index local))
      (combo-applib-set-url! i url)))

;; After each member's code: keep what it defined, clear the hooks
(define (combo-member! id ids defaults)
  (let ((title (if combo-pending (car combo-pending) id))
        (pages (if combo-pending (list->vector (cdr combo-pending)) (vector))))
    (set! combo-members
          (append combo-members
                  (list (vector id title pages app-subtitle-proc app-tick-proc app-data-proc
                                app-long-press app-views app-render-empty-pages ids defaults
                                (and (defined? 'app-has-config?) (app-has-config? id))))))
    (set! combo-pending #f)
    (set! app-subtitle-proc #f)
    (set! app-header-proc #f)
    (set! app-page-title-only #f)       ; the combined app titles every page itself
    (set! app-tick-proc #f)
    (set! app-data-proc #f)
    (set! app-long-press #f)
    (set! app-views '())
    (set! app-render-empty-pages '())
    (set! app-button combo-default-button)))

(define (combo-find-member id)
  (let loop ((ms combo-members))
    (cond ((null? ms) #f)
          ((string=? (combo-id (car ms)) id) (car ms))
          (else (loop (cdr ms))))))

;; The first position of character ch in s at or after start, else #f
(define (combo-char-pos s ch start)
  (let loop ((i start))
    (cond ((>= i (string-length s)) #f)
          ((char=? (string-ref s i) ch) i)
          (else (loop (+ i 1))))))

(define (combo-trim s)
  (let loop ((a 0) (b (string-length s)))
    (cond ((and (< a b) (char=? (string-ref s a) #\space)) (loop (+ a 1) b))
          ((and (< a b) (char=? (string-ref s (- b 1)) #\space)) (loop a (- b 1)))
          (else (substring s a b)))))

(define (combo-position x lst)
  (let loop ((l lst) (k 0))
    (cond ((null? l) #f) ((string=? (car l) x) k) (else (loop (cdr l) (+ k 1))))))

;; The page of member m called rest: an English page name, front, a number
;; (1 first) or the page's own name; #f when none
(define (combo-page-of m rest)
  (let* ((pages (combo-pages m)) (n (vector-length pages)) (named (combo-position rest (vector-ref m 9))))
    (cond ((string=? rest "front") (and (> n 0) 0))
          (named (and (< named n) named))
          ((string->number rest) (let ((k (- (string->number rest) 1))) (and (>= k 0) (< k n) k)))
          (else (let loop ((k 0))
                  (cond ((>= k n) #f)
                        ((string=? (vector-ref (vector-ref pages k) 0) rest) k)
                        (else (loop (+ k 1)))))))))

;; "weather.sevendays" / "stocks.front" / "wxpusher.news[0]" -> an entry, #f
;; when the app or the page is unknown
(define (combo-parse spec)
  (let* ((s (combo-trim spec)) (dot (combo-char-pos s #\. 0))
         (m (and dot (combo-find-member (substring s 0 dot))))
         (rest (if dot (substring s (+ dot 1) (string-length s)) "")))
    (and m
         (let* ((open (combo-char-pos rest #\[ 0))
                (close (and open (combo-char-pos rest #\] open))))
           (if (and open close)          ; a view
               (let* ((name (substring rest 0 open))
                      (idx (or (string->number (substring rest (+ open 1) close)) 0))
                      (v (let loop ((vs (vector-ref m 7)))
                           (cond ((null? vs) #f) ((string=? (car (car vs)) name) (car vs)) (else (loop (cdr vs)))))))
                 (and v (< (cadr v) (vector-length (combo-pages m))) (vector m (cadr v) (caddr v) idx)))
               (let ((k (combo-page-of m rest)))
                 (and k (vector m k #f 0))))))))

;; Every page of every member, in order (entries left empty)
(define (combo-all-entries)
  (let loop ((ms combo-members) (acc '()))
    (if (null? ms)
        (reverse acc)
        (loop (cdr ms)
              (let pages ((k 0) (acc acc))
                (if (< k (vector-length (combo-pages (car ms))))
                    (pages (+ k 1) (cons (vector (car ms) k #f 0) acc))
                    acc))))))

;; The entry's name in the header: its page's name (and the view's number)
(define (combo-entry-name e)
  (let ((page (vector-ref (combo-pages (vector-ref e 0)) (vector-ref e 1))))
    (if (vector-ref e 2)
        (string-append (vector-ref page 0) " " (number->string (+ (vector-ref e 3) 1)))
        (vector-ref page 0))))

;; The entry as a page of this app: the member's URL, interval and render
;; (or its view), each run as the member's code
(define (combo-entry-page e)
  (let* ((m (vector-ref e 0)) (local (vector-ref e 1)) (page (vector-ref (combo-pages m) local))
         (view (vector-ref e 2)) (vi (vector-ref e 3)))
    (vector (combo-entry-name e)
            (lambda () (combo-in m local (lambda () ((vector-ref page 1)))))
            (vector-ref page 2)
            (lambda (items)
              (combo-in m local (lambda () (if view (view items vi) ((vector-ref page 3) items))))))))

(define (combo-cur) (vector-ref combo-entries app-page-index))

;; Header: the entry's app and the page (or the app's own subtitle on its first page)
(define (app-header-title items) (combo-title (vector-ref (combo-cur) 0)))

(define (app-header-sub items)
  (let* ((e (combo-cur)) (m (vector-ref e 0)) (sub (vector-ref m 3)))
    (if (and sub items (= (vector-ref e 1) 0) (not (vector-ref e 2)))
        (or (combo-in m 0 (lambda () (sub items))) (combo-entry-name e))
        (combo-entry-name e))))

;; The document that arrived belongs to the entries with its URL: their app's data hook
(define (combo-data items)
  (let ((url (json-feed-url)))
    (let loop ((k 0) (seen '()))
      (if (< k (vector-length combo-entries))
          (let* ((e (vector-ref combo-entries k)) (m (vector-ref e 0)) (proc (vector-ref m 5)))
            (if (and proc (equal? (vector-ref app-urls k) url) (not (memq m seen)))
                (begin (combo-in m (vector-ref e 1) (lambda () (proc items)))
                       (loop (+ k 1) (cons m seen)))
                (loop (+ k 1) seen)))))))

;; Every second: the shown entry's app
(define (combo-tick tick)
  (if (> (vector-length combo-entries) 0)
      (let* ((e (combo-cur)) (m (vector-ref e 0)) (proc (vector-ref m 4)))
        (if proc (combo-in m (vector-ref e 1) (lambda () (proc tick)))))))

(define (combo-long-press)
  (let* ((e (combo-cur)) (m (vector-ref e 0)) (proc (vector-ref m 6)))
    (if proc (combo-in m (vector-ref e 1) proc))))

;; The pages entries lists (unknown ones left out; empty: all of them)
(define (combo-start! title)
  (let* ((specs (filter (lambda (s) (> (string-length (combo-trim s)) 0))
                        (str-split (app-config "entries" "") #\,)))
         (entries (if (null? specs)
                      (combo-all-entries)
                      (filter (lambda (e) e) (map combo-parse specs)))))
    (set! combo-entries (list->vector entries))
    (set! app-index-always #t)
    (set! app-data-proc combo-data)
    (set! app-tick-proc combo-tick)
    (set! app-long-press combo-long-press)   ; after the members: wxpusher defines its own
    ;; entries drawn before their data: their app's local or empty-drawn pages
    (set! app-render-empty-pages
          (let loop ((k 0) (acc '()))
            (if (< k (vector-length combo-entries))
                (let ((e (vector-ref combo-entries k)))
                  (loop (+ k 1) (if (memv (vector-ref e 1) (vector-ref (vector-ref e 0) 8)) (cons k acc) acc)))
                acc)))
    (if (null? entries)
        (combo-applib-define! title
                              (list (app-local-page "合集"
                                                    (lambda (items)
                                                      (txt-wrap 16 (+ HDR-H 20) (- (scr-w) 32) 200
                                                                "没有可显示的页面：本应用设置里的 entries 写的应用或页面不存在，例如 weather.front, calendar.today, wxpusher.news[0]"
                                                                theme-warning)))))
        (combo-applib-define! title (map combo-entry-page entries)))))


;;; =========================================================================
;;; Section: apps/weather/weather.scm
;;; =========================================================================
;;; =========================================================================
;;; Weather (天气预报), 320x480 portrait, on the app framework (applib.scm).
;;; Data: the app proxy's /app/weather: QWeather (和风天气) with a key and the
;;; account's API host, else Open-Meteo; the location is the public IP's city
;;; unless the app's ini sets one. One document serves every page.
;;;   1 home: now, 3 days, rain in the next 5 hours
;;;   2 7 days   3 24 hours   4 rain by the minute + air quality   5 indices
;;; =========================================================================

;; 1. Settings (apps/weather.ini, defaults in apps/weather/meta.ini) -----------

(define (weather-url)
  (let ((token (let ((t (app-config "qweather_token" "")))
                 (if (string=? t "") (app-config "qweather_key" "") t))))
    (app-url (string-append "/app/weather?loc=" (url-encode (app-config "location" "auto"))
                            "&token=" (url-encode token)
                            "&host=" (url-encode (app-config "qweather_host" ""))))))

(define (weather-update-interval-ms)
  (let* ((raw (app-config "update_interval" "120"))
         (num (if (number? raw) raw (string->number (if (string? raw) raw "120"))))
         (mins (max 30 (if (and num (> num 0)) num 120))))
    (* mins 60 1000)))

(define WEATHER-INTERVAL (weather-update-interval-ms))

(define (weather-normalize-time s)
  (let* ((trimmed (let loop ((i 0) (j (string-length s)))
                    (cond
                      ((>= i j) "")
                      ((char=? (string-ref s i) #\space) (loop (+ i 1) j))
                      ((char=? (string-ref s (- j 1)) #\space) (loop i (- j 1)))
                      (else (substring s i j)))))
         (parts (str-split trimmed #\:)))
    (if (= (length parts) 2)
        (let ((h (string->number (car parts)))
              (m (string->number (cadr parts))))
          (if (and h m (>= h 0) (<= h 23) (>= m 0) (<= m 59))
              (string-append (pad2 h) ":" (pad2 m))
              #f))
        #f)))

(define (weather-parse-refresh-times)
  (let* ((raw (app-config "refresh_times" ""))
         (raw-list (if (string? raw) (str-split raw #\,) '())))
    (let loop ((rest raw-list) (acc '()) (count 0))
      (if (or (null? rest) (>= count 4))
          (reverse acc)
          (let ((norm (weather-normalize-time (car rest))))
            (if norm
                (loop (cdr rest) (cons norm acc) (+ count 1))
                (loop (cdr rest) acc count)))))))

(define weather-last-refresh-hm "")
(define weather-refresh-times (weather-parse-refresh-times))

;; 2. Icons ------------------------------------------------------------------------

(define (fr r k) (quotient (* r k) 10))  ; k tenths of r

(define sun-rays '((10 0) (7 7) (0 10) (-7 7) (-10 0) (-7 -7) (0 -10) (7 -7)))
;; The icons' own colors (a theme.css may set them): the day scheme's
;; warning color is a dark amber for text, too dull for a sun
(theme-defaults! "night" '(("sun_icon_fg" . "warning_fg") ("thunder_icon_fg" . "warning_fg") ("snow_icon_fg" . "#ffffff")))
(theme-defaults! "day" '(("sun_icon_fg" . "#f29a12") ("thunder_icon_fg" . "#e08a00") ("snow_icon_fg" . "#6f9fc4")))

;; A sun with eight rays. Big: eight short lines (nine display-list
;; commands, the home page's one icon). Small (the 3-day and 7-day pages):
;; four lines through the centre, a background disc that parts them from the
;; sun, then the sun: six commands, so a week of suns fits the list.
;; rays? #f (the small sun behind a cloud): a disc in a ring, two commands.
(define (icon-sun cx cy r . rays?)
  (cond
    ((>= r 24)
     (gui-circle cx cy (fr r 6) (theme-color "sun_icon_fg") #t)
     (for-each (lambda (d)
                 (gui-line (+ cx (fr (fr r 8) (car d))) (+ cy (fr (fr r 8) (cadr d)))
                           (+ cx (fr (fr r 10) (car d))) (+ cy (fr (fr r 10) (cadr d))) (theme-color "sun_icon_fg")))
               sun-rays))
    ((and (pair? rays?) (not (car rays?)))
     (gui-circle cx cy (fr r 6) (theme-color "sun_icon_fg") #t)
     (gui-circle cx cy (fr r 9) (theme-color "sun_icon_fg") #f))
    (else
     (let ((o (fr r 10)) (d (fr r 7)))
       (gui-line (- cx o) cy (+ cx o) cy (theme-color "sun_icon_fg"))
       (gui-line cx (- cy o) cx (+ cy o) (theme-color "sun_icon_fg"))
       (gui-line (- cx d) (- cy d) (+ cx d) (+ cy d) (theme-color "sun_icon_fg"))
       (gui-line (- cx d) (+ cy d) (+ cx d) (- cy d) (theme-color "sun_icon_fg"))
       (gui-circle cx cy (fr r 8) theme-bg #t)
       (gui-circle cx cy (fr r 6) (theme-color "sun_icon_fg") #t)))))

(define (icon-cloud cx cy r color)
  (gui-circle (- cx (fr r 5)) (+ cy (fr r 1)) (fr r 5) color #t)
  (gui-circle (+ cx (fr r 1)) (- cy (fr r 2)) (fr r 6) color #t)
  (gui-circle (+ cx (fr r 6)) (+ cy (fr r 2)) (fr r 4) color #t)
  (gui-round-rect (- cx (fr r 9)) (+ cy (fr r 1)) (fr r 19) (fr r 5) (fr r 2) color #t))

(define (icon-drops cx cy r color n)
  (let loop ((i 0))
    (if (< i n)
        (let ((x (+ (- cx (fr r 5)) (* i (fr r 5)))))
          (gui-line x (+ cy (fr r 7)) (- x (fr r 2)) (+ cy (fr r 11)) color)
          (if (>= r 20) (gui-line (+ x 1) (+ cy (fr r 7)) (- (+ x 1) (fr r 2)) (+ cy (fr r 11)) color))
          (loop (+ i 1))))))

(define (icon-flakes cx cy r n)
  (let loop ((i 0))
    (if (< i n)
        (begin
          (gui-circle (+ (- cx (fr r 5)) (* i (fr r 5))) (+ cy (fr r 9)) (max 1 (fr r 1)) (theme-color "snow_icon_fg") #t)
          (loop (+ i 1))))))

(define (weather-icon kind cx cy r)
  (cond
    ((equal? kind "sun") (icon-sun cx cy r))
    ((equal? kind "partly")
     (icon-sun (- cx (fr r 4)) (- cy (fr r 4)) (fr r 7) #f)
     (icon-cloud (+ cx (fr r 2)) (+ cy (fr r 2)) (fr r 8) theme-text-sub))
    ((equal? kind "overcast")
     (icon-cloud (+ cx (fr r 2)) (- cy (fr r 2)) (fr r 8) theme-card-border)
     (icon-cloud (- cx (fr r 1)) (+ cy (fr r 1)) (fr r 9) theme-text-muted))
    ((equal? kind "rain")
     (icon-cloud cx (- cy (fr r 3)) r theme-text-muted)
     (icon-drops cx (- cy (fr r 3)) r theme-accent 3))
    ((equal? kind "storm")
     (icon-cloud cx (- cy (fr r 3)) r theme-card-border)
     (gui-line (+ cx (fr r 1)) (+ cy (fr r 3)) (- cx (fr r 2)) (+ cy (fr r 7)) (theme-color "thunder_icon_fg"))
     (gui-line (- cx (fr r 2)) (+ cy (fr r 7)) (+ cx (fr r 2)) (+ cy (fr r 7)) (theme-color "thunder_icon_fg"))
     (gui-line (+ cx (fr r 2)) (+ cy (fr r 7)) (- cx (fr r 1)) (+ cy (fr r 11)) (theme-color "thunder_icon_fg"))
     (if (>= r 20) (icon-drops (+ cx (fr r 5)) (- cy (fr r 3)) (fr r 7) theme-accent 1)))
    ((equal? kind "snow")
     (icon-cloud cx (- cy (fr r 3)) r theme-text-sub)
     (icon-flakes cx (- cy (fr r 3)) r 3))
    ((equal? kind "sleet")
     (icon-cloud cx (- cy (fr r 3)) r theme-text-sub)
     (icon-drops (- cx (fr r 2)) (- cy (fr r 3)) r theme-accent 1)
     (icon-flakes (+ cx (fr r 3)) (- cy (fr r 3)) r 2))
    ((equal? kind "fog")
     (let loop ((i 0))
       (if (< i 4)
           (begin
             (gui-round-rect (- cx (fr r (if (odd-i? i) 7 9))) (+ (- cy (fr r 6)) (* i (fr r 4)))
                             (fr r (if (odd-i? i) 14 18)) (max 2 (fr r 2)) 2 theme-text-muted #t)
             (loop (+ i 1))))))
    (else (icon-cloud cx cy (fr r 9) theme-text-sub))))

(define (odd-i? i) (= (remainder i 2) 1))

;; 3. Helpers --------------------------------------------------------------------

(define (aqi-color aqi)
  (cond ((not aqi) theme-text-muted)
        ((<= aqi 50) theme-success)
        ((<= aqi 100) theme-warning)
        ((<= aqi 150) col-orange)
        (else theme-danger)))

(define (deg s) (string-append s "°"))

;; "10/11 明天" -> ("10/11" "明天")
(define (day-date it) (str-part (it-a it) #\space 0))
(define (day-name it) (str-part (it-a it) #\space 1))
(define (day-max it) (str-part (it-d it) #\, 0))
(define (day-min it) (str-part (it-d it) #\, 1))
;; Day "e": "rain probability %,rain in 0.1 mm,humidity %" (QWeather has no
;; probability by day, Open-Meteo no humidity)
(define (day-rain-text it)
  (let ((pop (str-part (it-e it) #\, 0)) (hum (str-part (it-e it) #\, 2)))
    (cond ((not (str-empty? pop)) (string-append "降水 " pop "%"))
          ((not (str-empty? hum)) (string-append "湿度 " hum "%"))
          (else ""))))

(define (hour-label h) (string-append (int->str (remainder h 24)) "时"))

(define (weather-start-hour items)
  (let ((h (items-find items "hours"))) (if h (or (it-int h 4) 0) 0)))

(define (no-data y text) (txt 14 y text theme-text-muted))

;; 4. Page 1: home -------------------------------------------------------------------

(define (weather-render-now items)
  (let ((now (items-find items "now")) (now2 (items-find items "now2")) (air (items-find items "air")))
    (if now
        (begin
          (weather-icon (it-c now) 56 86 36)
          (big-unit 106 46 (it-a now) "°C" theme-text-main)
          (txt 108 88 (it-b now) theme-text-main)
          (if now2 (txt 108 110 (string-append (it-a now2) " " (it-b now2)) theme-text-sub))
          (txt 220 48 (string-append "体感 " (deg (it-d now))) theme-text-sub)
          (txt 220 70 (string-append "湿度 " (it-e now) "%") theme-text-sub)))
    (if air
        (let* ((aqi (it-int air 1)) (label (string-append "AQI " (it-a air) " " (it-b air)))
               (w (+ (txt-w label) 12)))
          (gui-round-rect 218 92 w 24 6 (aqi-color aqi) #f)
          (txt 224 96 label (aqi-color aqi))))
    (let ((warn (items-find items "warn")))
      (if warn
          (begin
            (gui-round-rect 10 128 300 24 6 theme-danger #f)
            (txt-fit 18 132 284 (it-a warn) theme-danger))))))

(define (weather-render-3days items y)
  (section y "三日预报")
  (let loop ((days (take (items-all items "day") 3)) (i 0))
    (if (pair? days)
        (let* ((d (car days)) (x (+ 10 (* i 102))) (cx (+ x 49)) (top (+ y 24)))
          (gui-round-rect x top 96 124 6 theme-card-border #f)
          (txt-center cx (+ top 6) (day-name d) (if (= i 0) theme-accent theme-text-main))
          (weather-icon (it-c d) cx (+ top 46) 17)
          (txt-center cx (+ top 70) (it-b d) theme-text-sub)
          (txt-center cx (+ top 92) (string-append (deg (day-max d)) " / " (deg (day-min d))) theme-text-main)
          (loop (cdr days) (+ i 1))))))

(define (weather-render-rain5 items y)
  (let ((r (items-find items "rain5h")) (h0 (weather-start-hour items)))
    (section y "未来5小时降水")
    (if (not r)
        (no-data (+ y 30) "暂无数据")
        (let* ((mm (it-ints r 1)) (pop (it-ints r 2)) (top (+ y 26)) (ch 70))
          (let loop ((i 0) (m mm) (p pop))
            (if (and (< i 5) (pair? m))
                (let* ((x (+ 10 (* i 61))) (pv (if (pair? p) (car p) 0))
                       (bh (quotient (* (clamp pv 0 100) ch) 100)))
                  (gui-rect (+ x 8) top 44 ch theme-dark-gray #t)
                  (if (> bh 0) (gui-rect (+ x 8) (- (+ top ch) bh) 44 bh theme-accent-dark #t))
                  (txt-center (+ x 30) (+ top 6) (string-append (int->str pv) "%") theme-text-main)
                  (txt-center (+ x 30) (+ top 40) (if (> (car m) 0) (fixed->str (car m) 1) "0")
                              (if (> (car m) 0) theme-accent theme-text-muted))
                  (txt-center (+ x 30) (+ top ch 4) (hour-label (+ h0 i)) theme-text-sub)
                  (loop (+ i 1) (cdr m) (if (pair? p) (cdr p) '())))))
          (txt 10 (+ top ch 28) (it-c r) (if (> (list-sum mm) 0) theme-accent theme-success))
          (txt-right 310 (+ top ch 28) "概率% / 毫米" theme-text-muted)))))

(define (weather-render-home items)
  (weather-render-now items)
  (weather-render-3days items 158)
  (weather-render-rain5 items 314))

;; 5. Page 2: 7 days ---------------------------------------------------------------------

(define (weather-render-week items)
  (let* ((days (items-all items "day"))
         (maxs (map (lambda (d) (or (string->fixed (day-max d) 0) 0)) days))
         (mins (map (lambda (d) (or (string->fixed (day-min d) 0) 0)) days))
         (lo (if (pair? mins) (list-min mins) 0))
         (hi (if (pair? maxs) (list-max maxs) 1))
         (span (max 1 (- hi lo))))
    (let loop ((ds days) (i 0) (mx maxs) (mn mins))
      (if (and (pair? ds) (< i 7))
          (let* ((d (car ds)) (y (+ 40 (* i 59))) (bx 214) (bw 56)
                 (x0 (+ bx (quotient (* (- (car mn) lo) bw) span)))
                 (x1 (+ bx (quotient (* (- (car mx) lo) bw) span))))
            (txt 10 (+ y 8) (day-name d) (if (= i 0) theme-accent theme-text-main))
            (txt 10 (+ y 30) (day-date d) theme-text-muted)
            (weather-icon (it-c d) 76 (+ y 26) 15)
            (txt-fit 100 (+ y 8) 76 (it-b d) theme-text-main)
            (txt 100 (+ y 30) (day-rain-text d) theme-text-muted)
            (txt-right 208 (+ y 18) (deg (day-min d)) theme-text-sub)
            (gui-round-rect bx (+ y 24) bw 6 3 theme-dark-gray #t)
            (gui-round-rect x0 (+ y 24) (max 6 (- x1 x0)) 6 3 theme-warning #t)
            (txt (+ bx bw 6) (+ y 18) (deg (day-max d)) theme-text-main)
            (loop (cdr ds) (+ i 1) (cdr mx) (cdr mn)))))))

;; 6. Page 3: 24 hours --------------------------------------------------------------------

(define (weather-render-hours items)
  (let ((h (items-find items "hours")))
    (if (not h)
        (no-data 60 "暂无逐小时数据")
        (let* ((temps (it-ints h 1)) (pops (it-ints h 2)) (h0 (or (it-int h 4) 0))
               (n (length temps)) (cx 34) (cw 270) (cy 70) (chh 96)
               (lo (- (list-min temps) 1)) (hi (+ (list-max temps) 1)))
          (section 40 "气温")
          (gui-rect cx cy cw chh theme-card-hdr #t)
          (line-chart cx cy cw chh temps lo hi theme-warning)
          (txt-right (- cx 4) (- cy 2) (deg (int->str (list-max temps))) theme-text-sub)
          (txt-right (- cx 4) (+ cy chh -16) (deg (int->str (list-min temps))) theme-text-sub)
          ;; a value every 4 hours on the curve
          (let loop ((i 0) (t temps))
            (if (pair? t)
                (begin
                  (if (= (remainder i 4) 0)
                      (let ((x (+ cx (quotient (* i (- cw 1)) (max 1 (- n 1)))))
                            (y (+ cy (- chh 1) (- (quotient (* (- (car t) lo) (- chh 1)) (- hi lo))))))
                        (gui-circle x y 2 theme-warning #t)
                        (txt-center (clamp x 44 296) (+ cy chh 4) (hour-label (+ h0 i)) theme-text-muted)))
                  (loop (+ i 1) (cdr t)))))
          (section 196 "降水概率 %")
          (gui-rect cx 222 cw 70 theme-card-hdr #t)
          (bar-chart cx 222 cw 70 pops 100 theme-accent)
          (txt-right (- cx 4) 220 "100" theme-text-muted)
          (txt-right (- cx 4) 276 "0" theme-text-muted)
          ;; table: every 3 hours
          (section 304 "逐3小时")
          (let loop ((i 0))
            (if (< i 8)
                (let* ((k (* i 3)) (x (+ 10 (* (remainder i 4) 76))) (y (+ 330 (* (quotient i 4) 62))))
                  (if (< k n)
                      (begin
                        (gui-round-rect x y 70 56 6 theme-card-border #f)
                        (txt-center (+ x 35) (+ y 4) (hour-label (+ h0 k)) theme-text-muted)
                        (txt-center (+ x 35) (+ y 20) (deg (int->str (list-ref temps k))) theme-text-main)
                        (txt-center (+ x 35) (+ y 37)
                                    (string-append (int->str (if (< k (length pops)) (list-ref pops k) 0)) "%")
                                    theme-accent)))
                  (loop (+ i 1)))))))))

;; 7. Page 4: rain by the minute, air, conditions ------------------------------------------

(define (weather-render-rain items)
  (let ((r (items-find items "rain")) (air (items-find items "air"))
        (now2 (items-find items "now2")) (now (items-find items "now")))
    (section 40 "未来2小时降水")
    (if (not r)
        (no-data 66 "暂无分钟级降水数据")
        (let* ((vals (it-ints r 1)) (step (or (it-int r 3) 15)) (hi (max 10 (list-max (cons 0 vals)))))
          (gui-rect 10 66 300 70 theme-card-hdr #t)
          (bar-chart 10 66 300 70 vals hi theme-accent)
          (txt 10 140 (it-d r) theme-text-muted)
          (txt-right 310 140 (string-append "+" (int->str (* step (length vals))) "分钟") theme-text-muted)
          (txt-fit 10 162 300 (if (str-empty? (it-b r)) "-" (it-b r))
                   (if (> (list-sum vals) 0) theme-accent theme-success))))
    (section 194 "空气质量")
    (if (not air)
        (no-data 220 "暂无空气质量数据")
        (let ((aqi (it-int air 1)))
          (big 14 222 (it-a air) (aqi-color aqi))
          (txt (+ 20 (big-w (it-a air))) 226 (it-b air) (aqi-color aqi))
          (txt (+ 20 (big-w (it-a air))) 246 (it-e air) theme-text-muted)
          (progress-bar 14 266 292 8 (quotient (* (clamp (or aqi 0) 0 300) 100) 300) (aqi-color aqi))
          (txt 14 280 (string-append "PM2.5  " (it-c air)) theme-text-sub)
          (txt 160 280 (string-append "PM10  " (it-d air)) theme-text-sub)))
    (section 312 "实况")
    (let ((tiles (list (list "风" (if now2 (string-append (it-a now2) " " (it-b now2)) "--"))
                       (list "气压" (if now2 (string-append (it-c now2) " hPa") "--"))
                       (list "能见度" (if (and now2 (not (str-empty? (it-d now2)))) (string-append (it-d now2) " km") "--"))
                       (list "湿度 / 紫外线" (string-append (if now (it-e now) "--") "% / "
                                                       (if (and now2 (not (str-empty? (it-e now2)))) (it-e now2) "-"))))))
      (let loop ((t tiles) (i 0))
        (if (pair? t)
            (let ((x (+ 10 (* (remainder i 2) 154))) (y (+ 338 (* (quotient i 2) 56))))
              (gui-round-rect x y 146 50 6 theme-card-border #f)
              (txt (+ x 8) (+ y 5) (car (car t)) theme-text-muted)
              (txt-fit (+ x 8) (+ y 26) 132 (cadr (car t)) theme-text-main)
              (loop (cdr t) (+ i 1))))))))

;; 8. Page 5: indices and warnings ------------------------------------------------------------

(define (weather-render-index items)
  (let ((y (let loop ((ws (items-all items "warn")) (y 40))
             (if (pair? ws)
                 (begin
                   (gui-round-rect 10 y 300 26 6 theme-danger #f)
                   (txt-fit 18 (+ y 4) 284 (it-a (car ws)) theme-danger)
                   (loop (cdr ws) (+ y 32)))
                 y))))
    (let loop ((xs (items-all items "idx")) (y y))
      (if (and (pair? xs) (< (+ y 52) 420))
          (let ((it (car xs)))
            (gui-round-rect 10 y 300 52 6 theme-card-border #f)
            (txt 20 (+ y 6) (it-a it) theme-accent)
            (txt-right 300 (+ y 6) (it-b it) theme-text-main)
            (txt-fit 20 (+ y 28) 280 (if (str-empty? (it-c it)) "-" (it-c it)) theme-text-sub)
            (loop (cdr xs) (+ y 58)))))
    (let ((loc (items-find items "loc")))
      (if loc (txt-fit 10 (- (body-bottom) 18) 300 (string-append "数据源: " (it-b loc)) theme-text-muted)))))

;; 9. Pages & Scheduled Refresh -----------------------------------------------------------------

(set! app-subtitle-proc
      (lambda (items) (let ((loc (items-find items "loc"))) (if loc (it-a loc) #f))))

(set! app-tick-proc
      (lambda (tick)
        (if (and (pair? weather-refresh-times)
                 (string? app-time)
                 (not (string=? app-time ""))
                 (not (string=? app-time weather-last-refresh-hm)))
            (let ((cur-hm (if (> (string-length app-time) 5)
                              (substring app-time 0 5)
                              app-time)))
              (if (member cur-hm weather-refresh-times)
                  (begin
                    (set! weather-last-refresh-hm app-time)
                    ;; refetch now; the cached forecast stays on screen until the
                    ;; new one arrives (and when the request fails)
                    (app-start-feed!)
                    (app-invalidate-all)))))))

(app-define! "天气"
  (list (app-page "首页" weather-url WEATHER-INTERVAL weather-render-home)
        (app-page "七日预报" weather-url WEATHER-INTERVAL weather-render-week)
        (app-page "24小时" weather-url WEATHER-INTERVAL weather-render-hours)
        (app-page "降水与空气" weather-url WEATHER-INTERVAL weather-render-rain)
        (app-page "生活指数" weather-url WEATHER-INTERVAL weather-render-index)))



;;; =========================================================================
;;; Section: build/combo/combo/member_weather.scm
;;; =========================================================================
;; generated by tools/build_apps.py: weather is loaded
(combo-member! "weather" (list "front" "sevendays" "hourly" "rain" "life")
               (list (cons "location" "auto") (cons "update_interval" "120") (cons "refresh_times" "") (cons "qweather_token" "") (cons "qweather_host" "") (cons "carousel" "") (cons "carousel_seconds" "") (cons "proxy_url" "") (cons "converter_url" "")))


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


;;; =========================================================================
;;; Section: build/combo/combo/member_calendar.scm
;;; =========================================================================
;; generated by tools/build_apps.py: calendar is loaded
(combo-member! "calendar" (list "today" "month" "moon")
               (list (cons "countdown" "春节=L01-01") (cons "world_clock" "美西=PST, 新西兰=NZST") (cons "location" "auto") (cons "carousel" "") (cons "carousel_seconds" "") (cons "proxy_url" "") (cons "converter_url" "")))


;;; =========================================================================
;;; Section: apps/wxpusher/wxpusher.scm
;;; =========================================================================
;;; =========================================================================
;;; WxPusher receiver, 320x480 portrait, on the app framework (applib.scm).
;;; The app proxy (minischeme-proxy) is a WxPusher client device: it keeps
;;; the service's WebSocket and collects the messages pushed to the user's
;;; WeChat; this app polls them at /app/wxpusher every 5 s and keeps them on
;;; the board (wxpusher.txt in its folder). Without a login the proxy sends
;;; the login QR code (its modules), drawn here with gui-bitmap to scan with
;;; WeChat. A public proxy keeps one login per device (the encrypted channel
;;; names it); a local one, one for the boards of its network.
;;;   home: the messages: the subject (【新】 on the right while unread), under
;;;   it the topic on the left and the time on the right
;;;   short press: the full messages, newest to oldest, then home again
;;;   long press at home: everything read
;;;   long press on a message: unread -> read; already read -> home
;;; Messages deleted here (the web page) are deleted at the proxy too: the
;;; feed URL carries ?del=<ids> until a document from it arrives; the proxy
;;; drops them and deletes them on the WxPusher service. 退出登录 on the web
;;; page goes the same way: ?logout=1 until a document comes back.
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
(define wx-logout #f)                   ; the web page's 退出登录, not yet taken by the proxy

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

;; The feed URL: with del=<ids> while deletions wait for the proxy, and
;; logout=1 while the logout does
(define (wx-base-url) (app-url "/app/wxpusher"))
(define (wx-url)
  (let ((q (append (if (null? wx-del) '() (list (string-append "del=" (web-join wx-del ","))))
                   (if wx-logout '("logout=1") '()))))
    (if (null? q) (wx-base-url) (string-append (wx-base-url) "?" (web-join q "&")))))

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
        ;; a document fetched with del= or logout=1: the proxy has them
        (if (and (or (pair? wx-del) wx-logout) (equal? (json-feed-url) (wx-url)))
            (begin
              (set! wx-del '())
              (set! wx-logout #f)
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
  (cond ((str-empty? (app-proxy)) "在系统设置中填写应用代理")
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
          (cons 'pending (length wx-del)) (cons 'logout wx-logout)
          ;; the login QR code as the proxy sent it: rows of hex, n modules a side
          (cons 'qr (if (and wx-qr (string=? wx-state "login")) wx-qr-key "")) (cons 'qrn wx-qr-n)))

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
    ((string=? name "logout")             ; sent with the next fetch
     (set! wx-logout #t)
     (app-set-url! 0 (wx-url))
     (wx-answer))
    (else (web-error (string-append "unknown call: " name)))))

;; 6. Start ------------------------------------------------------------------------------------------

(wx-load!)
(app-keys! "topic")                    ; beyond t, a..e: the message's topic
(set! app-render-empty-pages '(0))     ; the board's own messages, also before (or without) the proxy

;; For a combined app (apps/lib/combo.scm): wxpusher.news[i], message i (0 the
;; newest), the list when there are fewer
(app-view! "news" 0
           (lambda (items i)
             (let ((m (and (< i (length wx-list)) (list-ref wx-list i))))
               (if m (wx-render-message m) (wx-render-list)))))

(app-define! "WxPusher"
  (list (app-page "消息" wx-url WX-INTERVAL wx-render)))


;;; =========================================================================
;;; Section: build/combo/combo/member_wxpusher.scm
;;; =========================================================================
;; generated by tools/build_apps.py: wxpusher is loaded
(combo-member! "wxpusher" (list "messages")
               (list (cons "proxy_url" "") (cons "converter_url" "")))


;;; =========================================================================
;;; Section: apps/stocks/stocks.scm
;;; =========================================================================
;;; =========================================================================
;;; Stocks (股票行情), 320x480 portrait, on the app framework (applib.scm).
;;; Data: the app proxy's /app/stocks (Tencent quotes). Prices arrive as
;;; text ("1263.00"), changes as signed text ("+0.57"), the intraday trend in
;;; basis points against the previous close, 30-day closes in per-mille
;;; against the first day. Red rises, green falls.
;;;   1 home: indices, the index's intraday chart, the first watch list stocks
;;;   2 watch list   3 intraday charts of three indices   4 30-day trends
;;; =========================================================================

(define STOCKS-INTERVAL 20000)           ; the proxy caches 15 s while trading
(define STOCKS-KLINE-INTERVAL 600000)

(define (stocks-codes) (app-config "codes" "sh600519,sz300750,sz000858"))
(define (stocks-index) (app-config "index" "sh000001"))

(define (stocks-all-url)
  (app-url (string-append "/app/stocks?view=all&codes=" (url-encode (stocks-codes))
                          "&index=" (url-encode (stocks-index)))))

(define (stocks-url view)
  (lambda ()
    (app-url (string-append "/app/stocks?view=" view "&codes=" (url-encode (stocks-codes))
                            "&index=" (url-encode (stocks-index))))))

;; "+0.57" -> 57 (hundredths), for colors and bars
(define (pct-of it) (it-fixed it 3 2))

(define (pct-text it) (string-append (it-c it) "%"))

;; Quote "e": "change,high,low,previous close"
(define (q-change it) (str-part (it-e it) #\, 0))
(define (q-high it) (str-part (it-e it) #\, 1))
(define (q-low it) (str-part (it-e it) #\, 2))

;; "1282.00" -> "1282": four digits are precise enough for a day's range
(define (short-price s)
  (let ((parts (str-split s #\.)))
    (if (>= (string-length (car parts)) 4) (car parts) s)))

;; Change % in a filled box, right-aligned at xr
(define (pct-box xr y it)
  (let* ((t (pct-text it)) (w (max 64 (+ (txt-w t) 12))) (p (pct-of it)))
    (gui-round-rect (- xr w) y w 22 4 (rise-color p) #t)
    (txt-center (- xr (quotient w 2)) (+ y 3) t theme-bg)))

(define (market-badge items)
  (let ((m (items-find items "meta")))
    (if m
        (let* ((t (it-a m)) (open? (equal? t "交易中")) (w (+ (txt-w t) 12)))
          (gui-round-rect (- 310 w) (body-top) w 22 6 (if open? theme-success theme-text-muted) #f)
          (txt (+ (- 310 w) 6) (+ (body-top) 3) t (if open? theme-success theme-text-muted))))))

;; Intraday chart: basis points around the previous close (the zero line);
;; the x axis is the whole trading day (241 minutes), so a morning chart
;; covers only its part of the width
(define (trend-chart x y w h tr)
  (let* ((pts (it-ints tr 1)) (minutes (or (it-int tr 4) 241))
         (m (max 50 (list-max (map abs (if (pair? pts) pts '(0))))))
         (lo (- 0 m)) (hi m)
         (cw (max 8 (quotient (* w (clamp minutes 2 241)) 241)))
         (last (if (pair? pts) (list-ref pts (- (length pts) 1)) 0)))
    (gui-rect x y w h theme-card-hdr #t)
    (gui-line x (+ y (quotient h 2)) (+ x w -1) (+ y (quotient h 2)) theme-divider)  ; previous close
    (gui-line (+ x (quotient w 2)) y (+ x (quotient w 2)) (+ y h -1) theme-divider)  ; 11:30 / 13:00
    (line-chart x y cw h pts lo hi (rise-color last))
    (txt (+ x 2) y (string-append "+" (fixed->str m 2) "%") theme-text-muted)
    (txt (+ x 2) (+ y h -18) (string-append "-" (fixed->str m 2) "%") theme-text-muted)))

;; 1. Home ---------------------------------------------------------------------------

(define (index-tile x y it)
  (gui-round-rect x y 146 54 6 theme-card-border #f)
  (txt (+ x 8) (+ y 5) (it-a it) theme-text-muted)
  (txt-right (+ x 138) (+ y 5) (pct-text it) (rise-color (pct-of it)))
  (txt (+ x 8) (+ y 29) (it-b it) (rise-color (pct-of it)))
  (txt-right (+ x 138) (+ y 29) (q-change it) (rise-color (pct-of it))))

(define (quote-row y it)
  (txt 10 (+ y 2) (it-a it) theme-text-main)
  (txt 10 (+ y 22) (it-d it) theme-text-muted)
  (txt-right 220 (+ y 10) (it-b it) (rise-color (pct-of it)))
  (pct-box 310 (+ y 8) it)
  (gui-line 10 (+ y 43) 310 (+ y 43) theme-divider))

(define (stocks-render-home items)
  (let ((idx (items-all items "idx")) (tr (items-find items "trend")) (qs (items-all items "q")))
    (let loop ((xs idx) (i 0))
      (if (and (pair? xs) (< i 4))
          (begin
            (index-tile (+ 10 (* (remainder i 2) 154)) (+ 38 (* (quotient i 2) 60)) (car xs))
            (loop (cdr xs) (+ i 1)))))
    (if tr
        (let* ((code (it-c tr)) (iq (items-where items "idx" 4 code))
               (e (it-e tr)))
          (txt 10 162 (string-append (if iq (it-a iq) code) " 分时") theme-accent)
          (txt-right 310 162 (string-append "高 " (str-part e #\, 0) "  低 " (str-part e #\, 1)) theme-text-muted)
          (trend-chart 10 184 300 120 tr)))
    (let loop ((xs qs) (y 312) (i 0))
      (if (and (pair? xs) (< i 3))
          (begin (quote-row y (car xs)) (loop (cdr xs) (+ y 46) (+ i 1)))))))

;; 2. Watch list -------------------------------------------------------------------------

(define (stocks-render-list items)
  (market-badge items)
  (let ((qs (items-all items "q")))
    (if (null? qs)
        (txt 14 70 "自选股为空：在应用设置 codes 中填写股票代码" theme-text-muted)
        (let loop ((xs qs) (y (+ (body-top) 28)) (i 0))
          (if (and (pair? xs) (< i 9))
              (let ((it (car xs)))
                (txt 10 y (it-a it) theme-text-main)
                (txt-right 220 y (it-b it) (rise-color (pct-of it)))
                (pct-box 310 (- y 1) it)
                (txt 10 (+ y 20) (string-append (it-d it) " " (q-change it)) theme-text-muted)
                (txt-right 310 (+ y 20) (string-append "高" (short-price (q-high it)) " 低" (short-price (q-low it)))
                           theme-text-muted)
                (gui-line 10 (+ y 41) 310 (+ y 41) theme-divider)
                (loop (cdr xs) (+ y 44) (+ i 1))))))))

;; 3. Index intraday charts ------------------------------------------------------------

(define (stocks-render-trends items)
  (let loop ((trs (items-all items "trend")) (y (body-top)) (i 0))
    (if (and (pair? trs) (< i 3))
        (let* ((tr (car trs)) (iq (items-where items "idx" 4 (it-c tr))))
          (txt 10 y (if iq (it-a iq) (it-c tr)) theme-accent)
          (if iq
              (begin
                (txt-right 236 y (it-b iq) (rise-color (pct-of iq)))
                (txt-right 310 y (pct-text iq) (rise-color (pct-of iq)))))
          (trend-chart 10 (+ y 22) 300 108 tr)
          (loop (cdr trs) (+ y 138) (+ i 1))))))

;; 4. 30-day trends -----------------------------------------------------------------------

(define (kline-card x y it)
  (let* ((pts (it-ints it 2)) (pct (it-fixed it 4 1)) (r (series-range pts 20)))
    (gui-round-rect x y 146 132 6 theme-card-border #f)
    (txt-fit (+ x 8) (+ y 5) 130 (it-a it) theme-text-main)
    (txt (+ x 8) (+ y 26) (it-c it) theme-text-sub)
    (txt-right (+ x 138) (+ y 26) (string-append (it-d it) "%") (rise-color pct))
    (line-chart (+ x 6) (+ y 50) 134 76 pts (car r) (cdr r) (rise-color pct))))

(define (stocks-render-kline items)
  (let ((ks (items-all items "k")))
    (if (null? ks)
        (txt 14 70 "暂无走势数据" theme-text-muted)
        (let loop ((xs ks) (i 0))
          (if (and (pair? xs) (< i 6))
              (begin
                (kline-card (+ 10 (* (remainder i 2) 154)) (+ (body-top) (* (quotient i 2) 138)) (car xs))
                (loop (cdr xs) (+ i 1))))))))

;; Pages -----------------------------------------------------------------------------------------

(app-define! "股票行情"
  (list (app-page "首页" (stocks-url "home") STOCKS-INTERVAL stocks-render-home)
        (app-page "自选股" (stocks-url "list") STOCKS-INTERVAL stocks-render-list)
        (app-page "指数分时" (stocks-url "trend") STOCKS-INTERVAL stocks-render-trends)
        (app-page "30日走势" (stocks-url "kline") STOCKS-KLINE-INTERVAL stocks-render-kline)))

(set! app-subtitle-proc
      (lambda (items) (let ((m (items-find items "meta"))) (if m (it-a m) #f))))


;;; =========================================================================
;;; Section: build/combo/combo/member_stocks.scm
;;; =========================================================================
;; generated by tools/build_apps.py: stocks is loaded
(combo-member! "stocks" (list "front" "watchlist" "intraday" "trend30")
               (list (cons "codes" "sh600519,sz300750,sz000858,sh601318,sz002594") (cons "index" "sh000001") (cons "carousel" "") (cons "carousel_seconds" "") (cons "proxy_url" "") (cons "converter_url" "")))


;;; =========================================================================
;;; Section: build/combo/combo/start.scm
;;; =========================================================================
;; generated by tools/build_apps.py: the entries become this app's pages
(combo-start! "合集")

